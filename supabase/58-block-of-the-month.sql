-- =====================================================================
-- 58-block-of-the-month.sql  (run once in the Supabase SQL editor, after 57)
-- Block of the Month: one quilt (photo, name, description) and a PDF for each month.
-- Members see a month's button starting 7 days before that month begins (Guild time,
-- Central). The Block of the Month Chair, Administrators and the Superuser see every
-- month at any time and keep the page. Adds the role "Block of the Month Chair" (BOM Chair).
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): tables bom_settings, bom_months;
-- private Storage bucket block-of-the-month; role bom_chair.
-- =====================================================================

insert into public.roles (role_key, label, sort_order)
values ('bom_chair', 'Block of the Month Chair', 44)
on conflict (role_key) do update set label = excluded.label, sort_order = excluded.sort_order;

create or replace function public.can_manage_bom()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('bom_chair')
$$;

-- A month (first day of it) is open to members from 7 days before it begins.
create or replace function public.bom_is_released(p_month date)
returns boolean language sql stable security definer set search_path = public as $$
  select p_month - 7 <= public.guild_today()
$$;

create table if not exists public.bom_settings (
  id          boolean primary key default true check (id),     -- one row only
  quilt_name  text not null default '' check (length(quilt_name) <= 120),
  description text not null default '' check (length(description) <= 3000),
  photo_path  text,
  updated_at  timestamptz not null default now()
);
insert into public.bom_settings (id) values (true) on conflict (id) do nothing;
drop trigger if exists bom_settings_updated on public.bom_settings;
create trigger bom_settings_updated before update on public.bom_settings
  for each row execute function public.set_updated_at();

create table if not exists public.bom_months (
  id          uuid primary key default gen_random_uuid(),
  month_start date not null unique check (extract(day from month_start) = 1),
  pdf_path    text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
drop trigger if exists bom_months_updated on public.bom_months;
create trigger bom_months_updated before update on public.bom_months
  for each row execute function public.set_updated_at();

alter table public.bom_settings enable row level security;
alter table public.bom_months   enable row level security;
revoke all on public.bom_settings, public.bom_months from anon;
grant select, insert, update, delete on public.bom_settings, public.bom_months to authenticated;

drop policy if exists bom_settings_select on public.bom_settings;
create policy bom_settings_select on public.bom_settings
  for select to authenticated using (public.can_see_members_area() or public.can_manage_bom());
drop policy if exists bom_settings_insert on public.bom_settings;
create policy bom_settings_insert on public.bom_settings
  for insert to authenticated with check (public.can_manage_bom());
drop policy if exists bom_settings_update on public.bom_settings;
create policy bom_settings_update on public.bom_settings
  for update to authenticated using (public.can_manage_bom()) with check (public.can_manage_bom());

-- Members read only the months that have been released; the chair reads all.
drop policy if exists bom_months_select on public.bom_months;
create policy bom_months_select on public.bom_months
  for select to authenticated
  using (public.can_manage_bom() or (public.can_see_members_area() and public.bom_is_released(month_start)));
drop policy if exists bom_months_insert on public.bom_months;
create policy bom_months_insert on public.bom_months
  for insert to authenticated with check (public.can_manage_bom());
drop policy if exists bom_months_update on public.bom_months;
create policy bom_months_update on public.bom_months
  for update to authenticated using (public.can_manage_bom()) with check (public.can_manage_bom());
drop policy if exists bom_months_delete on public.bom_months;
create policy bom_months_delete on public.bom_months
  for delete to authenticated using (public.can_manage_bom());

-- Private bucket: members read the photo and the released months' PDFs; the chair writes.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('block-of-the-month', 'block-of-the-month', false, 20971520,
        array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists bom_files_select on storage.objects;
create policy bom_files_select on storage.objects
  for select to authenticated
  using (bucket_id = 'block-of-the-month' and (
    public.can_manage_bom()
    or (public.can_see_members_area() and (
          name like 'photos/%'
          or exists (select 1 from public.bom_months m where m.pdf_path = storage.objects.name and public.bom_is_released(m.month_start))))));
drop policy if exists bom_files_insert on storage.objects;
create policy bom_files_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'block-of-the-month' and public.can_manage_bom());
drop policy if exists bom_files_update on storage.objects;
create policy bom_files_update on storage.objects
  for update to authenticated
  using (bucket_id = 'block-of-the-month' and public.can_manage_bom())
  with check (bucket_id = 'block-of-the-month' and public.can_manage_bom());
drop policy if exists bom_files_delete on storage.objects;
create policy bom_files_delete on storage.objects
  for delete to authenticated using (bucket_id = 'block-of-the-month' and public.can_manage_bom());
