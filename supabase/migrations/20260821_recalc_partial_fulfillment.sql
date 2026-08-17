-- ─────────────────────────────────────────────────────────────────────
-- 20260821_recalc_partial_fulfillment
-- ─────────────────────────────────────────────────────────────────────
--
-- Fixes an algorithm flaw introduced by 20260820: when an existing
-- payment cycle had FEWER than 4 chronological presents in its series
-- (e.g. after mixed-cycle split reduced a paid 4-session cycle to
-- 3 Marți presents + 1 Engleză now in a different series), the recalc
-- would mark the cycle as "orphan" and set sessions_count=0 — leaving
-- the 3 remaining presents in open block and the paid cycle empty.
--
-- Fix: assign chunks of `min(4, remaining_presents)` to each existing
-- cycle in creation order (partial fulfillment). Only mark as orphan
-- when there are truly 0 presents left for the cycle. This is honest —
-- the cycle keeps the presents that DO belong to it, and if the total
-- presents are < 4, the paid metadata is preserved with a smaller
-- sessions_count.
--
-- Examples:
--   3 presents, 1 paid cycle    → paid gets 3 (sessions_count=3, paid)
--   5 presents, 1 paid cycle    → paid gets 4, 1 in open block
--   3 presents, 2 paid cycles   → paid#1 gets 3, paid#2 orphan(0)
--   4 presents, 1 due + 1 paid  → same order: 1st in-order cycle gets 4
--
-- Re-runs backfill so existing children heal.
-- ─────────────────────────────────────────────────────────────────────

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
  v_total_presents int;
  v_max_existing_rank int;
  v_cycle record;
  v_new_cycle_id uuid;
  v_advance record;
  v_chunk_start_date date;
  v_chunk_end_date date;
  v_chunk_wtype text;
  v_chunk_closing_ws uuid;
  v_chunk_size int;
  v_assigned int := 0;
  v_updates int := 0;
  v_created int := 0;
  v_deleted int := 0;
  v_orphaned_paid int := 0;
  v_notifications int := 0;
  v_full_cycles_after int;
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

  -- Detach all existing links for THIS series
  update public.attendance a
    set payment_cycle_id = null
    from public.scheduled_workshops sw
    where sw.id = a.scheduled_workshop_id
      and a.child_id = p_child_id
      and a.payment_cycle_id is not null
      and coalesce(sw.series_id, sw.recurring_series_id) = p_series_id;

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

  -- Walk existing cycles in creation order, assigning partial or full
  -- chunks of up to 4 chronological presents each.
  for v_cycle in
    select cycle_id, status, rank from tmp_series_cycles
    order by rank
  loop
    v_chunk_size := least(4, v_total_presents - v_assigned);

    if v_chunk_size > 0 then
      select
        min(workshop_date),
        max(workshop_date),
        (array_agg(workshop_type order by chrono_rank))[1]
      into v_chunk_start_date, v_chunk_end_date, v_chunk_wtype
      from tmp_series_presents
      where chrono_rank between v_assigned + 1 and v_assigned + v_chunk_size;

      update public.attendance set payment_cycle_id = v_cycle.cycle_id
        where id in (
          select attendance_id from tmp_series_presents
          where chrono_rank between v_assigned + 1
                                and v_assigned + v_chunk_size
        );

      update public.payment_cycles
        set period_start = v_chunk_start_date,
            period_end = v_chunk_end_date,
            sessions_count = v_chunk_size
        where id = v_cycle.cycle_id;

      v_assigned := v_assigned + v_chunk_size;
      v_updates := v_updates + 1;
    else
      -- No presents left; this cycle is truly orphaned.
      if v_cycle.status in ('due', 'overdue', 'cancelled') then
        delete from public.payment_cycles where id = v_cycle.cycle_id;
        v_deleted := v_deleted + 1;
      else
        update public.payment_cycles
          set sessions_count = 0,
              notes = coalesce(notes, '') ||
                E'\n⚠ Ciclu orfan după recalculare cronologică — nu mai există prezențe suportive pentru această serie. Preservat pentru păstrarea istoricului financiar.'
          where id = v_cycle.cycle_id;
        v_orphaned_paid := v_orphaned_paid + 1;
      end if;
    end if;
  end loop;

  -- Remaining chronological presents beyond existing cycles: create new
  -- cycles for every full group of 4.
  v_full_cycles_after := (v_total_presents - v_assigned) / 4;

  for i in 1..v_full_cycles_after loop
    select
      min(workshop_date),
      max(workshop_date),
      (array_agg(workshop_type order by chrono_rank))[1],
      (array_agg(scheduled_workshop_id order by chrono_rank desc))[1]
    into v_chunk_start_date, v_chunk_end_date, v_chunk_wtype,
         v_chunk_closing_ws
    from tmp_series_presents
    where chrono_rank between v_assigned + 1 and v_assigned + 4;

    -- Consume advance if any
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
        where chrono_rank between v_assigned + 1 and v_assigned + 4
      );

    v_assigned := v_assigned + 4;
    v_created := v_created + 1;
  end loop;

  return jsonb_build_object(
    'child_id', p_child_id,
    'series_id', p_series_id,
    'total_presents', v_total_presents,
    'existing_cycles_before', v_max_existing_rank,
    'cycles_reassigned', v_updates,
    'cycles_created', v_created,
    'cycles_deleted', v_deleted,
    'paid_cycles_orphaned', v_orphaned_paid,
    'notifications_created', v_notifications,
    'presents_in_open_block', v_total_presents - v_assigned
  );
end;
$$;

-- Re-run backfill to heal state from 20260820
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
    raise notice 'Re-heal % → %', v_child_id, v_result;
  end loop;
end$$;
