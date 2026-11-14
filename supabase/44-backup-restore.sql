-- 44-backup-restore.sql
-- Backups and Restore (backups: Superuser and Administrators; restore: Superuser only).
-- Matches claude/backup-restore-procedure.md. What this file adds:
--   * backup_log          one row per backup made (never holds a password; never cleared by a reset or a restore)
--   * backup_reminders    one row per reminder email sent (written by the send-backup-reminders Edge Function)
--   * restore_staging     holding area the Restore page fills while it loads a backup file (Superuser only)
--   * site_config.maintenance   the "site is being restored" switch (Superuser only)
--   * backup_status(), set_backup_reminder(), backup_tables(), backup_table(), backup_files(), backup_record()
--   * set_maintenance(), restore_site_counts(), restore_stage_clear(), restore_stage_put(), restore_site()
--   * export_site_backup() is replaced: the Reset the Site page's .json download still works, now leaves a
--     line in backup_log, and no longer includes private messages (see below).
-- The reminder frequency uses the existing site_config.backup_reminder_days (7, 14, 30 or 90).
-- NOT in a backup (and never touched by a restore): private messages (conversations, conversation_members,
-- messages, message_reports, message_blocks, member_messaging), signin_link_requests, backup_log,
-- backup_reminders, restore_staging. The site log and the roles list are in the backup file but a restore
-- never changes them. The Superuser account(s) are never replaced.
-- Run AFTER 43-messages.sql and BEFORE the last re-run of 38-reset-site.sql is not required; 38 can be run any time.
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

-- ---------- tables ----------
create table if not exists public.backup_log (
  id           bigint generated always as identity primary key,
  performed_at timestamptz not null default now(),
  performed_by uuid references public.members (id) on delete set null,
  kind         text not null default 'manual' check (kind in ('manual', 'reset', 'safety')),
  destination  text not null default 'device' check (destination in ('device', 'drive')),
  encrypted    boolean not null default false,
  size_bytes   bigint,
  file_name    text,
  details      jsonb not null default '{}'::jsonb
);
create index if not exists backup_log_at on public.backup_log (performed_at desc);
alter table public.backup_log enable row level security;
revoke all on public.backup_log from anon;
drop policy if exists backup_log_select on public.backup_log;
create policy backup_log_select on public.backup_log for select to authenticated using (public.is_admin());

create table if not exists public.backup_reminders (
  id         bigint generated always as identity primary key,
  sent_at    timestamptz not null default now(),
  recipients int not null default 0
);
alter table public.backup_reminders enable row level security;
revoke all on public.backup_reminders from anon;
drop policy if exists backup_reminders_select on public.backup_reminders;
create policy backup_reminders_select on public.backup_reminders for select to authenticated using (public.is_admin());

create table if not exists public.restore_staging (
  table_name text not null,
  seq        int  not null,
  rows       jsonb not null,
  primary key (table_name, seq)
);
alter table public.restore_staging enable row level security;
revoke all on public.restore_staging from anon, authenticated;

alter table public.site_config add column if not exists maintenance boolean not null default false;

-- ---------- helpers (not callable from the website) ----------
-- Tables that go into a backup file.
create or replace function public._backup_tables()
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(tablename::text order by tablename), '{}')
    from pg_tables
   where schemaname = 'public'
     and tablename not in ('signin_link_requests', 'restore_staging', 'backup_log', 'backup_reminders',
                           'conversations', 'conversation_members', 'messages', 'message_reports',
                           'message_blocks', 'member_messaging')
$$;
revoke all on function public._backup_tables() from public, anon, authenticated;

-- ---------- status (Superuser and Administrators) ----------
create or replace function public.backup_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_days int;
  v_last timestamptz;
  v_today date := (now() at time zone 'America/Chicago')::date;
  v_due date;
  v_by text;
begin
  if not public.is_admin() then raise exception 'Only the Superuser or an Administrator can see backups.'; end if;
  select backup_reminder_days into v_days from public.site_config where id;
  select max(performed_at) into v_last from public.backup_log;
  v_due := case when v_last is null then v_today
                else (v_last at time zone 'America/Chicago')::date + v_days end;
  select trim(m.first_name || ' ' || m.last_name) into v_by
    from public.backup_log b left join public.members m on m.id = b.performed_by
   order by b.performed_at desc limit 1;
  return jsonb_build_object(
    'reminder_days', v_days,
    'last_at', v_last,
    'last_by', v_by,
    'due_date', v_due,
    'days_until_due', v_due - v_today,
    'due', v_due <= v_today,
    'never', v_last is null,
    'maintenance', (select maintenance from public.site_config where id),
    'last_reminder_at', (select max(sent_at) from public.backup_reminders),
    'recent', coalesce((select jsonb_agg(r order by r.performed_at desc) from (
        select b.id, b.performed_at, b.kind, b.destination, b.encrypted, b.size_bytes, b.file_name,
               trim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')) as by_name
          from public.backup_log b left join public.members m on m.id = b.performed_by
         order by b.performed_at desc limit 12) r), '[]'::jsonb));
