-- =====================================================================
-- 52-join-privacy.sql  (run once in the Supabase SQL editor, after 51)
-- Join page: nobody can find out whether an email address belongs to a member
-- or has a waiting application. Tracker item 13 (Audie 3).
--
-- WHAT IT DOES
--   1. join_email_status() is deleted. It was the check that told the Join page
--      whether an email was a member, and it could be used to test addresses.
--      The new Join page does not call it. (An old copy of the Join page still
--      open in someone's browser would show an error at step 1; reloading fixes it.)
--   2. submit_membership_request() no longer says "we already have a record for
--      that email". For an address that is already a member or already has a
--      waiting application it saves nothing and returns normally, exactly like a
--      new application, so the answer looks the same for every address.
--   3. Rate limit by internet address (IP), counted on every application that
--      passes the form checks: 10 per IP per hour, and 100 per hour for the whole
--      site. Over the limit: "Too many applications from this connection just
--      now. Please wait a little while and try again, or contact the Membership
--      Chair." The wording does not depend on the email address.
--   4. Keeps a small log (join_attempt_log) to count against. Rows older than two
--      days are deleted each time someone applies.
--
-- ORDER: push join.html FIRST, wait for the site to update, THEN run this. The
-- new page works against the old SQL (an existing member's email would briefly
-- still get the old "we already have a record" message). Running this before the
-- push would make the live old Join page show an error at step 1.
--
-- WHAT THIS ADDS (for the backup list): one table, join_attempt_log, kept only
-- for counting. It is not worth backing up. Needs 49 (request_ip) to be run.
-- Safe to run twice.
-- =====================================================================

begin;

create table if not exists public.join_attempt_log (
  id  bigint generated always as identity primary key,
  at  timestamptz not null default now(),
  ip  text
);
create index if not exists jal_by_time on public.join_attempt_log (at);
create index if not exists jal_by_ip   on public.join_attempt_log (ip, at);

-- Nobody reads or writes the log directly; only the function below (security definer).
alter table public.join_attempt_log enable row level security;
revoke all on public.join_attempt_log from anon, authenticated;

-- 1. Remove the email check that revealed who is a member.
drop function if exists public.join_email_status(text);

-- 2 and 3. Same checks as before, then the rate limit, then duplicates are ignored quietly.
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
  v_ip     text := public.request_ip();
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

  -- Rate limit by internet address and for the whole site (does not depend on the email).
  delete from public.join_attempt_log where at < now() - interval '2 days';
  if (v_ip is not null and (select count(*) from public.join_attempt_log
                             where ip = v_ip and at > now() - interval '1 hour') >= 10)
     or (select count(*) from public.join_attempt_log where at > now() - interval '1 hour') >= 100 then
    raise exception 'Too many applications from this connection just now. Please wait a little while and try again, or contact the Membership Chair.';
  end if;
  insert into public.join_attempt_log (ip) values (v_ip);

  -- Already a member, or an application is already waiting: save nothing, say nothing different.
  if exists (select 1 from public.members where lower(email) = v_email) then
    return;
  end if;
  if exists (select 1 from public.membership_requests
              where lower(email) = v_email and status not in ('approved', 'declined')
                and created_at > now() - interval '60 days') then
    return;
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

-- Same permissions as before.
revoke all on function public.submit_membership_request(jsonb) from public;
grant execute on function public.submit_membership_request(jsonb) to anon, authenticated;

commit;
