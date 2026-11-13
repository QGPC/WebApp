-- =====================================================================
-- 18-charities.sql  (run once in the Supabase SQL editor)
-- Charities We Support: one list per calendar year, read by everyone
-- (visitors and members), kept by the President, Vice President,
-- Administrators and the Superuser from the President's Page.
-- Safe to run twice.
-- =====================================================================

create or replace function public.can_edit_charities()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('president') or public.has_role('vice_president')
$$;

create table if not exists public.charities (
  id         uuid primary key default gen_random_uuid(),
  year       smallint not null check (year between 2000 and 2100),
  name       text not null check (length(btrim(name)) > 0),
  what       text,                          -- what the Guild does for them
  city       text,
  website    text check (website is null or website ~* '^https?://'),
  sort_order int not null default 0,        -- position within the year (1, 2, 3 ...)
  created_by uuid references public.members (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists charities_year_order on public.charities (year, sort_order);

drop trigger if exists charities_updated on public.charities;
create trigger charities_updated before update on public.charities
  for each row execute function public.set_updated_at();

create or replace function public.charities_stamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := public.current_member_id();
    if coalesce(new.sort_order, 0) = 0 then
      select coalesce(max(sort_order), 0) + 1 into new.sort_order from public.charities where year = new.year;
    end if;
  end if;
  new.name    := btrim(new.name);
  new.what    := nullif(btrim(coalesce(new.what, '')), '');
  new.city    := nullif(btrim(coalesce(new.city, '')), '');
  new.website := nullif(btrim(coalesce(new.website, '')), '');
  return new;
end $$;

drop trigger if exists charities_stamp on public.charities;
create trigger charities_stamp before insert or update on public.charities
  for each row execute function public.charities_stamp();

alter table public.charities enable row level security;
grant select on public.charities to anon;
grant select, insert, update, delete on public.charities to authenticated;

drop policy if exists charities_select on public.charities;
create policy charities_select on public.charities
  for select to anon, authenticated using (true);

drop policy if exists charities_insert on public.charities;
create policy charities_insert on public.charities
  for insert to authenticated with check (public.can_edit_charities());

drop policy if exists charities_update on public.charities;
create policy charities_update on public.charities
  for update to authenticated using (public.can_edit_charities()) with check (public.can_edit_charities());

drop policy if exists charities_delete on public.charities;
create policy charities_delete on public.charities
  for delete to authenticated using (public.can_edit_charities());

-- Move one charity up (p_dir = -1) or down (p_dir = 1) within its year, in one step.
create or replace function public.charity_move(p_id uuid, p_dir int)
returns void language plpgsql security definer set search_path = public as $$
declare me public.charities; other public.charities;
begin
  if not public.can_edit_charities() then raise exception 'Not allowed.'; end if;
  select * into me from public.charities where id = p_id;
  if not found then return; end if;
  if p_dir < 0 then
    select * into other from public.charities where year = me.year and sort_order < me.sort_order order by sort_order desc limit 1;
  else
    select * into other from public.charities where year = me.year and sort_order > me.sort_order order by sort_order asc limit 1;
  end if;
  if not found then return; end if;
  update public.charities set sort_order = other.sort_order where id = me.id;
  update public.charities set sort_order = me.sort_order where id = other.id;
end $$;
revoke all on function public.charity_move(uuid, int) from public, anon;
grant execute on function public.charity_move(uuid, int) to authenticated;

-- Start a year from a copy of another year's list (only when the new year is still empty).
create or replace function public.charities_copy_year(p_from int, p_to int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.can_edit_charities() then raise exception 'Not allowed.'; end if;
  if exists (select 1 from public.charities where year = p_to) then
    raise exception 'That year already has charities.';
  end if;
  insert into public.charities (year, name, what, city, website, sort_order, created_by)
    select p_to, name, what, city, website, sort_order, public.current_member_id()
    from public.charities where year = p_from order by sort_order;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.charities_copy_year(int, int) from public, anon;
grant execute on function public.charities_copy_year(int, int) to authenticated;
