-- 02-profile-fields.sql
-- Adds the fields the My Profile page needs: a split mailing address and
-- quilting interests. Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

alter table public.members
  add column if not exists street_address  text,
  add column if not exists city            text,
  add column if not exists state           text,
  add column if not exists zip             text,
  add column if not exists interests       text[] not null default '{}',
  add column if not exists interests_other text;

-- carry over anything already in the old single-line address, then drop it
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'members'
               and column_name = 'mailing_address') then
    update public.members set street_address = mailing_address
     where street_address is null and mailing_address is not null;
    drop view if exists public.members_with_status;
    alter table public.members drop column mailing_address;
  end if;
end $$;

-- the view lists columns when it is created, so rebuild it to include the new ones
drop view if exists public.members_with_status;
create view public.members_with_status
  with (security_invoker = true) as
select m.*, public.membership_status(m.paid_through_year) as status
from public.members m;

revoke all on public.members_with_status from anon;
grant select on public.members_with_status to authenticated;

commit;
