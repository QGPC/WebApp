-- =====================================================================
-- Guild Website/App: foundation database setup (file 01)
-- Quilter's Guild of Parker County
--
-- HOW TO RUN: in the Supabase dashboard open SQL Editor > New query,
-- paste this whole file, press Run. It is safe to run again later
-- (it uses IF NOT EXISTS, OR REPLACE and DROP ... IF EXISTS).
--
-- WHAT IT CREATES
--   roles            the list of roles (Superuser, Administrator, board, chairs)
--   members          one row per member (the 11 import columns, plus links)
--   member_roles     who holds which role (the Superuser is DATA, not code)
--   site_config      one row: testing/live mode, renewals switch, backup reminder days
--   site_log         a log only the Superuser can read
--   functions        has_role, is_superuser, is_admin, is_active_member,
--                    membership_status (Active / grace / Inactive, worked out
--                    from Paid through, never stored)
--   access rules     row level security on every table
--   a link           that connects a sign-in account to the member row with the
--                    same email address
--
-- WHAT IT DOES NOT DO (later numbered files): programs, workshops, messages,
-- notices, calendars, kits, quilt statistics, requests, backups, storage buckets.
-- Not yet enforced here: the "acting as" role switch (Administrator and
-- Superuser must be switched into on purpose). That comes with the sign-in work.
--
-- Nothing in this file is secret. Do not put passwords or keys in it.
-- =====================================================================

-- ---------- 1. small helper ----------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------- 2. roles (a list, so roles can be added as data) ----------
create table if not exists public.roles (
  role_key   text primary key,
  label      text not null,
  sort_order int  not null default 100
);

insert into public.roles (role_key, label, sort_order) values
  ('superuser',              'Superuser',                              1),
  ('administrator',          'Administrator',                          2),
  ('president',              'President',                             10),
  ('vice_president',         'Vice President',                        11),
  ('secretary',              'Secretary',                             12),
  ('treasurer',              'Treasurer',                             13),
  ('past_president',         'Past President',                        14),
  ('newsletter_chair',       'Newsletter Chair',                      30),
  ('workshop_chair',         'Workshops Chair',                       31),
  ('membership_chair',       'Membership Chair',                      32),
  ('comfort_quilts_chair',   'Comfort Quilts Chair',                  33),
  ('sunshine_shadows_chair', 'Sunshine & Shadows Chair',              34),
  ('beekeeper',              'Beekeeper',                             35),
  ('program_chair',          'Program Chair (Next Year''s Programs)', 36),
  ('publicity_chair',        'Publicity Chair',                       37),
  ('digital_av_coordinator', 'Digital & A/V Coordinator',             38),
  ('show_and_tell_chair',    'Show & Tell Chair',                     39),
  ('finance_assets_chair',   'Finance & Assets Chair',                40),
  ('retreats_chair',         'Retreats Chair',                        41),
  ('quilt_show_chair',       'Quilt Show Chair',                      42),
  ('auction_chair',          'Auction Chair',                         43)
on conflict (role_key) do update
  set label = excluded.label, sort_order = excluded.sort_order;

