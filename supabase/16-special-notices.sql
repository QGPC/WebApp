-- =====================================================================
-- 16-special-notices.sql  (run once in the Supabase SQL editor)
-- Special Notices: urgent or important news shown in a highlighted card
-- on the Welcome page and the member home page. Posted from the
-- President's Page by the President, Vice President, Administrators and
-- the Superuser (same four roles as regular notices).
-- Each can have an optional photo (stored in the public bucket
-- "special-notices"; only the file name is kept in the table).
-- Safe to run twice.
-- =====================================================================

create table if not exists public.special_notices (
  id           uuid primary key default gen_random_uuid(),
  headline     text not null check (length(btrim(headline)) > 0),
  message      text,
  members_only boolean not null default false,
  show_until   date,                       -- blank = stays until removed
  photo_path   text,                       -- file name inside the bucket, or null
  photo_alt    text,                       -- description read aloud by screen readers
  created_by   uuid references public.members (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

drop trigger if exists special_notices_updated on public.special_notices;
create trigger special_notices_updated before update on public.special_notices
  for each row execute function public.set_updated_at();

create or replace function public.special_notices_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := public.current_member_id();
  end if;
  new.headline  := btrim(new.headline);
  new.message   := nullif(btrim(coalesce(new.message, '')), '');
  new.photo_alt := case when new.photo_path is null then null
                        else nullif(btrim(coalesce(new.photo_alt, '')), '') end;
  return new;
end $$;

drop trigger if exists special_notices_stamp on public.special_notices;
create trigger special_notices_stamp before insert or update on public.special_notices
  for each row execute function public.special_notices_stamp();

create index if not exists special_notices_order on public.special_notices (created_at desc);

alter table public.special_notices enable row level security;

grant select on public.special_notices to anon;
grant select, insert, update, delete on public.special_notices to authenticated;

-- Visitors: Everyone notices that have not expired.
drop policy if exists sn_public_select on public.special_notices;
create policy sn_public_select on public.special_notices
  for select to anon, authenticated
  using (not members_only and (show_until is null or show_until >= public.guild_today()));

-- Members (Active or grace) and Administrators: all that have not expired.
drop policy if exists sn_member_select on public.special_notices;
create policy sn_member_select on public.special_notices
  for select to authenticated
  using (public.can_see_members_area() and (show_until is null or show_until >= public.guild_today()));

-- The four posting roles see everything, expired included.
drop policy if exists sn_manage_select on public.special_notices;
create policy sn_manage_select on public.special_notices
  for select to authenticated using (public.can_post_notice());

drop policy if exists sn_insert on public.special_notices;
create policy sn_insert on public.special_notices
  for insert to authenticated with check (public.can_post_notice());

drop policy if exists sn_update on public.special_notices;
create policy sn_update on public.special_notices
  for update to authenticated using (public.can_post_notice()) with check (public.can_post_notice());

drop policy if exists sn_delete on public.special_notices;
create policy sn_delete on public.special_notices
  for delete to authenticated using (public.can_post_notice());

-- ---------------------------------------------------------------------
-- Photo storage. Public bucket, because the Welcome page shows these
-- photos to visitors. File names are random, so a photo for a
-- members-only notice cannot be guessed. JPG or PNG, up to 2 MB.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('special-notices', 'special-notices', true, 2097152, array['image/jpeg','image/png'])
on conflict (id) do update
  set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg','image/png'];

drop policy if exists sn_files_insert on storage.objects;
create policy sn_files_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'special-notices' and public.can_post_notice());

drop policy if exists sn_files_update on storage.objects;
create policy sn_files_update on storage.objects
  for update to authenticated
  using (bucket_id = 'special-notices' and public.can_post_notice())
  with check (bucket_id = 'special-notices' and public.can_post_notice());

drop policy if exists sn_files_delete on storage.objects;
create policy sn_files_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'special-notices' and public.can_post_notice());
