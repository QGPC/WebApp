-- =====================================================================
-- 59-block-of-the-month-years.sql  (run once in the Supabase SQL editor, after 58)
-- Block of the Month, part 2:
--   * each calendar year has its own quilt (photo, name, description); members choose a year
--   * each month can have a photo
--   * the chair can add extra files to a year, each with a photo and a short description
-- A year is shown to members once one of its months is open (7 days before the month begins).
-- The quilt you already saved with SQL 58 is moved to the year of your first month
-- (or this year if no month was added). Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): tables bom_years, bom_files; column bom_months.photo_path.
-- The table bom_settings from SQL 58 is no longer used (left in place, nothing reads it).
-- =====================================================================

alter table public.bom_months add column if not exists photo_path text;

create table if not exists public.bom_years (
  year        int primary key check (year between 2000 and 2200),
  quilt_name  text not null default '' check (length(quilt_name) <= 120),
  description text not null default '' check (length(description) <= 3000),
  photo_path  text,
  updated_at  timestamptz not null default now()
);
drop trigger if exists bom_years_updated on public.bom_years;
create trigger bom_years_updated before update on public.bom_years
  for each row execute function public.set_updated_at();

create table if not exists public.bom_files (
  id          uuid primary key default gen_random_uuid(),
  year        int not null check (year between 2000 and 2200),
  description text not null check (length(btrim(description)) between 1 and 300),
  photo_path  text,
  pdf_path    text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists bom_files_year_idx on public.bom_files (year);
drop trigger if exists bom_files_updated on public.bom_files;
create trigger bom_files_updated before update on public.bom_files
  for each row execute function public.set_updated_at();

-- Move the single quilt from SQL 58 into a year (only when that year has no entry yet).
do $$
begin
  if to_regclass('public.bom_settings') is not null then
    insert into public.bom_years (year, quilt_name, description, photo_path)
    select coalesce((select min(extract(year from month_start))::int from public.bom_months),
                    extract(year from public.guild_today())::int),
           s.quilt_name, s.description, s.photo_path
    from public.bom_settings s
    where s.quilt_name <> '' or s.description <> '' or s.photo_path is not null
    on conflict (year) do nothing;
  end if;
end $$;

-- A year is open to members when at least one of its months has been released.
create or replace function public.bom_year_open(p_year int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bom_months m
    where extract(year from m.month_start)::int = p_year and public.bom_is_released(m.month_start))
$$;

alter table public.bom_years enable row level security;
alter table public.bom_files enable row level security;
revoke all on public.bom_years, public.bom_files from anon;
grant select, insert, update, delete on public.bom_years, public.bom_files to authenticated;

drop policy if exists bom_years_select on public.bom_years;
create policy bom_years_select on public.bom_years
  for select to authenticated
  using (public.can_manage_bom() or (public.can_see_members_area() and public.bom_year_open(year)));
drop policy if exists bom_years_insert on public.bom_years;
create policy bom_years_insert on public.bom_years
  for insert to authenticated with check (public.can_manage_bom());
drop policy if exists bom_years_update on public.bom_years;
create policy bom_years_update on public.bom_years
  for update to authenticated using (public.can_manage_bom()) with check (public.can_manage_bom());
drop policy if exists bom_years_delete on public.bom_years;
create policy bom_years_delete on public.bom_years
  for delete to authenticated using (public.can_manage_bom());

drop policy if exists bom_extra_select on public.bom_files;
create policy bom_extra_select on public.bom_files
  for select to authenticated
  using (public.can_manage_bom() or (public.can_see_members_area() and public.bom_year_open(year)));
drop policy if exists bom_extra_insert on public.bom_files;
create policy bom_extra_insert on public.bom_files
  for insert to authenticated with check (public.can_manage_bom());
drop policy if exists bom_extra_update on public.bom_files;
create policy bom_extra_update on public.bom_files
  for update to authenticated using (public.can_manage_bom()) with check (public.can_manage_bom());
drop policy if exists bom_extra_delete on public.bom_files;
create policy bom_extra_delete on public.bom_files
  for delete to authenticated using (public.can_manage_bom());

-- Storage: a member can read a file only when a row they are allowed to see points at it
-- (so a photo or PDF of a month or year that is not open yet cannot be fetched).
drop policy if exists bom_files_select on storage.objects;
create policy bom_files_select on storage.objects
  for select to authenticated
  using (bucket_id = 'block-of-the-month' and (
    public.can_manage_bom()
    or (public.can_see_members_area() and (
          exists (select 1 from public.bom_years  y where y.photo_path = storage.objects.name)
       or exists (select 1 from public.bom_months m where m.pdf_path = storage.objects.name or m.photo_path = storage.objects.name)
       or exists (select 1 from public.bom_files  f where f.pdf_path = storage.objects.name or f.photo_path = storage.objects.name)))));
