-- ─────────────────────────────────────────────────────────────────────
-- 20260828_deactivate_enrollments_for_archived_series
-- ─────────────────────────────────────────────────────────────────────
--
-- Reported bug (2026-08-18): the archived series "MIERCURI - Modelare 3D"
-- keeps appearing in:
--   * the children-list filter dropdown "Toate atelierele"
--   * the workshop chip on a child's row (Leon Leizer in the screenshot)
--   * the child details "Atelierul la care vine" section (via
--     childWorkshopSeriesProvider)
--
-- Root cause: `cancelWorkshopSeries` (Dart) correctly flips both
-- `workshop_series.is_active = false` AND
-- `workshop_enrollments.is_active = false` for enrolled children. But
-- the Modelare 3D series was archived through a legacy flow (proof:
-- 20260825 had to normalise its `archived_at` from NULL to a real
-- timestamp). That legacy flow never cascaded to enrollments, so
-- `workshop_enrollments.is_active = true` lingered on rows whose
-- series is dead. Every UI surface that lists a child's active
-- workshops picks them up.
--
-- Fix: one-shot cleanup — for every workshop_series that is
-- inactive/archived, set its still-active enrollments to inactive.
-- Preserves the enrollment row itself as an audit trail (matches the
-- current Dart flow which never deletes enrollments).
--
-- Idempotent + non-destructive.
-- ─────────────────────────────────────────────────────────────────────

update public.workshop_enrollments we
   set is_active = false
  from public.workshop_series ws
 where we.series_id = ws.id
   and we.is_active = true
   and (ws.is_active = false or ws.archived_at is not null);

do $$
declare
  v_left int;
begin
  select count(*) into v_left
    from public.workshop_enrollments we
    join public.workshop_series ws on ws.id = we.series_id
   where we.is_active = true
     and (ws.is_active = false or ws.archived_at is not null);
  raise notice 'Post-cleanup: % active enrollments still point to archived series (should be 0).',
    v_left;
end$$;
