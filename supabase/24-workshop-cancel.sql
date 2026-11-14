-- 24-workshop-cancel.sql
-- Cancelling a workshop registration, and recording the refund that is owed.
-- Run after 22-workshops.sql and 23-workshop-payment-method.sql. Safe to run twice.
--
-- Only the Workshops Chair, Administrators and the Superuser may cancel or record a refund
-- (the Program Chair can see cancelled registrations but not change them).
-- A cancelled registration gives up its spot, its materials lock again, and if the person had paid
-- a refund is recorded as owed (the amount they paid) until the chair marks it refunded.

create or replace function public.can_cancel_workshops()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('workshop_chair')
$$;
grant execute on function public.can_cancel_workshops() to authenticated;

alter table public.workshop_registrations drop constraint if exists workshop_registrations_status_check;
alter table public.workshop_registrations
  add constraint workshop_registrations_status_check check (status in ('waitlist', 'waiting', 'accepted', 'cancelled'));

alter table public.workshop_registrations
  add column if not exists cancelled_at     timestamptz,
  add column if not exists cancel_emailed_at timestamptz,
  add column if not exists refund_due       numeric(8,2) not null default 0,
  add column if not exists refund_status    text not null default 'none' check (refund_status in ('none', 'owed', 'refunded')),
  add column if not exists refunded_at      timestamptz,
  add column if not exists refund_method    text check (refund_method is null or refund_method in ('cash', 'check', 'online')),
  add column if not exists refund_note      text;

-- A cancelled person may sign up again, so only live registrations must be one per email.
drop index if exists public.wreg_one_per_email;
create unique index if not exists wreg_one_per_email on public.workshop_registrations (month_id, lower(email)) where status <> 'cancelled';

-- Cancel. Returns the refund that is now owed (0 if they had not paid).
create or replace function public.workshop_cancel(p_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare r public.workshop_registrations%rowtype; v_refund numeric;
begin
  if not public.can_cancel_workshops() then raise exception 'not allowed'; end if;
  select * into r from public.workshop_registrations where id = p_id for update;
  if not found then raise exception 'No such registration.'; end if;
  if r.status = 'cancelled' then return r.refund_due; end if;
  v_refund := case when r.paid then r.total_due else 0 end;
  update public.workshop_registrations
     set status = 'cancelled', cancelled_at = now(), refund_due = v_refund,
         refund_status = case when v_refund > 0 then 'owed' else 'none' end
   where id = p_id;
  return v_refund;
end $$;
grant execute on function public.workshop_cancel(uuid) to authenticated;

-- The chair has returned the money.
create or replace function public.workshop_refunded(p_id uuid, p_method text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_method text := lower(btrim(coalesce(p_method, '')));
begin
  if not public.can_cancel_workshops() then raise exception 'not allowed'; end if;
  if v_method not in ('cash', 'check', 'online') then raise exception 'Please choose how it was refunded.'; end if;
  update public.workshop_registrations
     set refund_status = 'refunded', refunded_at = now(), refund_method = v_method,
         refund_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_id and status = 'cancelled' and refund_status = 'owed';
  if not found then raise exception 'There is no refund owed on that registration.'; end if;
end $$;
grant execute on function public.workshop_refunded(uuid, text, text) to authenticated;

-- A paid registration cannot be deleted (that would lose the refund record): cancel it instead.
create or replace function public.workshop_remove(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.workshop_registrations%rowtype;
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  select * into r from public.workshop_registrations where id = p_id;
  if not found then return; end if;
  if r.paid and r.status <> 'cancelled' then raise exception 'This person has paid. Cancel the registration so the refund is recorded.'; end if;
  if r.status = 'cancelled' and r.refund_status = 'owed' then raise exception 'A refund is still owed. Mark it refunded first.'; end if;
  delete from public.workshop_registrations where id = p_id;
end $$;
grant execute on function public.workshop_remove(uuid) to authenticated;

-- Mark paid must never revive a cancelled registration.
create or replace function public.workshop_mark_paid(p_id uuid, p_method text, p_ref text default null)
returns text language plpgsql security definer set search_path = public as $$
declare r public.workshop_registrations%rowtype; m public.program_months%rowtype;
        v_method text := lower(btrim(coalesce(p_method, '')));
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  if v_method not in ('cash', 'check', 'online') then raise exception 'Please choose how it was paid.'; end if;
  select * into r from public.workshop_registrations where id = p_id for update;
  if not found then raise exception 'No such registration.'; end if;
  if r.status = 'cancelled' then raise exception 'That registration was cancelled.'; end if;
  select * into m from public.program_months where id = r.month_id;
  if r.status in ('waiting', 'accepted') then return r.status; end if;
  if m.ws_spots is not null and public.workshop_held(r.month_id) >= m.ws_spots then
    raise exception 'The workshop is full.';
  end if;
  update public.workshop_registrations
     set paid = true, paid_at = coalesce(paid_at, now()), status = 'waiting',
         pay_method = v_method, pay_ref = nullif(btrim(coalesce(p_ref, '')), '')
   where id = p_id;
  return 'waiting';
end $$;
grant execute on function public.workshop_mark_paid(uuid, text, text) to authenticated;
