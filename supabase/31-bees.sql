-- =====================================================================
-- 31-bees.sql  (run once in the Supabase SQL editor, after 30)
-- Bees: small groups of members who meet to sew. The Bees page is public
-- (visitors and members). The Bees Chair (role "beekeeper"), Administrators
-- and the Superuser add, change and remove bees and their photos.
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table bees; public Storage
-- bucket bees (photos).
-- =====================================================================

create or replace function public.can_manage_bees()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('beekeeper')
$$;

create table if not exists public.bees (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(btrim(name)) > 0),
  meets_when    text,
  meets_where   text,
  about         text,
  is_open       boolean not null default true,      -- open to new members
  photo_path    text,                               -- file name in the bees bucket
  contact_name  text,
  contact_email text,
  contact_phone text,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create or replace function public.bees_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and coalesce(new.sort_order, 0) = 0 then
    select coalesce(max(sort_order), 0) + 1 into new.sort_order from public.bees;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists bees_stamp on public.bees;
create trigger bees_stamp before insert or update on public.bees
  for each row execute function public.bees_stamp();

alter table public.bees enable row level security;
grant select on public.bees to anon;
grant select, insert, update, delete on public.bees to authenticated;

drop policy if exists bees_select on public.bees;
create policy bees_select on public.bees for select to anon, authenticated using (true);
drop policy if exists bees_insert on public.bees;
create policy bees_insert on public.bees for insert to authenticated with check (public.can_manage_bees());
drop policy if exists bees_update on public.bees;
create policy bees_update on public.bees for update to authenticated
  using (public.can_manage_bees()) with check (public.can_manage_bees());
drop policy if exists bees_delete on public.bees;
create policy bees_delete on public.bees for delete to authenticated using (public.can_manage_bees());

-- ---------------------------------------------------------------------
-- Photos: public bucket (the page is public). Random file names.
-- JPG or PNG, up to 2 MB.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bees', 'bees', true, 2097152, array['image/jpeg','image/png'])
on conflict (id) do update
  set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg','image/png'];

drop policy if exists bees_files_insert on storage.objects;
create policy bees_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'bees' and public.can_manage_bees());
drop policy if exists bees_files_update on storage.objects;
create policy bees_files_update on storage.objects for update to authenticated
  using (bucket_id = 'bees' and public.can_manage_bees())
  with check (bucket_id = 'bees' and public.can_manage_bees());
drop policy if exists bees_files_delete on storage.objects;
create policy bees_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'bees' and public.can_manage_bees());
