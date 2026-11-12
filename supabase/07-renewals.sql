-- 07-renewals.sql
-- Membership renewals: a signed-in member sends a renewal request from the Renew page,
-- and the Membership Chair approves it on Membership Requests (which updates the member's
-- record and moves Paid through forward). Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

alter table public.membership_requests
  add column if not exists renewal_year smallint;

-- Which calendar year a renewal covers: the first year the member is not yet paid through,
-- and never earlier than this year. (Paid through 2026 renews for 2027; a member in the
-- March grace period, paid through last year, renews for this year.) The Membership Chair's
-- Renew switch decides when renewals are available.
drop function if exists public.renewal_target_year(date);
create or replace function public.renewal_target_year(p_paid_through int, p_on date default current_date)
returns int language sql immutable as $$
  select greatest(extract(year from p_on)::int, coalesce(p_paid_through, 0) + 1)
$$;

-- What the Renew page and the home page need to know about the signed-in member.
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
    'target_year', t,
    'already', t > extract(year from current_date)::int + 1,
    'pending', exists (select 1 from public.membership_requests
                        where member_id = m.id and kind = 'renewal' and status <> 'approved'),
    'dues', jsonb_build_object('Regular', c.renew_dues_regular, 'Junior', c.renew_dues_junior, 'Exempt', c.renew_dues_exempt));
end $$;

-- A signed-in member sends a renewal request.
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
  if not c.renewals_open then
    raise exception 'Renewals are not open right now.';
  end if;
  t := public.renewal_target_year(m.paid_through_year);
  if t > extract(year from current_date)::int + 1 then
    raise exception 'Your membership is already paid through December 31, %.', m.paid_through_year;
  end if;
  if exists (select 1 from public.membership_requests
              where member_id = m.id and kind = 'renewal' and status <> 'approved') then
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

-- Approve: now handles both new members and renewals.
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

revoke all on function public.my_renewal_status() from public, anon;
revoke all on function public.submit_renewal_request(jsonb) from public, anon;
revoke all on function public.approve_membership_request(uuid) from public, anon;
grant execute on function public.my_renewal_status() to authenticated;
grant execute on function public.submit_renewal_request(jsonb) to authenticated;
grant execute on function public.approve_membership_request(uuid) to authenticated;

commit;
