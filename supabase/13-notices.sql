-- =====================================================================
-- 13-notices.sql  (run once in the Supabase SQL editor)
-- Guild notices: posted by the President, Vice President, Administrators
-- and the Superuser; shown on the Guild home Notices card.
-- Safe to run twice.
-- =====================================================================

-- "Today" in the Guild's own time zone, so a notice set to show until
-- Friday stays up through Friday evening in Texas.
create or replace function public.guild_today()
returns date language sql stable as $$
  select (now() at time zone 'America/Chicago')::date
$$;

create or replace function public.can_post_notice()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('president') or public.has_role('vice_president')
$$;

create table if not exists public.notices (
  id           uuid primary key default gen_random_uuid(),
  title        text not null check (length(btrim(title)) > 0),
  summary      text,
  show_until   date,                       -- blank = stays until removed
  members_only boolean not null default false,
  pinned       boolean not null default false,
  created_by   uuid references public.members (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

drop trigger if exists notices_updated on public.notices;
create trigger notices_updated before update on public.notices
  for each row execute function public.set_updated_at();

create or replace function public.notices_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := public.current_member_id();
  end if;
  new.title   := btrim(new.title);
  new.summary := nullif(btrim(coalesce(new.summary, '')), '');
  return new;
end $$;

drop trigger if exists notices_stamp on public.notices;
create trigger notices_stamp before insert or update on public.notices
  for each row execute function public.notices_stamp();

create index if not exists notices_order on public.notices (pinned desc, created_at desc);

alter table public.notices enable row level security;

grant select on public.notices to anon;
grant select, insert, update, delete on public.notices to authenticated;

-- Visitors: public notices that have not expired.
drop policy if exists notices_public_select on public.notices;
create policy notices_public_select on public.notices
  for select to anon, authenticated
  using (not members_only and (show_until is null or show_until >= public.guild_today()));

-- Members (Active or grace) and Administrators: all notices that have not expired.
drop policy if exists notices_member_select on public.notices;
create policy notices_member_select on public.notices
  for select to authenticated
  using (public.can_see_members_area() and (show_until is null or show_until >= public.guild_today()));

-- The four posting roles see everything, expired ones included, so they can fix or delete them.
drop policy if exists notices_manage_select on public.notices;
create policy notices_manage_select on public.notices
  for select to authenticated using (public.can_post_notice());

drop policy if exists notices_insert on public.notices;
create policy notices_insert on public.notices
  for insert to authenticated with check (public.can_post_notice());

drop policy if exists notices_update on public.notices;
create policy notices_update on public.notices
  for update to authenticated using (public.can_post_notice()) with check (public.can_post_notice());

drop policy if exists notices_delete on public.notices;
create policy notices_delete on public.notices
  for delete to authenticated using (public.can_post_notice());