-- ---------- 3. members ----------
create table if not exists public.members (
  id                uuid primary key default gen_random_uuid(),
  auth_user_id      uuid unique references auth.users (id) on delete set null,
  email             text not null,
  first_name        text not null,
  last_name         text not null,
  membership_type   text not null check (membership_type in ('Regular', 'Exempt', 'Junior')),
  member_since      int  check (member_since between 1900 and 2200),
  paid_through_year int  check (paid_through_year between 1900 and 2200),
  cell_phone        text,
  facebook_name     text,
  mailing_address   text,
  directory_opt_out boolean not null default false,
  birthday_month    smallint check (birthday_month between 1 and 12),
  birthday_day      smallint check (birthday_day between 1 and 31),
  import_batch_id   uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- one member per email address, ignoring capital letters
create unique index if not exists members_email_lower_key
  on public.members (lower(email));

-- Active / grace / inactive, worked out on the day (never stored).
-- Active : Paid through is this year or later.
-- grace  : Paid through is last year and today is on or before March 31.
-- inactive: anything else (including no Paid through).
create or replace function public.membership_status(p_paid_through int, p_on date default current_date)
returns text language sql immutable as $$
  select case
    when p_paid_through is null then 'inactive'
    when p_paid_through >= extract(year from p_on)::int then 'active'
    when p_paid_through = extract(year from p_on)::int - 1
         and p_on <= make_date(extract(year from p_on)::int, 3, 31) then 'grace'
    else 'inactive'
  end
$$;

-- ---------- 4. who holds which role ----------
create table if not exists public.member_roles (
  member_id   uuid not null references public.members (id) on delete cascade,
  role_key    text not null references public.roles (role_key),
  assigned_by uuid references public.members (id) on delete set null,
  assigned_at timestamptz not null default now(),
  primary key (member_id, role_key)
);

-- ---------- 5. site settings (exactly one row) and the site log ----------
create table if not exists public.site_config (
  id                   boolean primary key default true check (id),
  site_mode            text not null default 'testing' check (site_mode in ('testing', 'live')),
  renewals_open        boolean not null default false,
  backup_reminder_days int not null default 30 check (backup_reminder_days > 0),
  went_live_at         timestamptz,
  updated_at           timestamptz not null default now()
);
insert into public.site_config (id) values (true) on conflict do nothing;

create table if not exists public.site_log (
  id              bigint generated always as identity primary key,
  at              timestamptz not null default now(),
  actor_member_id uuid references public.members (id) on delete set null,
  action          text not null,
  details         jsonb not null default '{}'::jsonb
);

-- ---------- 6. who is asking? (helper functions) ----------
-- These look at the signed-in person. They run with the database owner's
-- rights so the access rules below can use them without looping.
create or replace function public.current_member_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.members where auth_user_id = auth.uid() limit 1
$$;

create or replace function public.has_role(p_role text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.member_roles mr
    join public.members m on m.id = mr.member_id
    where m.auth_user_id = auth.uid() and mr.role_key = p_role
  )
$$;

create or replace function public.is_superuser()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('superuser')
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('superuser') or public.has_role('administrator')
$$;

-- An Active or grace-period member. Inactive members and visitors are treated the same.
create or replace function public.is_active_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.members m
    where m.auth_user_id = auth.uid()
      and public.membership_status(m.paid_through_year) in ('active', 'grace')
  )
$$;

-- Later member-only pages use this: an active member, or an Administrator / Superuser.
create or replace function public.can_see_members_area()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_active_member() or public.is_admin()
$$;

-- ---------- 7. guards (rules the website cannot get around) ----------
-- Changes made from the website run as 'anon' or 'authenticated'. Changes made
-- in the Supabase dashboard / SQL editor are not limited by the checks below.

-- members: tidy the email; only the Membership Chair, Administrators and the
-- Superuser may add members or change the membership record; an ordinary
-- member may change only their own contact details.
create or replace function public.members_guard()
returns trigger language plpgsql as $$
begin
  new.email := lower(btrim(new.email));
  new.updated_at := now();
  if current_user in ('anon', 'authenticated') then
    if not (public.is_admin() or public.has_role('membership_chair')) then
      if tg_op = 'INSERT' then
        raise exception 'Only the Membership Chair, an Administrator or the Superuser can add members.';
      end if;
      if old.auth_user_id is distinct from auth.uid() then
        raise exception 'You can change only your own record.';
      end if;
      if new.id              is distinct from old.id
         or new.auth_user_id    is distinct from old.auth_user_id
         or new.email           is distinct from old.email
         or new.membership_type is distinct from old.membership_type
         or new.member_since    is distinct from old.member_since
         or new.paid_through_year is distinct from old.paid_through_year
         or new.import_batch_id is distinct from old.import_batch_id then
        raise exception 'You can change your contact details, but not your membership record. Ask the Membership Chair.';
      end if;
    end if;
  end if;
  return new;
