-- =====================================================================
-- 49-workshop-signup-guard.sql  (run once in the Supabase SQL editor, after 48)
-- Spam guard for the anonymous (non-member) workshop sign-up. Tracker item 4.
--
-- WHAT IT DOES (non-members only; a signed-in member is never limited):
--   1. Hidden "website" field (honeypot). Real people never see it, so never
--      fill it in. If it has anything in it, the sign-up looks like it worked
--      but nothing is saved.
--   2. Rate limits, counted over the last hour, on sign-ups that were saved:
--        5 per email address, 10 per internet address (IP), 60 for the whole site.
--      Over the limit: "Too many sign-ups just now. Please wait a little while
--      and try again, or contact the Workshop Manager."
--   3. Keeps a small log (workshop_signup_log) to count against. Rows older than
--      two days are deleted each time someone signs up.
--
-- The old 4-argument workshop_signup is replaced by a 5-argument one (the extra
-- one is the hidden field, and it has a default). Run this FIRST, then push the
-- new programs.html: the old page keeps working in between (it just sends 4
-- arguments), whereas the new page would fail against the old function.
--
-- WHAT THIS ADDS (for the backup list): one table, workshop_signup_log, kept
-- only for counting. It is not worth backing up. No new columns elsewhere.
-- Safe to run twice.
-- =====================================================================

begin;

create table if not exists public.workshop_signup_log (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  ip        text,
  email_lc  text not null,
  month_id  uuid
);
create index if not exists wsl_by_time  on public.workshop_signup_log (at);
create index if not exists wsl_by_ip    on public.workshop_signup_log (ip, at);
create index if not exists wsl_by_email on public.workshop_signup_log (email_lc, at);

-- Nobody reads or writes the log directly; only the function below (security definer).
alter table public.workshop_signup_log enable row level security;
revoke all on public.workshop_signup_log from anon, authenticated;

-- The caller's internet address as the Supabase API passes it on (null if unknown).
create or replace function public.request_ip()
returns text language plpgsql stable set search_path = public as $$
declare h json; v text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    return null;
  end;
  if h is null then return null; end if;
  v := btrim(split_part(coalesce(h->>'x-forwarded-for', h->>'cf-connecting-ip', ''), ',', 1));
  return nullif(v, '');
end $$;

-- Replace the old version (4 arguments) with the guarded one (5 arguments).
drop function if exists public.workshop_signup(uuid, text, text, text);

create or replace function public.workshop_signup(
  p_month_id uuid, p_name text, p_email text, p_phone text, p_website text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.program_months%rowtype;
  mem public.members%rowtype;
  v_is_member boolean := (public.current_member_id() is not null and public.can_see_members_area());
  v_name text; v_email text; v_phone text; v_nm numeric := 0; v_kit numeric := 0; v_fee numeric;
  v_year int; v_id uuid; v_total numeric; v_ip text;
begin
  select * into m from public.program_months where id = p_month_id and status = 'published' and has_workshop;
  if not found then raise exception 'This workshop is not open for sign-up.'; end if;
  if m.ws_last_date is not null and m.ws_last_date < public.guild_today() then
    raise exception 'The last date to register has passed.';
  end if;
  v_fee := coalesce(m.ws_fee, 0);

  if v_is_member then
    select * into mem from public.members where id = public.current_member_id();
    v_name := btrim(coalesce(mem.first_name, '') || ' ' || coalesce(mem.last_name, ''));
    v_email := mem.email;
    v_phone := null;
  else
    if not m.ws_nonmember_ok then
      raise exception 'This workshop is open to Guild members. Please sign in to sign up.';
    end if;
    v_name := btrim(coalesce(p_name, '')); v_email := btrim(coalesce(p_email, '')); v_phone := btrim(coalesce(p_phone, ''));
    if v_name = '' then raise exception 'Please type your name.'; end if;
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please type a valid email address.'; end if;
    if v_phone = '' then raise exception 'Please type your phone number.'; end if;
    v_year := extract(year from coalesce(m.ws_date, m.month_on));
    select fee into v_nm from public.nonmember_fees where year = v_year;
    v_nm := coalesce(v_nm, 0);
  end if;
  if v_email is null or v_email = '' then raise exception 'There is no email address on file for you.'; end if;
  if m.ws_kit_guild then v_kit := coalesce(m.ws_kit_fee, 0); end if;
  v_total := v_fee + v_nm + v_kit;

  if not v_is_member then
    -- Honeypot: a person never sees this field. Pretend it worked; save nothing.
    if btrim(coalesce(p_website, '')) <> '' then
      return jsonb_build_object('id', null, 'total_due', v_total, 'fee', v_fee, 'nonmember_fee', v_nm,
                                'kit_fee', v_kit, 'is_member', false);
    end if;

    -- Rate limits (last hour).
    v_ip := public.request_ip();
    delete from public.workshop_signup_log where at < now() - interval '2 days';
    if (select count(*) from public.workshop_signup_log
         where email_lc = lower(v_email) and at > now() - interval '1 hour') >= 5
       or (v_ip is not null and (select count(*) from public.workshop_signup_log
             where ip = v_ip and at > now() - interval '1 hour') >= 10)
       or (select count(*) from public.workshop_signup_log where at > now() - interval '1 hour') >= 60 then
      raise exception 'Too many sign-ups just now. Please wait a little while and try again, or contact the Workshop Manager.';
    end if;
  end if;

  begin
    insert into public.workshop_registrations
      (month_id, member_id, is_member, name, email, phone, fee, nonmember_fee, kit_fee, total_due)
    values (p_month_id, case when v_is_member then public.current_member_id() end, v_is_member,
            v_name, v_email, v_phone, v_fee, v_nm, v_kit, v_total)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'That email address is already signed up for this workshop.';
  end;

  -- Counted only when the sign-up was saved (a refused attempt rolls back anyway).
  if not v_is_member then
    insert into public.workshop_signup_log (ip, email_lc, month_id) values (v_ip, lower(v_email), p_month_id);
  end if;

  return jsonb_build_object('id', v_id, 'total_due', v_total, 'fee', v_fee, 'nonmember_fee', v_nm, 'kit_fee', v_kit, 'is_member', v_is_member);
end $$;
grant execute on function public.workshop_signup(uuid, text, text, text, text) to anon, authenticated;

commit;
