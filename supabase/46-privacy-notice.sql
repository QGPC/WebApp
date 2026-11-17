-- =====================================================================
-- 46-privacy-notice.sql  (run once in the Supabase SQL editor, after 45)
-- The text of the Privacy Notice page. Everyone (including signed-out
-- visitors) reads it. Administrators and the Superuser change it, from
-- Site Administration > Privacy Notice (privacy-manage.html). Nothing is
-- pre-filled: until text is saved, the page says the notice is being
-- prepared. Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table privacy_notice (one row).
-- Reset the Site does not touch it.
-- =====================================================================

create table if not exists public.privacy_notice (
  id         boolean primary key default true check (id),   -- one row only
  body       text not null default '' check (length(body) <= 20000),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.privacy_notice (id) values (true) on conflict (id) do nothing;

create or replace function public.privacy_notice_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
drop trigger if exists privacy_notice_touch on public.privacy_notice;
create trigger privacy_notice_touch before insert or update on public.privacy_notice
  for each row execute function public.privacy_notice_touch();

alter table public.privacy_notice enable row level security;
grant select on public.privacy_notice to anon;
grant select, insert, update on public.privacy_notice to authenticated;

drop policy if exists privacy_notice_select on public.privacy_notice;
create policy privacy_notice_select on public.privacy_notice for select to anon, authenticated using (true);
drop policy if exists privacy_notice_insert on public.privacy_notice;
create policy privacy_notice_insert on public.privacy_notice for insert to authenticated with check (public.is_admin());
drop policy if exists privacy_notice_update on public.privacy_notice;
create policy privacy_notice_update on public.privacy_notice for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
