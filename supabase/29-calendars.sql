-- =====================================================================
-- 29-calendars.sql  (run once in the Supabase SQL editor, after 28)
-- Lets an Administrator or the Superuser add and turn on or off calendars
-- (the Calendars page), and lets a calendar name one extra role that may
-- type in its events (for example a chair). Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): column calendars.editor_role.
-- =====================================================================

alter table public.calendars add column if not exists editor_role text references public.roles (role_key) on delete set null;

-- May the person type events into this calendar?
-- Typed-in calendars only: the President, Vice President, Administrators and Superuser,
-- plus the holder of the role named in editor_role (if any).
create or replace function public.can_edit_calendar(p_cal uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.calendars c
    where c.id = p_cal and c.active and c.kind = 'manual'
      and (public.can_post_notice() or (c.editor_role is not null and public.has_role(c.editor_role)))
  )
$$;

-- Administrators and the Superuser add and change calendars (calendars are turned off, not deleted)
grant insert, update on public.calendars to authenticated;
drop policy if exists calendars_insert on public.calendars;
create policy calendars_insert on public.calendars for insert to authenticated with check (public.is_admin());
drop policy if exists calendars_update on public.calendars;
create policy calendars_update on public.calendars for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Program and Workshop calendars are made from Program Planning, so they stay as they are
create or replace function public.calendars_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and old.kind = 'derived' and new.kind <> 'derived' then
    raise exception 'A calendar made from another page cannot be changed to typed-in.';
  end if;
  if new.color !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Choose one of the colors.'; end if;
  new.name := btrim(new.name);
  if length(new.name) = 0 then raise exception 'Enter a name for the calendar.'; end if;
  return new;
end $$;
drop trigger if exists calendars_guard on public.calendars;
create trigger calendars_guard before insert or update on public.calendars
  for each row execute function public.calendars_guard();