end $$;

create or replace function public.set_backup_reminder(p_days int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only the Superuser or an Administrator can change this.'; end if;
  if p_days not in (7, 14, 30, 90) then raise exception 'Choose every week, 2 weeks, month or 3 months.'; end if;
  update public.site_config set backup_reminder_days = p_days where id;   -- the existing trigger writes the site log
end $$;

-- ---------- making a backup (Superuser and Administrators) ----------
create or replace function public.backup_tables()
returns text[] language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only the Superuser or an Administrator can make a backup.'; end if;
  return public._backup_tables();
end $$;

create or replace function public.backup_table(p_table text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rows jsonb;
begin
  if not public.is_admin() then raise exception 'Only the Superuser or an Administrator can make a backup.'; end if;
  if not (p_table = any (public._backup_tables())) then raise exception 'Unknown table.'; end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', p_table) into rows;
  return rows;
end $$;

-- Uploaded files (photos, PDFs, newsletters) so the backup can include them.
create or replace function public.backup_files()
returns table (bucket text, name text, size bigint, is_public boolean)
language plpgsql stable security definer set search_path = public, storage as $$
begin
  if not public.is_admin() then raise exception 'Only the Superuser or an Administrator can make a backup.'; end if;
  return query
    select o.bucket_id::text, o.name::text, coalesce((o.metadata->>'size')::bigint, 0), coalesce(b.public, false)
      from storage.objects o join storage.buckets b on b.id = o.bucket_id
     where o.name not like '%.emptyFolderPlaceholder'
     order by o.bucket_id, o.name;
end $$;

-- The page calls this once the file is saved. kind 'safety' (made just before a restore) is Superuser only.
create or replace function public.backup_record(p_kind text, p_destination text, p_encrypted boolean,
                                                p_size bigint, p_file text, p_details jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_admin() then raise exception 'Only the Superuser or an Administrator can make a backup.'; end if;
  if p_kind not in ('manual', 'safety') then raise exception 'Unknown kind of backup.'; end if;
  if p_kind = 'safety' and not public.is_superuser() then raise exception 'Only the Superuser can make a safety backup.'; end if;
  if p_destination not in ('device', 'drive') then raise exception 'Unknown destination.'; end if;
  insert into public.backup_log (performed_by, kind, destination, encrypted, size_bytes, file_name, details)
  values (public.current_member_id(), p_kind, p_destination, coalesce(p_encrypted, false), p_size,
          left(coalesce(p_file, ''), 120), coalesce(p_details, '{}'::jsonb))
  returning id into v_id;
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'backup exported',
          jsonb_build_object('kind', p_kind, 'destination', p_destination, 'encrypted', coalesce(p_encrypted, false),
                             'file', left(coalesce(p_file, ''), 120)));
  return v_id;
end $$;

-- The Reset the Site page's .json download (Superuser only). Same name as before.
create or replace function public.export_site_backup()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t text;
  doc jsonb := '{}'::jsonb;
  rows jsonb;
  counts jsonb := '{}'::jsonb;
begin
  if not public.is_superuser() then
    raise exception 'Only the Superuser can make a backup here.';
  end if;
  foreach t in array public._backup_tables() loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', t) into rows;
    doc := doc || jsonb_build_object(t, rows);
    counts := counts || jsonb_build_object(t, jsonb_array_length(rows));
  end loop;
  insert into public.backup_log (performed_by, kind, destination, encrypted, file_name, details)
  values (public.current_member_id(), 'reset', 'device', false, 'guild-backup.json', jsonb_build_object('counts', counts));
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'backup exported', jsonb_build_object('counts', counts));
  return jsonb_build_object('made_at', now(), 'format', 'guild-backup-json-1', 'counts', counts, 'tables', doc);
end $$;

-- ---------- maintenance switch (Superuser only) ----------
create or replace function public.set_maintenance(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_superuser() then raise exception 'Only the Superuser can do this.'; end if;
  update public.site_config set maintenance = coalesce(p_on, false) where id;
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), case when p_on then 'maintenance on' else 'maintenance off' end, '{}'::jsonb);
end $$;

