-- ─────────────────────────────────────────────────────────────────────
-- 20260819_workshop_series_start_date
-- ─────────────────────────────────────────────────────────────────────
--
-- Persists the real first-occurrence date of a recurring series, and
-- exposes idempotent RPCs to materialise any missing weekly
-- `scheduled_workshops` rows from that start date to today.
--
-- Why this exists:
--   The legacy generator (`generate_weekly_workshops(p_week_start)`)
--   materialises exactly ONE week when invoked. Weeks that were never
--   generated stay missing forever. Diagnostic on 2026-08-17 showed
--   Marți-Robotică missing 28-Jul + 4-Aug (child had presents on 21-Jul
--   and 11-Aug but nothing in between), and Engleză missing 24-Jul,
--   31-Jul, 7-Aug, 14-Aug (huge gap). The 2026-08-18 auto-backfill from
--   the workshop-form only fires on CREATE — existing series stayed
--   broken.
--
-- Fix:
--   1. Add `workshop_series.start_date date` (nullable). Backfill it
--      from the earliest known `scheduled_workshops.workshop_date` per
--      series (matching either canonical `series_id` OR legacy
--      `recurring_series_id`).
--   2. `ensure_series_backfilled(uuid)` — reads start_date, iterates
--      weekly to today via `backfill_series_sessions`. Idempotent.
--      Skips existing (series_id, workshop_date) pairs regardless of
--      active/archived state — cancelled sessions stay cancelled.
--   3. `ensure_child_series_backfilled(uuid)` — iterates the child's
--      active enrollments, calls #2 for each. Returns a jsonb summary.
--      Cheap to call on every calendar open (~1 RPC per open, most
--      series have 0 missing sessions).
--
-- Additive + idempotent. Safe to re-run.
-- ─────────────────────────────────────────────────────────────────────

-- ── 1. Add start_date column ─────────────────────────────────────────
alter table public.workshop_series
  add column if not exists start_date date;

comment on column public.workshop_series.start_date is
  'First date of the recurring series. Immutable after creation. '
  'Consumed by ensure_series_backfilled() to materialise missing '
  'weekly scheduled_workshops rows.';

-- ── 2. Backfill start_date for existing series ───────────────────────
update public.workshop_series ws
   set start_date = subq.min_date
  from (
    select coalesce(sw.series_id, sw.recurring_series_id) as sid,
           min(sw.workshop_date) as min_date
      from public.scheduled_workshops sw
     where coalesce(sw.series_id, sw.recurring_series_id) is not null
     group by coalesce(sw.series_id, sw.recurring_series_id)
  ) subq
 where subq.sid = ws.id
   and ws.start_date is null;

-- ── 3. Per-series backfill helper ────────────────────────────────────
create or replace function public.ensure_series_backfilled(p_series_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date;
begin
  -- Prefer stored start_date; fall back to derived (defensive for any
  -- edge case where a series has no start_date after the migration).
  select coalesce(
    ws.start_date,
    (select min(sw.workshop_date)
       from public.scheduled_workshops sw
      where sw.series_id = ws.id
         or sw.recurring_series_id = ws.id)
  )
  into v_start
  from public.workshop_series ws
  where ws.id = p_series_id;

  if v_start is null then
    -- No history at all — nothing to backfill.
    return 0;
  end if;

  -- Heal missing start_date opportunistically so next call skips the
  -- coalesce lookup.
  update public.workshop_series
     set start_date = v_start
   where id = p_series_id and start_date is null;

  return public.backfill_series_sessions(p_series_id, v_start, current_date);
end;
$$;

comment on function public.ensure_series_backfilled(uuid) is
  'Idempotent: materialises every missing weekly scheduled_workshops '
  'row for the series between its start_date and today. Existing rows '
  '(active or cancelled) are left untouched.';

revoke all on function public.ensure_series_backfilled(uuid) from public;
grant execute on function public.ensure_series_backfilled(uuid)
  to authenticated, service_role;

-- ── 4. Per-child aggregator RPC ──────────────────────────────────────
create or replace function public.ensure_child_series_backfilled(
  p_child_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_series_id uuid;
  v_total_inserted int := 0;
  v_series_count int := 0;
  v_inserted int;
  v_per_series jsonb := '[]'::jsonb;
begin
  for v_series_id in
    select series_id from public.workshop_enrollments
     where child_id = p_child_id and is_active = true
  loop
    v_inserted := public.ensure_series_backfilled(v_series_id);
    v_total_inserted := v_total_inserted + v_inserted;
    v_series_count := v_series_count + 1;
    if v_inserted > 0 then
      v_per_series := v_per_series || jsonb_build_object(
        'series_id', v_series_id,
        'inserted', v_inserted
      );
    end if;
  end loop;

  return jsonb_build_object(
    'child_id', p_child_id,
    'series_scanned', v_series_count,
    'total_inserted', v_total_inserted,
    'per_series', v_per_series
  );
end;
$$;

comment on function public.ensure_child_series_backfilled(uuid) is
  'Idempotent: ensures every recurring series the child is currently '
  'enrolled in has all its weekly scheduled_workshops materialised '
  'from series.start_date to today. Called on calendar open.';

revoke all on function public.ensure_child_series_backfilled(uuid)
  from public;
grant execute on function public.ensure_child_series_backfilled(uuid)
  to authenticated, service_role;
