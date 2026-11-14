-- =====================================================================
-- 26-comfort-quilts.sql  (run once in the Supabase SQL editor, after 25)
-- Comfort Quilts: page text, sizes and organizations (public); the Pattern
-- Library with kits and kit claims, and Quilts Needing Work with claims
-- (members only); the quilts-in and quilts-out log behind the statistics.
-- Kept by the Comfort Quilts Chair, Administrators and the Superuser.
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): tables comfort_settings,
-- comfort_sizes, comfort_orgs, comfort_patterns, comfort_kit_claims,
-- quilts_needing_work, comfort_log_in, comfort_log_out, comfort_year_start;
-- private Storage bucket comfort-patterns.
-- =====================================================================

create or replace function public.can_manage_comfort()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('comfort_quilts_chair')
$$;

-- ---------------------------------------------------------------------
-- Page text, sizes, organizations (everyone reads)
-- ---------------------------------------------------------------------
create table if not exists public.comfort_settings (
  id         boolean primary key default true check (id),   -- one row only
  intro      text not null default '',
  drop_off   text not null default '',
  needs      jsonb not null default '[]'::jsonb,            -- list of short text lines
  updated_at timestamptz not null default now()
);
insert into public.comfort_settings (id, intro, drop_off)
values (true,
  'Our members make quilts for people who need comfort, and anyone is welcome to help.',
  'Bring finished quilts to any Guild meeting, or contact the Comfort Quilts Chair.')
on conflict (id) do nothing;

create table if not exists public.comfort_sizes (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(btrim(name)) > 0),
  finished_size text,
  sort_order    int not null default 0
);
insert into public.comfort_sizes (name, sort_order)
select v.name, v.n from (values ('Baby / NICU', 1), ('Child', 2), ('Lap / wheelchair', 3), ('Teen / adult', 4)) as v(name, n)
where not exists (select 1 from public.comfort_sizes);

create table if not exists public.comfort_orgs (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) > 0),
  address    text,
  what       text,                  -- what the Guild gives them
  website    text check (website is null or website ~* '^https?://'),
  sort_order int not null default 0
);

create or replace function public.comfort_sort_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and coalesce(new.sort_order, 0) = 0 then
    execute format('select coalesce(max(sort_order), 0) + 1 from public.%I', tg_table_name) into new.sort_order;
  end if;
  return new;
end $$;
drop trigger if exists comfort_sizes_sort on public.comfort_sizes;
create trigger comfort_sizes_sort before insert on public.comfort_sizes for each row execute function public.comfort_sort_stamp();
drop trigger if exists comfort_orgs_sort on public.comfort_orgs;
create trigger comfort_orgs_sort before insert on public.comfort_orgs for each row execute function public.comfort_sort_stamp();

alter table public.comfort_settings enable row level security;
alter table public.comfort_sizes    enable row level security;
alter table public.comfort_orgs     enable row level security;
grant select on public.comfort_settings, public.comfort_sizes, public.comfort_orgs to anon;
grant select, insert, update, delete on public.comfort_settings, public.comfort_sizes, public.comfort_orgs to authenticated;

do $$
declare t text;
begin
  foreach t in array array['comfort_settings', 'comfort_sizes', 'comfort_orgs'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.can_manage_comfort())', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.can_manage_comfort()) with check (public.can_manage_comfort())', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.can_manage_comfort())', t || '_delete', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Pattern Library and kit claims (members only)
