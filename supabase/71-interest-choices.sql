-- =====================================================================
-- 71-interest-choices.sql  (run once, after 70)
-- The Quilting Interests check boxes become an editable list.
-- Everyone (including the signed-out Join form) reads it. Administrators
-- and the Superuser add, rename and delete choices, from Site
-- Administration > Quilting Interests (interests-manage.html).
--   Rename: members and membership requests that had the old name get the
--           new one.
--   Delete: the choice is no longer offered. Member records are not changed
--           here; it drops off a member's record the next time that member
--           saves My Profile or renews.
-- Safe to run twice (the starting choices are added only to an empty list).
--
-- WHAT THIS ADDS (for the backup list): table interest_choices.
-- Reset the Site does not touch it.
-- =====================================================================

create table if not exists public.interest_choices (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (name = btrim(name) and length(name) between 1 and 40),
  sort_order int  not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists interest_choices_name_key on public.interest_choices (lower(name));

insert into public.interest_choices (name, sort_order)
select v.name, v.sort_order
  from (values ('Piecing', 10), ('Applique', 20), ('Paper Piecing', 30), ('English Paper Piecing', 40),
               ('Modern Quilts', 50), ('Color Theory', 60), ('Hand Quilting', 70), ('Embroidery', 80)) as v(name, sort_order)
 where not exists (select 1 from public.interest_choices);

alter table public.interest_choices enable row level security;
revoke all on public.interest_choices from anon, authenticated;
grant select on public.interest_choices to anon;
grant select, insert, delete on public.interest_choices to authenticated;   -- renames go through rename_interest()

drop policy if exists interest_choices_select on public.interest_choices;
create policy interest_choices_select on public.interest_choices for select to anon, authenticated using (true);
drop policy if exists interest_choices_insert on public.interest_choices;
create policy interest_choices_insert on public.interest_choices for insert to authenticated
  with check (public.is_admin());
drop policy if exists interest_choices_delete on public.interest_choices;
create policy interest_choices_delete on public.interest_choices for delete to authenticated
  using (public.is_admin());

create or replace function public.rename_interest(p_id uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_old text;
  v_new text := btrim(coalesce(p_name, ''));
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only an Administrator can change the interest choices.';
  end if;
  select name into v_old from public.interest_choices where id = p_id for update;
  if v_old is null then raise exception 'That choice is no longer on the list.'; end if;
  update public.interest_choices set name = v_new where id = p_id;
  if v_new <> v_old then
    update public.members set interests = array_replace(interests, v_old, v_new) where v_old = any (interests);
    update public.membership_requests set interests = array_replace(interests, v_old, v_new) where v_old = any (interests);
  end if;
end $$;
revoke all on function public.rename_interest(uuid, text) from public, anon;
grant execute on function public.rename_interest(uuid, text) to authenticated;
