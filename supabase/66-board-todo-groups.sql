-- =====================================================================
-- 66-board-todo-groups.sql  (run once in the Supabase SQL editor, after 65)
-- Board To-Do List: two group choices under Assign to.
--   'all'      = every Executive Board and committee chair role (sort order 10 and up)
--   'all_exec' = every Executive Board role (sort order 10 to 29)
-- Roles added to the roles list later are included by themselves.
-- Safe to run twice. If 63 is ever run again, run 65 and this one after it.
--
-- WHAT THIS ADDS (for the backup list): nothing new; two functions are replaced.
-- =====================================================================

create or replace function public.board_todos_roles_ok()
returns trigger language plpgsql as $$
begin
  if exists (select 1 from unnest(new.roles) x
              where x is distinct from 'all' and x is distinct from 'all_exec'
                and not exists (select 1 from public.roles r where r.role_key = x and r.sort_order >= 10)) then
    raise exception 'Tasks can be assigned only to Board and committee chair roles.';
  end if;
  return new;
end $$;

-- Who may tick a task: same as in 63, plus holders of any role in an assigned group.
create or replace function public.can_complete_todo(p_todo uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_manage_todos() or (public.can_see_members_area() and exists (
    select 1 from public.board_todos t
      join public.member_roles mr on mr.member_id = public.current_member_id()
      join public.roles r on r.role_key = mr.role_key
     where t.id = p_todo
       and (mr.role_key = any (t.roles)
         or ('all' = any (t.roles) and r.sort_order >= 10)
         or ('all_exec' = any (t.roles) and r.sort_order between 10 and 29))))
$$;
