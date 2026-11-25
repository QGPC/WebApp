-- =====================================================================
-- 63-board-todos.sql  (run once in the Supabase SQL editor, after 62)
-- Board To-Do List: tasks by month, assigned to Board and committee chair roles,
-- ticked off once per calendar year.
--   Add / change / delete tasks: President, Vice President, Administrators, Superuser.
--   See the list: anyone holding an Executive Board or committee chair role,
--     Administrators, Superuser. Inactive members see nothing.
--   Tick or untick a task: a holder of one of its assigned roles, plus the
--     President, Vice President, Administrators and Superuser.
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): tables board_todos, board_todo_done.
-- Backups pick up new tables by themselves.
-- =====================================================================

create or replace function public.can_manage_todos()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('president') or public.has_role('vice_president')
$$;

create or replace function public.can_see_todos()
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_manage_todos() or (public.can_see_members_area() and exists (
    select 1 from public.member_roles mr
     where mr.member_id = public.current_member_id()
       and mr.role_key not in ('superuser', 'administrator')))
$$;

create table if not exists public.board_todos (
  id          uuid primary key default gen_random_uuid(),
  month       smallint not null check (month between 1 and 12),
  title       text not null check (length(btrim(title)) between 1 and 150),
  details     text check (details is null or length(details) <= 600),
  roles       text[] not null,
  first_year  int not null check (first_year between 2000 and 2200),
  last_year   int check (last_year between 2000 and 2200),   -- blank = repeats every year
  created_by  uuid references public.members (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (last_year is null or last_year >= first_year)
);
alter table public.board_todos drop constraint if exists board_todos_roles_check;
alter table public.board_todos add constraint board_todos_roles_check check (cardinality(roles) >= 1);

-- Only Board and committee chair roles (sort order 10 and up in the roles list).
-- Roles added to that list later can be assigned without changing this file.
create or replace function public.board_todos_roles_ok()
returns trigger language plpgsql as $$
begin
  if exists (select 1 from unnest(new.roles) x
              where not exists (select 1 from public.roles r where r.role_key = x and r.sort_order >= 10)) then
    raise exception 'Tasks can be assigned only to Board and committee chair roles.';
  end if;
  return new;
end $$;
drop trigger if exists board_todos_roles_ok on public.board_todos;
create trigger board_todos_roles_ok before insert or update of roles on public.board_todos
  for each row execute function public.board_todos_roles_ok();

drop trigger if exists board_todos_updated on public.board_todos;
create trigger board_todos_updated before update on public.board_todos
  for each row execute function public.set_updated_at();

-- One row = that task was completed for that year. No row = not done.
create table if not exists public.board_todo_done (
  todo_id        uuid not null references public.board_todos (id) on delete cascade,
  year           int  not null check (year between 2000 and 2200),
  completed_by   uuid references public.members (id) on delete set null,
  completed_name text not null default '',   -- kept even if the member is later removed
  completed_on   date not null default public.guild_today(),
  primary key (todo_id, year)
);

create or replace function public.can_complete_todo(p_todo uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_manage_todos() or (public.can_see_members_area() and exists (
    select 1 from public.board_todos t
      join public.member_roles mr on mr.role_key = any (t.roles)
     where t.id = p_todo and mr.member_id = public.current_member_id()))
$$;

-- The database, not the page, fills in who and when, and refuses years or
-- months the task does not apply to yet.
create or replace function public.board_todo_done_stamp()
returns trigger language plpgsql as $$
declare t public.board_todos;
begin
  if current_user in ('anon', 'authenticated') then
    select * into t from public.board_todos where id = new.todo_id;
    if t.id is null or new.year < t.first_year or (t.last_year is not null and new.year > t.last_year) then
      raise exception 'That task is not on the list for %.', new.year;
    end if;
    if make_date(new.year, t.month, 1) > public.guild_today() then
      raise exception 'That month has not started yet.';
    end if;
    new.completed_by := public.current_member_id();
    new.completed_on := public.guild_today();
    select btrim(m.first_name || ' ' || m.last_name) into new.completed_name
      from public.members m where m.id = new.completed_by;
  end if;
  return new;
end $$;
drop trigger if exists board_todo_done_stamp on public.board_todo_done;
create trigger board_todo_done_stamp before insert on public.board_todo_done
  for each row execute function public.board_todo_done_stamp();

alter table public.board_todos     enable row level security;
alter table public.board_todo_done enable row level security;
revoke all on public.board_todos, public.board_todo_done from anon, authenticated;
grant select, insert, update, delete on public.board_todos to authenticated;
grant select, insert, delete on public.board_todo_done to authenticated;   -- never edited: untick and tick again

drop policy if exists bt_select on public.board_todos;
create policy bt_select on public.board_todos for select to authenticated using (public.can_see_todos());
drop policy if exists bt_insert on public.board_todos;
create policy bt_insert on public.board_todos for insert to authenticated with check (public.can_manage_todos());
drop policy if exists bt_update on public.board_todos;
create policy bt_update on public.board_todos for update to authenticated
  using (public.can_manage_todos()) with check (public.can_manage_todos());
drop policy if exists bt_delete on public.board_todos;
create policy bt_delete on public.board_todos for delete to authenticated using (public.can_manage_todos());

drop policy if exists btd_select on public.board_todo_done;
create policy btd_select on public.board_todo_done for select to authenticated using (public.can_see_todos());
drop policy if exists btd_insert on public.board_todo_done;
create policy btd_insert on public.board_todo_done for insert to authenticated with check (public.can_complete_todo(todo_id));
drop policy if exists btd_delete on public.board_todo_done;
create policy btd_delete on public.board_todo_done for delete to authenticated using (public.can_complete_todo(todo_id));
