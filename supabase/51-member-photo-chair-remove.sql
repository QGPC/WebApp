-- =====================================================================
-- 51-member-photo-chair-remove.sql  (run once in the Supabase SQL editor, after 50)
-- Lets the Membership Chair, Administrators and the Superuser remove a
-- member's Directory photo (a "Remove this photo" button in the Member
-- Directory detail panel). Until now only the member could remove their
-- own (and Administrators the file, with no button).
-- A member still cannot add, replace or remove anyone else's photo.
--
-- WHAT IT ADDS (for the backup list): nothing new; one storage rule replaced.
-- ORDER: run this FIRST, then push directory.html, profile.html and home.html.
-- Safe to run twice.
-- =====================================================================
begin;
drop policy if exists mphoto_delete on storage.objects;
create policy mphoto_delete on storage.objects for delete to authenticated
  using (bucket_id = 'member-photos'
         and (split_part(name, '/', 1) = public.current_member_id()::text
              or public.is_admin() or public.has_role('membership_chair')));
commit;
