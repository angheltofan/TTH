-- ============================================================================
-- generate_weekly_workshops — idempotent
--
-- Replaces the prior `generate_weekly_workshops(date)` RPC body with a
-- version that:
--
--   1. Iterates the active `workshop_series` rows.
--   2. Materialises one `scheduled_workshops` row per series for the
--      target Monday-to-Sunday window, using each series' `day_of_week`
--      to pick the exact date inside the window.
--   3. **Skips the insert when a row already exists for that
--      (series_id, workshop_date) tuple — regardless of `is_active`.**
--      This is the fix for the "cancelled session reappears next week"
--      bug: previously the generator could re-insert a session for a
--      series + date combination after the admin had soft-cancelled it
--      via `cancelSession()` (which sets `is_active = false`).
--
-- The new body is intentionally conservative: it only INSERTs missing
-- rows. It never UPDATEs existing rows (so cancelled sessions stay
-- cancelled), never deletes anything, and never touches `attendance` or
-- `workshop_enrollments`.
--
-- Returns the integer count of rows actually inserted.
-- ============================================================================

create or replace function public.generate_weekly_workshops(p_week_start date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_series       record;
  v_target_date  date;
  v_dow_index    int;
  v_inserted     int := 0;
begin
  -- Normalise p_week_start to its Monday (ISO weekday 1) so callers
  -- can pass any day inside the target week.
  p_week_start := p_week_start - ((extract(isodow from p_week_start)::int) - 1);

  for v_series in
    select id, title, workshop_type, day_of_week, start_time, end_time,
           trainer_id, is_active
      from public.workshop_series
     where is_active = true
  loop
    -- Map the series' Romanian day_of_week to an offset 0..6 inside
    -- the Monday-anchored window. Tolerant of trailing diacritic
    -- variants ("Marți" / "Marti", "Miercuri", etc.).
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
      continue;
    end if;

    v_target_date := p_week_start + v_dow_index;

    -- Idempotency guard. If ANY scheduled_workshops row already exists
    -- for this series on this date — active OR inactive (cancelled),
    -- canonical `series_id` OR legacy `recurring_series_id` — skip.
    -- Cancelled sessions therefore stay cancelled across regenerations.
    if exists (
      select 1
        from public.scheduled_workshops sw
       where sw.workshop_date = v_target_date
         and (sw.series_id           = v_series.id
              or sw.recurring_series_id = v_series.id)
    ) then
      continue;
    end if;

    insert into public.scheduled_workshops (
      title, workshop_type, workshop_date, day_of_week,
      start_time, end_time, trainer_id, series_id, is_active
    )
    values (
      v_series.title, v_series.workshop_type, v_target_date,
      v_series.day_of_week, v_series.start_time, v_series.end_time,
      v_series.trainer_id, v_series.id, true
    );

    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end;
$$;

comment on function public.generate_weekly_workshops(date) is
  'Materialises scheduled_workshops for the week containing p_week_start. '
  'Idempotent: skips any (series_id, workshop_date) combination that '
  'already exists, regardless of is_active. Cancelled sessions are NOT '
  're-created. Returns the number of inserted rows.';
