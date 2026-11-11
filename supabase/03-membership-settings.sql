-- 03-membership-settings.sql
-- Dues amounts, plus safe ways for the Membership Chair to turn the Renew
-- Membership button on or off and to change the dues, without being able to
-- change anything else in the site settings. Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

alter table public.site_config
  add column if not exists renew_dues_regular numeric(7,2) not null default 25.00 check (renew_dues_regular >= 0),
  add column if not exists renew_dues_junior  numeric(7,2) not null default 15.00 check (renew_dues_junior  >= 0),
  add column if not exists renew_dues_exempt  numeric(7,2) not null default 0.00  check (renew_dues_exempt  >= 0),
  add column if not exists join_dues_regular  numeric(7,2) not null default 25.00 check (join_dues_regular  >= 0),
  add column if not exists join_dues_junior   numeric(7,2) not null default 15.00 check (join_dues_junior   >= 0),
  add column if not exists join_dues_exempt   numeric(7,2) not null default 0.00  check (join_dues_exempt   >= 0);

-- Membership Chair or Superuser: turn the Renew Membership button on or off
create or replace function public.set_renewals_open(p_open boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can change this.';
  end if;
  update public.site_config set renewals_open = p_open where id;
end $$;

-- Membership Chair or Superuser: change the dues amounts
create or replace function public.set_dues(
  p_renew_regular numeric, p_renew_junior numeric, p_renew_exempt numeric,
  p_join_regular  numeric, p_join_junior  numeric, p_join_exempt  numeric)
returns void language plpgsql security definer set search_path = public as $$
declare old_row public.site_config;
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can change this.';
  end if;
  select * into old_row from public.site_config where id;
  update public.site_config set
    renew_dues_regular = p_renew_regular, renew_dues_junior = p_renew_junior, renew_dues_exempt = p_renew_exempt,
    join_dues_regular  = p_join_regular,  join_dues_junior  = p_join_junior,  join_dues_exempt  = p_join_exempt
  where id;
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'dues changed', jsonb_build_object(
    'renew', jsonb_build_array(old_row.renew_dues_regular, old_row.renew_dues_junior, old_row.renew_dues_exempt,
                               p_renew_regular, p_renew_junior, p_renew_exempt),
    'join',  jsonb_build_array(old_row.join_dues_regular, old_row.join_dues_junior, old_row.join_dues_exempt,
                               p_join_regular, p_join_junior, p_join_exempt)));
end $$;

revoke all on function public.set_renewals_open(boolean) from public, anon;
revoke all on function public.set_dues(numeric, numeric, numeric, numeric, numeric, numeric) from public, anon;
grant execute on function public.set_renewals_open(boolean) to authenticated;
grant execute on function public.set_dues(numeric, numeric, numeric, numeric, numeric, numeric) to authenticated;

commit;
