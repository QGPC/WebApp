-- =====================================================================
-- 50-member-photos.sql  (run once in the Supabase SQL editor, after 49)
-- Directory photo: a member can add, replace or remove their own photo on
-- My Profile. It shows beside their name in the Member Directory, for
-- signed-in members only (the files are in a PRIVATE bucket and are opened
-- with short-lived links). A member who chose "Not listed in the Member
-- Directory" is not in the list, so their photo is not shown either.
--
-- WHAT IT ADDS (for the backup list):
--   column  members.photo_path        the file name, like <member id>/<random>.jpg
--   bucket  member-photos             private, JPG only, up to 1 MB each
--   trigger members_photo_guard       a member can only point photo_path at a file in their own folder
--   The Member Directory function now also returns photo_path.
--   The photo FILES are not part of a database backup (same as the other file buckets).
--
-- ORDER: run this FIRST, then push profile.html and directory.html. The old
-- pages keep working in between (they ignore the new column).
-- Safe to run twice.
-- =====================================================================

begin;

alter table public.members add column if not exists photo_path text;

-- A member may only use a file in their own folder (members/<their id>/...).
create or replace function public.members_photo_guard()
returns trigger language plpgsql as $$
begin
  if new.photo_path is not null then
    if new.photo_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{8,64}\.jpg$'
       or split_part(new.photo_path, '/', 1) <> new.id::text then
      raise exception 'That photo file is not allowed.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists members_photo_guard on public.members;
create trigger members_photo_guard
  before insert or update of photo_path on public.members
  for each row execute function public.members_photo_guard();

-- Private bucket: JPG only (the page shrinks and converts the picture), 1 MB.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('member-photos', 'member-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

-- Add, replace and remove: only in your own folder (an Administrator or the Superuser may remove any).
drop policy if exists mphoto_insert on storage.objects;
create policy mphoto_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'member-photos'
              and split_part(name, '/', 1) = public.current_member_id()::text);
drop policy if exists mphoto_update on storage.objects;
create policy mphoto_update on storage.objects for update to authenticated
  using (bucket_id = 'member-photos' and split_part(name, '/', 1) = public.current_member_id()::text)
  with check (bucket_id = 'member-photos' and split_part(name, '/', 1) = public.current_member_id()::text);
drop policy if exists mphoto_delete on storage.objects;
create policy mphoto_delete on storage.objects for delete to authenticated
  using (bucket_id = 'member-photos'
         and (split_part(name, '/', 1) = public.current_member_id()::text or public.is_admin()));
-- See / open: Active or grace members, Administrators and the Superuser (same people as the Directory).
drop policy if exists mphoto_select on storage.objects;
create policy mphoto_select on storage.objects for select to authenticated
  using (bucket_id = 'member-photos' and public.can_see_members_area());

-- The Member Directory list, now with the photo file name. (Same rules as before.)
drop function if exists public.member_directory();
create or replace function public.member_directory()
returns table (
  id uuid, first_name text, last_name text, email text, cell_phone text,
  street_address text, city text, state text, zip text,
  birthday_month smallint, birthday_day smallint,
  interests text[], interests_other text, photo_path text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see_members_area() then
    raise exception 'The Member Directory is for Guild members only.';
  end if;
  return query
    select m.id, m.first_name, m.last_name, m.email, m.cell_phone,
           m.street_address, m.city, m.state, m.zip,
           m.birthday_month, m.birthday_day, m.interests, m.interests_other, m.photo_path
    from public.members m
    where not m.directory_opt_out
      and public.membership_status(m.paid_through_year) in ('active', 'grace')
    order by lower(m.last_name), lower(m.first_name);
end $$;

revoke all on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

commit;
