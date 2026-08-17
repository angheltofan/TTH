-- ─────────────────────────────────────────────────────────────────────
-- 20260818_backfill_series_sessions
-- ─────────────────────────────────────────────────────────────────────
--
-- New RPC: `backfill_series_sessions(p_series_id, p_from_date, p_to_date)`.
--
-- Purpose: when an admin creates a recurring workshop with a start date
-- in the past (e.g. today is Aug 17 but "start of series = Jul 7"), the
-- weekly generator only materialises the CURRENT week going forward.
-- This RPC fills in the missing past weeks so the historical attendance
-- calendar has real `scheduled_workshops` rows to hang attendance on.
--
-- Behavior:
--   • Iterates weekly from p_from_date (inclusive) to p_to_date (inclusive,
--     defaulting to today).
--   • For each week, picks the correct weekday from the series'
--     `day_of_week` (Romanian; tolerant of "Marti"/"Marți" variants —
--     matches the existing generate_weekly_workshops logic).
--   • Inserts a scheduled_workshops row unless one already exists for
--     (series_id, workshop_date) — matches either the canonical series_id
--     or the legacy recurring_series_id column. Idempotent: safe to
--     re-run.
--   • Never touches attendance, workshop_enrollments, or existing
--     scheduled_workshops rows (so cancelled sessions stay cancelled).
--   • SECURITY DEFINER so the RPC can bypass RLS on scheduled_workshops
--     when the caller is admin/trainer — matches generate_weekly_workshops.
--
-- Returns the integer count of rows actually inserted.
-- ─────────────────────────────────────────────────────────────────────

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
         start_time, end_time, trainer_id
    into v_series
    from public.workshop_series
   where id = p_series_id;
  if v_series.id is null then
    raise exception 'workshop_series % not found', p_series_id;
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

  -- Anchor iteration at the Monday of p_from_date's ISO week.
  v_week_start := p_from_date
    - ((extract(isodow from p_from_date)::int) - 1);

  while v_week_start <= v_end loop
    v_target_date := v_week_start + v_dow_index;

    -- Skip weeks whose target day falls outside the range [p_from_date, v_end].
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

comment on function public.backfill_series_sessions(uuid, date, date) is
  'Materialises weekly scheduled_workshops rows for a series from p_from_date '
  'to p_to_date (default today). Idempotent — skips any (series_id, '
  'workshop_date) that already exists. Called after admin creates a '
  'recurring workshop with a historical start date so past sessions '
  'appear in the attendance calendar.';

revoke all on function public.backfill_series_sessions(uuid, date, date)
  from public;
grant execute on function public.backfill_series_sessions(uuid, date, date)
  to authenticated, service_role;
