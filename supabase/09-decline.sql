-- 09-decline.sql
-- Decline button on Membership Requests. A declined request leaves the queue (the record is kept),
-- the person can apply again right away, and nothing is added to the member list. Replaces some
-- functions from 04, 07 and 08, so run those first. Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

-- allow the new status
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.membership_requests'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%approved%'
  loop
    execute format('alter table public.membership_requests drop constraint %I', c);
  end loop;
end $$;
alter table public.membership_requests
  add constraint membership_requests_status_check check (status in ('new', 'paid', 'approved', 'declined'));

alter table public.membership_requests
  add column if not exists declined_by uuid references public.members (id) on delete set null,
  add column if not exists declined_at timestamptz,
  add column if not exists decline_note text;

-- Membership Chair or Superuser: decline a request that has not been approved
create or replace function public.decline_membership_request(p_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.membership_requests;
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can do this.';
  end if;
  select * into r from public.membership_requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status = 'approved' then raise exception 'That request was already approved.'; end if;
  if r.status = 'declined' then raise exception 'That request was already declined.'; end if;
  update public.membership_requests
     set status = 'declined', declined_by = public.current_member_id(), declined_at = now(),
         decline_note = left(nullif(btrim(coalesce(p_note, '')), ''), 300)
   where id = p_id;
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'membership request declined',
          jsonb_build_object('request_id', p_id, 'kind', r.kind, 'email', r.email));
end $$;

revoke all on function public.decline_membership_request(uuid, text) from public, anon;
grant execute on function public.decline_membership_request(uuid, text) to authenticated;

-- Updated so a declined request does not count as waiting, and cannot be approved.
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
              where lower(email) = v_email and status not in ('approved', 'declined')
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

create or replace function public.join_email_status(p_email text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v text := lower(btrim(coalesce(p_email, '')));
begin
  if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v) > 200 then
    raise exception 'Please enter a valid email address.';
  end if;
  if exists (select 1 from public.members where lower(email) = v) then return 'member'; end if;
  if exists (select 1 from public.membership_requests
              where lower(email) = v and status not in ('approved', 'declined') and created_at > now() - interval '60 days') then
    return 'pending';
  end if;
  return 'new';
end $$;

create or replace function public.my_renewal_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  m public.members;
  c public.site_config;
  t int;
begin
  select * into m from public.members where auth_user_id = auth.uid();
  if not found then
    return jsonb_build_object('has_member', false);
  end if;
  select * into c from public.site_config where id;
  t := public.renewal_target_year(m.paid_through_year);
  return jsonb_build_object(
    'has_member', true,
    'open', c.renewals_open,
    'can_renew', (c.renewals_open or public.membership_status(m.paid_through_year) = 'inactive'),
    'target_year', t,
    'already', t > extract(year from current_date)::int + 1,
    'pending', exists (select 1 from public.membership_requests
                        where member_id = m.id and kind = 'renewal' and status not in ('approved', 'declined')),
    'dues', jsonb_build_object('Regular', c.renew_dues_regular, 'Junior', c.renew_dues_junior, 'Exempt', c.renew_dues_exempt));
end $$;

create or replace function public.submit_renewal_request(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  m        public.members;
  c        public.site_config;
  t        int;
  v_type   text := initcap(lower(btrim(coalesce(p->>'membership_type', ''))));
  v_first  text := btrim(coalesce(p->>'first_name', ''));
  v_last   text := btrim(coalesce(p->>'last_name', ''));
  v_amount numeric(7,2);
  v_bm     smallint := nullif(p->>'birthday_month', '')::smallint;
  v_bd     smallint := nullif(p->>'birthday_day', '')::smallint;
  v_int    text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'interests', '[]'::jsonb))), '{}');
  v_help   text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'help_committees', '[]'::jsonb))), '{}');
