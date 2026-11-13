-- =====================================================================
-- 15-events.sql  (run once, after 14-whats-new.sql)
-- Calendars and events. One events table; each event belongs to a calendar.
--   Guild events    public,     typed in on the Guild Calendar page
--   Board meetings  board only, typed in on the Board Calendar page
--   Programs, Workshops: public, made later from Program Planning
-- The month events card on the Guild home reads all calendars the viewer may see.
-- Safe to run twice.
-- =====================================================================

-- Board = Executive Board plus every committee chair (a flag on the roles list,
-- so a role added later can be included by setting it).
alter table public.roles add column if not exists is_board boolean not null default false;
update public.roles set is_board = true
  where (sort_order between 10 and 29) or sort_order >= 30;

create or replace function public.is_board_member()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1
    from public.member_roles mr
    join public.roles r on r.role_key = mr.role_key
    where mr.member_id = public.current_member_id() and r.is_board
  )
$$;

create table if not exists public.calendars (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique,
  name       text not null,
  color      text not null default '#0157AE',
  visibility text not null default 'public' check (visibility in ('public', 'members', 'board')),
  kind       text not null default 'manual' check (kind in ('manual', 'derived')),
  active     boolean not null default true,
  sort_order int not null default 100
);

insert into public.calendars (slug, name, color, visibility, kind, sort_order) values
  ('programs',  'Monthly program', '#0157AE', 'public', 'derived', 10),
  ('workshops', 'Workshop',        '#2F6B5A', 'public', 'derived', 20),
  ('guild',     'Guild event',     '#8A6F3B', 'public', 'manual',  30),
  ('board',     'Board meeting',   '#0F6E78', 'board',  'manual',  40)
on conflict (slug) do nothing;

create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  calendar_id uuid not null references public.calendars (id) on delete cascade,
  title       text not null check (length(btrim(title)) > 0),
  starts_on   date not null,
  time_text   text,                       -- free text, e.g. "6:30 PM"
  location    text,
  details     text,
  kind        text not null default 'event' check (kind in ('event', 'important')),  -- Board calendar: meeting or important date
  created_by  uuid references public.members (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists events_by_day on public.events (starts_on);
create index if not exists events_by_cal on public.events (calendar_id, starts_on);

drop trigger if exists events_updated on public.events;
create trigger events_updated before update on public.events
  for each row execute function public.set_updated_at();

create or replace function public.events_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.created_by := public.current_member_id(); end if;
  new.title     := btrim(new.title);
  new.time_text := nullif(btrim(coalesce(new.time_text, '')), '');
  new.location  := nullif(btrim(coalesce(new.location, '')), '');
  new.details   := nullif(btrim(coalesce(new.details, '')), '');
  return new;
end $$;
drop trigger if exists events_stamp on public.events;
create trigger events_stamp before insert or update on public.events
  for each row execute function public.events_stamp();

-- May the signed-in person (or a visitor) see this calendar?
create or replace function public.can_see_calendar(p_cal uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.calendars c
    where c.id = p_cal and c.active and (
      c.visibility = 'public'
      or (c.visibility = 'members' and public.can_see_members_area())
      or (c.visibility = 'board'   and public.is_board_member())
    )
  )
$$;

-- May the person type events into this calendar? Typed-in calendars: the
-- President, Vice President, Administrators and Superuser (same four as notices).
create or replace function public.can_edit_calendar(p_cal uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_post_notice() and exists (
    select 1 from public.calendars c where c.id = p_cal and c.active and c.kind = 'manual'
  )
$$;

alter table public.calendars enable row level security;
alter table public.events    enable row level security;

grant select on public.calendars, public.events to anon;
grant select on public.calendars to authenticated;
grant select, insert, update, delete on public.events to authenticated;

drop policy if exists calendars_select on public.calendars;
create policy calendars_select on public.calendars
  for select to anon, authenticated using (public.can_see_calendar(id) or public.is_admin());

drop policy if exists events_select on public.events;
create policy events_select on public.events
  for select to anon, authenticated using (public.can_see_calendar(calendar_id));

drop policy if exists events_insert on public.events;
create policy events_insert on public.events
  for insert to authenticated with check (public.can_edit_calendar(calendar_id));

drop policy if exists events_update on public.events;
create policy events_update on public.events
  for update to authenticated
  using (public.can_edit_calendar(calendar_id)) with check (public.can_edit_calendar(calendar_id));

drop policy if exists events_delete on public.events;
create policy events_delete on public.events
  for delete to authenticated using (public.can_edit_calendar(calendar_id));
