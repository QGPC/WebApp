-- 39-news-retreats.sql  (run once in the Supabase SQL editor, after 38)
-- In the News, Retreats, and Publicity Chair access to Notices.
--   * news_items : the In the News page (public). Edited by the Publicity Chair, President, Vice President,
--                  Administrators and Superuser.
--   * retreats   : the Retreats page (public). Edited by the Retreats Chair, Administrators and Superuser.
--                  Each retreat's start date is also put on the Guild events calendar automatically
--                  (events.retreat_id links the event to its retreat; deleting the retreat removes the event).
--   * notices    : the Publicity Chair may also read, post, change and delete notices.
-- Safe to run more than once.
--
-- WHAT THIS ADDS (for the backup list): tables news_items and retreats; column events.retreat_id.

begin;

-- ---------- In the News ----------
create or replace function public.can_edit_news()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('president') or public.has_role('vice_president')
         or public.has_role('publicity_chair')
$$;

create table if not exists public.news_items (
  id           uuid primary key default gen_random_uuid(),
  headline     text not null check (length(btrim(headline)) > 0),
  publication  text,
  published_on date not null,
  link_url     text check (link_url is null or link_url ~* '^https?://[^[:space:]]+$'),
  note         text,
  created_by   uuid references public.members (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists news_items_by_date on public.news_items (published_on desc);

create or replace function public.news_items_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.created_by := public.current_member_id(); end if;
  new.headline    := btrim(new.headline);
  new.publication := nullif(btrim(coalesce(new.publication, '')), '');
  new.link_url    := nullif(btrim(coalesce(new.link_url, '')), '');
  new.note        := nullif(btrim(coalesce(new.note, '')), '');
  new.updated_at  := now();
  return new;
end $$;
drop trigger if exists news_items_stamp on public.news_items;
create trigger news_items_stamp before insert or update on public.news_items
  for each row execute function public.news_items_stamp();

alter table public.news_items enable row level security;
grant select on public.news_items to anon;
grant select, insert, update, delete on public.news_items to authenticated;

drop policy if exists news_items_select on public.news_items;
create policy news_items_select on public.news_items for select to anon, authenticated using (true);
drop policy if exists news_items_insert on public.news_items;
create policy news_items_insert on public.news_items for insert to authenticated with check (public.can_edit_news());
drop policy if exists news_items_update on public.news_items;
create policy news_items_update on public.news_items for update to authenticated
  using (public.can_edit_news()) with check (public.can_edit_news());
drop policy if exists news_items_delete on public.news_items;
create policy news_items_delete on public.news_items for delete to authenticated using (public.can_edit_news());

-- ---------- Retreats ----------
create or replace function public.can_manage_retreats()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('retreats_chair')
$$;

create table if not exists public.retreats (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) > 0),
  starts_on   date not null,
  ends_on     date,
  place       text,
  cost_text   text,
  about       text,
  signup_text text,
  created_by  uuid references public.members (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);
create index if not exists retreats_by_date on public.retreats (starts_on);

create or replace function public.retreats_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.created_by := public.current_member_id(); end if;
  new.name        := btrim(new.name);
  new.place       := nullif(btrim(coalesce(new.place, '')), '');
  new.cost_text   := nullif(btrim(coalesce(new.cost_text, '')), '');
  new.about       := nullif(btrim(coalesce(new.about, '')), '');
  new.signup_text := nullif(btrim(coalesce(new.signup_text, '')), '');
  new.updated_at  := now();
  return new;
end $$;
drop trigger if exists retreats_stamp on public.retreats;
create trigger retreats_stamp before insert or update on public.retreats
  for each row execute function public.retreats_stamp();

alter table public.retreats enable row level security;
grant select on public.retreats to anon;
grant select, insert, update, delete on public.retreats to authenticated;

drop policy if exists retreats_select on public.retreats;
create policy retreats_select on public.retreats for select to anon, authenticated using (true);
drop policy if exists retreats_insert on public.retreats;
create policy retreats_insert on public.retreats for insert to authenticated with check (public.can_manage_retreats());
drop policy if exists retreats_update on public.retreats;
create policy retreats_update on public.retreats for update to authenticated
  using (public.can_manage_retreats()) with check (public.can_manage_retreats());
drop policy if exists retreats_delete on public.retreats;
create policy retreats_delete on public.retreats for delete to authenticated using (public.can_manage_retreats());

-- a retreat shows on the Guild events calendar (on its first day; a longer retreat says "Oct 3 to Oct 5")
alter table public.events add column if not exists retreat_id uuid unique references public.retreats (id) on delete cascade;

create or replace function public.retreats_sync_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_cal  uuid;
  v_time text;
begin
  select id into v_cal from public.calendars where slug = 'guild';
  if v_cal is null then return new; end if;
  v_time := case when new.ends_on is not null and new.ends_on <> new.starts_on
                 then to_char(new.starts_on, 'Mon FMDD') || ' to ' || to_char(new.ends_on, 'Mon FMDD') else null end;
  insert into public.events (calendar_id, title, starts_on, time_text, location, details, kind, retreat_id)
  values (v_cal, 'Retreat: ' || new.name, new.starts_on, v_time, new.place, left(new.about, 300), 'event', new.id)
  on conflict (retreat_id) do update set
    title = excluded.title, starts_on = excluded.starts_on, time_text = excluded.time_text,
    location = excluded.location, details = excluded.details, calendar_id = excluded.calendar_id;
  return new;
end $$;
drop trigger if exists retreats_sync_event on public.retreats;
create trigger retreats_sync_event after insert or update on public.retreats
  for each row execute function public.retreats_sync_event();

-- ---------- Publicity Chair and Notices ----------
drop policy if exists notices_publicity_select on public.notices;
create policy notices_publicity_select on public.notices for select to authenticated using (public.has_role('publicity_chair'));
drop policy if exists notices_publicity_insert on public.notices;
create policy notices_publicity_insert on public.notices for insert to authenticated with check (public.has_role('publicity_chair'));
drop policy if exists notices_publicity_update on public.notices;
create policy notices_publicity_update on public.notices for update to authenticated
  using (public.has_role('publicity_chair')) with check (public.has_role('publicity_chair'));
drop policy if exists notices_publicity_delete on public.notices;
create policy notices_publicity_delete on public.notices for delete to authenticated using (public.has_role('publicity_chair'));

commit;