begin
  select * into m from public.members where auth_user_id = auth.uid();
  if not found then
    raise exception 'No membership record is linked to your account. Please contact the Membership Chair.';
  end if;
  select * into c from public.site_config where id;
  -- Active and grace-period members renew while the Membership Chair's Renew switch is on.
  -- A lapsed (Inactive) member can always renew; this is how they come back through Join.
  if not (c.renewals_open or public.membership_status(m.paid_through_year) = 'inactive') then
    raise exception 'Renewals are not open right now.';
  end if;
  t := public.renewal_target_year(m.paid_through_year);
  if t > extract(year from current_date)::int + 1 then
    raise exception 'Your membership is already paid through December 31, %.', m.paid_through_year;
  end if;
  if exists (select 1 from public.membership_requests
              where member_id = m.id and kind = 'renewal' and status not in ('approved', 'declined')) then
    raise exception 'Your renewal has already been sent and is waiting for the Membership Chair.';
  end if;
  if v_type not in ('Regular', 'Exempt', 'Junior') then
    raise exception 'Please choose a membership type.';
  end if;
  if v_first = '' or v_last = '' or length(v_first) > 80 or length(v_last) > 80 then
    raise exception 'Please enter your first and last name.';
  end if;
  if (v_bm is null) <> (v_bd is null) then
    raise exception 'Please choose both a birthday month and day, or neither.';
  end if;
  if coalesce(array_length(v_int, 1), 0) > 30 or coalesce(array_length(v_help, 1), 0) > 30 then
    raise exception 'Too many choices.';
  end if;

  v_amount := case v_type when 'Regular' then c.renew_dues_regular when 'Junior' then c.renew_dues_junior else c.renew_dues_exempt end;

  insert into public.membership_requests (
    kind, membership_type, first_name, last_name, email, cell_phone, facebook_name,
    street_address, city, state, zip, directory_opt_out, birthday_month, birthday_day,
    interests, interests_other, help_committees, help_other, amount_due, payment_status,
    member_id, renewal_year)
  values (
    'renewal', v_type, v_first, v_last, m.email,
    left(nullif(btrim(p->>'cell_phone'), ''), 40), left(nullif(btrim(p->>'facebook_name'), ''), 120),
    left(nullif(btrim(p->>'street_address'), ''), 200), left(nullif(btrim(p->>'city'), ''), 80),
    left(upper(nullif(btrim(p->>'state'), '')), 2), left(nullif(btrim(p->>'zip'), ''), 10),
    coalesce((p->>'directory_opt_out')::boolean, false), v_bm, v_bd,
    v_int, left(nullif(btrim(p->>'interests_other'), ''), 300),
    v_help, left(nullif(btrim(p->>'help_other'), ''), 300),
    coalesce(v_amount, 0),
    case when coalesce(v_amount, 0) = 0 then 'not_required' else 'pending' end,
    m.id, t);
end $$;

create or replace function public.approve_membership_request(p_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.membership_requests;
  v_member uuid;
  v_year int;
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can do this.';
  end if;
  select * into r from public.membership_requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status = 'approved' then raise exception 'That request is already approved.'; end if;
  if r.status = 'declined' then raise exception 'That request was declined.'; end if;
  if r.payment_status = 'pending' then raise exception 'Confirm the payment first.'; end if;

  if r.kind = 'renewal' then
    if r.member_id is null then raise exception 'That renewal is not linked to a member.'; end if;
    v_year := coalesce(r.renewal_year, extract(year from current_date)::int);
    update public.members set
      first_name = r.first_name, last_name = r.last_name, membership_type = r.membership_type,
      cell_phone = r.cell_phone, facebook_name = r.facebook_name,
      street_address = r.street_address, city = r.city, state = r.state, zip = r.zip,
      directory_opt_out = r.directory_opt_out,
      birthday_month = r.birthday_month, birthday_day = r.birthday_day,
      interests = r.interests, interests_other = r.interests_other,
      paid_through_year = greatest(coalesce(paid_through_year, 0), v_year)
     where id = r.member_id;
    if not found then raise exception 'The member for this renewal no longer exists.'; end if;
    v_member := r.member_id;
    insert into public.site_log (actor_member_id, action, details)
    values (public.current_member_id(), 'renewal approved',
            jsonb_build_object('member_id', v_member, 'paid_through_year', v_year));
  else
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
  end if;

  update public.membership_requests
     set status = 'approved', member_id = v_member,
         approved_by = public.current_member_id(), approved_at = now()
   where id = p_id;
  return v_member;
end $$;

commit;
