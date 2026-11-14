-- 23-workshop-payment-method.sql
-- Record HOW a workshop sign-up was paid (cash, check or online) and an optional check number.
-- Run after 22-workshops.sql. Safe to run twice.

alter table public.workshop_registrations
  add column if not exists pay_method text check (pay_method is null or pay_method in ('cash', 'check', 'online')),
  add column if not exists pay_ref    text;   -- check number or other note

-- The old one-argument version is replaced by one that takes the method.
drop function if exists public.workshop_mark_paid(uuid);

create or replace function public.workshop_mark_paid(p_id uuid, p_method text, p_ref text default null)
returns text language plpgsql security definer set search_path = public as $$
declare r public.workshop_registrations%rowtype; m public.program_months%rowtype;
        v_method text := lower(btrim(coalesce(p_method, '')));
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  if v_method not in ('cash', 'check', 'online') then raise exception 'Please choose how it was paid.'; end if;
  select * into r from public.workshop_registrations where id = p_id for update;
  if not found then raise exception 'No such registration.'; end if;
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
