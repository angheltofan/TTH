-- ============================================================================
-- Production-launch indexes — PROPOSED, DO NOT PUSH WITHOUT REVIEW
--
-- Read-only audit recommendation. Every CREATE INDEX uses `IF NOT EXISTS`
-- so applying this migration against a database where the index already
-- lives is a no-op. None of these add columns, change types, or affect
-- RLS — the only DB effect is creating indexes.
--
-- Source of truth: the queries enumerated in the Phase 2 audit report.
-- Each index is annotated with the exact filter / order / join pattern
-- that benefits from it and the read paths involved.
--
-- File renamed with `_PROPOSED` suffix on purpose so `supabase db push`
-- does not pick it up by accident.
-- ============================================================================

-- ── 1. attendance ───────────────────────────────────────────────────────────
--
-- Backs every "current cycle" lookup. The combination filters down to a
-- small fraction of rows per child, so a multi-column btree is the right
-- shape. Used by:
--   * child_details_repository.fetchChildCurrentStatusRows
--     (attendance WHERE child_id = ? AND payment_cycle_id IS NULL
--      AND is_archived = false)
--   * parent_dashboard_repository.buildSummaryForChild (paid path)
--     (same shape + status='present')
CREATE INDEX IF NOT EXISTS idx_attendance_child_open_block
  ON public.attendance (child_id, is_archived, payment_cycle_id);

-- Backs workshop_details_repository + attendance ranking tools in the
-- assistant. Filter is `scheduled_workshop_id = ? AND is_archived = false`.
CREATE INDEX IF NOT EXISTS idx_attendance_workshop_active
  ON public.attendance (scheduled_workshop_id, is_archived);

-- Backs every date-windowed attendance read: the assistant's
-- toolGetWorkshopAttendanceAnalysis, monthly management report,
-- toolGetAttendanceByWorkshopRankings, toolGetMonthSummary, etc. The
-- common shape is `WHERE marked_at >= ? AND marked_at <= ? AND
-- is_archived = false`. Without this index every report scans the full
-- attendance table.
CREATE INDEX IF NOT EXISTS idx_attendance_marked_at_active
  ON public.attendance (marked_at, is_archived);

-- ── 2. payment_cycles ───────────────────────────────────────────────────────
--
-- Per-child cycle history (child_details "Status plată" + parent
-- dashboard "latest cycle" lookup).
CREATE INDEX IF NOT EXISTS idx_payment_cycles_child_status
  ON public.payment_cycles (child_id, status);

-- Backs:
--   * payments-due page (`status IN ('due','overdue')` plus a children
--     join — the join column on children.payment_type already has
--     `idx_children_payment_type`, so the planner can pick either
--     side first depending on selectivity)
--   * assistant get_recent_confirmed_payments / get_advance_paid_cycles
--   * monthly management report's payment aggregation
-- The (status, paid_at) order keeps recent paid-cycles cheap to fetch.
CREATE INDEX IF NOT EXISTS idx_payment_cycles_status_paid_at
  ON public.payment_cycles (status, paid_at);

-- ── 3. workshop_enrollments ─────────────────────────────────────────────────
--
-- Two complementary indexes — one per access direction. is_active=true is
-- the universal filter for every consumer.
CREATE INDEX IF NOT EXISTS idx_workshop_enrollments_series_active
  ON public.workshop_enrollments (series_id, is_active);

CREATE INDEX IF NOT EXISTS idx_workshop_enrollments_child_active
  ON public.workshop_enrollments (child_id, is_active);

-- ── 4. scheduled_workshops ──────────────────────────────────────────────────
--
-- Dashboard "today" and "this week" lookups:
--   `WHERE workshop_date = today AND is_active = true ORDER BY start_time`
--   `WHERE workshop_date BETWEEN monday AND sunday AND is_active = true`
CREATE INDEX IF NOT EXISTS idx_scheduled_workshops_date_active
  ON public.scheduled_workshops (workshop_date, is_active);

-- Used by workshops_repository.getFutureScheduledForSeries:
--   `WHERE (series_id = ? OR recurring_series_id = ?) AND workshop_date >= ?`
-- Two separate single-column indexes let the planner OR-them together. A
-- composite (series_id, workshop_date) is cheap and covers the canonical
-- series_id path; the legacy `recurring_series_id` is intentionally
-- indexed separately because the OR-rewrite would otherwise force a
-- sequential scan.
CREATE INDEX IF NOT EXISTS idx_scheduled_workshops_series_date
  ON public.scheduled_workshops (series_id, workshop_date);

CREATE INDEX IF NOT EXISTS idx_scheduled_workshops_recurring_series_date
  ON public.scheduled_workshops (recurring_series_id, workshop_date)
  WHERE recurring_series_id IS NOT NULL;

-- ── 5. notifications ────────────────────────────────────────────────────────
--
-- Every notification read filters on `recipient_id = ?` and one of:
--   `is_read = false` (bell badge)
--   `expires_at IS NULL OR expires_at > now()` (list / bell)
-- A 3-column index covers both paths.
CREATE INDEX IF NOT EXISTS idx_notifications_recipient_read_expires
  ON public.notifications (recipient_id, is_read, expires_at);

-- ── 6. children ─────────────────────────────────────────────────────────────
--
-- `idx_children_payment_type` (children.payment_type) ALREADY EXISTS in
-- `20260618_children_payment_type.sql` — no duplicate.
--
-- Active-only filters appear on every children-list path. With the
-- typical 0.6:0.4 active:inactive ratio in this app, a partial index on
-- `is_active = true` lowers the cost of `WHERE is_active = true` reads
-- without bloating index size.
CREATE INDEX IF NOT EXISTS idx_children_is_active
  ON public.children (is_active)
  WHERE is_active = true;

-- ── 7. Conditional indexes for tables that MAY NOT EXIST ────────────────────
--
-- `child_progress` and `lesson_materials` are flagged in docs/database_schema.md
-- as "future-feature placeholders — unknown if present in DB". The
-- assistant tools (`toolGetProgressSummary`, `toolGetMaterialsSummary`,
-- etc.) wrap reads in `safeProgressFetch` / `safeMaterialsFetch` which
-- detect 42P01 / PGRST205 and degrade gracefully.
--
-- The DO blocks below create the recommended indexes ONLY if the table
-- exists, so this migration is safe to apply against any environment.
-- If the table is later created, the index should be added explicitly.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'child_progress'
  ) THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_child_progress_child_created '
            'ON public.child_progress (child_id, created_at DESC)';
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'lesson_materials'
  ) THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_lesson_materials_type_active '
            'ON public.lesson_materials (workshop_type, is_active)';
  END IF;
END $$;
