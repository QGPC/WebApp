-- =====================================================================
-- 22-workshops.sql  (run once, after 21-program-costs.sql)
-- Workshop sign-up, registrations, acceptance and locked materials.
-- Payment is NOT connected yet: a sign-up starts on the waitlist (unpaid).
-- The Workshop Manager records a payment with "Mark paid" until Zeffy is linked.
--
-- A registration's status:
--   waitlist  not paid yet, or the workshop was full when it was paid
--   waiting   paid and holding a spot, waiting for the Workshop Manager to accept it
--   accepted  accepted: patterns and materials are open to the person
-- Spots held = waiting + accepted. A workshop is full when held reaches its spots.
-- Safe to run twice.
-- =====================================================================

-- Workshop Manager = Workshops Chair, Program Chair, Administrators, Superuser.
create or replace function public.can_manage_workshops()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('workshop_chair') or public.has_role('program_chair')
$$;

-- Two small additions to the month: who collects the kit fee, and the Zeffy link (added later).
alter table public.program_months
  add column if not exists ws_kit_guild boolean not null default false,   -- true = the Guild collects the kit fee with the registration
  add column if not exists ws_pay_url   text check (ws_pay_url is null or ws_pay_url ~* '^https?://'),
  add column if not exists ws_nonmember_ok boolean not null default false;   -- the Workshop Manager's "Non-member sign-up allowed" switch

create table if not exists public.workshop_registrations (
  id             uuid primary key default gen_random_uuid(),
  month_id       uuid not null references public.program_months (id) on delete cascade,
  member_id      uuid references public.members (id) on delete set null,
  is_member      boolean not null default false,
  name           text not null check (length(btrim(name)) > 0),
  email          text not null check (position('@' in email) > 1),
  phone          text,
  fee            numeric(8,2) not null default 0,
  nonmember_fee  numeric(8,2) not null default 0,
  kit_fee        numeric(8,2) not null default 0,
  total_due      numeric(8,2) not null default 0,
  paid           boolean not null default false,
  paid_at        timestamptz,
  status         text not null default 'waitlist' check (status in ('waitlist', 'waiting', 'accepted')),
  signed_up_at   timestamptz not null default now(),
  accepted_at    timestamptz,
  access_token   text unique,
  last_accepted_email_at timestamptz,
  email_error    text
);
create unique index if not exists wreg_one_per_email on public.workshop_registrations (month_id, lower(email));
create index if not exists wreg_by_month on public.workshop_registrations (month_id, status);
create index if not exists wreg_by_member on public.workshop_registrations (member_id);

