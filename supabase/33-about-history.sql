-- =====================================================================
-- 33-about-history.sql  (run once in the Supabase SQL editor, after 32)
-- About Our Guild and Guild History.
--  * Guild History: an introduction paragraph and a timeline (year, heading,
--    details). Everyone reads it; Administrators and the Superuser edit it.
--  * About Our Guild: the people who hold the Board and committee-chair
--    roles, taken from Roles & Permissions. Visitors see names and roles;
--    signed-in members also see contact details (not for a member who chose
--    "Not listed in the Member Directory").
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): tables guild_history_settings,
-- guild_history_entries.
-- =====================================================================

create table if not exists public.guild_history_settings (
  id         boolean primary key default true check (id),   -- one row only
  intro      text not null default '',
  updated_at timestamptz not null default now()
);
insert into public.guild_history_settings (id, intro) values (true, '') on conflict (id) do nothing;

create table if not exists public.guild_history_entries (
  id         uuid primary key default gen_random_uuid(),
  year_text  text not null default '',
  title      text not null check (length(btrim(title)) > 0),
  details    text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.history_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists history_settings_touch on public.guild_history_settings;
create trigger history_settings_touch before update on public.guild_history_settings for each row execute function public.history_touch();
drop trigger if exists history_entries_touch on public.guild_history_entries;
create trigger history_entries_touch before update on public.guild_history_entries for each row execute function public.history_touch();

alter table public.guild_history_settings enable row level security;
alter table public.guild_history_entries  enable row level security;
grant select on public.guild_history_settings, public.guild_history_entries to anon;
grant select, insert, update, delete on public.guild_history_settings, public.guild_history_entries to authenticated;

do $$
declare t text;
begin
  foreach t in array array['guild_history_settings', 'guild_history_entries'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_admin())', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_admin())', t || '_delete', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- About Our Guild: who holds the Board and chair roles
-- ---------------------------------------------------------------------
create or replace function public.about_leaders()
returns table (
  role_key text, role_label text, sort_order int, member_id uuid,
  first_name text, last_name text,
  email text, cell_phone text, address text, birthday_month smallint, birthday_day smallint, interests text[]
)
language plpgsql stable security definer set search_path = public as $$
declare v_full boolean := public.can_see_members_area();
begin
  return query
    select r.role_key, r.label, r.sort_order, m.id, m.first_name, m.last_name,
           case when v_full and not m.directory_opt_out then m.email end,
           case when v_full and not m.directory_opt_out then m.cell_phone end,
           case when v_full and not m.directory_opt_out then
             nullif(btrim(concat_ws(', ', nullif(btrim(coalesce(m.street_address, '')), ''), nullif(btrim(coalesce(m.city, '')), ''),
                    nullif(btrim(concat_ws(' ', nullif(btrim(coalesce(m.state, '')), ''), nullif(btrim(coalesce(m.zip, '')), ''))), ''))), '') end,
           case when v_full and not m.directory_opt_out then m.birthday_month end,
           case when v_full and not m.directory_opt_out then m.birthday_day end,
           case when v_full and not m.directory_opt_out then m.interests end
    from public.member_roles mr
    join public.roles r   on r.role_key = mr.role_key
    join public.members m on m.id = mr.member_id
    where r.sort_order >= 10
      and public.membership_status(m.paid_through_year) in ('active', 'grace')
    order by r.sort_order, lower(m.last_name), lower(m.first_name);
end $$;
grant execute on function public.about_leaders() to anon, authenticated;
