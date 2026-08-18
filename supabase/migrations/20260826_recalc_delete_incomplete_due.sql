-- ─────────────────────────────────────────────────────────────────────
-- 20260826_recalc_delete_incomplete_due
-- ─────────────────────────────────────────────────────────────────────
--
-- Reported bug (2026-08-18): if an admin marks the 4th present that
-- closes a due cycle, then deletes that same present, the cycle stays
-- as `due` with sessions_count=3 and the "Plată necesară" notification
-- remains active. The screenshot shows MARȚI - ROBOTICĂ cycle #2
-- with status "De plată" and only 3 presents (28.07, 04.08, 11.08).
--
-- Root cause: 20260821 introduced partial fulfillment — a paid cycle
-- that lost supporting presents still keeps its 1-3 remaining rows
-- linked so financial history stays consistent. That logic was
-- applied UNIFORMLY to every non-advance cycle including due /
-- overdue / cancelled cycles. But those cycles have no financial
-- record worth preserving; if they no longer have 4 chronological
-- presents in their series, they simply must not exist.
--
-- Fix: partial fulfillment applies only to `paid` cycles (which carry
-- paid_at / confirmed_by / payment_method that must survive). Due /
-- overdue / cancelled cycles with fewer than 4 presents get DELETED,
-- their attendance rows fall back to the open block, and any unread
-- "Plată necesară" notification tied to the same child + relevant
-- workshop is dropped so the notification bell doesn't lie.
--
-- Also: one-time backfill so children currently affected by the bug
-- (the screenshot case) heal immediately — payment_cycles rows with
-- status in ('due','overdue','cancelled') AND sessions_count < 4 will
-- be deleted, their attendance detached to the open block.
--
-- No changes to the trigger, upsert_advance_payment, or the FK/RLS
-- surface. Additive + idempotent.
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

  -- Walk existing cycles: full chunks (4) always reuse; partial chunks
  -- only preserved for PAID cycles (financial metadata must survive).
  -- Due / overdue / cancelled cycles without 4 supporting presents are
  -- DELETED — they never should have existed, and their attendance
  -- (already detached above) stays in the open block.
  for v_cycle in
    select cycle_id, status, rank from tmp_series_cycles
    order by rank
  loop
    v_chunk_size := least(4, v_total_presents - v_assigned);

    if v_chunk_size = 4 then
      -- Full cycle: always reuse, regardless of status.
      select
        min(workshop_date),
        max(workshop_date),
        (array_agg(workshop_type order by chrono_rank))[1]
      into v_chunk_start_date, v_chunk_end_date, v_chunk_wtype
      from tmp_series_presents
      where chrono_rank between v_assigned + 1 and v_assigned + 4;

      update public.attendance set payment_cycle_id = v_cycle.cycle_id
        where id in (
          select attendance_id from tmp_series_presents
          where chrono_rank between v_assigned + 1 and v_assigned + 4
        );

      update public.payment_cycles
        set period_start = v_chunk_start_date,
            period_end = v_chunk_end_date,
            sessions_count = 4
        where id = v_cycle.cycle_id;

      v_assigned := v_assigned + 4;
      v_updates := v_updates + 1;
    else
      -- Partial or zero chunk.
      if v_cycle.status = 'paid' then
        -- Preserve financial history via partial fulfillment.
        if v_chunk_size > 0 then
          select
            min(workshop_date),
            max(workshop_date),
            (array_agg(workshop_type order by chrono_rank))[1]
          into v_chunk_start_date, v_chunk_end_date, v_chunk_wtype
          from tmp_series_presents
          where chrono_rank between v_assigned + 1
                                and v_assigned + v_chunk_size;

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
        else
          update public.payment_cycles
            set sessions_count = 0,
                notes = coalesce(notes, '') ||
                  E'\n⚠ Ciclu orfan după recalculare — nu mai există prezențe suportive. Preservat pentru păstrarea istoricului financiar.'
            where id = v_cycle.cycle_id;
        end if;
        v_orphaned_paid := v_orphaned_paid + 1;
      else
        -- due / overdue / cancelled cycle with fewer than 4 presents:
        -- delete outright. Attendance stays unlinked (open block).
        -- Also drop any unread "Plată necesară" notification linked to
        -- this child + one of the workshops that used to belong to
        -- this cycle, so the notification bell doesn't lie.
        delete from public.notifications n
          where n.related_child_id = p_child_id
            and n.type = 'payment'
            and coalesce(n.is_read, false) = false
            and exists (
              select 1
                from public.attendance a
                join public.scheduled_workshops sw
                  on sw.id = a.scheduled_workshop_id
               where a.child_id = p_child_id
                 and coalesce(sw.series_id, sw.recurring_series_id) = p_series_id
                 and n.related_workshop_id = a.scheduled_workshop_id
            );

        delete from public.payment_cycles where id = v_cycle.cycle_id;
        v_deleted := v_deleted + 1;
      end if;
    end if;
  end loop;

  -- Remaining chronological presents beyond existing cycles: create
  -- new cycles for every full group of 4.
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

-- ── Self-heal: run recalc for every child so the currently-affected
--    Robotică cycle #2 (3 presents, still due) gets cleaned up.
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
    raise notice 'Post-fix recalc % → %', v_child_id, v_result;
  end loop;
end$$;
