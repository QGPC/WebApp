-- 36-member-import.sql
-- Import Members (Superuser only): load the member list from a CSV file.
--   * member_imports: one small audit row per import (who, when, file name, counts, undone_at)
--   * import_members(rows, mode, file_name): saves the checked rows in ONE transaction
--   * undo_member_import(batch): removes the members that import added, unless they have
--     since signed in, hold a role, or were changed
-- No sign-in accounts are created and no emails are sent. Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

create table if not exists public.member_imports (
  id             uuid primary key default gen_random_uuid(),
  at             timestamptz not null default now(),
  by_member_id   uuid references public.members (id) on delete set null,
  file_name      text,
  mode           text not null check (mode in ('skip', 'update')),
  rows_sent      int not null default 0,
  added          int not null default 0,
  updated        int not null default 0,
  skipped        int not null default 0,
  undone_at      timestamptz,
  removed        int
);

alter table public.member_imports enable row level security;
revoke all on public.member_imports from anon;
drop policy if exists member_imports_select on public.member_imports;
create policy member_imports_select on public.member_imports
  for select to authenticated using (public.is_superuser());
grant select on public.member_imports to authenticated;

-- ---------------------------------------------------------------
-- import_members: p_rows is a JSON list. Each row has first_name, last_name, email,
-- membership_type and any of: member_since, paid_through_year, cell_phone, facebook_name,
-- street_address, city, state, zip, directory_opt_out, birthday_month, birthday_day.
-- A key that is missing is left alone when an existing member is updated.
-- ---------------------------------------------------------------
create or replace function public.import_members(p_rows jsonb, p_mode text, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r        jsonb;
  v_email  text;
  v_batch  uuid := gen_random_uuid();
  v_added  int := 0;
  v_upd    int := 0;
  v_skip   int := 0;
  v_id     uuid;
  v_n      int;
begin
  if not public.is_superuser() then
    raise exception 'Only the Superuser can import members.';
  end if;
  if p_mode not in ('skip', 'update') then
    raise exception 'Choose whether to skip or update members who are already on file.';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'No rows were sent.';
  end if;
  v_n := jsonb_array_length(p_rows);
  if v_n = 0 then raise exception 'No rows were sent.'; end if;
  if v_n > 3000 then raise exception 'That file has more than 3000 rows. Please split it.'; end if;

  insert into public.member_imports (id, by_member_id, file_name, mode, rows_sent)
  values (v_batch, public.current_member_id(), left(p_file_name, 200), p_mode, v_n);

  for r in select * from jsonb_array_elements(p_rows) loop
    v_email := lower(btrim(r->>'email'));
    if v_email is null or v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      v_skip := v_skip + 1; continue;
    end if;
    select id into v_id from public.members where lower(email) = v_email;
    if v_id is not null then
      if p_mode = 'skip' then
        v_skip := v_skip + 1;
      else
        update public.members m set
          first_name        = coalesce(nullif(btrim(r->>'first_name'), ''), m.first_name),
          last_name         = coalesce(nullif(btrim(r->>'last_name'), ''), m.last_name),
          membership_type   = coalesce(nullif(r->>'membership_type', ''), m.membership_type),
          member_since      = case when r ? 'member_since'      then nullif(r->>'member_since', '')::int      else m.member_since end,
          paid_through_year = case when r ? 'paid_through_year' then nullif(r->>'paid_through_year', '')::int else m.paid_through_year end,
          cell_phone        = case when r ? 'cell_phone'        then left(nullif(btrim(r->>'cell_phone'), ''), 40) else m.cell_phone end,
          facebook_name     = case when r ? 'facebook_name'     then left(nullif(btrim(r->>'facebook_name'), ''), 120) else m.facebook_name end,
          street_address    = case when r ? 'street_address'    then left(nullif(btrim(r->>'street_address'), ''), 200) else m.street_address end,
          city              = case when r ? 'city'              then left(nullif(btrim(r->>'city'), ''), 80) else m.city end,
          state             = case when r ? 'state'             then left(nullif(btrim(r->>'state'), ''), 20) else m.state end,
          zip               = case when r ? 'zip'               then left(nullif(btrim(r->>'zip'), ''), 12) else m.zip end,
          directory_opt_out = case when r ? 'directory_opt_out' then coalesce((r->>'directory_opt_out')::boolean, false) else m.directory_opt_out end,
          birthday_month    = case when r ? 'birthday_month'    then nullif(r->>'birthday_month', '')::smallint else m.birthday_month end,
          birthday_day      = case when r ? 'birthday_month'    then nullif(r->>'birthday_day', '')::smallint else m.birthday_day end
        where m.id = v_id;
        v_upd := v_upd + 1;
      end if;
    else
      insert into public.members (
        email, first_name, last_name, membership_type, member_since, paid_through_year,
        cell_phone, facebook_name, street_address, city, state, zip,
        directory_opt_out, birthday_month, birthday_day, import_batch_id)
      values (
        v_email, left(btrim(r->>'first_name'), 80), left(btrim(r->>'last_name'), 80), r->>'membership_type',
        nullif(r->>'member_since', '')::int, nullif(r->>'paid_through_year', '')::int,
        left(nullif(btrim(r->>'cell_phone'), ''), 40), left(nullif(btrim(r->>'facebook_name'), ''), 120),
        left(nullif(btrim(r->>'street_address'), ''), 200), left(nullif(btrim(r->>'city'), ''), 80),
        left(nullif(btrim(r->>'state'), ''), 20), left(nullif(btrim(r->>'zip'), ''), 12),
        coalesce((r->>'directory_opt_out')::boolean, false),
        nullif(r->>'birthday_month', '')::smallint, nullif(r->>'birthday_day', '')::smallint, v_batch);
      v_added := v_added + 1;
    end if;
  end loop;

  update public.member_imports set added = v_added, updated = v_upd, skipped = v_skip where id = v_batch;
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'members imported',
          jsonb_build_object('batch', v_batch, 'added', v_added, 'updated', v_upd, 'skipped', v_skip, 'mode', p_mode));
  return jsonb_build_object('batch', v_batch, 'added', v_added, 'updated', v_upd, 'skipped', v_skip);
