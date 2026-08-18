-- ─────────────────────────────────────────────────────────────────────
-- 20260823_attendance_delete_trainer
-- ─────────────────────────────────────────────────────────────────────
--
-- Reason: the "Șterge prezența" button (added 2026-08-21) was gated to
-- admins only. Trainers reported that on mobile PWA they could not
-- delete a wrongly-marked attendance for their own workshops even
-- though they can UPDATE the same row (via the existing
-- `attendance_update_admin_or_trainer` policy). This is inconsistent
-- and blocked a legitimate correction path.
--
-- Fix: replace the admin-only DELETE policy with one that mirrors the
-- UPDATE policy. Trainer can DELETE attendance rows for scheduled
-- workshops they own; admin retains full access.
--
-- The Flutter UI already computes "canEditWorkshop" as
-- `isAdmin OR (isTrainer AND s.trainerId == profile.id)` for the
-- Prezent/Absent buttons; the delete button now follows the same rule.
--
-- The trigger `trg_recalculate_cycles_on_attendance` fires on DELETE
-- and re-runs the per-(child, series) recalc, so the payment cycle
-- consistency guarantees hold regardless of who deletes the row.
-- ─────────────────────────────────────────────────────────────────────

drop policy if exists attendance_delete_admin on public.attendance;

create policy attendance_delete_admin_or_trainer
  on public.attendance
  for delete
  using (
    is_admin() or is_trainer_for_scheduled_workshop(scheduled_workshop_id)
  );

comment on policy attendance_delete_admin_or_trainer on public.attendance is
  'Admin can delete any attendance row. Trainer can delete rows only '
  'for scheduled_workshops they own. Mirrors the UPDATE policy so the '
  'trainer''s correction flow is consistent across UPDATE and DELETE. '
  'Recalc trigger keeps payment cycles consistent on DELETE.';
