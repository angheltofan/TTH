-- ─────────────────────────────────────────────────────────────────────
-- 20260817_chronological_payment_cycles
-- ─────────────────────────────────────────────────────────────────────
--
-- Fix: payment cycles were being closed in the ORDER attendance was
-- entered, not in the CHRONOLOGICAL order of the actual workshop dates.
-- With historical attendance entry now supported by the calendar page,
-- this became a data-integrity bug.
--
-- Root cause (in the legacy trigger `create_payment_cycle_after_4_present`):
--   • Cycle-creation was triggered by "count of unlinked presents >= 4".
--   • That count reaches 4 when the FOURTH row is INSERTED, not when the
--     child has FOUR chronologically-consecutive presents.
--   • So a user entering (7 Jul, 14 Jul, 21 Jul, 11 Aug) got a cycle for
--     those 4 rows even though 28 Jul + 4 Aug exist between 21 Jul and
--     11 Aug — leaving those two dates permanently in the "open block"
--     while the cycle carried period_start=7 Jul, period_end=11 Aug
--     (5-week span for a 4-week product).
--
-- Fix: cycle assignment is now deterministic and independent from
-- insertion order. A single function `recalculate_child_payment_cycles`
-- rebuilds the mapping for a child from scratch on every attendance
-- change:
--
--   1. Advisory lock per child (prevents concurrent recalcs from racing).
--   2. Fetch every present attendance for the child, ordered by
--      (workshop_date, start_time, id).
--   3. expected_cycles = floor(N / 4).
--   4. Detach: set attendance.payment_cycle_id = NULL for every row.
--   5. Walk existing non-advance cycles in creation order — reuse
--      cycle[i] for chunk[i]. Financial metadata (status, paid_at,
--      confirmed_by, payment_method) is PRESERVED; only period_start,
--      period_end, sessions_count and the attached attendance rows are
--      rewritten.
--   6. Extra chunks beyond existing cycles → consume a paid_advance if
--      one exists (converting it to a paid cycle exactly like the legacy
--      trigger did), otherwise create a due cycle + notification.
--   7. Extra cycles beyond expected chunks:
--        • due / overdue / cancelled → DELETE.
--        • paid / (paid_advance never appears here) → PRESERVE with
--          sessions_count = 0 and an audit note, so financial history is
--          never lost silently.
--
-- The recalc is invoked by a trigger on attendance INSERT / UPDATE /
-- DELETE. A WHEN-like short-circuit inside the trigger function skips
-- re-firing when the recalc itself is what changed a row (only
-- payment_cycle_id changed → no-op) — prevents infinite recursion.
--
-- A one-shot backfill at the end of this migration runs the new algorithm
-- once for every child with attendance, healing any legacy drift.
-- Financial data on paid cycles is preserved; only the attendance→cycle
-- mapping is rewritten.
--
-- Additive + idempotent + destructive-of-legacy-trigger. Safe to re-run.
-- ─────────────────────────────────────────────────────────────────────

-- ── 1. Drop the legacy trigger + function ────────────────────────────
drop trigger if exists trg_create_payment_cycle_after_4_present
  on public.attendance;
drop function if exists public.create_payment_cycle_after_4_present();

