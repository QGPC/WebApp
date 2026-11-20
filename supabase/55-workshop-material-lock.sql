-- =====================================================================
-- 55-workshop-material-lock.sql  (run once; safe to run twice)
-- Each workshop file gets a "Hide file until registered" choice.
--   locked = true   the file stays locked until the person's registration is accepted
--                   (this is how every file has worked so far, so existing files stay locked)
--   locked = false  anyone who can see the published workshop can open the file
-- =====================================================================
alter table public.workshop_materials add column if not exists locked boolean not null default true;

-- Unlocked files can be downloaded by anyone, but only while the workshop month is published.
drop policy if exists wm_files_select_open on storage.objects;
create policy wm_files_select_open on storage.objects for select to anon, authenticated
  using (bucket_id = 'workshop-materials' and exists (
    select 1 from public.workshop_materials w
    join public.program_months m on m.id = w.month_id
    where w.path = storage.objects.name and w.locked = false and m.status = 'published'));
