-- =====================================================================
-- 45-welcome-message.sql  (run once in the Supabase SQL editor, after 44)
-- The short welcome paragraph in the banner on the public Welcome page.
-- Everyone (including signed-out visitors) reads it. The President, Vice
-- President, Administrators and Superuser change it, on the President's
-- Page (welcome-message-manage.html). A blank message means the Welcome page
-- shows its built-in sentence. Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table welcome_message (one row).
-- Reset the Site does not touch it.
-- =====================================================================

create table if not exists public.welcome_message (
  id         boolean primary key default true check (id),   -- one row only
  message    text not null default '' check (length(message) <= 600),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.welcome_message (id) values (true) on conflict (id) do nothing;

create or replace function public.welcome_message_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
drop trigger if exists welcome_message_touch on public.welcome_message;
create trigger welcome_message_touch before insert or update on public.welcome_message
  for each row execute function public.welcome_message_touch();

alter table public.welcome_message enable row level security;
grant select on public.welcome_message to anon;
grant select, insert, update on public.welcome_message to authenticated;

drop policy if exists welcome_message_select on public.welcome_message;
create policy welcome_message_select on public.welcome_message for select to anon, authenticated using (true);
drop policy if exists welcome_message_insert on public.welcome_message;
create policy welcome_message_insert on public.welcome_message for insert to authenticated with check (public.can_post_notice());
drop policy if exists welcome_message_update on public.welcome_message;
create policy welcome_message_update on public.welcome_message for update to authenticated
  using (public.can_post_notice()) with check (public.can_post_notice());