-- ---------------------------------------------------------------------
create table if not exists public.comfort_patterns (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(btrim(name)) > 0),
  size_name      text,
  level          text not null default 'Beginner' check (level in ('Beginner', 'Easy', 'Intermediate')),
  pdf_path       text,                    -- file in the private bucket comfort-patterns
  photo_path     text,
  kits_available int  not null default 0 check (kits_available >= 0),
  created_by     uuid default public.current_member_id() references public.members (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
drop trigger if exists comfort_patterns_updated on public.comfort_patterns;
create trigger comfort_patterns_updated before update on public.comfort_patterns
  for each row execute function public.set_updated_at();

create table if not exists public.comfort_kit_claims (
  id             uuid primary key default gen_random_uuid(),
  pattern_id     uuid not null references public.comfort_patterns (id) on delete cascade,
  member_id      uuid not null references public.members (id) on delete cascade,
  claimed_at     timestamptz not null default now(),
  seen_by_chair  boolean not null default false,
  unique (pattern_id, member_id)           -- one kit per member per pattern
);

alter table public.comfort_patterns   enable row level security;
alter table public.comfort_kit_claims enable row level security;
revoke all on public.comfort_patterns, public.comfort_kit_claims from anon;
grant select, insert, update, delete on public.comfort_patterns, public.comfort_kit_claims to authenticated;

drop policy if exists comfort_patterns_select on public.comfort_patterns;
create policy comfort_patterns_select on public.comfort_patterns
  for select to authenticated using (public.can_see_members_area() or public.can_manage_comfort());
drop policy if exists comfort_patterns_insert on public.comfort_patterns;
create policy comfort_patterns_insert on public.comfort_patterns
  for insert to authenticated with check (public.can_manage_comfort());
drop policy if exists comfort_patterns_update on public.comfort_patterns;
create policy comfort_patterns_update on public.comfort_patterns
  for update to authenticated using (public.can_manage_comfort()) with check (public.can_manage_comfort());
drop policy if exists comfort_patterns_delete on public.comfort_patterns;
create policy comfort_patterns_delete on public.comfort_patterns
  for delete to authenticated using (public.can_manage_comfort());

-- Members create a claim only through comfort_kit_claim() below (no insert policy).
drop policy if exists comfort_kit_claims_select on public.comfort_kit_claims;
create policy comfort_kit_claims_select on public.comfort_kit_claims
  for select to authenticated using (member_id = public.current_member_id() or public.can_manage_comfort());
drop policy if exists comfort_kit_claims_update on public.comfort_kit_claims;
create policy comfort_kit_claims_update on public.comfort_kit_claims
  for update to authenticated using (public.can_manage_comfort()) with check (public.can_manage_comfort());
drop policy if exists comfort_kit_claims_delete on public.comfort_kit_claims;
create policy comfort_kit_claims_delete on public.comfort_kit_claims
  for delete to authenticated using (member_id = public.current_member_id() or public.can_manage_comfort());

-- The list members see: kits left and whether the member already has one. "New" = added in the last 30 days.
create or replace function public.comfort_patterns_list()
returns table (id uuid, name text, size_name text, level text, pdf_path text, photo_path text,
               kits_left int, mine boolean, is_new boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.size_name, p.level, p.pdf_path, p.photo_path,
         greatest(0, p.kits_available - (select count(*) from public.comfort_kit_claims c where c.pattern_id = p.id))::int,
         exists (select 1 from public.comfort_kit_claims c where c.pattern_id = p.id and c.member_id = public.current_member_id()),
         p.created_at > now() - interval '30 days'
  from public.comfort_patterns p
  where public.can_see_members_area() or public.can_manage_comfort()
  order by p.name
$$;

create or replace function public.comfort_kit_claim(p_pattern uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id(); pat public.comfort_patterns; taken int;
begin
  if me is null or not (public.can_see_members_area() or public.can_manage_comfort()) then
    raise exception 'Please sign in as a member to claim a kit.';
  end if;
  select * into pat from public.comfort_patterns where id = p_pattern for update;
  if not found then raise exception 'That pattern is no longer in the library.'; end if;
  if exists (select 1 from public.comfort_kit_claims where pattern_id = p_pattern and member_id = me) then return; end if;
  select count(*) into taken from public.comfort_kit_claims where pattern_id = p_pattern;
  if pat.kits_available - taken <= 0 then raise exception 'All of the kits for this pattern have been claimed.'; end if;
  insert into public.comfort_kit_claims (pattern_id, member_id) values (p_pattern, me);
end $$;

create or replace function public.comfort_kit_release(p_pattern uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.comfort_kit_claims where pattern_id = p_pattern and member_id = public.current_member_id();
end $$;

-- The chair sees who claimed which kit.
create or replace function public.comfort_kit_claims_list()
returns table (id uuid, pattern_id uuid, pattern_name text, size_name text, level text,
               member_name text, claimed_at timestamptz, seen_by_chair boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.pattern_id, p.name, p.size_name, p.level,
         btrim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')), c.claimed_at, c.seen_by_chair
  from public.comfort_kit_claims c
  join public.comfort_patterns p on p.id = c.pattern_id
  join public.members m on m.id = c.member_id
  where public.can_manage_comfort()
  order by c.claimed_at desc
$$;

create or replace function public.comfort_kits_mark_seen()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_comfort() then raise exception 'Not allowed.'; end if;
  update public.comfort_kit_claims set seen_by_chair = true where not seen_by_chair;
end $$;

-- ---------------------------------------------------------------------
-- Quilts Needing Work (members only)
-- ---------------------------------------------------------------------
create table if not exists public.quilts_needing_work (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(btrim(name)) > 0),
  size_name     text,
  need          text not null default 'Quilting' check (need in ('Quilting', 'Binding')),
  note          text,
  added_at      timestamptz not null default now(),
  claimed_by    uuid references public.members (id) on delete set null,
  claimed_at    timestamptz,
  seen_by_chair boolean not null default false,
  finished_at   timestamptz
);
create index if not exists qnw_open on public.quilts_needing_work (added_at) where finished_at is null;

alter table public.quilts_needing_work enable row level security;
revoke all on public.quilts_needing_work from anon;
grant select, insert, update, delete on public.quilts_needing_work to authenticated;
drop policy if exists qnw_select on public.quilts_needing_work;
create policy qnw_select on public.quilts_needing_work for select to authenticated using (public.can_manage_comfort());
drop policy if exists qnw_insert on public.quilts_needing_work;
create policy qnw_insert on public.quilts_needing_work for insert to authenticated with check (public.can_manage_comfort());
drop policy if exists qnw_update on public.quilts_needing_work;
create policy qnw_update on public.quilts_needing_work for update to authenticated
  using (public.can_manage_comfort()) with check (public.can_manage_comfort());
drop policy if exists qnw_delete on public.quilts_needing_work;
create policy qnw_delete on public.quilts_needing_work for delete to authenticated using (public.can_manage_comfort());

-- Members see the open list through this function (no names of other claimers; the chair gets names).
create or replace function public.quilts_nw_list()
returns table (id uuid, name text, size_name text, need text, note text, added_at timestamptz,
               claimed boolean, mine boolean, claimed_by_name text, claimed_at timestamptz, seen_by_chair boolean)
language sql stable security definer set search_path = public as $$
  select q.id, q.name, q.size_name, q.need, q.note, q.added_at,
         q.claimed_by is not null,
         q.claimed_by is not null and q.claimed_by = public.current_member_id(),
         case when public.can_manage_comfort() and q.claimed_by is not null
              then (select btrim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')) from public.members m where m.id = q.claimed_by) end,
         q.claimed_at, q.seen_by_chair
  from public.quilts_needing_work q
  where q.finished_at is null and (public.can_see_members_area() or public.can_manage_comfort())
  order by q.added_at
$$;

create or replace function public.quilt_claim(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id(); q public.quilts_needing_work;
begin
  if me is null or not (public.can_see_members_area() or public.can_manage_comfort()) then
    raise exception 'Please sign in as a member to claim a quilt.';
  end if;
  select * into q from public.quilts_needing_work where id = p_id and finished_at is null for update;
  if not found then raise exception 'That quilt is no longer on the list.'; end if;
  if q.claimed_by is not null and q.claimed_by <> me then raise exception 'Another member is finishing this one.'; end if;
  update public.quilts_needing_work set claimed_by = me, claimed_at = coalesce(q.claimed_at, now()),
         seen_by_chair = case when q.claimed_by = me then q.seen_by_chair else false end
   where id = p_id;
end $$;

-- A member gives back their own claim; the chair can release any claim.
create or replace function public.quilt_release(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.quilts_needing_work
     set claimed_by = null, claimed_at = null, seen_by_chair = false
   where id = p_id and finished_at is null
     and (claimed_by = public.current_member_id() or public.can_manage_comfort());
end $$;

create or replace function public.quilts_mark_seen()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_comfort() then raise exception 'Not allowed.'; end if;
  update public.quilts_needing_work set seen_by_chair = true
   where claimed_by is not null and not seen_by_chair and finished_at is null;
end $$;

-- ---------------------------------------------------------------------
-- Quilts in and out (the statistics). Raw log is chair-only; the public
-- numbers come from comfort_public_stats() below.
-- ---------------------------------------------------------------------
create table if not exists public.comfort_log_in (
  id          uuid primary key default gen_random_uuid(),
  received_on date not null,
  n           int  not null check (n > 0),
  source      text not null default 'manual',        -- manual, or finished (from Quilts Needing Work)
  created_by  uuid default public.current_member_id() references public.members (id) on delete set null,
  created_at  timestamptz not null default now()
);
create table if not exists public.comfort_log_out (
  id         uuid primary key default gen_random_uuid(),
  given_on   date not null,
  n          int  not null check (n > 0),
  org_id     uuid references public.comfort_orgs (id) on delete set null,
  org_label  text not null,                           -- the organization's name when logged, or the "other" name
  created_by uuid default public.current_member_id() references public.members (id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.comfort_year_start (
  year    smallint primary key check (year between 2000 and 2100),
  on_hand int not null check (on_hand >= 0)           -- quilts on hand on January 1
);
create index if not exists comfort_log_in_date  on public.comfort_log_in (received_on);
create index if not exists comfort_log_out_date on public.comfort_log_out (given_on);

alter table public.comfort_log_in     enable row level security;
alter table public.comfort_log_out    enable row level security;
alter table public.comfort_year_start enable row level security;
revoke all on public.comfort_log_in, public.comfort_log_out, public.comfort_year_start from anon;
grant select, insert, update, delete on public.comfort_log_in, public.comfort_log_out, public.comfort_year_start to authenticated;

do $$
declare t text;
begin
  foreach t in array array['comfort_log_in', 'comfort_log_out', 'comfort_year_start'] loop
    execute format('drop policy if exists %I on public.%I', t || '_all', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.can_manage_comfort()) with check (public.can_manage_comfort())', t || '_all', t);
  end loop;
end $$;

-- "By the numbers" on the public Comfort Quilts page.
create or replace function public.comfort_public_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  today date := public.guild_today();
  y int := extract(year from public.guild_today());
  m int := extract(month from public.guild_today());
  ys date := make_date(extract(year from public.guild_today())::int, 1, 1);
  ms date := make_date(extract(year from public.guild_today())::int, extract(month from public.guild_today())::int, 1);
  orgs jsonb; other_n int;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'given', coalesce(g.n, 0)) order by o.sort_order), '[]'::jsonb)
    into orgs
  from public.comfort_orgs o
  left join (select org_id, sum(n)::int n from public.comfort_log_out
              where given_on >= ys and given_on <= today and org_id is not null group by org_id) g on g.org_id = o.id;
  select coalesce(sum(n), 0)::int into other_n from public.comfort_log_out
   where given_on >= ys and given_on <= today and org_id is null;
  return jsonb_build_object(
    'as_of', today, 'year', y, 'month', m,
    'month_in',  (select coalesce(sum(n), 0)::int from public.comfort_log_in  where received_on >= ms and received_on <= today),
    'month_out', (select coalesce(sum(n), 0)::int from public.comfort_log_out where given_on    >= ms and given_on    <= today),
    'ytd_in',    (select coalesce(sum(n), 0)::int from public.comfort_log_in  where received_on >= ys and received_on <= today),
    'ytd_out',   (select coalesce(sum(n), 0)::int from public.comfort_log_out where given_on    >= ys and given_on    <= today),
    'orgs', orgs, 'other_given', other_n);
end $$;

-- Marking a quilt finished takes it off the list and counts one more quilt in, today.
create or replace function public.quilt_finish(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_comfort() then raise exception 'Not allowed.'; end if;
  update public.quilts_needing_work set finished_at = now() where id = p_id and finished_at is null;
  if found then
    insert into public.comfort_log_in (received_on, n, source) values (public.guild_today(), 1, 'finished');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Counts: badge for the chair, and the unclaimed count for the members' button
-- ---------------------------------------------------------------------
create or replace function public.comfort_chair_counts()
returns table (new_quilts int, new_kits int)
language sql stable security definer set search_path = public as $$
  select case when public.can_manage_comfort()
              then (select count(*)::int from public.quilts_needing_work where claimed_by is not null and not seen_by_chair and finished_at is null) else 0 end,
         case when public.can_manage_comfort()
              then (select count(*)::int from public.comfort_kit_claims where not seen_by_chair) else 0 end
$$;

create or replace function public.quilts_unclaimed_count()
returns int language sql stable security definer set search_path = public as $$
  select case when public.can_see_members_area() or public.can_manage_comfort()
              then (select count(*)::int from public.quilts_needing_work where finished_at is null and claimed_by is null) else 0 end
$$;

-- ---------------------------------------------------------------------
-- Private Storage bucket for pattern PDFs and photos (members read, the chair writes)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comfort-patterns', 'comfort-patterns', false, 20971520,
        array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists cp_files_select on storage.objects;
create policy cp_files_select on storage.objects
  for select to authenticated
  using (bucket_id = 'comfort-patterns' and (public.can_see_members_area() or public.can_manage_comfort()));
drop policy if exists cp_files_insert on storage.objects;
create policy cp_files_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'comfort-patterns' and public.can_manage_comfort());
drop policy if exists cp_files_update on storage.objects;
create policy cp_files_update on storage.objects
  for update to authenticated
  using (bucket_id = 'comfort-patterns' and public.can_manage_comfort())
  with check (bucket_id = 'comfort-patterns' and public.can_manage_comfort());
drop policy if exists cp_files_delete on storage.objects;
create policy cp_files_delete on storage.objects
  for delete to authenticated using (bucket_id = 'comfort-patterns' and public.can_manage_comfort());

-- ---------------------------------------------------------------------
-- Function permissions
-- ---------------------------------------------------------------------
revoke all on function
  public.comfort_patterns_list(), public.comfort_kit_claim(uuid), public.comfort_kit_release(uuid),
  public.comfort_kit_claims_list(), public.comfort_kits_mark_seen(),
  public.quilts_nw_list(), public.quilt_claim(uuid), public.quilt_release(uuid), public.quilts_mark_seen(),
  public.quilt_finish(uuid), public.comfort_chair_counts(), public.quilts_unclaimed_count()
  from public, anon;
grant execute on function
  public.comfort_patterns_list(), public.comfort_kit_claim(uuid), public.comfort_kit_release(uuid),
  public.comfort_kit_claims_list(), public.comfort_kits_mark_seen(),
  public.quilts_nw_list(), public.quilt_claim(uuid), public.quilt_release(uuid), public.quilts_mark_seen(),
  public.quilt_finish(uuid), public.comfort_chair_counts(), public.quilts_unclaimed_count()
  to authenticated;
revoke all on function public.comfort_public_stats() from public;
grant execute on function public.comfort_public_stats() to anon, authenticated;
