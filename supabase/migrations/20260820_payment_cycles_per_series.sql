-- ─────────────────────────────────────────────────────────────────────
-- 20260820_payment_cycles_per_series
-- ─────────────────────────────────────────────────────────────────────
--
-- Payment cycles become per (child, workshop_series) instead of just
-- per child. Fixes the cross-series bug where a child enrolled in two
-- workshops had their attendance combined into a single cycle
-- (Marți-Robotică + Vineri-Engleză mixed together — Darius's case).
--
-- Diagnostic (2026-08-17):
--   • 15 payment_cycles are single-series (safe backfill)
--   • 4 payment_cycles are mixed:
--       - 2 due (safe to split)
--       - 2 paid (48cad5fd + 83b88e95): metadata preserved on the
--         majority-series side, minority attendance detached to open
--         block for their own series
--   • 6 paid_advance cycles:
--       - 2 have exactly 1 active enrollment (unambiguous)
--       - 4 have no active enrollment; fall back to any enrollment,
--         then to historical attendance, then leave series_id NULL
--         (allowed as a transient state; admin can fix manually)
--
-- What this migration does:
--   1. Add payment_cycles.series_id (nullable, FK NO ACTION)
--   2. Backfill single-series cycles deterministically
--   3. Split mixed cycles by majority-attendance-count
--   4. Attach series_id to advance payments (best-effort chain)
--   5. Replace uniqueness index: one advance per (child, series)
--   6. Add index on (child_id, series_id)
--   7. Rewrite recalc function to operate per (child, series)
--   8. Rewrite trigger to determine the affected series and recalc
--      only that pair
--   9. Rewrite upsert_advance_payment RPC to require series_id
--
-- What this migration does NOT do (deferred to Phase 2):
--   • Refactor Dart repositories/providers/UI to consume series_id
--   • Refactor views (child_current_status, etc.) — those are queried
--     by the Dart layer and must be updated in lockstep with Dart
--   • Refactor AI assistant tools
--
-- Additive + idempotent for the schema changes. The mixed-cycle split
-- is not idempotent (it detaches minority attendance rows), but it's
-- guarded by "series_id is null" so re-running is safe (no-op after
-- first run).
-- ─────────────────────────────────────────────────────────────────────

-- ── 1. Add series_id column ──────────────────────────────────────────
alter table public.payment_cycles
  add column if not exists series_id uuid
    references public.workshop_series(id)
    on update no action on delete no action;

comment on column public.payment_cycles.series_id is
  'Workshop series this cycle counts attendance from. Enforced by '
  'trigger + recalc logic. NULL only tolerated for legacy paid_advance '
  'rows that could not be safely mapped during migration 20260820.';

create index if not exists idx_payment_cycles_child_series
  on public.payment_cycles(child_id, series_id);

-- ── 2. Backfill single-series cycles (deterministic) ─────────────────
with cycle_series as (
  select
    a.payment_cycle_id,
    coalesce(sw.series_id, sw.recurring_series_id) as series_id
  from public.attendance a
  join public.scheduled_workshops sw on sw.id = a.scheduled_workshop_id
  where a.payment_cycle_id is not null
),
single_series as (
  select payment_cycle_id,
         (array_agg(distinct series_id))[1] as series_id
  from cycle_series
  group by payment_cycle_id
  having count(distinct series_id) = 1
)
update public.payment_cycles pc
   set series_id = ss.series_id
  from single_series ss
 where ss.payment_cycle_id = pc.id
   and pc.series_id is null;

-- ── 3. Split mixed cycles by majority-attendance-count ───────────────
do $$
declare
  v_cycle record;
  v_majority_series uuid;
  v_detached int;
begin
  for v_cycle in
    with cycle_series as (
      select
        a.payment_cycle_id,
        coalesce(sw.series_id, sw.recurring_series_id) as series_id
      from public.attendance a
      join public.scheduled_workshops sw on sw.id = a.scheduled_workshop_id
      where a.payment_cycle_id is not null
    ),
    per_series as (
      select payment_cycle_id, series_id, count(*) as att_count
      from cycle_series
      group by payment_cycle_id, series_id
    ),
    ranked as (
      select payment_cycle_id, series_id, att_count,
        row_number() over (
          partition by payment_cycle_id
          order by att_count desc, series_id asc
        ) as rank
      from per_series
    ),
    mixed_majority as (
      select
        r.payment_cycle_id, r.series_id as majority_series
      from ranked r
      where r.rank = 1
        and exists (
          select 1 from ranked r2
          where r2.payment_cycle_id = r.payment_cycle_id and r2.rank > 1
        )
    )
    select
      pc.id as cycle_id,
      pc.status,
      pc.notes as existing_notes,
      mm.majority_series
    from mixed_majority mm
    join public.payment_cycles pc on pc.id = mm.payment_cycle_id
    where pc.series_id is null  -- idempotency: skip if already split
  loop
    v_majority_series := v_cycle.majority_series;

    -- Detach minority attendance rows first (so recalc can rebuild them
    -- into their own series' open block).
    with detached as (
      update public.attendance a
        set payment_cycle_id = null
        from public.scheduled_workshops sw
        where sw.id = a.scheduled_workshop_id
          and a.payment_cycle_id = v_cycle.cycle_id
          and coalesce(sw.series_id, sw.recurring_series_id)
              <> v_majority_series
        returning a.id
    )
    select count(*) into v_detached from detached;

    -- Assign majority series + audit note. Financial metadata untouched.
    update public.payment_cycles
      set series_id = v_majority_series,
          notes = coalesce(v_cycle.existing_notes, '') ||
            format(
              E'\n[Migration 20260820: split legacy mixed cycle → majority=%s, %s attendance rows from other series detached to open block]',
              v_majority_series, v_detached)
      where id = v_cycle.cycle_id;

    raise notice 'Split mixed cycle % → majority=%, detached=%',
      v_cycle.cycle_id, v_majority_series, v_detached;
  end loop;
end$$;

-- ── 4. Backfill paid_advance series_id (best-effort chain) ──────────
do $$
declare
  v_advance record;
  v_series_id uuid;
  v_source text;
begin
  for v_advance in
    select id, child_id, workshop_type from public.payment_cycles
    where status = 'paid_advance' and series_id is null
  loop
    v_series_id := null;
    v_source := null;

    -- Step A: single active enrollment
    if (select count(*) from public.workshop_enrollments
        where child_id = v_advance.child_id and is_active = true) = 1 then
      select we.series_id into v_series_id
        from public.workshop_enrollments we
        where we.child_id = v_advance.child_id and we.is_active = true;
      v_source := 'single_active_enrollment';
    end if;

    -- Step B: active enrollment matching workshop_type
    if v_series_id is null and v_advance.workshop_type is not null then
      select we.series_id into v_series_id
        from public.workshop_enrollments we
        join public.workshop_series ws on ws.id = we.series_id
        where we.child_id = v_advance.child_id
          and we.is_active = true
          and ws.workshop_type = v_advance.workshop_type
        limit 1;
      if v_series_id is not null then
        v_source := 'active_workshop_type_match';
      end if;
    end if;

    -- Step C: any enrollment (active or inactive)
    if v_series_id is null then
      select we.series_id into v_series_id
        from public.workshop_enrollments we
        where we.child_id = v_advance.child_id
        limit 1;
      if v_series_id is not null then
        v_source := 'any_enrollment_fallback';
      end if;
    end if;

    -- Step D: historical attendance
    if v_series_id is null then
      select coalesce(sw.series_id, sw.recurring_series_id)
        into v_series_id
        from public.attendance a
        join public.scheduled_workshops sw on sw.id = a.scheduled_workshop_id
        where a.child_id = v_advance.child_id
          and coalesce(sw.series_id, sw.recurring_series_id) is not null
        limit 1;
      if v_series_id is not null then
        v_source := 'historical_attendance_fallback';
      end if;
    end if;

    if v_series_id is not null then
      update public.payment_cycles
        set series_id = v_series_id,
            notes = coalesce(notes, '') ||
              format(E'\n[Migration 20260820: paid_advance series_id derived via %s]',
                     v_source)
        where id = v_advance.id;
      raise notice 'Advance % → series % via %',
        v_advance.id, v_series_id, v_source;
    else
      raise warning 'Advance % (child %) — NO series could be assigned. '
        'Admin action required.', v_advance.id, v_advance.child_id;
    end if;
  end loop;
end$$;

-- ── 5. Replace advance uniqueness index (one per child → one per pair)
drop index if exists public.uq_payment_cycles_one_advance_per_child;

create unique index if not exists uq_payment_cycles_one_advance_per_child_series
  on public.payment_cycles(child_id, series_id)
  where status = 'paid_advance' and series_id is not null;

-- ── 6. New per-(child, series) recalc function ───────────────────────
create or replace function public.recalculate_child_series_payment_cycles(
  p_child_id uuid,
  p_series_id uuid
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
  if p_child_id is null or p_series_id is null then
    return jsonb_build_object('skipped', 'null_params');
  end if;

  perform pg_advisory_xact_lock(hashtext(
    'child_series_cycles:' || p_child_id::text || ':' || p_series_id::text));

  select payment_type into v_payment_type
    from public.children where id = p_child_id;
  if v_payment_type is null or v_payment_type = 'free' then
    return jsonb_build_object('skipped',
      case when v_payment_type is null then 'child_not_found'
           else 'free_child' end);
  end if;

  -- Chronological presents for THIS (child, series)
  create temporary table if not exists tmp_series_presents (
    attendance_id uuid,
    scheduled_workshop_id uuid,
    workshop_date date,
    start_time time,
    workshop_type text,
    chrono_rank int
  ) on commit drop;
  truncate tmp_series_presents;

  insert into tmp_series_presents (
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
    and a.is_archived = false
    and coalesce(sw.series_id, sw.recurring_series_id) = p_series_id;

  select count(*) into v_total_presents from tmp_series_presents;
  v_expected := v_total_presents / 4;

  -- Detach existing links belonging to THIS series
  update public.attendance a
    set payment_cycle_id = null
    from public.scheduled_workshops sw
    where sw.id = a.scheduled_workshop_id
      and a.child_id = p_child_id
      and a.payment_cycle_id is not null
      and coalesce(sw.series_id, sw.recurring_series_id) = p_series_id;

  -- Existing non-advance cycles for THIS pair
  create temporary table if not exists tmp_series_cycles (
    cycle_id uuid,
    status text,
    created_at timestamptz,
    rank int
  ) on commit drop;
  truncate tmp_series_cycles;

  insert into tmp_series_cycles (cycle_id, status, created_at, rank)
  select id, status, created_at,
         row_number() over (order by created_at asc, id asc)
  from public.payment_cycles
  where child_id = p_child_id
    and series_id = p_series_id
    and status <> 'paid_advance';

  v_max_existing_rank := coalesce(
    (select max(rank) from tmp_series_cycles), 0);

  -- Walk chunks
  for i in 1..v_expected loop
    select
      min(workshop_date),
      max(workshop_date),
      (array_agg(workshop_type order by chrono_rank))[1],
      (array_agg(scheduled_workshop_id order by chrono_rank desc))[1]
    into v_chunk_start_date, v_chunk_end_date, v_chunk_wtype,
         v_chunk_closing_ws
    from tmp_series_presents
    where chrono_rank between (i - 1) * 4 + 1 and i * 4;

    if i <= v_max_existing_rank then
      select cycle_id into v_new_cycle_id
        from tmp_series_cycles where rank = i;

      update public.attendance set payment_cycle_id = v_new_cycle_id
        where id in (
          select attendance_id from tmp_series_presents
          where chrono_rank between (i - 1) * 4 + 1 and i * 4
        );

      update public.payment_cycles
        set period_start = v_chunk_start_date,
            period_end = v_chunk_end_date,
            sessions_count = 4
        where id = v_new_cycle_id;

      v_updates := v_updates + 1;
    else
      -- Try paid_advance for THIS (child, series)
      select id, payment_method, paid_at, confirmed_by
        into v_advance
        from public.payment_cycles
        where child_id = p_child_id
          and series_id = p_series_id
          and status = 'paid_advance'
        order by paid_at asc nulls last, created_at asc
        limit 1 for update;

      if v_advance.id is not null then
        insert into public.payment_cycles (
          child_id, series_id, workshop_type, sessions_count, status,
          period_start, period_end,
          payment_method, paid_at, confirmed_by, notes
        ) values (
          p_child_id, p_series_id, v_chunk_wtype, 4, 'paid',
          v_chunk_start_date, v_chunk_end_date,
          v_advance.payment_method, v_advance.paid_at,
          v_advance.confirmed_by,
          'Ciclu generat automat după 4 prezențe. Achitat în avans.'
        ) returning id into v_new_cycle_id;

        delete from public.payment_cycles where id = v_advance.id;
      else
        insert into public.payment_cycles (
          child_id, series_id, workshop_type, sessions_count, status,
          period_start, period_end, notes
        ) values (
          p_child_id, p_series_id, v_chunk_wtype, 4, 'due',
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
          select attendance_id from tmp_series_presents
          where chrono_rank between (i - 1) * 4 + 1 and i * 4
        );

      v_created := v_created + 1;
    end if;
  end loop;

  -- Extras beyond expected
  for v_cycle in
    select cycle_id, status from tmp_series_cycles
    where rank > v_expected order by rank
  loop
    if v_cycle.status in ('due', 'overdue', 'cancelled') then
      delete from public.payment_cycles where id = v_cycle.cycle_id;
      v_deleted := v_deleted + 1;
    else
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
    'series_id', p_series_id,
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

comment on function public.recalculate_child_series_payment_cycles(uuid, uuid) is
  'Deterministic per (child, series) chronological recalc. Preserves '
  'financial metadata on paid cycles. Idempotent.';

revoke all on function public.recalculate_child_series_payment_cycles(uuid, uuid)
  from public;
grant execute on function public.recalculate_child_series_payment_cycles(uuid, uuid)
  to authenticated, service_role;

-- ── 7. Wrapper that recalculates every series for a child ────────────
create or replace function public.recalculate_all_child_payment_cycles(
  p_child_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_series_id uuid;
  v_results jsonb := '[]'::jsonb;
  v_r jsonb;
begin
  for v_series_id in
    select distinct series_id from (
      select coalesce(sw.series_id, sw.recurring_series_id) as series_id
        from public.attendance a
        join public.scheduled_workshops sw on sw.id = a.scheduled_workshop_id
        where a.child_id = p_child_id
      union
      select we.series_id
        from public.workshop_enrollments we
        where we.child_id = p_child_id and we.is_active = true
    ) u
    where u.series_id is not null
  loop
    v_r := public.recalculate_child_series_payment_cycles(
      p_child_id, v_series_id);
    v_results := v_results || v_r;
  end loop;
  return jsonb_build_object('child_id', p_child_id, 'results', v_results);
end;
$$;

comment on function public.recalculate_all_child_payment_cycles(uuid) is
  'Runs recalculate_child_series_payment_cycles for every workshop '
  'series the child has attendance in OR is currently enrolled in. '
  'Idempotent.';

revoke all on function public.recalculate_all_child_payment_cycles(uuid)
  from public;
grant execute on function public.recalculate_all_child_payment_cycles(uuid)
  to authenticated, service_role;

-- Replace the legacy per-child function with a wrapper so callers that
-- still use the old name keep working during Phase 2.
create or replace function public.recalculate_child_payment_cycles(
  p_child_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.recalculate_all_child_payment_cycles(p_child_id);
end;
$$;

-- ── 8. Rewrite trigger function: series-aware ────────────────────────
create or replace function public.tg_recalculate_cycles_on_attendance()
returns trigger
language plpgsql
as $$
declare
  v_child_id uuid;
  v_ws_id uuid;
  v_series_id uuid;
  v_old_ws_id uuid;
  v_old_series_id uuid;
begin
  -- Self-recursion guard
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
  v_ws_id := case
    when tg_op = 'DELETE' then old.scheduled_workshop_id
    else new.scheduled_workshop_id
  end;

  if v_child_id is null or v_ws_id is null then return null; end if;

  select coalesce(sw.series_id, sw.recurring_series_id)
    into v_series_id
    from public.scheduled_workshops sw
    where sw.id = v_ws_id;

  if v_series_id is not null then
    perform public.recalculate_child_series_payment_cycles(
      v_child_id, v_series_id);
  end if;

  -- If UPDATE changed the scheduled_workshop_id, also recalc old series
  if tg_op = 'UPDATE'
     and old.scheduled_workshop_id is distinct from
         new.scheduled_workshop_id then
    v_old_ws_id := old.scheduled_workshop_id;
    select coalesce(sw.series_id, sw.recurring_series_id)
      into v_old_series_id
      from public.scheduled_workshops sw
      where sw.id = v_old_ws_id;
    if v_old_series_id is not null
       and v_old_series_id is distinct from v_series_id then
      perform public.recalculate_child_series_payment_cycles(
        v_child_id, v_old_series_id);
    end if;
  end if;

  return null;
end;
$$;

-- Trigger definition unchanged; only the function body was rewritten.

-- ── 9. Rewrite upsert_advance_payment RPC (series-scoped) ────────────
--
-- The old signature accepted (p_child_id, p_amount, p_payment_method,
-- p_notes) and enforced uniqueness per child. The new signature adds
-- p_series_id and enforces uniqueness per (child, series).
--
-- IMPORTANT: The old signature is DROPPED to prevent Dart callers from
-- accidentally creating an advance without a series after Phase 2 is
-- deployed. Phase 2 must update the Dart repository to pass series_id.

drop function if exists public.upsert_advance_payment(uuid, numeric, text, text);
drop function if exists public.upsert_advance_payment(uuid, text, text);

create or replace function public.upsert_advance_payment(
  p_child_id uuid,
  p_series_id uuid,
  p_payment_method text default null,
  p_notes text default null
) returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_existing_id uuid;
  v_workshop_type text;
begin
  if p_child_id is null or p_series_id is null then
    raise exception 'p_child_id and p_series_id are required';
  end if;

  select workshop_type into v_workshop_type
    from public.workshop_series where id = p_series_id;

  select id into v_existing_id
    from public.payment_cycles
    where child_id = p_child_id
      and series_id = p_series_id
      and status = 'paid_advance'
    for update;

  if v_existing_id is not null then
    update public.payment_cycles
      set payment_method = coalesce(p_payment_method, payment_method),
          notes = coalesce(p_notes, notes),
          paid_at = now(),
          confirmed_by = coalesce(auth.uid(), confirmed_by)
      where id = v_existing_id;
    return jsonb_build_object('id', v_existing_id, 'action', 'updated');
  end if;

  insert into public.payment_cycles (
    child_id, series_id, workshop_type, sessions_count, status,
    payment_method, paid_at, confirmed_by, notes
  ) values (
    p_child_id, p_series_id, v_workshop_type, 0, 'paid_advance',
    p_payment_method, now(), auth.uid(), p_notes
  ) returning id into v_existing_id;

  return jsonb_build_object('id', v_existing_id, 'action', 'created');
end;
$$;

comment on function public.upsert_advance_payment(uuid, uuid, text, text) is
  'Creates or updates the single paid_advance cycle for a (child, series). '
  'Consumed by the recalc function on the next cycle-closing insert.';

grant execute on function public.upsert_advance_payment(uuid, uuid, text, text)
  to authenticated;

-- ── 10. One-time full recalc — heals any legacy drift ────────────────
--
-- Now that every cycle has series_id populated and the recalc function
-- is series-aware, run it for every child. Preserves paid metadata,
-- rearranges attendance within its own series only.
do $$
declare
  v_child_id uuid;
  v_result jsonb;
begin
  for v_child_id in
    select distinct child_id from public.attendance
    where is_archived = false
  loop
    v_result := public.recalculate_all_child_payment_cycles(v_child_id);
    raise notice 'Recalc-all % → %', v_child_id, v_result;
  end loop;
end$$;
