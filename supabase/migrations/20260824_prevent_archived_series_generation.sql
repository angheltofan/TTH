-- ─────────────────────────────────────────────────────────────────────
-- 20260824_prevent_archived_series_generation
-- ─────────────────────────────────────────────────────────────────────
--
-- Reported bug (2026-08-18): archived workshop series reappear every
-- week in the app. Diagnostic on production data confirmed:
--
--   series `MIERCURI - Modelare 3D` (d27fc938-…) has
--   `workshop_series.is_active = false` (correctly archived) yet a NEW
--   `scheduled_workshops` row was auto-created on 2026-08-17 for
--   workshop_date 2026-08-19.
--
-- Root cause: `generate_recurring_workshops_for_week` builds its
-- template pool from `scheduled_workshops` filtered ONLY by
-- `sw.is_active = true`. It never joins `workshop_series` to check
-- whether the parent series is active. So as long as any old scheduled
-- session in the series is still `is_active = true`, the weekly
-- generator picks it as template and materialises a new row for the
-- current week — bypassing the series-level archive.
--
-- Fix: join `workshop_series` and additionally require
-- `ws.is_active = true AND ws.archived_at is null`. Both flags are
-- checked because historical archive flows haven't always set both
-- (the diagnostic showed a series with is_active=false but
-- archived_at=null).
--
-- Same guard applied to `backfill_series_sessions` — otherwise
-- opening the calendar for a child still enrolled in an archived
-- series would silently re-generate the historic sessions on demand.
--
-- Cleanup: any scheduled_workshops rows that were created for
-- archived series and still show as active are:
--   - soft-cancelled (is_active=false + archived_at=now()) if they
--     have attendance rows (preserve history)
--   - hard-deleted if they have no attendance
--
-- Additive + idempotent. Safe to re-run.
-- ─────────────────────────────────────────────────────────────────────

