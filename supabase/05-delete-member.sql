-- 05-delete-member.sql
-- Lets the Membership Chair (or the Superuser) delete a member, with safeguards:
--   * a Superuser can never be deleted here (remove the Superuser role first, on Roles & Permissions)
--   * only a Superuser can delete an Administrator
--   * nobody can delete their own record
-- Deleting a member also deletes their website sign-in account, so the email can be used again.
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

create or replace function public.delete_member(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  m public.members;
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can delete a member.';
  end if;
  select * into m from public.members where id = p_id;
  if not found then
    raise exception 'That member was not found.';
  end if;
  if p_id = public.current_member_id() then
    raise exception 'You cannot delete your own record.';
  end if;
  if exists (select 1 from public.member_roles where member_id = p_id and role_key = 'superuser') then
    raise exception 'A Superuser cannot be deleted here.';
  end if;
  if exists (select 1 from public.member_roles where member_id = p_id and role_key = 'administrator')
     and not public.is_superuser() then
    raise exception 'Only a Superuser can delete an Administrator.';
  end if;

  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'member deleted',
          jsonb_build_object('member_id', m.id, 'email', m.email, 'name', m.first_name || ' ' || m.last_name));

  delete from public.members where id = p_id;
  if m.auth_user_id is not null then
    delete from auth.users where id = m.auth_user_id;
  end if;
end $$;

revoke all on function public.delete_member(uuid) from public, anon;
grant execute on function public.delete_member(uuid) to authenticated;

commit;
