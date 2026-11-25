-- =====================================================================
-- 67-reset-block-of-the-month.sql  (run once in the Supabase SQL editor, after 66)
-- Reset the Site now covers Block of the Month: its years, months, extra files
-- and uploaded photos and PDFs are cleared only when "The pages and files the
-- chairs prepared" is unticked. The Block of the Month Chair role is kept.
-- This replaces only the two reset functions (including what 64 added). If 64 is
-- ever run again, run this one after it. Do NOT re-run 38.
-- Safe to run twice.
-- =====================================================================

begin;

-- ---------- preview counts ----------
create or replace function public.reset_site_counts(p_keep jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_admins boolean := coalesce((p_keep->>'admins')::boolean, true);
  t text;
  out jsonb := '{}'::jsonb;
begin
  if not public.is_superuser() then raise exception 'Only the Superuser can do this.'; end if;
  out := out || jsonb_build_object('members', (
    select count(*) from public.members m
     where not exists (select 1 from public.member_roles r where r.member_id = m.id
                        and (r.role_key = 'superuser' or (v_admins and r.role_key = 'administrator')))));
  foreach t in array array['membership_requests','workshop_registrations','whats_new','last_seen','notices','special_notices',
      'member_emails','sunshine_notes','comfort_kit_claims','quilts_needing_work','comfort_log_in','comfort_log_out',
      'comfort_year_start','member_imports','board_todo_done',
      'board_todos','program_months','program_month_costs','program_costs','nonmember_fees','workshop_materials','newsletters','charities',
      'bees','guild_history_entries','comfort_patterns','news_items','retreats','events','guild_contact','site_appearance',
      'conversations','message_blocks','member_messaging',
      'bom_years','bom_months','bom_files'] loop
    out := out || jsonb_build_object(t, public._count_rows(t));
  end loop;
  return jsonb_build_object('counts', out,
    'mode', (select site_mode from public.site_config where id),
    'last_reset_at', (select last_reset_at from public.site_config where id));
end $$;

-- ---------- the reset ----------
-- p_keep: {"settings":true,"dues":true,"admins":true,"content":true}; a missing key counts as true.
create or replace function public.reset_site(p_keep jsonb, p_phrase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_settings boolean := coalesce((p_keep->>'settings')::boolean, true);
  v_dues     boolean := coalesce((p_keep->>'dues')::boolean, true);
  v_admins   boolean := coalesce((p_keep->>'admins')::boolean, true);
  v_content  boolean := coalesce((p_keep->>'content')::boolean, true);
  v_me       uuid := public.current_member_id();
  v_ids      uuid[];
  v_users    uuid[];
  v_removed  bigint;
  t          text;
  counts     jsonb := '{}'::jsonb;
  buckets    text[] := array['special-notices'];
  n          bigint;
  content_tables text[] := array['workshop_materials','program_month_costs','program_costs','program_months',
      'nonmember_fees','newsletters','charities','bees','guild_history_entries','comfort_patterns','news_items','retreats','events','board_todos',
      'bom_files','bom_months','bom_years','bom_settings'];
  existing   text[] := '{}';
begin
  if not public.is_superuser() then
    raise exception 'Only the Superuser can reset the site.';
  end if;
  if (select site_mode from public.site_config where id) <> 'testing' then
    raise exception 'The site is live. It cannot be reset.';
  end if;
  if p_phrase is distinct from 'RESET' then
    raise exception 'Type RESET in capital letters to confirm.';
  end if;
  if not exists (select 1 from public.site_log
                  where action = 'backup exported' and actor_member_id = v_me and at > now() - interval '30 minutes') then
    raise exception 'Download a backup first (it must be made within the last 30 minutes).';
  end if;

  -- people to remove: everyone except Superusers (and Administrators if kept)
  select coalesce(array_agg(m.id), '{}'), coalesce(array_agg(m.auth_user_id) filter (where m.auth_user_id is not null), '{}')
    into v_ids, v_users
    from public.members m
   where not exists (select 1 from public.member_roles r where r.member_id = m.id
                      and (r.role_key = 'superuser' or (v_admins and r.role_key = 'administrator')));

  -- test activity (always cleared)
  foreach t in array array['membership_requests','workshop_registrations','whats_new','last_seen','notices','special_notices',
      'member_emails','sunshine_notes','comfort_kit_claims','quilts_needing_work','comfort_log_in','comfort_log_out',
      'comfort_year_start','member_imports','board_todo_done','signin_link_requests',
      'conversations','message_blocks','member_messaging'] loop
    if to_regclass('public.' || quote_ident(t)) is not null then
      execute format('delete from public.%I where true', t);
      get diagnostics n = row_count;
      counts := counts || jsonb_build_object(t, n);
    end if;
  end loop;

  delete from public.members where id = any(v_ids);
  get diagnostics v_removed = row_count;
  counts := counts || jsonb_build_object('members', v_removed);
  delete from auth.users where id = any(v_users);

  -- pages and files the chairs prepared
  if not v_content then
    foreach t in array content_tables loop
      if to_regclass('public.' || quote_ident(t)) is not null then
        counts := counts || jsonb_build_object(t, public._count_rows(t));
        existing := existing || t;
      end if;
    end loop;
    if array_length(existing, 1) is not null then
      execute 'truncate table ' || (select string_agg(format('public.%I', e), ', ') from unnest(existing) e) || ' cascade';
    end if;
    buckets := buckets || array['program-photos','workshop-materials','comfort-patterns','newsletters','bees','block-of-the-month'];
  end if;

  -- settings and appearance
  if not v_settings then
    delete from public.guild_contact where true;
    delete from public.site_appearance where true;
    buckets := buckets || array['site-appearance'];
  end if;
  if not v_dues then
    update public.site_config set
      renew_dues_regular = 25.00, renew_dues_junior = 15.00, renew_dues_exempt = 0,
      join_dues_regular  = 25.00, join_dues_junior  = 15.00, join_dues_exempt  = 0,
      renewals_open = false
    where id;
  end if;

  update public.site_config set last_reset_at = now() where id;
  insert into public.site_log (actor_member_id, action, details)
  values (v_me, 'site reset', jsonb_build_object('keep', jsonb_build_object('settings', v_settings, 'dues', v_dues,
          'admins', v_admins, 'content', v_content), 'counts', counts));
  return jsonb_build_object('counts', counts, 'buckets', to_jsonb(buckets),
                            'kept', jsonb_build_object('settings', v_settings, 'dues', v_dues, 'admins', v_admins, 'content', v_content));
end $$;

revoke all on function public.reset_site_counts(jsonb) from public, anon;
revoke all on function public.reset_site(jsonb, text) from public, anon;
grant execute on function public.reset_site_counts(jsonb) to authenticated;
grant execute on function public.reset_site(jsonb, text) to authenticated;

commit;
