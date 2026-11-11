-- 04-membership-requests.sql
-- Applications from the Join the Guild page, and the Membership Chair's steps:
-- confirm payment, then approve (which adds the person to the member list).
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

create table if not exists public.membership_requests (
  id                   uuid primary key default gen_random_uuid(),
  created_at           timestamptz not null default now(),
  kind                 text not null default 'new' check (kind in ('new', 'renewal')),
  membership_type      text not null check (membership_type in ('Regular', 'Exempt', 'Junior')),
  first_name           text not null,
  last_name            text not null,
  email                text not null,
  cell_phone           text,
  facebook_name        text,
  street_address       text,
  city                 text,
  state                text,
  zip                  text,
  directory_opt_out    boolean not null default false,
  birthday_month       smallint check (birthday_month between 1 and 12),
  birthday_day         smallint check (birthday_day between 1 and 31),
  interests            text[] not null default '{}',
  interests_other      text,
  help_committees      text[] not null default '{}',
  help_other           text,
  amount_due           numeric(7,2) not null default 0,
  payment_status       text not null default 'pending' check (payment_status in ('pending', 'received', 'not_required')),
  payment_confirmed_by uuid references public.members (id) on delete set null,
  payment_confirmed_at timestamptz,
  status               text not null default 'new' check (status in ('new', 'paid', 'approved')),
  member_id            uuid references public.members (id) on delete set null,
  approved_by          uuid references public.members (id) on delete set null,
  approved_at          timestamptz
);

create index if not exists membership_requests_status_idx on public.membership_requests (status, created_at desc);

alter table public.membership_requests enable row level security;
revoke all on public.membership_requests from anon, authenticated;
grant select on public.membership_requests to authenticated;

-- only the Membership Chair and the Superuser can read applications;
-- nobody changes them directly (the functions below do that)
drop policy if exists membership_requests_select on public.membership_requests;
create policy membership_requests_select on public.membership_requests
  for select to authenticated
  using (public.is_superuser() or public.has_role('membership_chair'));

-- Anyone (not signed in) can send an application, through this function only.
create or replace function public.submit_membership_request(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_type   text := initcap(lower(btrim(coalesce(p->>'membership_type', ''))));
  v_first  text := btrim(coalesce(p->>'first_name', ''));
  v_last   text := btrim(coalesce(p->>'last_name', ''));
  v_email  text := lower(btrim(coalesce(p->>'email', '')));
  v_amount numeric(7,2);
  v_bm     smallint := nullif(p->>'birthday_month', '')::smallint;
  v_bd     smallint := nullif(p->>'birthday_day', '')::smallint;
  v_int    text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'interests', '[]'::jsonb))), '{}');
  v_help   text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'help_committees', '[]'::jsonb))), '{}');
begin
  if v_type not in ('Regular', 'Exempt', 'Junior') then
    raise exception 'Please choose a membership type.';
  end if;
  if v_first = '' or v_last = '' or length(v_first) > 80 or length(v_last) > 80 then
    raise exception 'Please enter your first and last name.';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then
    raise exception 'Please enter a valid email address.';
  end if;
  if (v_bm is null) <> (v_bd is null) then
    raise exception 'Please choose both a birthday month and day, or neither.';
  end if;
  if coalesce(array_length(v_int, 1), 0) > 30 or coalesce(array_length(v_help, 1), 0) > 30 then
    raise exception 'Too many choices.';
  end if;
  if exists (select 1 from public.membership_requests
              where lower(email) = v_email and status <> 'approved'
                and created_at > now() - interval '60 days') then
    raise exception 'We already have a record for that email address. If you are a member, please sign in, or contact the Membership Chair.';
  end if;
  if exists (select 1 from public.members where lower(email) = v_email) then
    raise exception 'We already have a record for that email address. If you are a member, please sign in, or contact the Membership Chair.';
  end if;

  select case v_type when 'Regular' then join_dues_regular when 'Junior' then join_dues_junior else join_dues_exempt end
    into v_amount from public.site_config where id;

  insert into public.membership_requests (
    kind, membership_type, first_name, last_name, email, cell_phone, facebook_name,
    street_address, city, state, zip, directory_opt_out, birthday_month, birthday_day,
    interests, interests_other, help_committees, help_other, amount_due, payment_status)
  values (
    'new', v_type, v_first, v_last, v_email,
    left(nullif(btrim(p->>'cell_phone'), ''), 40), left(nullif(btrim(p->>'facebook_name'), ''), 120),
    left(nullif(btrim(p->>'street_address'), ''), 200), left(nullif(btrim(p->>'city'), ''), 80),
    left(upper(nullif(btrim(p->>'state'), '')), 2), left(nullif(btrim(p->>'zip'), ''), 10),
    coalesce((p->>'directory_opt_out')::boolean, false), v_bm, v_bd,
    v_int, left(nullif(btrim(p->>'interests_other'), ''), 300),
    v_help, left(nullif(btrim(p->>'help_other'), ''), 300),
    coalesce(v_amount, 0),
    case when coalesce(v_amount, 0) = 0 then 'not_required' else 'pending' end);
end $$;

revoke all on function public.submit_membership_request(jsonb) from public;
grant execute on function public.submit_membership_request(jsonb) to anon, authenticated;

-- Step 1: the Membership Chair confirms the payment arrived
create or replace function public.confirm_membership_payment(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can do this.';
  end if;
  update public.membership_requests
     set payment_status = 'received', status = 'paid',
         payment_confirmed_by = public.current_member_id(), payment_confirmed_at = now()
   where id = p_id and status = 'new' and payment_status = 'pending';
  if not found then
    raise exception 'That request is not waiting for payment.';
  end if;
end $$;

-- Step 2: approve. Adds the person to the member list, Active through December 31 of this year.
create or replace function public.approve_membership_request(p_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.membership_requests;
  v_member uuid;
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can do this.';
  end if;
  select * into r from public.membership_requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status = 'approved' then raise exception 'That request is already approved.'; end if;
  if r.payment_status = 'pending' then raise exception 'Confirm the payment first.'; end if;
  if r.kind <> 'new' then raise exception 'Renewals are approved on a later screen.'; end if;
  if exists (select 1 from public.members where lower(email) = lower(r.email)) then
    raise exception 'A member with that email address already exists.';
  end if;

  insert into public.members (
    email, first_name, last_name, membership_type, member_since, paid_through_year,
    cell_phone, facebook_name, street_address, city, state, zip, directory_opt_out,
    birthday_month, birthday_day, interests, interests_other)
  values (
    r.email, r.first_name, r.last_name, r.membership_type,
    extract(year from current_date)::int, extract(year from current_date)::int,
    r.cell_phone, r.facebook_name, r.street_address, r.city, r.state, r.zip, r.directory_opt_out,
    r.birthday_month, r.birthday_day, r.interests, r.interests_other)
  returning id into v_member;

  update public.membership_requests
     set status = 'approved', member_id = v_member,
         approved_by = public.current_member_id(), approved_at = now()
   where id = p_id;
  return v_member;
end $$;

revoke all on function public.confirm_membership_payment(uuid) from public, anon;
revoke all on function public.approve_membership_request(uuid) from public, anon;
grant execute on function public.confirm_membership_payment(uuid) to authenticated;
grant execute on function public.approve_membership_request(uuid) to authenticated;

commit;
