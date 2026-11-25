-- =====================================================================
-- 70-mission-statement.sql  (run once, after 69)
-- The Guild Mission Statement on the public About Our Guild page.
-- Everyone (including signed-out visitors) reads it. The Publicity Chair,
-- Administrators and the Superuser change it, from the Publicity Chair page
-- (mission-statement-manage.html). A blank statement shows "will be posted
-- here soon". Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table mission_statement (one row).
-- Reset the Site does not touch it.
-- =====================================================================

create table if not exists public.mission_statement (
  id         boolean primary key default true check (id),   -- one row only
  body       text not null default '' check (length(body) <= 2000),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.mission_statement (id) values (true) on conflict (id) do nothing;

create or replace function public.mission_statement_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
drop trigger if exists mission_statement_touch on public.mission_statement;
create trigger mission_statement_touch before insert or update on public.mission_statement
  for each row execute function public.mission_statement_touch();

alter table public.mission_statement enable row level security;
grant select on public.mission_statement to anon;
grant select, insert, update on public.mission_statement to authenticated;

drop policy if exists mission_statement_select on public.mission_statement;
create policy mission_statement_select on public.mission_statement for select to anon, authenticated using (true);
drop policy if exists mission_statement_insert on public.mission_statement;
create policy mission_statement_insert on public.mission_statement for insert to authenticated
  with check (public.is_admin() or public.has_role('publicity_chair'));
drop policy if exists mission_statement_update on public.mission_statement;
create policy mission_statement_update on public.mission_statement for update to authenticated
  using (public.is_admin() or public.has_role('publicity_chair'))
  with check (public.is_admin() or public.has_role('publicity_chair'));