end $$;

-- members: if a sign-in account with the same email already exists, link it
create or replace function public.members_link_existing_account()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.auth_user_id is null then
    select u.id into new.auth_user_id
    from auth.users u
    where lower(u.email) = lower(btrim(new.email))
    limit 1;
  end if;
  return new;
end $$;

drop trigger if exists members_a_guard on public.members;
create trigger members_a_guard
  before insert or update on public.members
  for each row execute function public.members_guard();

drop trigger if exists members_b_link on public.members;
create trigger members_b_link
  before insert on public.members
  for each row execute function public.members_link_existing_account();

-- sign-in accounts: when an account is created, link it to the member row
-- with the same email (so approval-then-password-setup finds the member)
create or replace function public.link_auth_user_to_member()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.members
     set auth_user_id = new.id
   where lower(email) = lower(new.email)
     and auth_user_id is null;
  return new;
end $$;

drop trigger if exists on_auth_user_created_link_member on auth.users;
create trigger on_auth_user_created_link_member
  after insert on auth.users
  for each row execute function public.link_auth_user_to_member();

-- member_roles: stamp who assigned a role (website changes only)
create or replace function public.member_roles_stamp()
returns trigger language plpgsql as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.assigned_by := public.current_member_id();
    new.assigned_at := now();
  end if;
  return new;
end $$;

drop trigger if exists member_roles_stamp on public.member_roles;
create trigger member_roles_stamp
  before insert on public.member_roles
  for each row execute function public.member_roles_stamp();

-- member_roles: the last Superuser can never be removed
create or replace function public.member_roles_keep_last_superuser()
returns trigger language plpgsql as $$
begin
  if old.role_key = 'superuser'
     and (select count(*) from public.member_roles where role_key = 'superuser') <= 1 then
    raise exception 'The last Superuser cannot be removed.';
  end if;
  return old;
end $$;

drop trigger if exists member_roles_keep_last_superuser on public.member_roles;
create trigger member_roles_keep_last_superuser
  before delete on public.member_roles
  for each row execute function public.member_roles_keep_last_superuser();

-- site_config: Go live is one way from the website; note the moment it happens
create or replace function public.site_config_guard()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if current_user in ('anon', 'authenticated')
     and old.site_mode = 'live' and new.site_mode = 'testing' then
    raise exception 'The site is live and cannot be put back into testing mode from the website.';
  end if;
  if old.site_mode = 'testing' and new.site_mode = 'live' and new.went_live_at is null then
    new.went_live_at := now();
  end if;
  return new;
end $$;

drop trigger if exists site_config_guard on public.site_config;
create trigger site_config_guard
  before update on public.site_config
  for each row execute function public.site_config_guard();

-- site_config: write a log row when the mode, renewals switch or reminder days change
create or replace function public.site_config_log()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.site_mode is distinct from old.site_mode
     or new.renewals_open is distinct from old.renewals_open
     or new.backup_reminder_days is distinct from old.backup_reminder_days then
    insert into public.site_log (actor_member_id, action, details)
    values (public.current_member_id(), 'site_config changed',
            jsonb_build_object(
              'site_mode',            jsonb_build_array(old.site_mode, new.site_mode),
              'renewals_open',        jsonb_build_array(old.renewals_open, new.renewals_open),
              'backup_reminder_days', jsonb_build_array(old.backup_reminder_days, new.backup_reminder_days)));
  end if;
  return new;
end $$;

drop trigger if exists site_config_log on public.site_config;
create trigger site_config_log
  after update on public.site_config
  for each row execute function public.site_config_log();

-- ---------- 8. a view that shows each member's status ----------
create or replace view public.members_with_status
  with (security_invoker = true) as
select m.*, public.membership_status(m.paid_through_year) as status
from public.members m;

-- ---------- 9. access rules (row level security) ----------
alter table public.roles        enable row level security;
alter table public.members      enable row level security;
alter table public.member_roles enable row level security;
alter table public.site_config  enable row level security;
alter table public.site_log     enable row level security;

