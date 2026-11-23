-- 61: Block of the Month colorways (two optional extra photos of the quilt per year).
-- Run once in the Supabase SQL editor. Safe to run again.
-- WHAT THIS ADDS (for the backup list): columns on bom_years: colorway1_name, colorway1_path,
--   colorway2_name, colorway2_path. Photos live in the existing private bucket block-of-the-month.
-- Members can read a colorway photo only when they can see that year (same rule as the quilt photo).

alter table public.bom_years
  add column if not exists colorway1_name text,
  add column if not exists colorway1_path text,
  add column if not exists colorway2_name text,
  add column if not exists colorway2_path text;

alter table public.bom_years drop constraint if exists bom_years_colorway_names_len;
alter table public.bom_years add constraint bom_years_colorway_names_len check (
  (colorway1_name is null or char_length(colorway1_name) <= 40) and
  (colorway2_name is null or char_length(colorway2_name) <= 40));

drop policy if exists bom_files_select on storage.objects;
create policy bom_files_select on storage.objects
  for select to authenticated
  using (bucket_id = 'block-of-the-month' and (
    public.can_manage_bom()
    or (public.can_see_members_area() and (
          exists (select 1 from public.bom_years  y where y.photo_path = storage.objects.name
                                                       or y.colorway1_path = storage.objects.name
                                                       or y.colorway2_path = storage.objects.name)
       or exists (select 1 from public.bom_months m where m.pdf_path = storage.objects.name or m.photo_path = storage.objects.name)
       or exists (select 1 from public.bom_files  f where f.pdf_path = storage.objects.name or f.photo_path = storage.objects.name)))));