end $$;

-- ---------------------------------------------------------------
-- undo_member_import: removes the members this import added, except anyone who has signed in
-- (has a sign-in account), holds a role, or has changed their own record since.
-- ---------------------------------------------------------------
create or replace function public.undo_member_import(p_batch uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_total   int;
  v_removed int;
begin
  if not public.is_superuser() then
    raise exception 'Only the Superuser can undo an import.';
  end if;
  if not exists (select 1 from public.member_imports where id = p_batch) then
    raise exception 'That import was not found.';
  end if;
  if exists (select 1 from public.member_imports where id = p_batch and undone_at is not null) then
    raise exception 'That import was already undone.';
  end if;
  select count(*) into v_total from public.members where import_batch_id = p_batch;
  with gone as (
    delete from public.members m
     where m.import_batch_id = p_batch
       and m.auth_user_id is null
       and m.updated_at <= m.created_at + interval '1 minute'
       and not exists (select 1 from public.member_roles mr where mr.member_id = m.id)
    returning 1)
  select count(*) into v_removed from gone;
  update public.member_imports set undone_at = now(), removed = v_removed where id = p_batch;
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'member import undone',
          jsonb_build_object('batch', p_batch, 'removed', v_removed, 'kept', v_total - v_removed));
  return jsonb_build_object('removed', v_removed, 'kept', v_total - v_removed);
end $$;

revoke all on function public.import_members(jsonb, text, text) from public, anon;
revoke all on function public.undo_member_import(uuid) from public, anon;
grant execute on function public.import_members(jsonb, text, text) to authenticated;
grant execute on function public.undo_member_import(uuid) to authenticated;

commit;
