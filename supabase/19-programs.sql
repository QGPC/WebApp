-- =====================================================================
-- 19-programs.sql  (run once, after 18-charities.sql)
-- Programs & Workshops, build 1: one row per month (a program and an
-- optional workshop), a single "Where & when" card, photos, and the
-- Programs / Workshops events on the calendar (kept in step automatically).
-- Drafts are seen only by the people who can edit; published months by everyone.
-- Safe to run twice.
-- =====================================================================

-- Who may plan programs: Program Chair, President, Vice President, Administrators, Superuser.
create or replace function public.can_edit_programs()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('program_chair')
      or public.has_role('president') or public.has_role('vice_president')
$$;

create table if not exists public.program_months (
  id             uuid primary key default gen_random_uuid(),
  month_on       date not null unique check (extract(day from month_on) = 1),
  status         text not null default 'draft' check (status in ('draft', 'published')),
  -- the monthly program
  prog_date      date,
  prog_time      text,
  prog_place     text,
  prog_speaker   text,
  prog_site      text check (prog_site is null or prog_site ~* '^https?://'),
  prog_title     text,
  prog_bio       text,
  prog_about     text,
  prog_photo     text,
  prog_photo_alt text,
  -- the workshop (optional)
  has_workshop   boolean not null default false,
  ws_same        boolean not null default true,     -- same speaker as the program
  ws_speaker     text,
  ws_date        date,
  ws_time        text,
  ws_place       text,
  ws_title       text,
  ws_fee         numeric(8,2) check (ws_fee is null or ws_fee >= 0),
  ws_spots       int check (ws_spots is null or ws_spots >= 0),
  ws_last_date   date,
  ws_level       text,
  ws_kit_fee     numeric(8,2) check (ws_kit_fee is null or ws_kit_fee >= 0),
  ws_kit_to      text,
  ws_kit_desc    text,
  ws_desc        text,
  ws_photo       text,
  ws_photo_alt   text,
  created_by     uuid references public.members (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

drop trigger if exists program_months_updated on public.program_months;
create trigger program_months_updated before update on public.program_months
  for each row execute function public.set_updated_at();

create or replace function public.program_months_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.created_by := public.current_member_id(); end if;
  new.prog_time := nullif(btrim(coalesce(new.prog_time, '')), '');
  new.prog_place := nullif(btrim(coalesce(new.prog_place, '')), '');
  new.prog_speaker := nullif(btrim(coalesce(new.prog_speaker, '')), '');
  new.prog_title := nullif(btrim(coalesce(new.prog_title, '')), '');
  new.ws_title := nullif(btrim(coalesce(new.ws_title, '')), '');
  return new;
end $$;
drop trigger if exists program_months_stamp on public.program_months;
create trigger program_months_stamp before insert or update on public.program_months
  for each row execute function public.program_months_stamp();

-- Keep the Programs and Workshops calendar events in step with published months.
create or replace function public.program_months_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  pc uuid; wc uuid;
begin
  if tg_op = 'DELETE' then
    delete from public.events where source_id = old.id;
    return old;
  end if;
  delete from public.events where source_id = new.id;
  if new.status = 'published' then
    select id into pc from public.calendars where slug = 'programs';
    select id into wc from public.calendars where slug = 'workshops';
    if new.prog_date is not null and pc is not null then
      insert into public.events (calendar_id, title, starts_on, time_text, location, details, source_id)
      values (pc, coalesce(new.prog_title, 'Monthly program')
                  || case when new.prog_speaker is not null then ' with ' || new.prog_speaker else '' end,
              new.prog_date, new.prog_time, new.prog_place, null, new.id);
    end if;
    if new.has_workshop and new.ws_date is not null and wc is not null then
      insert into public.events (calendar_id, title, starts_on, time_text, location, details, source_id)
      values (wc, coalesce(new.ws_title, 'Workshop'),
              new.ws_date, new.ws_time, coalesce(new.ws_place, new.prog_place), null, new.id);
    end if;
  end if;
  return new;
end $$;

alter table public.events add column if not exists source_id uuid;
create index if not exists events_by_source on public.events (source_id);

drop trigger if exists program_months_sync on public.program_months;
create trigger program_months_sync after insert or update or delete on public.program_months
  for each row execute function public.program_months_sync();

-- The standing "Where & when" card (always one row).
create table if not exists public.program_settings (
  id          int primary key default 1 check (id = 1),
  prog_day    text, prog_time text, prog_place text, prog_address text,
  ws_day      text, ws_time   text, ws_place   text, ws_address   text,
  note        text,
  updated_at  timestamptz not null default now()
);
insert into public.program_settings (id) values (1) on conflict (id) do nothing;
drop trigger if exists program_settings_updated on public.program_settings;
create trigger program_settings_updated before update on public.program_settings
  for each row execute function public.set_updated_at();

alter table public.program_months   enable row level security;
alter table public.program_settings enable row level security;

grant select on public.program_months, public.program_settings to anon;
grant select, insert, update, delete on public.program_months to authenticated;
grant select, update on public.program_settings to authenticated;

drop policy if exists pm_select on public.program_months;
create policy pm_select on public.program_months
  for select to anon, authenticated using (status = 'published' or public.can_edit_programs());
drop policy if exists pm_insert on public.program_months;
create policy pm_insert on public.program_months
  for insert to authenticated with check (public.can_edit_programs());
drop policy if exists pm_update on public.program_months;
create policy pm_update on public.program_months
  for update to authenticated using (public.can_edit_programs()) with check (public.can_edit_programs());
drop policy if exists pm_delete on public.program_months;
create policy pm_delete on public.program_months
  for delete to authenticated using (public.can_edit_programs());

drop policy if exists ps_select on public.program_settings;
create policy ps_select on public.program_settings for select to anon, authenticated using (true);
drop policy if exists ps_update on public.program_settings;
create policy ps_update on public.program_settings
  for update to authenticated using (public.can_edit_programs()) with check (public.can_edit_programs());

-- Photos: public bucket (speaker photos are shown to visitors). JPG or PNG, up to 2 MB.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('program-photos', 'program-photos', true, 2097152, array['image/jpeg','image/png'])
on conflict (id) do update
  set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg','image/png'];

drop policy if exists pp_files_insert on storage.objects;
create policy pp_files_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'program-photos' and public.can_edit_programs());
drop policy if exists pp_files_update on storage.objects;
create policy pp_files_update on storage.objects
  for update to authenticated
  using (bucket_id = 'program-photos' and public.can_edit_programs())
  with check (bucket_id = 'program-photos' and public.can_edit_programs());
drop policy if exists pp_files_delete on storage.objects;
create policy pp_files_delete on storage.objects
  for delete to authenticated using (bucket_id = 'program-photos' and public.can_edit_programs());
