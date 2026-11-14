-- =====================================================================
-- 35-guild-contact.sql  (run once in the Supabase SQL editor, after 34)
-- The Guild's contact details (mailing address, email, phone) for the page
-- footer and Contact Us, and the link to the Guild's Facebook page for the
-- header. Everyone reads them; only the Superuser changes them (on the Site
-- Appearance page). Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table guild_contact (one row).
-- =====================================================================

create table if not exists public.guild_contact (
  id           boolean primary key default true check (id),   -- one row only
  street       text not null default '',
  city         text not null default '',
  state        text not null default 'TX',
  zip          text not null default '',
  email        text not null default '',
  phone        text not null default '',
  facebook_url text not null default '' check (facebook_url = '' or facebook_url ~* '^https://'),
  updated_at   timestamptz not null default now()
);
insert into public.guild_contact (id) values (true) on conflict (id) do nothing;

create or replace function public.guild_contact_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists guild_contact_touch on public.guild_contact;
create trigger guild_contact_touch before update on public.guild_contact
  for each row execute function public.guild_contact_touch();

alter table public.guild_contact enable row level security;
grant select on public.guild_contact to anon;
grant select, insert, update on public.guild_contact to authenticated;

drop policy if exists guild_contact_select on public.guild_contact;
create policy guild_contact_select on public.guild_contact for select to anon, authenticated using (true);
drop policy if exists guild_contact_insert on public.guild_contact;
create policy guild_contact_insert on public.guild_contact for insert to authenticated with check (public.has_role('superuser'));
drop policy if exists guild_contact_update on public.guild_contact;
create policy guild_contact_update on public.guild_contact for update to authenticated
  using (public.has_role('superuser')) with check (public.has_role('superuser'));