-- ---------- restore (Superuser only) ----------
create or replace function public.restore_site_counts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t text; out jsonb := '{}'::jsonb;
begin
  if not public.is_superuser() then raise exception 'Only the Superuser can restore the site.'; end if;
  foreach t in array public._backup_tables() loop
    out := out || jsonb_build_object(t, public._count_rows(t));
  end loop;
  return out;
end $$;

create or replace function public.restore_stage_clear()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_superuser() then raise exception 'Only the Superuser can restore the site.'; end if;
  delete from public.restore_staging where true;
end $$;

create or replace function public.restore_stage_put(p_table text, p_seq int, p_rows jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_superuser() then raise exception 'Only the Superuser can restore the site.'; end if;
  if not (p_table = any (public._backup_tables())) then
    raise exception 'This backup holds a table (%) that this site does not have. It is from a different version of the site.', p_table;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'The backup file is not in the expected form.'; end if;
  insert into public.restore_staging (table_name, seq, rows) values (p_table, p_seq, p_rows)
  on conflict (table_name, seq) do update set rows = excluded.rows;
end $$;

-- p_tables: the names of the tables the backup file holds (each must already be staged, even if empty).
create or replace function public.restore_site(p_phrase text, p_tables jsonb, p_made_at text, p_made_by text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me       uuid := public.current_member_id();
  v_all      text[] := public._backup_tables();
  v_declared text[];
  v_tbls     text[];
  v_order    text[] := '{}';
  v_left     text[];
  v_next     text[];
  v_protect  text[] := array['site_log', 'roles'];
  v_special  text[] := array['members', 'member_roles', 'site_config'];
  v_keep     uuid[];
  v_keepmail text[];
  t          text;
  v_rows     jsonb;
  v_cols     text;
  v_sel      text;
  v_set      text;
  v_counts   jsonb := '{}'::jsonb;
  v_n        bigint;
  sq         record;
begin
  if not public.is_superuser() then raise exception 'Only the Superuser can restore the site.'; end if;
  if p_phrase is distinct from 'RESTORE' then raise exception 'Type RESTORE in capital letters to confirm.'; end if;
  if not exists (select 1 from public.backup_log
                  where kind = 'safety' and performed_by = v_me and performed_at > now() - interval '30 minutes') then
    raise exception 'The safety backup of the site as it is now has not been made (it must be made within the last 30 minutes). Nothing was changed.';
  end if;
  if jsonb_typeof(p_tables) <> 'array' then raise exception 'The backup file is not in the expected form.'; end if;

  select coalesce(array_agg(x), '{}') into v_declared from jsonb_array_elements_text(p_tables) x;
  foreach t in array v_declared loop
    if not (t = any (v_all)) then
      raise exception 'This backup holds a table (%) that this site does not have. It is from a different version of the site. Nothing was changed.', t;
    end if;
    if not exists (select 1 from public.restore_staging where table_name = t) then
      raise exception 'The backup was not fully loaded (missing %). Nothing was changed.', t;
    end if;
  end loop;
  select coalesce(array_agg(x), '{}') into v_tbls from unnest(v_declared) x where not (x = any (v_protect));
  if not ('members' = any (v_tbls)) then raise exception 'This backup has no member list, so it cannot be restored. Nothing was changed.'; end if;

  -- parents before children
  v_left := v_tbls;
  while coalesce(array_length(v_left, 1), 0) > 0 loop
    select coalesce(array_agg(x), '{}') into v_next from unnest(v_left) x
     where not exists (
       select 1 from pg_constraint c
         join pg_class cc on cc.oid = c.conrelid join pg_namespace cn on cn.oid = cc.relnamespace and cn.nspname = 'public'
         join pg_class pc on pc.oid = c.confrelid join pg_namespace pn on pn.oid = pc.relnamespace and pn.nspname = 'public'
        where c.contype = 'f' and cc.relname = x and pc.relname <> x
          and pc.relname = any (v_left));
    if coalesce(array_length(v_next, 1), 0) = 0 then v_next := v_left; end if;   -- a cycle: take the rest as they are
    v_order := v_order || v_next;
    select coalesce(array_agg(x), '{}') into v_left from unnest(v_left) x where not (x = any (v_next));
  end loop;

  -- the Superuser account(s) are never replaced
  select coalesce(array_agg(member_id), '{}') into v_keep from public.member_roles where role_key = 'superuser';
  select coalesce(array_agg(lower(btrim(email))), '{}') into v_keepmail from public.members where id = any (v_keep);

  -- no automatic behaviours while the backed-up rows go back in
  foreach t in array v_order loop
    execute format('alter table public.%I disable trigger user', t);
  end loop;

  -- 1. empty the tables (children first); members and role assignments are handled below
  for i in reverse coalesce(array_length(v_order, 1), 0) .. 1 loop
    t := v_order[i];
    continue when t = any (v_special);
    execute format('delete from public.%I', t);
  end loop;

  -- 2. members: remove those not in the backup, then put the backed-up ones back (same ids)
  select coalesce(jsonb_agg(e order by s.seq, x.ord), '[]'::jsonb) into v_rows
    from public.restore_staging s, jsonb_array_elements(s.rows) with ordinality as x(e, ord)
   where s.table_name = 'members';
  delete from public.members m
   where not (m.id = any (v_keep))
     and not exists (select 1 from jsonb_array_elements(v_rows) e where (e->>'id')::uuid = m.id);
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position),
         string_agg(case when column_name = 'auth_user_id'
              then 'coalesce((select u.id from auth.users u where u.id = r.auth_user_id), (select u.id from auth.users u where lower(u.email) = lower(btrim(r.email)) limit 1)) as auth_user_id'
              else 'r.' || quote_ident(column_name) end, ', ' order by ordinal_position),
         string_agg(quote_ident(column_name) || ' = excluded.' || quote_ident(column_name), ', ' order by ordinal_position) filter (where column_name <> 'id')
    into v_cols, v_sel, v_set
    from information_schema.columns where table_schema = 'public' and table_name = 'members' and is_generated = 'NEVER';
  begin
    execute format('insert into public.members (%s) select %s from jsonb_populate_recordset(null::public.members, $1) r
                     where not (r.id = any ($2)) and lower(btrim(r.email)) <> all ($3)
                     on conflict (id) do update set %s', v_cols, v_sel, v_set)
      using v_rows, v_keep, v_keepmail;
  exception when others then
    raise exception 'The members in this backup could not be put back (%). The backup may be from a different version of the site. Nothing was changed.', sqlerrm;
  end;

  -- 3. role assignments (the Superuser's own are left alone)
  delete from public.member_roles where not (member_id = any (v_keep));
  select coalesce(jsonb_agg(e order by s.seq, x.ord), '[]'::jsonb) into v_rows
    from public.restore_staging s, jsonb_array_elements(s.rows) with ordinality as x(e, ord)
   where s.table_name = 'member_roles';
  insert into public.member_roles (member_id, role_key, assigned_by, assigned_at)
  select r.member_id, r.role_key,
         case when exists (select 1 from public.members m where m.id = r.assigned_by) then r.assigned_by end,
         coalesce(r.assigned_at, now())
    from jsonb_populate_recordset(null::public.member_roles, v_rows) r
   where not (r.member_id = any (v_keep))
     and exists (select 1 from public.members m where m.id = r.member_id)
     and exists (select 1 from public.roles o where o.role_key = r.role_key)
  on conflict do nothing;

  -- 4. site settings (dues, renewal switch). The live/testing mode, go-live date, last reset, maintenance
  --    switch and reminder frequency are never taken from a backup.
  if 'site_config' = any (v_declared) then
    select coalesce(jsonb_agg(e order by s.seq, x.ord), '[]'::jsonb) into v_rows
      from public.restore_staging s, jsonb_array_elements(s.rows) with ordinality as x(e, ord)
     where s.table_name = 'site_config';
    if jsonb_array_length(v_rows) > 0 then
      select string_agg(quote_ident(column_name) || ' = r.' || quote_ident(column_name), ', ')
        into v_set
        from information_schema.columns
       where table_schema = 'public' and table_name = 'site_config'
         and column_name not in ('id', 'site_mode', 'went_live_at', 'last_reset_at', 'maintenance', 'updated_at', 'backup_reminder_days');
      begin
        execute format('update public.site_config c set %s from jsonb_populate_recordset(null::public.site_config, $1) r where c.id', v_set)
          using v_rows;
      exception when others then
        raise exception 'The site settings in this backup could not be put back (%). Nothing was changed.', sqlerrm;
      end;
    end if;
  end if;

  -- 5. everything else, parents first
  foreach t in array v_order loop
    continue when t = any (v_special);
    select coalesce(jsonb_agg(e order by s.seq, x.ord), '[]'::jsonb) into v_rows
      from public.restore_staging s, jsonb_array_elements(s.rows) with ordinality as x(e, ord)
     where s.table_name = t;
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
      into v_cols
      from information_schema.columns where table_schema = 'public' and table_name = t and is_generated = 'NEVER';
    begin
      execute format('insert into public.%1$I (%2$s) overriding system value select %2$s from jsonb_populate_recordset(null::public.%1$I, $1)', t, v_cols)
        using v_rows;
      get diagnostics v_n = row_count;
    exception when others then
      raise exception 'The "%" information in this backup could not be put back (%). The backup may be from a different version of the site. Nothing was changed.', t, sqlerrm;
    end;
    v_counts := v_counts || jsonb_build_object(t, v_n);
  end loop;
  v_counts := v_counts || jsonb_build_object('members', (select count(*) from public.members));

  -- counters for tables that number their own rows
  for sq in select c.table_name, c.column_name from information_schema.columns c
            where c.table_schema = 'public' and c.table_name = any (v_order)
              and (c.is_identity = 'YES' or c.column_default like 'nextval%') loop
    execute format('select setval(pg_get_serial_sequence(%L, %L), coalesce(max(%I), 0) + 1, false) from public.%I',
                   'public.' || sq.table_name, sq.column_name, sq.column_name, sq.table_name);
  end loop;

  -- private messages are not in backups; drop any conversation left with nobody in it
  delete from public.conversations c
   where not exists (select 1 from public.conversation_members cm where cm.conversation_id = c.id);

  foreach t in array v_order loop
    execute format('alter table public.%I enable trigger user', t);
  end loop;

  delete from public.restore_staging where true;
  insert into public.site_log (actor_member_id, action, details)
  values (v_me, 'site restored',
          jsonb_build_object('backup_made_at', left(p_made_at, 40), 'backup_made_by', left(p_made_by, 80), 'counts', v_counts));
  return jsonb_build_object('counts', v_counts, 'left_alone', (select coalesce(array_agg(x), '{}') from unnest(v_all) x where not (x = any (v_declared))));
end $$;

-- ---------- who may call what ----------
revoke all on function public.backup_status() from public, anon;
revoke all on function public.set_backup_reminder(int) from public, anon;
revoke all on function public.backup_tables() from public, anon;
revoke all on function public.backup_table(text) from public, anon;
revoke all on function public.backup_files() from public, anon;
revoke all on function public.backup_record(text, text, boolean, bigint, text, jsonb) from public, anon;
revoke all on function public.export_site_backup() from public, anon;
revoke all on function public.set_maintenance(boolean) from public, anon;
revoke all on function public.restore_site_counts() from public, anon;
revoke all on function public.restore_stage_clear() from public, anon;
revoke all on function public.restore_stage_put(text, int, jsonb) from public, anon;
revoke all on function public.restore_site(text, jsonb, text, text) from public, anon;
grant execute on function public.backup_status() to authenticated;
grant execute on function public.set_backup_reminder(int) to authenticated;
grant execute on function public.backup_tables() to authenticated;
grant execute on function public.backup_table(text) to authenticated;
grant execute on function public.backup_files() to authenticated;
grant execute on function public.backup_record(text, text, boolean, bigint, text, jsonb) to authenticated;
grant execute on function public.export_site_backup() to authenticated;
grant execute on function public.set_maintenance(boolean) to authenticated;
grant execute on function public.restore_site_counts() to authenticated;
grant execute on function public.restore_stage_clear() to authenticated;
grant execute on function public.restore_stage_put(text, int, jsonb) to authenticated;
grant execute on function public.restore_site(text, jsonb, text, text) to authenticated;

commit;

-- ---------------------------------------------------------------------------
-- OPTIONAL: send the backup reminder emails on a schedule (Supabase dashboard, one time).
-- The Backups page also triggers the reminder when a Superuser or Administrator opens it,
-- so the schedule is a safety net for when nobody visits. To schedule it:
--   1. Edge Functions > Secrets: add CRON_SECRET = a long random string (keep it in the password manager).
--   2. Database > Extensions: turn on pg_cron and pg_net.
--   3. SQL Editor, run once (replace the two placeholders; do not save this with the real secret in GitHub):
--        select cron.schedule('guild-backup-reminder', '0 14 * * *',
--          $$ select net.http_post(
--               url := 'https://eqifnuckgyesevyphhis.supabase.co/functions/v1/send-backup-reminders',
--               headers := jsonb_build_object('Content-Type','application/json','x-cron-secret','PUT-THE-CRON-SECRET-HERE'),
--               body := '{}'::jsonb) $$);
--      (14:00 UTC is 8 or 9 in the morning in Texas.) The function checks who is calling itself, so deploy it with "Verify JWT" turned OFF.
-- ---------------------------------------------------------------------------
