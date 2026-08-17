-- ─────────────────────────────────────────────────────────────────────
-- 20260822_drop_legacy_views
-- ─────────────────────────────────────────────────────────────────────
--
-- Removes five pre-series-refactor views that assumed one global cycle
-- per child. Since the per-(child, series) refactor (2026-08-20) and
-- the chronological-classification fix (2026-08-21), the Dart layer
-- reads directly from base tables and aggregates client-side. A
-- codebase audit on 2026-08-22 confirmed there are no remaining Dart
-- callers watching the Riverpod providers backed by these views.
--
-- Views dropped:
--   • child_current_status          (per-child cycle summary; superseded
--                                    by CurrentStatusCard's per-series
--                                    grouping over the attendance table)
--   • child_payment_status_rows     (per-attendance × cycle join; the
--                                    new PaymentStatusCard rebuilds
--                                    groups from payment_cycles +
--                                    attendance chronologically)
--   • child_current_cycle_summary   (unused since PaymentStatusCard
--                                    refactor)
--   • child_current_cycle_activity  (idem)
--   • child_activity_history        (only consumer was
--                                    getActivityHistory, no live watcher)
--
-- Safety: `drop view if exists`, no cascade — if any hidden object
-- depends on these, the migration errors out cleanly and I re-inspect
-- before pushing again.
-- ─────────────────────────────────────────────────────────────────────

drop view if exists public.child_current_status;
drop view if exists public.child_payment_status_rows;
drop view if exists public.child_current_cycle_summary;
drop view if exists public.child_current_cycle_activity;
drop view if exists public.child_activity_history;
