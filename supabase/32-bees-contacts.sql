-- =====================================================================
-- 32-bees-contacts.sql  (run once in the Supabase SQL editor, after 31)
-- A bee's contact person now comes from the member database instead of
-- being typed in. The chair records whether the contact has agreed to
-- show their email and/or phone on the public Bees page; nothing is shown
-- unless it is ticked. The public page reads the current email and phone
-- from the member record through bees_public(), so a change in My Profile
-- shows up without editing the bee.
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): columns bees.contact_member_id,
-- bees.show_email, bees.show_phone. The old typed contact_name,
-- contact_email and contact_phone columns are removed.
-- =====================================================================

alter table public.bees add column if not exists contact_member_id uuid references public.members (id) on delete set null;
alter table public.bees add column if not exists show_email boolean not null default false;
alter table public.bees add column if not exists show_phone boolean not null default false;
alter table public.bees drop column if exists contact_name;
alter table public.bees drop column if exists contact_email;
alter table public.bees drop column if exists contact_phone;

-- The chair's member picker: Active and grace members only.
create or replace function public.bees_member_pick()
returns table (id uuid, first_name text, last_name text, email text, cell_phone text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_manage_bees() then
    raise exception 'Only the Bees Chair, Administrators and the Superuser can choose a contact.';
  end if;
  return query
    select m.id, m.first_name, m.last_name, m.email, m.cell_phone
    from public.members m
    where public.membership_status(m.paid_through_year) in ('active', 'grace')
    order by lower(m.last_name), lower(m.first_name);
end $$;
revoke all on function public.bees_member_pick() from public, anon;
grant execute on function public.bees_member_pick() to authenticated;

-- The public list: the contact's name always, email and phone only if allowed.
create or replace function public.bees_public()
returns table (
  id uuid, name text, meets_when text, meets_where text, about text, is_open boolean,
  photo_path text, sort_order int, contact_name text, contact_email text, contact_phone text
)
language sql stable security definer set search_path = public as $$
  select b.id, b.name, b.meets_when, b.meets_where, b.about, b.is_open, b.photo_path, b.sort_order,
         case when m.id is null then null else btrim(m.first_name || ' ' || m.last_name) end,
         case when b.show_email then m.email end,
         case when b.show_phone then m.cell_phone end
  from public.bees b
  left join public.members m on m.id = b.contact_member_id
  order by b.sort_order, lower(b.name)
$$;
grant execute on function public.bees_public() to anon, authenticated;
