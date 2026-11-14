-- =====================================================================
-- 34-site-appearance.sql  (run once in the Supabase SQL editor, after 33)
-- Site Appearance: the color and pattern of the banner on every page.
-- Everyone reads it (every page needs it); only the Superuser changes it.
-- The optional fabric photo is kept in a public Storage bucket.
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table site_appearance (one row);
-- public Storage bucket site-appearance.
-- =====================================================================

create table if not exists public.site_appearance (
  id          boolean primary key default true check (id),   -- one row only
  color       text not null default '#017DB0' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  texture     text not null default 'quilt'   check (texture in ('quilt', 'plain', 'stripes', 'checker', 'fabric')),
  pattern     text not null default 'cobalt'  check (pattern in ('cobalt', 'cream', 'ink')),
  strength    int  not null default 6         check (strength between 1 and 10),
  fabric_path text,
  updated_at  timestamptz not null default now()
);
insert into public.site_appearance (id) values (true) on conflict (id) do nothing;

create or replace function public.site_appearance_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists site_appearance_touch on public.site_appearance;
create trigger site_appearance_touch before update on public.site_appearance
  for each row execute function public.site_appearance_touch();

alter table public.site_appearance enable row level security;
grant select on public.site_appearance to anon;
grant select, insert, update on public.site_appearance to authenticated;

drop policy if exists site_appearance_select on public.site_appearance;
create policy site_appearance_select on public.site_appearance for select to anon, authenticated using (true);
drop policy if exists site_appearance_insert on public.site_appearance;
create policy site_appearance_insert on public.site_appearance for insert to authenticated with check (public.has_role('superuser'));
drop policy if exists site_appearance_update on public.site_appearance;
create policy site_appearance_update on public.site_appearance for update to authenticated
  using (public.has_role('superuser')) with check (public.has_role('superuser'));

-- Fabric photo: public bucket (every page shows it). JPG or PNG, up to 1 MB.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site-appearance', 'site-appearance', true, 1048576, array['image/jpeg','image/png'])
on conflict (id) do update
  set public = true, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg','image/png'];

drop policy if exists sa_files_insert on storage.objects;
create policy sa_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'site-appearance' and public.has_role('superuser'));
drop policy if exists sa_files_update on storage.objects;
create policy sa_files_update on storage.objects for update to authenticated
  using (bucket_id = 'site-appearance' and public.has_role('superuser'))
  with check (bucket_id = 'site-appearance' and public.has_role('superuser'));
drop policy if exists sa_files_delete on storage.objects;
create policy sa_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'site-appearance' and public.has_role('superuser'));