-- visitors (not signed in) get nothing except the site mode
revoke all on public.roles, public.members, public.member_roles, public.site_log from anon;
revoke all on public.members_with_status from anon;

-- roles: any signed-in person can read the list
drop policy if exists roles_select on public.roles;
create policy roles_select on public.roles
  for select to authenticated using (true);

-- members: you see your own record; the Membership Chair, Administrators and
-- the Superuser see everyone. (The directory for members comes later as a
-- separate safe view that respects "hide me from the Directory".)
drop policy if exists members_select on public.members;
create policy members_select on public.members
  for select to authenticated
  using (auth_user_id = auth.uid() or public.is_admin() or public.has_role('membership_chair'));

drop policy if exists members_insert on public.members;
create policy members_insert on public.members
  for insert to authenticated
  with check (public.is_admin() or public.has_role('membership_chair'));

drop policy if exists members_update on public.members;
create policy members_update on public.members
  for update to authenticated
  using (auth_user_id = auth.uid() or public.is_admin() or public.has_role('membership_chair'))
  with check (auth_user_id = auth.uid() or public.is_admin() or public.has_role('membership_chair'));

drop policy if exists members_delete on public.members;
create policy members_delete on public.members
  for delete to authenticated
  using (public.is_superuser());

-- member_roles: you see your own roles; Administrators and the Superuser see all.
-- Only the Superuser can give or take away Superuser and Administrator; an
-- Administrator can assign every other role.
drop policy if exists member_roles_select on public.member_roles;
create policy member_roles_select on public.member_roles
  for select to authenticated
  using (member_id = public.current_member_id() or public.is_admin());

drop policy if exists member_roles_insert on public.member_roles;
create policy member_roles_insert on public.member_roles
  for insert to authenticated
  with check (
    public.is_superuser()
    or (public.is_admin() and role_key not in ('superuser', 'administrator'))
  );

drop policy if exists member_roles_delete on public.member_roles;
create policy member_roles_delete on public.member_roles
  for delete to authenticated
  using (
    public.is_superuser()
    or (public.is_admin() and role_key not in ('superuser', 'administrator'))
  );

-- site_config: everyone can read it (the "testing mode" bar needs it);
-- only the Superuser can change it
drop policy if exists site_config_select on public.site_config;
create policy site_config_select on public.site_config
  for select to anon, authenticated using (true);

drop policy if exists site_config_update on public.site_config;
create policy site_config_update on public.site_config
  for update to authenticated
  using (public.is_superuser()) with check (public.is_superuser());

-- site_log: only the Superuser can read it; nobody writes to it from the website
drop policy if exists site_log_select on public.site_log;
create policy site_log_select on public.site_log
  for select to authenticated using (public.is_superuser());

-- ---------- 10. first Superusers (run by hand, from this editor only) ----------
-- This creates a member row and gives it the Superuser role. It cannot be
-- called from the website. The sign-in account is made separately (see the
-- steps that come with this file); when it is created it links to this row
-- by email address.
create or replace function public.bootstrap_superuser(p_email text, p_first_name text, p_last_name text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  insert into public.members (email, first_name, last_name, membership_type, paid_through_year)
  values (p_email, p_first_name, p_last_name, 'Regular', extract(year from current_date)::int)
  on conflict (lower(email)) do update
    set first_name = excluded.first_name, last_name = excluded.last_name
  returning id into v_id;

  insert into public.member_roles (member_id, role_key)
  values (v_id, 'superuser')
  on conflict do nothing;
end $$;

revoke all on function public.bootstrap_superuser(text, text, text) from public, anon, authenticated;

-- >>> Fill in the two Guild email addresses, remove the two leading dashes on
-- >>> each line, then run just those two lines.
-- select public.bootstrap_superuser('REX-EMAIL-HERE', 'Rex', 'Shrauner');
-- select public.bootstrap_superuser('PAM-EMAIL-HERE', 'Pam', 'Luke');
