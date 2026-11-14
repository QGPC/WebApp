-- =====================================================================
-- 28-sunshine.sql  (run once in the Supabase SQL editor, after 27)
-- Sunshine & Shadows: members share happy news (Sunshine) or hard news
-- (Shadow); the Sunshine & Shadows Chair reviews every note before it
-- appears; members read the approved notes. Members only.
-- Kept by the Sunshine & Shadows Chair, Administrators and the Superuser.
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): table sunshine_notes.
-- =====================================================================

create or replace function public.can_manage_sunshine()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('sunshine_shadows_chair')
$$;

create table if not exists public.sunshine_notes (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null check (kind in ('sun', 'shadow')),
  about_name       text not null check (length(btrim(about_name)) > 0),
  body             text not null check (length(btrim(body)) > 0),
  card_address     text,
  consent          boolean not null default false,
  submitted_by     uuid references public.members (id) on delete set null,
  submitted_at     timestamptz not null default now(),
  status           text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'taken_down')),
  headline         text,                      -- written or confirmed by the Chair
  expires_on       date,                      -- blank = stays until taken down; shown through this date
  decided_at       timestamptz,
  decided_by       uuid references public.members (id) on delete set null,
  decline_note     text,
  decline_emailed_at timestamptz,
  email_error      text
);
create index if not exists sunshine_notes_status_idx on public.sunshine_notes (status, submitted_at desc);

alter table public.sunshine_notes enable row level security;
grant select, update, delete on public.sunshine_notes to authenticated;   -- no direct insert: members use sunshine_submit()

-- Only the Chair, Administrators and the Superuser read the table directly (members use sunshine_list()).
drop policy if exists sunshine_select on public.sunshine_notes;
create policy sunshine_select on public.sunshine_notes for select to authenticated using (public.can_manage_sunshine());
drop policy if exists sunshine_update on public.sunshine_notes;
create policy sunshine_update on public.sunshine_notes for update to authenticated
  using (public.can_manage_sunshine()) with check (public.can_manage_sunshine());
drop policy if exists sunshine_delete on public.sunshine_notes;
create policy sunshine_delete on public.sunshine_notes for delete to authenticated using (public.can_manage_sunshine());

-- ---------------------------------------------------------------------
-- A member shares a note (goes to the Chair; nothing is shown yet)
-- ---------------------------------------------------------------------
create or replace function public.sunshine_submit(p_kind text, p_about text, p_body text, p_card text, p_consent boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id();
begin
  if me is null or not (public.can_see_members_area() or public.can_manage_sunshine()) then
    raise exception 'Please sign in as a member to share a note.';
  end if;
  if p_kind not in ('sun', 'shadow') then raise exception 'Please choose Sunshine or Shadow.'; end if;
  if length(btrim(coalesce(p_about, ''))) = 0 then raise exception 'Please say who it is about.'; end if;
  if length(btrim(coalesce(p_body, ''))) = 0 then raise exception 'Please write what you would like to share.'; end if;
  if length(p_about) > 120 or length(p_body) > 1000 or length(coalesce(p_card, '')) > 300 then raise exception 'That is too long.'; end if;
  if not coalesce(p_consent, false) then raise exception 'Please confirm the person or family is OK with this being shared.'; end if;
  insert into public.sunshine_notes (kind, about_name, body, card_address, consent, submitted_by)
  values (p_kind, btrim(p_about), btrim(p_body), nullif(btrim(coalesce(p_card, '')), ''), true, me);
end $$;

-- ---------------------------------------------------------------------
-- Members read the notes that are up (no submitter details)
-- ---------------------------------------------------------------------
create or replace function public.sunshine_list()
returns table (id uuid, kind text, headline text, body text, card_address text, posted_at timestamptz)
language sql stable security definer set search_path = public as $$
  select n.id, n.kind, coalesce(nullif(btrim(n.headline), ''), n.about_name), n.body, n.card_address, n.decided_at
  from public.sunshine_notes n
  where n.status = 'approved'
    and (n.expires_on is null or n.expires_on >= public.guild_today())
    and (public.can_see_members_area() or public.can_manage_sunshine())
  order by n.decided_at desc
$$;

-- ---------------------------------------------------------------------
-- The Chair's queue, with the sender's contact details (Chair only)
-- ---------------------------------------------------------------------
create or replace function public.sunshine_queue()
returns table (id uuid, kind text, about_name text, body text, card_address text, consent boolean, submitted_at timestamptz,
               from_name text, from_email text, from_phone text)
language sql stable security definer set search_path = public as $$
  select n.id, n.kind, n.about_name, n.body, n.card_address, n.consent, n.submitted_at,
         btrim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')), m.email, m.cell_phone
  from public.sunshine_notes n left join public.members m on m.id = n.submitted_by
  where n.status = 'pending' and public.can_manage_sunshine()
  order by n.submitted_at
$$;

create or replace function public.sunshine_pending_count()
returns int language sql stable security definer set search_path = public as $$
  select case when public.can_manage_sunshine()
              then (select count(*)::int from public.sunshine_notes where status = 'pending') else 0 end
$$;

-- Approve (optionally with changed wording) or decline
create or replace function public.sunshine_approve(p_id uuid, p_headline text, p_body text, p_expires date)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_sunshine() then raise exception 'Only the Sunshine & Shadows Chair can approve notes.'; end if;
  if length(btrim(coalesce(p_headline, ''))) = 0 then raise exception 'Please write the headline members will see.'; end if;
  if length(btrim(coalesce(p_body, ''))) = 0 then raise exception 'The message cannot be empty.'; end if;
  if p_expires is not null and p_expires < public.guild_today() then raise exception 'Choose today or a later date.'; end if;
  update public.sunshine_notes
     set status = 'approved', headline = btrim(p_headline), body = btrim(p_body), expires_on = p_expires,
         decided_at = now(), decided_by = public.current_member_id()
   where id = p_id and status = 'pending';
  if not found then raise exception 'That note is no longer waiting.'; end if;
end $$;

create or replace function public.sunshine_decline(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_sunshine() then raise exception 'Only the Sunshine & Shadows Chair can decline notes.'; end if;
  update public.sunshine_notes
     set status = 'declined', decline_note = nullif(btrim(coalesce(p_note, '')), ''),
         decided_at = now(), decided_by = public.current_member_id()
   where id = p_id and status = 'pending';
  if not found then raise exception 'That note is no longer waiting.'; end if;
end $$;

create or replace function public.sunshine_take_down(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_sunshine() then raise exception 'Only the Sunshine & Shadows Chair can take notes down.'; end if;
  update public.sunshine_notes set status = 'taken_down', decided_at = now() where id = p_id and status = 'approved';
end $$;

revoke all on function
  public.sunshine_submit(text, text, text, text, boolean), public.sunshine_list(), public.sunshine_queue(),
  public.sunshine_pending_count(), public.sunshine_approve(uuid, text, text, date), public.sunshine_decline(uuid, text),
  public.sunshine_take_down(uuid), public.can_manage_sunshine()
  from public, anon;
grant execute on function
  public.sunshine_submit(text, text, text, text, boolean), public.sunshine_list(), public.sunshine_queue(),
  public.sunshine_pending_count(), public.sunshine_approve(uuid, text, text, date), public.sunshine_decline(uuid, text),
  public.sunshine_take_down(uuid), public.can_manage_sunshine()
  to authenticated;
