-- =====================================================================
-- 47-bees-no-public-contact.sql  (run once in the Supabase SQL editor, after 46)
-- The public Bees page no longer shows a bee contact's email or phone.
-- It shows only the contact's name; members find the email and phone in
-- the Member Directory. (Decision by Rex, 2026-11-17, after the access audit.)
--
--   1. Clears the old "show email" / "show phone" ticks.
--   2. bees_public() now returns the contact's name only.
--   3. bees_member_pick() (the Bees Chair's picker) now returns only id and
--      name, so the chair's page no longer receives members' email or phone.
--   4. A check makes sure nobody can turn the two ticks back on.
-- Safe to run twice.
--
-- WHAT THIS CHANGES (for the backup list): no new tables or columns. The
-- columns bees.show_email and bees.show_phone stay but are always false.
-- =====================================================================

begin;

update public.bees set show_email = false, show_phone = false
 where show_email or show_phone;

alter table public.bees drop constraint if exists bees_no_public_contact;
alter table public.bees add constraint bees_no_public_contact
  check (not show_email and not show_phone);

-- The public list: the contact's name only.
drop function if exists public.bees_public();
create function public.bees_public()
returns table (
  id uuid, name text, meets_when text, meets_where text, about text, is_open boolean,
  photo_path text, sort_order int, contact_name text
)
language sql stable security definer set search_path = public as $$
  select b.id, b.name, b.meets_when, b.meets_where, b.about, b.is_open, b.photo_path, b.sort_order,
         case when m.id is null then null else btrim(m.first_name || ' ' || m.last_name) end
  from public.bees b
  left join public.members m on m.id = b.contact_member_id
  order by b.sort_order, lower(b.name)
$$;
revoke all on function public.bees_public() from public;
grant execute on function public.bees_public() to anon, authenticated;

-- The chair's member picker: Active and grace members, names only.
drop function if exists public.bees_member_pick();
create function public.bees_member_pick()
returns table (id uuid, first_name text, last_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_manage_bees() then
    raise exception 'Only the Bees Chair, Administrators and the Superuser can choose a contact.';
  end if;
  return query
    select m.id, m.first_name, m.last_name
    from public.members m
    where public.membership_status(m.paid_through_year) in ('active', 'grace')
    order by lower(m.last_name), lower(m.first_name);
end $$;
revoke all on function public.bees_member_pick() from public, anon;
grant execute on function public.bees_member_pick() to authenticated;

commit;