-- ── 2. New sole cycle-management function ────────────────────────────
create or replace function public.recalculate_child_payment_cycles(
  p_child_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment_type text;
  v_expected int;
  v_total_presents int;
  v_max_existing_rank int;
  v_cycle record;
  v_new_cycle_id uuid;
  v_advance record;
  v_chunk_start_date date;
  v_chunk_end_date date;
  v_chunk_wtype text;
  v_chunk_closing_ws uuid;
  v_updates int := 0;
  v_created int := 0;
  v_deleted int := 0;
  v_orphaned_paid int := 0;
  v_notifications int := 0;
begin
  -- Serialize per-child so concurrent recalcs can't race.
  perform pg_advisory_xact_lock(
    hashtext('child_cycles:' || p_child_id::text));

  select payment_type into v_payment_type
    from public.children where id = p_child_id;
  if v_payment_type is null or v_payment_type = 'free' then
    return jsonb_build_object('skipped',
      case when v_payment_type is null then 'child_not_found'
           else 'free_child' end);
  end if;

  -- ── Step 1: build chronological present array in a temp table ──────
  create temporary table if not exists tmp_chrono_presents (
    attendance_id uuid,
    scheduled_workshop_id uuid,
    workshop_date date,
    start_time time,
    workshop_type text,
    chrono_rank int
  ) on commit drop;
  truncate tmp_chrono_presents;

  insert into tmp_chrono_presents (
    attendance_id, scheduled_workshop_id, workshop_date, start_time,
    workshop_type, chrono_rank
  )
  select a.id, a.scheduled_workshop_id, sw.workshop_date,
         sw.start_time, sw.workshop_type,
         row_number() over (
           order by sw.workshop_date asc,
                    sw.start_time asc nulls first,
                    a.id asc
         )
  from public.attendance a
  join public.scheduled_workshops sw on sw.id = a.scheduled_workshop_id
  where a.child_id = p_child_id
    and a.status = 'present'
    and a.is_archived = false;

  select count(*) into v_total_presents from tmp_chrono_presents;
  v_expected := v_total_presents / 4;

  -- ── Step 2: detach every existing link (safe: FK is ON DELETE SET
  --           NULL, but we don't delete cycles yet — just null the FK).
  update public.attendance
    set payment_cycle_id = null
    where child_id = p_child_id
      and payment_cycle_id is not null;

  -- ── Step 3: load existing non-advance cycles in creation order ─────
  create temporary table if not exists tmp_existing_cycles (
    cycle_id uuid,
    status text,
    created_at timestamptz,
    rank int
  ) on commit drop;
  truncate tmp_existing_cycles;

  insert into tmp_existing_cycles (cycle_id, status, created_at, rank)
  select id, status, created_at,
         row_number() over (order by created_at asc, id asc)
  from public.payment_cycles
  where child_id = p_child_id
    and status <> 'paid_advance';

  v_max_existing_rank := coalesce(
    (select max(rank) from tmp_existing_cycles), 0);

  -- ── Step 4: walk chunks, reuse or create ───────────────────────────
  for i in 1..v_expected loop
    select
      min(workshop_date),
      max(workshop_date),
      (array_agg(workshop_type order by chrono_rank))[1],
      (array_agg(scheduled_workshop_id order by chrono_rank desc))[1]
    into v_chunk_start_date, v_chunk_end_date, v_chunk_wtype,
         v_chunk_closing_ws
    from tmp_chrono_presents
    where chrono_rank between (i - 1) * 4 + 1 and i * 4;

    if i <= v_max_existing_rank then
      -- Reuse existing cycle, keep financial metadata untouched.
      select cycle_id into v_new_cycle_id
        from tmp_existing_cycles where rank = i;

      update public.attendance set payment_cycle_id = v_new_cycle_id
        where id in (
          select attendance_id from tmp_chrono_presents
          where chrono_rank between (i - 1) * 4 + 1 and i * 4
        );

      update public.payment_cycles
        set period_start = v_chunk_start_date,
            period_end = v_chunk_end_date,
            sessions_count = 4
        where id = v_new_cycle_id;

      v_updates := v_updates + 1;
    else
      -- Try to consume a paid_advance credit — matches legacy behavior.
      select id, payment_method, paid_at, confirmed_by
        into v_advance
        from public.payment_cycles
        where child_id = p_child_id and status = 'paid_advance'
        order by paid_at asc nulls last, created_at asc
        limit 1 for update;

      if v_advance.id is not null then
        insert into public.payment_cycles (
          child_id, workshop_type, sessions_count, status,
          period_start, period_end,
          payment_method, paid_at, confirmed_by, notes
        ) values (
          p_child_id, v_chunk_wtype, 4, 'paid',
          v_chunk_start_date, v_chunk_end_date,
          v_advance.payment_method, v_advance.paid_at,
          v_advance.confirmed_by,
          'Ciclu generat automat după 4 prezențe. Achitat în avans.'
        ) returning id into v_new_cycle_id;

        delete from public.payment_cycles where id = v_advance.id;
      else
        insert into public.payment_cycles (
          child_id, workshop_type, sessions_count, status,
          period_start, period_end, notes
        ) values (
          p_child_id, v_chunk_wtype, 4, 'due',
          v_chunk_start_date, v_chunk_end_date,
          'Ciclu generat automat după 4 prezențe.'
        ) returning id into v_new_cycle_id;

        insert into public.notifications (
          title, body, type, related_child_id, related_workshop_id
        ) values (
          'Plată necesară',
          'Copilul a acumulat 4 prezențe. A fost generat un ciclu de plată.',
          'payment',
          p_child_id,
          v_chunk_closing_ws
        );
        v_notifications := v_notifications + 1;
      end if;

      update public.attendance set payment_cycle_id = v_new_cycle_id
        where id in (
          select attendance_id from tmp_chrono_presents
          where chrono_rank between (i - 1) * 4 + 1 and i * 4
        );

      v_created := v_created + 1;
    end if;
  end loop;

  -- ── Step 5: extras beyond expected — delete due-ish, preserve paid ─
  for v_cycle in
    select cycle_id, status from tmp_existing_cycles
    where rank > v_expected order by rank
  loop
    if v_cycle.status in ('due', 'overdue', 'cancelled') then
      delete from public.payment_cycles where id = v_cycle.cycle_id;
      v_deleted := v_deleted + 1;
    else
      -- Paid cycle without chronological support: preserve financial
      -- record, mark as orphan, zero out the session count. Admin can
      -- decide later.
      update public.payment_cycles
        set sessions_count = 0,
            notes = coalesce(notes, '') ||
              E'\n⚠ Ciclu orfan după recalculare cronologică — atendențele suportive au fost reasignate cronologic către alte cicluri sau au dispărut. Preservat pentru păstrarea istoricului financiar.'
        where id = v_cycle.cycle_id;
      v_orphaned_paid := v_orphaned_paid + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'child_id', p_child_id,
    'total_presents', v_total_presents,
    'expected_cycles', v_expected,
    'existing_cycles_before', v_max_existing_rank,
    'cycles_reassigned', v_updates,
    'cycles_created', v_created,
    'cycles_deleted', v_deleted,
    'paid_cycles_orphaned', v_orphaned_paid,
    'notifications_created', v_notifications
  );
end;
$$;

comment on function public.recalculate_child_payment_cycles(uuid) is
  'Rebuilds the mapping between attendance rows and payment cycles for '
  'ONE child from scratch, deterministically, in chronological workshop '
  'order. Idempotent. Preserves financial metadata on paid cycles. '
  'Invoked by trg_recalculate_cycles_on_attendance on every attendance '
  'change. Also callable directly for admin fix-ups.';

revoke all on function public.recalculate_child_payment_cycles(uuid)
  from public;
grant execute on function public.recalculate_child_payment_cycles(uuid)
  to authenticated, service_role;

-- ── 3. New trigger: calls recalc, skips self-recursion ───────────────
create or replace function public.tg_recalculate_cycles_on_attendance()
returns trigger
language plpgsql
as $$
declare
  v_child_id uuid;
begin
  -- Short-circuit: when the only thing that changed is payment_cycle_id
  -- (that's US), don't recurse.
  if tg_op = 'UPDATE'
     and old.status is not distinct from new.status
     and old.is_archived is not distinct from new.is_archived
     and old.child_id is not distinct from new.child_id
     and old.scheduled_workshop_id is not distinct from
         new.scheduled_workshop_id then
    return null;
  end if;

  v_child_id := case
    when tg_op = 'DELETE' then old.child_id
    else new.child_id
  end;
  if v_child_id is null then return null; end if;

  perform public.recalculate_child_payment_cycles(v_child_id);
  return null;
end;
$$;

drop trigger if exists trg_recalculate_cycles_on_attendance
  on public.attendance;
create trigger trg_recalculate_cycles_on_attendance
after insert or update or delete on public.attendance
for each row execute function public.tg_recalculate_cycles_on_attendance();

-- ── 4. One-time backfill for existing data ───────────────────────────
--
-- Runs the new algorithm across every child with attendance. Financial
-- metadata on paid cycles is preserved; only the attendance→cycle
-- mapping is rewritten. Legacy drift (Darius's 5-week cycle etc.) is
-- healed here.
do $$
declare
  v_child_id uuid;
  v_result jsonb;
begin
  for v_child_id in
    select distinct child_id from public.attendance
    where is_archived = false
  loop
    v_result := public.recalculate_child_payment_cycles(v_child_id);
    raise notice 'Recalc % → %', v_child_id, v_result;
  end loop;
end$$;
