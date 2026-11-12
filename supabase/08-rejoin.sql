-- 08-rejoin.sql
-- Lapsed members come back through the Join page: Join asks for the email first, and if the email
-- is already a member it sends them to sign in and renew (the Renew page fills in their details).
-- Also: a lapsed (Inactive) member can renew at any time, even when the Renew switch is off.
-- Replaces two functions from 07-renewals.sql, so run 07 first. Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

-- Join page, step 1: is this email new, already a member, or already applied?
-- Returns only 'new', 'member' or 'pending'; no personal details leave the database.
create or replace function public.join_email_status(p_email text)
returns text language plpgsql stable security definer set search_path = public as $$
declare v text := lower(btrim(coalesce(p_email, '')));
begin
  if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v) > 200 then
    raise exception 'Please enter a valid email address.';
  end if;
  if exists (select 1 from public.members where lower(email) = v) then return 'member'; end if;
  if exists (select 1 from public.membership_requests
              where lower(email) = v and status <> 'approved' and created_at > now() - interval '60 days') then
    return 'pending';
  end if;
  return 'new';
end $$;

revoke all on function public.join_email_status(text) from public;
grant execute on function public.join_email_status(text) to anon, authenticated;

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
    'can_renew', (c.renewals_open or public.membership_status(m.paid_through_year) = 'inactive'),
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

commit;
