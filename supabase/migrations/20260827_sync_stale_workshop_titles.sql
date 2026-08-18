-- ─────────────────────────────────────────────────────────────────────
-- 20260827_sync_stale_workshop_titles
-- ─────────────────────────────────────────────────────────────────────
--
-- Reported bug (2026-08-18): renaming a workshop leaves the old name
-- visible everywhere in the app that reads from
-- `scheduled_workshops.title` — dashboard cards, calendar history,
-- PDF reports, attendance timelines. The client-side
-- `WorkshopsRepository.updateSeries` was propagating identity fields
-- only to future + active rows; past + cancelled rows kept their
-- stale copy of the title.
--
-- The Dart fix (same PR) now propagates identity fields (title,
-- workshop_type, notes) to ALL scheduled_workshops for the series
-- going forward. This migration performs the one-shot heal for rows
-- that were left stale by the pre-fix behaviour: every
-- scheduled_workshops row whose title/workshop_type/notes differ from
-- the parent workshop_series gets synchronised in-place.
--
-- Only aligns identity fields — day_of_week / start_time / end_time /
-- trainer_id remain per-occurrence (a rescheduled or reassigned
-- session must not be overwritten by the series' current schedule).
--
-- Idempotent (no-op on re-run once titles match). No FK / RLS / trigger
-- surface changes.
-- ─────────────────────────────────────────────────────────────────────

update public.scheduled_workshops sw
   set title         = ws.title,
       workshop_type = ws.workshop_type,
       notes         = coalesce(sw.notes, ws.notes)
  from public.workshop_series ws
 where coalesce(sw.series_id, sw.recurring_series_id) = ws.id
   and (sw.title         is distinct from ws.title
     or sw.workshop_type is distinct from ws.workshop_type);

do $$
declare
  v_left int;
begin
  select count(*) into v_left
    from public.scheduled_workshops sw
    join public.workshop_series ws
      on coalesce(sw.series_id, sw.recurring_series_id) = ws.id
   where sw.title is distinct from ws.title
      or sw.workshop_type is distinct from ws.workshop_type;
  raise notice 'Post-sync: % scheduled_workshops still drift from series identity (should be 0).',
    v_left;
end$$;
