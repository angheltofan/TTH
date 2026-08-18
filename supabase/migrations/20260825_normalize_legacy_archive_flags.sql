-- ─────────────────────────────────────────────────────────────────────
-- 20260825_normalize_legacy_archive_flags
-- ─────────────────────────────────────────────────────────────────────
--
-- Housekeeping. The current `cancelWorkshopSeries` flow in Dart sets
-- BOTH `is_active = false` AND `archived_at = now()` — but historical
-- archive flows (before the schema added `archived_at`) only flipped
-- `is_active`. Production had 1 confirmed inconsistent row on 2026-08-18
-- (MIERCURI - Modelare 3D). The 20260824 fix guards on both flags so
-- the bug can't recur, but the inconsistent rows should still be
-- normalised so:
--   • diagnostics / reports that filter on `archived_at is not null`
--     don't miss them
--   • the state matches what the app now writes
--
-- Strategy: set `archived_at = coalesce(updated_at, created_at, now())`
-- on any row that has `is_active = false` AND `archived_at is null`,
-- for both `workshop_series` and `scheduled_workshops`. Uses
-- `updated_at` first (most likely = the archive moment) then falls back
-- gracefully. Never overwrites an existing `archived_at`.
--
-- Idempotent + non-destructive.
-- ─────────────────────────────────────────────────────────────────────

update public.workshop_series
   set archived_at = coalesce(updated_at, created_at, now())
 where is_active = false
   and archived_at is null;

update public.scheduled_workshops
   set archived_at = coalesce(updated_at, created_at, now())
 where is_active = false
   and archived_at is null;

-- Emit a NOTICE with the counts so the push log shows the impact.
do $$
declare
  v_series_left int;
  v_sw_left int;
begin
  select count(*) into v_series_left
    from public.workshop_series
   where is_active = false and archived_at is null;
  select count(*) into v_sw_left
    from public.scheduled_workshops
   where is_active = false and archived_at is null;
  raise notice 'Post-normalize: %(workshop_series) + %(scheduled_workshops) rows still inconsistent (should be 0).',
    v_series_left, v_sw_left;
end$$;
