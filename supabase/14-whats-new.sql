-- =====================================================================
-- 14-whats-new.sql  (run once, after 13-notices.sql)
-- "What's New": short posts about site changes, written by chairs, the
-- President, Vice President, Administrators and the Superuser, and shown
-- to members from the What's New button on the Guild home page.
-- Also a small "last seen" table so each member sees how many posts are new.
-- Safe to run twice.
-- =====================================================================

-- Anyone who holds any role (every chair, board member, Administrator, Superuser).
create or replace function public.can_post_whats_new()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.member_roles mr
    where mr.member_id = public.current_member_id()
  )
$$;

create table if not exists public.whats_new (
  id             uuid primary key default gen_random_uuid(),
  page_key       text not null default 'other',
  headline       text not null check (length(btrim(headline)) > 0),
  detail         text,
  link_label     text,
  link_url       text,
  posted_by      uuid references public.members (id) on delete set null,
  posted_by_role text,                       -- shown as "Posted by the <role>"
  posted_at      timestamptz not null default now(),
  expires_on     date not null              -- drops off after this day
);

create or replace function public.whats_new_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_member uuid; v_role text;
begin
  new.headline   := btrim(new.headline);
  new.detail     := nullif(btrim(coalesce(new.detail, '')), '');
  new.link_label := nullif(btrim(coalesce(new.link_label, '')), '');
  new.link_url   := nullif(btrim(coalesce(new.link_url, '')), '');
  if tg_op = 'INSERT' then
    v_member := public.current_member_id();
    new.posted_by := v_member;
    -- the poster's most senior role, for the "Posted by the ..." line
    select r.label into v_role
      from public.member_roles mr join public.roles r on r.role_key = mr.role_key
      where mr.member_id = v_member
      order by r.sort_order limit 1;
    new.posted_by_role := coalesce(v_role, 'Guild');
    new.posted_at := now();
  end if;
  return new;
end $$;

drop trigger if exists whats_new_stamp on public.whats_new;
create trigger whats_new_stamp before insert or update on public.whats_new
  for each row execute function public.whats_new_stamp();

create index if not exists whats_new_recent on public.whats_new (posted_at desc);

create table if not exists public.last_seen (
  member_id uuid not null references public.members (id) on delete cascade,
  page_key  text not null,
  seen_at   timestamptz not null default now(),
  primary key (member_id, page_key)
);

alter table public.whats_new enable row level security;
alter table public.last_seen enable row level security;

revoke all on public.whats_new, public.last_seen from anon;
grant select, insert, update, delete on public.whats_new, public.last_seen to authenticated;

-- Members (Active or grace) and Administrators read posts that have not expired.
drop policy if exists whats_new_select on public.whats_new;
create policy whats_new_select on public.whats_new
  for select to authenticated
  using (public.can_see_members_area() and expires_on >= public.guild_today());

-- Posters also see their own expired posts, and Administrators see all, to fix or remove them.
drop policy if exists whats_new_manage_select on public.whats_new;
create policy whats_new_manage_select on public.whats_new
  for select to authenticated
  using (public.is_admin() or (public.can_post_whats_new() and posted_by = public.current_member_id()));

drop policy if exists whats_new_insert on public.whats_new;
create policy whats_new_insert on public.whats_new
  for insert to authenticated with check (public.can_post_whats_new());

-- Edit or remove: your own posts; Administrators and the Superuser can change any.
drop policy if exists whats_new_update on public.whats_new;
create policy whats_new_update on public.whats_new
  for update to authenticated
  using (public.is_admin() or posted_by = public.current_member_id())
  with check (public.is_admin() or posted_by = public.current_member_id());

drop policy if exists whats_new_delete on public.whats_new;
create policy whats_new_delete on public.whats_new
  for delete to authenticated
  using (public.is_admin() or posted_by = public.current_member_id());

-- last_seen: each member reads and writes only their own rows.
drop policy if exists last_seen_select on public.last_seen;
create policy last_seen_select on public.last_seen
  for select to authenticated using (member_id = public.current_member_id());

drop policy if exists last_seen_insert on public.last_seen;
create policy last_seen_insert on public.last_seen
  for insert to authenticated with check (member_id = public.current_member_id());

drop policy if exists last_seen_update on public.last_seen;
create policy last_seen_update on public.last_seen
  for update to authenticated
  using (member_id = public.current_member_id()) with check (member_id = public.current_member_id());
