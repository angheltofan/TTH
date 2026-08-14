-- ────────────────────────────────────────────────────────────────────
-- 20260623_workshop_soft_delete — PROPOSED, do not push without review
-- ────────────────────────────────────────────────────────────────────
--
-- Preserves child attendance history when a workshop is retired.
--
-- Design principles
--   • Attendance is append-only history: the app is being changed to
--     stop issuing DELETE FROM attendance.  This migration removes the
--     structural risk of accidental cascade by ensuring FKs from
--     attendance are RESTRICT / NO ACTION, never CASCADE.
--   • Workshops are soft-deleted (archived) with three new columns:
--     `archived_at`, `archived_by`, `archived_reason`.  The existing
--     `is_active` flag stays and keeps its "hidden from active lists"
--     semantics for temporary hides; `archived_at IS NOT NULL` marks
--     the permanent archival state.
--   • Hard-delete is still legal for scheduled_workshops rows that have
--     no attendance and no active enrollment — the FK RESTRICT is what
--     prevents accidental history loss.  No BEFORE-DELETE trigger is
--     added (per operator preference: FK safety + app-level guards).
--
-- Additive + idempotent.  Safe to re-run.
-- ────────────────────────────────────────────────────────────────────

-- 1. Archive columns ─────────────────────────────────────────────────
alter table public.scheduled_workshops
  add column if not exists archived_at     timestamptz null,
  add column if not exists archived_by     uuid        null references public.profiles(id) on delete set null,
  add column if not exists archived_reason text        null;

alter table public.workshop_series
  add column if not exists archived_at     timestamptz null,
  add column if not exists archived_by     uuid        null references public.profiles(id) on delete set null,
  add column if not exists archived_reason text        null;

comment on column public.scheduled_workshops.archived_at is
  'When set, the workshop is archived: hidden from active lists but preserved for history + reports.';
comment on column public.workshop_series.archived_at is
  'When set, the workshop series is archived: hidden from active lists but preserved for history + reports.';

-- 2. Partial indexes for the two most common queries ─────────────────
create index if not exists ix_sched_ws_active_by_date
  on public.scheduled_workshops (workshop_date)
  where archived_at is null;

create index if not exists ix_wseries_active
  on public.workshop_series (id)
  where archived_at is null;

-- 3. Defensive FK hardening — keep attendance history safe ───────────
--
-- attendance.scheduled_workshop_id and attendance.child_id must not be
-- allowed to CASCADE on parent delete.  If they already are RESTRICT /
-- NO ACTION (the pre-existing state, as evidenced by the fact that the
-- old app code had to manually DELETE FROM attendance before deleting
-- scheduled_workshops), this block is a no-op.  If somehow they were
-- CASCADE, it flips them to NO ACTION.
--
-- We use a do-block so we can look up the current delete_action
-- and only touch the constraint if it needs changing.

do $$
declare
  cur_action text;
  fk_name    text;
begin
  select rc.delete_rule, tc.constraint_name
    into cur_action, fk_name
    from information_schema.referential_constraints rc
    join information_schema.table_constraints tc
      on tc.constraint_name = rc.constraint_name
     and tc.constraint_schema = rc.constraint_schema
    join information_schema.key_column_usage kcu
      on kcu.constraint_name = tc.constraint_name
     and kcu.constraint_schema = tc.constraint_schema
   where tc.table_schema = 'public'
     and tc.table_name = 'attendance'
     and kcu.column_name = 'scheduled_workshop_id'
     and tc.constraint_type = 'FOREIGN KEY'
   limit 1;

  if fk_name is not null and cur_action = 'CASCADE' then
    execute format(
      'alter table public.attendance drop constraint %I, '
      'add constraint attendance_scheduled_workshop_id_fkey '
      'foreign key (scheduled_workshop_id) '
      'references public.scheduled_workshops(id) '
      'on update no action on delete no action',
      fk_name);
    raise notice 'attendance.scheduled_workshop_id FK: CASCADE -> NO ACTION';
  else
    raise notice 'attendance.scheduled_workshop_id FK left as-is (delete_rule = %)', cur_action;
  end if;
end$$;

do $$
declare
  cur_action text;
  fk_name    text;
begin
  select rc.delete_rule, tc.constraint_name
    into cur_action, fk_name
    from information_schema.referential_constraints rc
    join information_schema.table_constraints tc
      on tc.constraint_name = rc.constraint_name
     and tc.constraint_schema = rc.constraint_schema
    join information_schema.key_column_usage kcu
      on kcu.constraint_name = tc.constraint_name
     and kcu.constraint_schema = tc.constraint_schema
   where tc.table_schema = 'public'
     and tc.table_name = 'attendance'
     and kcu.column_name = 'child_id'
     and tc.constraint_type = 'FOREIGN KEY'
   limit 1;

  if fk_name is not null and cur_action = 'CASCADE' then
    execute format(
      'alter table public.attendance drop constraint %I, '
      'add constraint attendance_child_id_fkey '
      'foreign key (child_id) references public.children(id) '
      'on update no action on delete no action',
      fk_name);
    raise notice 'attendance.child_id FK: CASCADE -> NO ACTION';
  else
    raise notice 'attendance.child_id FK left as-is (delete_rule = %)', cur_action;
  end if;
end$$;

-- 4. What this migration does NOT do ─────────────────────────────────
--
--   • No BEFORE DELETE trigger on attendance / workshop_enrollments.
--     Per operator decision: rely on FK safety + application-level
--     removal of destructive actions.
--   • No changes to workshop_enrollments FKs — those already function
--     as append-only history through the is_active toggle.
--   • No data migration — every existing row remains valid.  Existing
--     `is_active = false` workshops keep their meaning; they are just
--     not automatically considered "archived".  Operators may retro-
--     archive them by running a follow-up UPDATE if desired.
