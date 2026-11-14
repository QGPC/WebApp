-- =====================================================================
-- 27-newsletters.sql  (run once in the Supabase SQL editor, after 26)
-- Newsletters: one PDF per month, kept by the Newsletter Chair,
-- Administrators and the Superuser; read by members only.
-- A draft is visible only to those who manage newsletters.
-- The newest published issue is the "current" issue (worked out on the page).
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table newsletters;
-- private Storage bucket newsletters.
-- =====================================================================

create or replace function public.can_manage_newsletters()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('newsletter_chair')
$$;

create table if not exists public.newsletters (
  id           uuid primary key default gen_random_uuid(),
  year         int  not null check (year between 2000 and 2100),
  month        int  not null check (month between 1 and 12),
  pdf_path     text not null,
  file_name    text not null,
  size_bytes   bigint,
  status       text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  created_by   uuid default public.current_member_id(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (year, month)
);

create or replace function public.newsletters_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'published' and new.published_at is null then new.published_at := now(); end if;
  if new.status = 'draft' then new.published_at := null; end if;
  return new;
end $$;
drop trigger if exists newsletters_stamp on public.newsletters;
create trigger newsletters_stamp before insert or update on public.newsletters
  for each row execute function public.newsletters_stamp();
drop trigger if exists newsletters_updated on public.newsletters;
create trigger newsletters_updated before update on public.newsletters
  for each row execute function public.set_updated_at();

alter table public.newsletters enable row level security;
grant select, insert, update, delete on public.newsletters to authenticated;

drop policy if exists newsletters_select on public.newsletters;
create policy newsletters_select on public.newsletters
  for select to authenticated
  using (public.can_manage_newsletters() or (status = 'published' and public.can_see_members_area()));
drop policy if exists newsletters_insert on public.newsletters;
create policy newsletters_insert on public.newsletters
  for insert to authenticated with check (public.can_manage_newsletters());
drop policy if exists newsletters_update on public.newsletters;
create policy newsletters_update on public.newsletters
  for update to authenticated using (public.can_manage_newsletters()) with check (public.can_manage_newsletters());
drop policy if exists newsletters_delete on public.newsletters;
create policy newsletters_delete on public.newsletters
  for delete to authenticated using (public.can_manage_newsletters());

-- Lets the Storage policy ask "may this person read this file?" (members: published issues only)
create or replace function public.newsletter_file_visible(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_manage_newsletters()
      or (public.can_see_members_area()
          and exists (select 1 from public.newsletters n where n.pdf_path = p_path and n.status = 'published'))
$$;
revoke all on function public.newsletter_file_visible(text), public.can_manage_newsletters() from public, anon;
grant execute on function public.newsletter_file_visible(text), public.can_manage_newsletters() to authenticated;

-- ---------------------------------------------------------------------
-- Private Storage bucket: members read published issues, the chair writes
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('newsletters', 'newsletters', false, 20971520, array['application/pdf'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists nl_files_select on storage.objects;
create policy nl_files_select on storage.objects
  for select to authenticated
  using (bucket_id = 'newsletters' and public.newsletter_file_visible(name));
drop policy if exists nl_files_insert on storage.objects;
create policy nl_files_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'newsletters' and public.can_manage_newsletters());
drop policy if exists nl_files_update on storage.objects;
create policy nl_files_update on storage.objects
  for update to authenticated
  using (bucket_id = 'newsletters' and public.can_manage_newsletters())
  with check (bucket_id = 'newsletters' and public.can_manage_newsletters());
drop policy if exists nl_files_delete on storage.objects;
create policy nl_files_delete on storage.objects
  for delete to authenticated using (bucket_id = 'newsletters' and public.can_manage_newsletters());
