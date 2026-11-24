-- 62: Block of the Month copyright notice (optional text on each year's quilt card).
-- Run once in the Supabase SQL editor. Safe to run again.
-- WHAT THIS ADDS (for the backup list): column bom_years.copyright (text, up to 1000 characters, optional).
-- Existing row-level rules already cover it; members see it only for years they can see.

alter table public.bom_years add column if not exists copyright text;
alter table public.bom_years drop constraint if exists bom_years_copyright_len;
alter table public.bom_years add constraint bom_years_copyright_len check (copyright is null or char_length(copyright) <= 1000);