create table if not exists public.workshop_materials (
  id         uuid primary key default gen_random_uuid(),
  month_id   uuid not null references public.program_months (id) on delete cascade,
  name       text not null check (length(btrim(name)) > 0),
  path       text not null,            -- inside the private bucket: <month_id>/<random>-<file>
  bytes      bigint,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists wmat_by_month on public.workshop_materials (month_id, sort_order);

alter table public.workshop_registrations enable row level security;
alter table public.workshop_materials     enable row level security;

grant select on public.workshop_registrations to authenticated;
grant select on public.workshop_materials to anon, authenticated;
grant insert, update, delete on public.workshop_materials to authenticated;

-- People see their own registration; managers see all. Nobody writes registrations directly (functions below do).
drop policy if exists wreg_select on public.workshop_registrations;
create policy wreg_select on public.workshop_registrations for select to authenticated
  using (public.can_manage_workshops() or member_id = public.current_member_id());

-- The file list (names only) is public for published months, so locked files can be shown greyed out.
drop policy if exists wmat_select on public.workshop_materials;
create policy wmat_select on public.workshop_materials for select to anon, authenticated
  using (public.can_edit_programs()
         or exists (select 1 from public.program_months m where m.id = month_id and m.status = 'published'));
drop policy if exists wmat_write on public.workshop_materials;
create policy wmat_write on public.workshop_materials for all to authenticated
  using (public.can_edit_programs()) with check (public.can_edit_programs());

-- Private bucket for the files themselves.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('workshop-materials', 'workshop-materials', false, 20971520,
  array['application/pdf','image/jpeg','image/png',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/msword'])
on conflict (id) do update
  set public = false, file_size_limit = 20971520,
      allowed_mime_types = array['application/pdf','image/jpeg','image/png',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/msword'];

drop policy if exists wm_files_insert on storage.objects;
create policy wm_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'workshop-materials' and public.can_edit_programs());
drop policy if exists wm_files_update on storage.objects;
create policy wm_files_update on storage.objects for update to authenticated
  using (bucket_id = 'workshop-materials' and public.can_edit_programs())
  with check (bucket_id = 'workshop-materials' and public.can_edit_programs());
drop policy if exists wm_files_delete on storage.objects;
create policy wm_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'workshop-materials' and public.can_edit_programs());
-- Download: planners, managers, and a member whose registration for that workshop is accepted.
drop policy if exists wm_files_select on storage.objects;
create policy wm_files_select on storage.objects for select to authenticated
  using (bucket_id = 'workshop-materials' and (
    public.can_edit_programs() or public.can_manage_workshops()
    or exists (select 1 from public.workshop_registrations r
               where r.member_id = public.current_member_id() and r.status = 'accepted'
                 and r.month_id::text = split_part(name, '/', 1))
  ));

-- ---------------------------------------------------------------------
-- Sign up. Visitors may call this.
-- A signed-in member signs up as a member (name and email come from the member record).
-- Anyone else is a non-member: only allowed when the Workshop Manager has turned on
-- "Non-member sign-up allowed" for that workshop; they give name, email and phone and pay the non-member fee.
-- Starts on the waitlist, unpaid. Returns what is due so the payment step can use it.
-- ---------------------------------------------------------------------
create or replace function public.workshop_signup(
  p_month_id uuid, p_name text, p_email text, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.program_months%rowtype;
  mem public.members%rowtype;
  v_is_member boolean := (public.current_member_id() is not null and public.can_see_members_area());
  v_name text; v_email text; v_phone text; v_nm numeric := 0; v_kit numeric := 0; v_fee numeric;
  v_year int; v_id uuid; v_total numeric;
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

  begin
    insert into public.workshop_registrations
      (month_id, member_id, is_member, name, email, phone, fee, nonmember_fee, kit_fee, total_due)
    values (p_month_id, case when v_is_member then public.current_member_id() end, v_is_member,
            v_name, v_email, v_phone, v_fee, v_nm, v_kit, v_total)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'That email address is already signed up for this workshop.';
  end;
  return jsonb_build_object('id', v_id, 'total_due', v_total, 'fee', v_fee, 'nonmember_fee', v_nm, 'kit_fee', v_kit, 'is_member', v_is_member);
end $$;
grant execute on function public.workshop_signup(uuid, text, text, text) to anon, authenticated;

-- The Workshop Manager's switch: may non-members sign up for this workshop?
create or replace function public.workshop_set_nonmember_ok(p_month_id uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  update public.program_months set ws_nonmember_ok = coalesce(p_on, false) where id = p_month_id;
end $$;
grant execute on function public.workshop_set_nonmember_ok(uuid, boolean) to authenticated;

-- Spots held by a workshop (paid and waiting, or accepted).
create or replace function public.workshop_held(p_month_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.workshop_registrations
  where month_id = p_month_id and status in ('waiting', 'accepted')
$$;

-- Record a payment (the Workshop Manager's "Mark paid" / "Promote from the waitlist").
-- Takes a spot if one is open; otherwise the person stays on the waitlist, paid.
create or replace function public.workshop_mark_paid(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare r public.workshop_registrations%rowtype; m public.program_months%rowtype; v_status text;
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  select * into r from public.workshop_registrations where id = p_id for update;
  if not found then raise exception 'No such registration.'; end if;
  select * into m from public.program_months where id = r.month_id;
  if r.status in ('waiting', 'accepted') then return r.status; end if;
  if m.ws_spots is not null and public.workshop_held(r.month_id) >= m.ws_spots then
    raise exception 'The workshop is full.';
  end if;
  update public.workshop_registrations set paid = true, paid_at = coalesce(paid_at, now()), status = 'waiting' where id = p_id;
  return 'waiting';
end $$;
grant execute on function public.workshop_mark_paid(uuid) to authenticated;

-- Accept: opens the materials. Makes the private link token for a non-member.
create or replace function public.workshop_accept(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  update public.workshop_registrations
     set status = 'accepted', accepted_at = now(),
         access_token = coalesce(access_token, replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
   where id = p_id and status = 'waiting';
  if not found then raise exception 'That registration is not waiting for acceptance.'; end if;
end $$;
grant execute on function public.workshop_accept(uuid) to authenticated;

-- Undo accept: locks the files again (the private link stops working until accepted again).
create or replace function public.workshop_unaccept(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  update public.workshop_registrations set status = 'waiting' where id = p_id and status = 'accepted';
end $$;
grant execute on function public.workshop_unaccept(uuid) to authenticated;

create or replace function public.workshop_remove(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  delete from public.workshop_registrations where id = p_id;
end $$;
grant execute on function public.workshop_remove(uuid) to authenticated;

-- Public numbers for the workshop card: spots held, and how many more registrations are needed
-- for the workshop to run (break-even after the Maximum Workshop Subsidy).
-- Returns only counts, never costs.
create or replace function public.workshop_status(p_month_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  m public.program_months%rowtype; v_held int; v_total numeric; v_pct numeric; v_need int := null; v_more int := null;
begin
  select * into m from public.program_months where id = p_month_id and status = 'published' and has_workshop;
  if not found then return null; end if;
  v_held := public.workshop_held(p_month_id);
  select coalesce((select ws_fee from public.program_month_costs where month_on = m.month_on), 0)
       + coalesce((select sum(amount * (100 - pct_program) / 100) from public.program_costs where month_on = m.month_on), 0)
    into v_total;
  select coalesce(max_subsidy_pct, 0) into v_pct from public.workshop_settings where id = 1;
  if v_total > 0 and coalesce(m.ws_fee, 0) > 0 then
    v_need := ceil((v_total - v_total * coalesce(v_pct, 0) / 100) / m.ws_fee);
    v_more := greatest(v_need - v_held, 0);
  end if;
  return jsonb_build_object('spots', m.ws_spots, 'held', v_held,
    'spots_left', case when m.ws_spots is null then null else greatest(m.ws_spots - v_held, 0) end,
    'more_needed', v_more);
end $$;
grant execute on function public.workshop_status(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- The Workshop Manager also sees the workshop total cost and the settings (for the cost analysis block).
-- ---------------------------------------------------------------------
create or replace function public.workshop_total_cost(p_month date)
returns numeric language sql stable security definer set search_path = public as $$
  select case when public.can_edit_programs() or public.can_manage_workshops() then
    coalesce((select ws_fee from public.program_month_costs where month_on = p_month), 0)
    + coalesce((select sum(amount * (100 - pct_program) / 100) from public.program_costs where month_on = p_month), 0)
  end
$$;
grant execute on function public.workshop_total_cost(date) to authenticated;

drop policy if exists wset_select on public.workshop_settings;
create policy wset_select on public.workshop_settings for select to authenticated
  using (public.can_edit_programs() or public.can_manage_workshops() or public.is_admin());

-- The non-member fee for a published workshop, so the sign-up form can show it (the fee table itself is not public).
create or replace function public.workshop_nonmember_fee(p_month_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select f.fee from public.nonmember_fees f
                   where f.year = extract(year from coalesce(m.ws_date, m.month_on))::int), 0)
  from public.program_months m where m.id = p_month_id and m.status = 'published' and m.has_workshop
$$;
grant execute on function public.workshop_nonmember_fee(uuid) to anon, authenticated;