-- ── 1. Fix weekly generator ──────────────────────────────────────────
create or replace function public.generate_recurring_workshops_for_week(
  p_week_start date
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  created_count integer;
begin
  with latest_source as (
    select distinct on (coalesce(sw.series_id, sw.recurring_series_id))
      sw.*
    from public.scheduled_workshops sw
    join public.workshop_series ws
      on ws.id = coalesce(sw.series_id, sw.recurring_series_id)
    where sw.is_recurring = true
      and sw.is_active = true
      and coalesce(sw.series_id, sw.recurring_series_id) is not null
      and sw.title not ilike 'ISTORIC%'
      -- NEW guard: series itself must be active + not archived.
      and ws.is_active = true
      and ws.archived_at is null
    order by
      coalesce(sw.series_id, sw.recurring_series_id),
      sw.workshop_date desc
  ),
  to_insert as (
    select
      ls.id as source_id,
      ls.title,
      ls.workshop_type,
      (
        p_week_start
        + ((extract(isodow from ls.workshop_date)::int - 1) || ' days')::interval
      )::date as new_date,
      ls.day_of_week,
      ls.start_time,
      ls.end_time,
      ls.trainer_id,
      ls.notes,
      coalesce(ls.series_id, ls.recurring_series_id) as resolved_series_id,
      ls.is_recurring
    from latest_source ls
  ),
  inserted as (
    insert into public.scheduled_workshops (
      title, workshop_type, workshop_date, day_of_week,
      start_time, end_time, trainer_id, notes,
      is_active, series_id, recurring_series_id, is_recurring
    )
    select
      ti.title, ti.workshop_type, ti.new_date, ti.day_of_week,
      ti.start_time, ti.end_time, ti.trainer_id, ti.notes,
      true, ti.resolved_series_id, ti.resolved_series_id, true
    from to_insert ti
    where not exists (
      select 1 from public.scheduled_workshops sw
      where coalesce(sw.series_id, sw.recurring_series_id) = ti.resolved_series_id
        and sw.workshop_date = ti.new_date
    )
    returning id, series_id, workshop_date
  )
  select count(*) into created_count from inserted;
  return created_count;
end;
$$;

comment on function public.generate_recurring_workshops_for_week(date) is
  'Materialises one scheduled_workshops row per active workshop_series '
  'for the week containing p_week_start. Skips series whose is_active is '
  'false OR archived_at is set. Idempotent (no duplicate rows per '
  'series+date). Since 2026-08-24 (fix for archived-reappear bug).';

-- ── 2. Same guard on backfill_series_sessions ────────────────────────
create or replace function public.backfill_series_sessions(
  p_series_id uuid,
  p_from_date date,
  p_to_date date default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_series      record;
  v_dow_index   int;
  v_week_start  date;
  v_target_date date;
  v_end         date;
  v_inserted    int := 0;
begin
  if p_series_id is null or p_from_date is null then
    raise exception 'p_series_id and p_from_date are required';
  end if;

  v_end := coalesce(p_to_date, current_date);
  if v_end < p_from_date then
    return 0;
  end if;

  select id, title, workshop_type, day_of_week,
         start_time, end_time, trainer_id, is_active, archived_at
    into v_series
    from public.workshop_series
   where id = p_series_id;
  if v_series.id is null then
    raise exception 'workshop_series % not found', p_series_id;
  end if;

  -- NEW guard: refuse to backfill for archived / inactive series.
  -- Prevents `ensure_series_backfilled` (called on calendar open) from
  -- silently re-generating historic sessions for a series the admin
  -- has explicitly retired.
  if v_series.is_active = false or v_series.archived_at is not null then
    return 0;
  end if;

  v_dow_index := case lower(coalesce(v_series.day_of_week, ''))
    when 'luni'      then 0
    when 'marti'     then 1
    when 'marți'     then 1
    when 'miercuri'  then 2
    when 'joi'       then 3
    when 'vineri'    then 4
    when 'sambata'   then 5
    when 'sâmbătă'   then 5
    when 'duminica'  then 6
    when 'duminică'  then 6
    else null
  end;
  if v_dow_index is null then
    raise exception 'unrecognised day_of_week: %', v_series.day_of_week;
  end if;

  v_week_start := p_from_date
    - ((extract(isodow from p_from_date)::int) - 1);

  while v_week_start <= v_end loop
    v_target_date := v_week_start + v_dow_index;
    if v_target_date >= p_from_date and v_target_date <= v_end then
      if not exists (
        select 1 from public.scheduled_workshops sw
         where sw.workshop_date = v_target_date
           and (sw.series_id = p_series_id
             or sw.recurring_series_id = p_series_id)
      ) then
        insert into public.scheduled_workshops (
          title, workshop_type, workshop_date, day_of_week,
          start_time, end_time, trainer_id, series_id,
          recurring_series_id, is_active, is_recurring
        ) values (
          v_series.title, v_series.workshop_type, v_target_date,
          v_series.day_of_week, v_series.start_time, v_series.end_time,
          v_series.trainer_id, p_series_id, p_series_id, true, true
        );
        v_inserted := v_inserted + 1;
      end if;
    end if;
    v_week_start := v_week_start + 7;
  end loop;

  return v_inserted;
end;
$$;

-- ── 3. Cleanup orphan rows already created for archived series ──────
do $$
declare
  v_ws record;
  v_has_attendance boolean;
  v_deleted int := 0;
  v_archived int := 0;
begin
  for v_ws in
    select sw.id, sw.workshop_date, sw.title,
           coalesce(sw.series_id, sw.recurring_series_id) as series_id
    from public.scheduled_workshops sw
    join public.workshop_series ws
      on ws.id = coalesce(sw.series_id, sw.recurring_series_id)
    where sw.is_active = true
      and sw.archived_at is null
      and (ws.is_active = false or ws.archived_at is not null)
  loop
    select exists (
      select 1 from public.attendance
      where scheduled_workshop_id = v_ws.id
    ) into v_has_attendance;

    if v_has_attendance then
      update public.scheduled_workshops
        set is_active = false,
            archived_at = now(),
            archived_reason = coalesce(archived_reason, '') ||
              E'\n[20260824: seria a fost arhivată dar sesiunea a fost regenerată automat înainte de fix. Sesiunea are prezențe — soft-arhivată pentru păstrarea istoricului.]'
        where id = v_ws.id;
      v_archived := v_archived + 1;
      raise notice 'Soft-archived orphan: % (%) [%]',
        v_ws.title, v_ws.workshop_date, v_ws.id;
    else
      delete from public.scheduled_workshops where id = v_ws.id;
      v_deleted := v_deleted + 1;
      raise notice 'Hard-deleted orphan: % (%) [%]',
        v_ws.title, v_ws.workshop_date, v_ws.id;
    end if;
  end loop;

  raise notice 'Orphan cleanup complete: % deleted, % soft-archived',
    v_deleted, v_archived;
end$$;
