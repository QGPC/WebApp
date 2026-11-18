-- =====================================================================
-- 53-public-site-info.sql  (run once in the Supabase SQL editor, after 52)
-- Tracker item 28 (Audie 7): visitors who are not signed in can no longer read
-- the whole site_config table. They get a small view with only what the public
-- pages need: the Join dues amounts and the "site is being restored" switch.
--
-- WHAT IT DOES
--   1. Creates view public.public_site_info (join_dues_regular, join_dues_junior,
--      join_dues_exempt, maintenance).
--   2. Replaces the site_config read rule so only signed-in people can read the
--      table (members still need renewals_open and the renewal dues; the
--      Superuser tools read everything). Visitors who are not signed in can no
--      longer see the testing/live mode, reminder days, or reset dates.
--
-- ORDER: push join.html and maintenance.html FIRST, wait for the site to
-- update, THEN run this. Run before the push, the live Join page would show
-- no dues amounts until the push arrives.
--
-- WHAT THIS ADDS (for the backup list): one view, nothing stored. Safe to run twice.
-- =====================================================================

begin;

create or replace view public.public_site_info as
  select join_dues_regular, join_dues_junior, join_dues_exempt, maintenance
  from public.site_config
  where id;

revoke all on public.public_site_info from anon, authenticated;
grant select on public.public_site_info to anon, authenticated;

drop policy if exists site_config_select on public.site_config;
create policy site_config_select on public.site_config
  for select to authenticated using (true);

commit;
