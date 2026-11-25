-- =====================================================================
-- 65-board-todo-even-odd.sql  (run once in the Supabase SQL editor, after 64)
-- Board To-Do List: "Even years" and "Odd years" choices under How often.
-- Safe to run twice. If 63 is ever run again, run this one after it.
--
-- WHAT THIS ADDS (for the backup list): column board_todos.year_parity
-- ('even', 'odd', or blank for every year / one time).
-- =====================================================================

alter table public.board_todos add column if not exists year_parity text;
alter table public.board_todos drop constraint if exists board_todos_year_parity_check;
alter table public.board_todos add constraint board_todos_year_parity_check
  check (year_parity is null or year_parity in ('even', 'odd'));

-- Same as in 63, plus: no ticks for a year of the wrong kind.
create or replace function public.board_todo_done_stamp()
returns trigger language plpgsql as $$
declare t public.board_todos;
begin
  if current_user in ('anon', 'authenticated') then
    select * into t from public.board_todos where id = new.todo_id;
    if t.id is null or new.year < t.first_year or (t.last_year is not null and new.year > t.last_year) then
      raise exception 'That task is not on the list for %.', new.year;
    end if;
    if t.year_parity is not null and (new.year % 2 = 0) <> (t.year_parity = 'even') then
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
