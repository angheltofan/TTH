-- ─────────────────────────────────────────────────────────────────────
-- REVERT: 20260817_chronological_payment_cycles
-- ─────────────────────────────────────────────────────────────────────
--
-- Manual rollback for 20260817_chronological_payment_cycles.sql.
--
-- NOT in the migrations folder — do NOT rely on `supabase db push` to
-- apply it. Run in SQL Editor (or via psql) ONLY if the new trigger is
-- misbehaving in production. Restores the legacy trigger + function
-- exactly as it existed before the migration (source: production
-- pg_proc.prosrc snapshot taken 2026-08-17).
--
-- Important caveats:
--   • This revert does NOT undo the backfill run inside the forward
--     migration. Any cycle re-assignments that happened during that
--     backfill remain in place — the legacy trigger would have produced
--     the same "insertion-order" bug on future INSERTS but existing
--     rows keep their new chronological alignment. That's actually fine
--     financially (paid metadata was preserved).
--   • Attendance rows that the backfill re-linked will keep their new
--     payment_cycle_id. The legacy trigger only writes NEW rows, it
--     doesn't touch existing links.
--
-- If you need a stronger revert (e.g. restore the exact pre-migration
-- attendance→cycle mapping), take a fresh pg_dump BEFORE running the
-- forward migration. There is no way to reconstruct it from the current
-- schema alone.
-- ─────────────────────────────────────────────────────────────────────

-- 1. Drop the new trigger + wrapper
drop trigger if exists trg_recalculate_cycles_on_attendance
  on public.attendance;
drop function if exists public.tg_recalculate_cycles_on_attendance();

-- 2. Keep or drop the new recalc RPC?
--    Comment: leaving it in place lets admin still call it manually to
--    fix drift. If you truly want to purge it:
-- drop function if exists public.recalculate_child_payment_cycles(uuid);

-- 3. Re-install the legacy trigger + function exactly as it was
create or replace function public.create_payment_cycle_after_4_present()
returns trigger
language plpgsql
as $$
declare
  present_count integer;
  new_cycle_id uuid;
  first_date date;
  last_date date;
  v_advance_id uuid;
  v_payment_method text;
  v_paid_at timestamptz;
  v_confirmed_by uuid;
  v_new_status text;
  v_notes text;
begin
  if new.status <> 'present' then
    return new;
  end if;

  select count(*)
  into present_count
  from public.attendance a
  where a.child_id = new.child_id
    and a.status = 'present'
    and a.payment_cycle_id is null;

  if present_count >= 4 then

    select
      min(sw.workshop_date),
      max(sw.workshop_date)
    into first_date, last_date
    from public.attendance a
    join public.scheduled_workshops sw
      on sw.id = a.scheduled_workshop_id
    where a.child_id = new.child_id
      and a.status = 'present'
      and a.payment_cycle_id is null;

    select
      pc.id,
      pc.payment_method,
      pc.paid_at,
      pc.confirmed_by
    into
      v_advance_id,
      v_payment_method,
      v_paid_at,
      v_confirmed_by
    from public.payment_cycles pc
    where pc.child_id = new.child_id
      and pc.status = 'paid_advance'
    order by pc.paid_at asc nulls last, pc.created_at asc
    limit 1
    for update;

    if v_advance_id is not null then
      v_new_status := 'paid';
      v_notes := 'Ciclu generat automat după 4 prezențe. Achitat în avans.';
    else
      v_new_status := 'due';
      v_notes := 'Ciclu generat automat după 4 prezențe.';
    end if;

    insert into public.payment_cycles (
      child_id,
      workshop_type,
      sessions_count,
      status,
      period_start,
      period_end,
      payment_method,
      paid_at,
      confirmed_by,
      notes
    )
    values (
      new.child_id,
      (
        select sw.workshop_type
        from public.scheduled_workshops sw
        where sw.id = new.scheduled_workshop_id
        limit 1
      ),
      4,
      v_new_status,
      first_date,
      last_date,
      v_payment_method,
      v_paid_at,
      v_confirmed_by,
      v_notes
    )
    returning id into new_cycle_id;

    update public.attendance
    set payment_cycle_id = new_cycle_id
    where id in (
      select a.id
      from public.attendance a
      join public.scheduled_workshops sw
        on sw.id = a.scheduled_workshop_id
      where a.child_id = new.child_id
        and a.status = 'present'
        and a.payment_cycle_id is null
      order by sw.workshop_date asc, sw.start_time asc
      limit 4
    );

    if v_advance_id is not null then
      delete from public.payment_cycles
      where id = v_advance_id;
    else
      insert into public.notifications (
        title,
        body,
        type,
        related_child_id,
        related_workshop_id
      )
      values (
        'Plată necesară',
        'Copilul a acumulat 4 prezențe. A fost generat un ciclu de plată.',
        'payment',
        new.child_id,
        new.scheduled_workshop_id
      );
    end if;

  end if;

  return new;
end;
$$;

create trigger trg_create_payment_cycle_after_4_present
after insert or update on public.attendance
for each row execute function public.create_payment_cycle_after_4_present();
