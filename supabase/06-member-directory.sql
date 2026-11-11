-- 06-member-directory.sql
-- Gives signed-in Guild members the Member Directory list WITHOUT opening up the
-- members table. The function returns only the directory fields, only for members
-- who are Active or in the grace period and who have not chosen "Not listed in the
-- Member Directory". Only an Active/grace member, an Administrator or the Superuser
-- may call it. Visitors (not signed in) and Inactive members get nothing.
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

create or replace function public.member_directory()
returns table (
  id uuid, first_name text, last_name text, email text, cell_phone text,
  street_address text, city text, state text, zip text,
  birthday_month smallint, birthday_day smallint,
  interests text[], interests_other text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see_members_area() then
    raise exception 'The Member Directory is for Guild members only.';
  end if;
  return query
    select m.id, m.first_name, m.last_name, m.email, m.cell_phone,
           m.street_address, m.city, m.state, m.zip,
           m.birthday_month, m.birthday_day, m.interests, m.interests_other
    from public.members m
    where not m.directory_opt_out
      and public.membership_status(m.paid_through_year) in ('active', 'grace')
    order by lower(m.last_name), lower(m.first_name);
end $$;

revoke all on function public.member_directory() from public, anon;
grant execute on function public.member_directory() to authenticated;

commit;
