-- 43-messages.sql  (run once in the Supabase SQL editor, after 42)
-- Private messages between Guild members, and the Administrators' review of reported messages.
--
-- HOW IT IS BUILT
--   * Nobody (not even a signed-in member) can read or write the message tables directly. Every read and
--     write goes through the functions below, which check who is asking. This is tighter than table-by-table
--     access rules and keeps private threads private.
--   * Only Active or grace-period members (and Administrators / the Superuser) can use messages. Inactive
--     members are treated like visitors.
--   * Messages are private from other members and from Administrators, who see only a reported message and the
--     two before and two after it. They are NOT end-to-end encrypted: whoever can open the Supabase dashboard
--     (the Superuser) can technically read the tables. Say so in the Privacy Notice.
--   * Messages stay until someone deletes them. A member can delete (not edit) their own messages; the text is
--     erased and the thread shows "This message was deleted."
--
-- BEHAVIORS (chosen in the mockup; Rex to confirm)
--   * "Do not allow" (profile) stops other members starting a conversation with you or adding you to a group.
--     Conversations already under way stay open and you can still reply.
--   * Blocking is silent. The blocked member is not told; they can no longer start a conversation with you or
--     add you to a group, and you no longer see their messages.
--   * "Turn off this member's messaging" (Administrators) lets that member read but not send.
--   * Members listed here are Active/grace members who have NOT chosen "Not listed in the Member Directory".
--   * A group has 2 to 12 people. Nobody can be added after it starts. A member can leave a group.
--   * Sending is limited to 30 messages in 10 minutes per member.
--
-- Safe to run more than once.
--
-- WHAT THIS ADDS (for the backup list): tables member_messaging, conversations, conversation_members, messages,
-- message_reports, message_blocks.

begin;

-- ---------- tables ----------
create table if not exists public.member_messaging (
  member_id    uuid primary key references public.members (id) on delete cascade,
  allowed      boolean not null default true,       -- the member's own choice (My Profile)
  suspended    boolean not null default false,      -- set by an Administrator after a report
  suspended_at timestamptz,
  suspended_by uuid references public.members (id) on delete set null
);

create table if not exists public.conversations (
  id         uuid primary key default gen_random_uuid(),
  title      text check (title is null or length(btrim(title)) between 1 and 80),
  is_group   boolean not null default false,
  created_by uuid references public.members (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  member_id       uuid not null references public.members (id) on delete cascade,
  joined_at       timestamptz not null default now(),
  last_read_at    timestamptz,
  left_at         timestamptz,
  primary key (conversation_id, member_id)
);
create index if not exists conversation_members_by_member on public.conversation_members (member_id) where left_at is null;

create table if not exists public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  sender_id        uuid references public.members (id) on delete set null,
  body             text not null default '',
  sent_at          timestamptz not null default now(),
  deleted_at       timestamptz,
  removed_by_admin boolean not null default false
);
create index if not exists messages_by_conversation on public.messages (conversation_id, sent_at);
create index if not exists messages_by_sender on public.messages (sender_id, sent_at);

create table if not exists public.message_reports (
  id                 uuid primary key default gen_random_uuid(),
  message_id         uuid not null references public.messages (id) on delete cascade,
  reported_by        uuid references public.members (id) on delete set null,
  reported_member_id uuid references public.members (id) on delete set null,
  reason             text,
  reported_at        timestamptz not null default now(),
  status             text not null default 'waiting' check (status in ('waiting', 'dismissed', 'removed', 'messaging_off')),
  resolved_by        uuid references public.members (id) on delete set null,
  resolved_at        timestamptz,
  snapshot           jsonb not null,   -- the reported message and up to two before and after, saved at the moment of reporting
  unique (message_id, reported_by)
);
create index if not exists message_reports_by_status on public.message_reports (status, reported_at desc);

create table if not exists public.message_blocks (
  blocker_id uuid not null references public.members (id) on delete cascade,
  blocked_id uuid not null references public.members (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- no direct access from the website, only through the functions below
alter table public.member_messaging     enable row level security;
alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages             enable row level security;
alter table public.message_reports      enable row level security;
alter table public.message_blocks       enable row level security;
revoke all on public.member_messaging, public.conversations, public.conversation_members,
              public.messages, public.message_reports, public.message_blocks from public, anon, authenticated;

-- ---------- internal helpers (not callable from the website) ----------
-- who is using messages? Raises unless an Active/grace member or an Administrator.
create or replace function public._msg_me()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if not public.can_see_members_area() then
    raise exception 'Private messages are for Guild members only.';
  end if;
  v := public.current_member_id();
  if v is null then
    raise exception 'No membership record is linked to this account.';
  end if;
  return v;
end $$;

create or replace function public._msg_blocked(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.message_blocks
                  where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a))
$$;

create or replace function public._msg_can_send(me uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from public.member_messaging where member_id = me and suspended) then
    raise exception 'Your messaging has been turned off. Please contact an Administrator.';
  end if;
  if (select count(*) from public.messages where sender_id = me and sent_at > now() - interval '10 minutes') >= 30 then
    raise exception 'You are sending messages very quickly. Please wait a few minutes and try again.';
  end if;
end $$;

create or replace function public._msg_body(p text)
returns text language plpgsql immutable as $$
declare b text := btrim(coalesce(p, ''));
begin
  if length(b) = 0 then raise exception 'Please write a message.'; end if;
  if length(b) > 4000 then raise exception 'That message is too long (4000 characters at most).'; end if;
  return b;
end $$;

revoke all on function public._msg_me(), public._msg_blocked(uuid, uuid), public._msg_can_send(uuid),
  public._msg_body(text) from public, anon, authenticated;

-- ---------- who can I message? ----------
create or replace function public.messaging_directory()
returns table (id uuid, first_name text, last_name text)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public._msg_me();
begin
  return query
    select m.id, m.first_name, m.last_name
      from public.members m
      left join public.member_messaging mm on mm.member_id = m.id
     where m.id <> me
       and not m.directory_opt_out
       and public.membership_status(m.paid_through_year) in ('active', 'grace')
       and coalesce(mm.allowed, true)
       and not public._msg_blocked(me, m.id)
     order by lower(m.last_name), lower(m.first_name);
end $$;

-- ---------- start a conversation (one person, or a group) ----------
create or replace function public.start_conversation(p_recipients uuid[], p_title text, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me    uuid := public._msg_me();
  rec   uuid[];
  n     int;
  bad   int;
  cid   uuid;
  body  text;
  ttl   text := nullif(btrim(coalesce(p_title, '')), '');
begin
  perform public._msg_can_send(me);
  body := public._msg_body(p_body);
  select coalesce(array_agg(distinct x), '{}') into rec
    from unnest(coalesce(p_recipients, '{}')) x where x is not null and x <> me;
  n := coalesce(array_length(rec, 1), 0);
  if n = 0 then raise exception 'Choose at least one member to message.'; end if;
  if n > 11 then raise exception 'A group can have up to 12 people, including you.'; end if;
  if ttl is not null and length(ttl) > 80 then raise exception 'The group name can be up to 80 characters.'; end if;

  -- the same message as "cannot receive" for every reason (turned off, blocked, not listed, not a current member)
  select count(*) into bad from unnest(rec) r(rid)
   where not exists (
     select 1 from public.members m
       left join public.member_messaging mm on mm.member_id = m.id
      where m.id = r.rid
        and not m.directory_opt_out
        and public.membership_status(m.paid_through_year) in ('active', 'grace')
        and coalesce(mm.allowed, true)
        and not public._msg_blocked(me, m.id));
  if bad > 0 then
    raise exception 'One or more of those members cannot receive private messages.';
  end if;

  if n = 1 then
    -- reuse the existing one-to-one conversation with this member, if there is one
    select c.id into cid
      from public.conversations c
     where not c.is_group
       and exists (select 1 from public.conversation_members x where x.conversation_id = c.id and x.member_id = me and x.left_at is null)
       and exists (select 1 from public.conversation_members y where y.conversation_id = c.id and y.member_id = rec[1] and y.left_at is null)
     limit 1;
  end if;

  if cid is null then
    insert into public.conversations (title, is_group, created_by)
    values (case when n > 1 then ttl else null end, n > 1, me)
    returning id into cid;
    insert into public.conversation_members (conversation_id, member_id, last_read_at) values (cid, me, now());
    insert into public.conversation_members (conversation_id, member_id)
      select cid, r from unnest(rec) r;
  end if;

  insert into public.messages (conversation_id, sender_id, body) values (cid, me, body);
  update public.conversation_members set last_read_at = now() where conversation_id = cid and member_id = me;
  return cid;
end $$;

-- ---------- reply ----------
create or replace function public.send_message(p_conversation uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := public._msg_me(); body text; mid uuid;
begin
  if not exists (select 1 from public.conversation_members
                  where conversation_id = p_conversation and member_id = me and left_at is null) then
    raise exception 'You are not part of that conversation.';
  end if;
  perform public._msg_can_send(me);
  body := public._msg_body(p_body);
  insert into public.messages (conversation_id, sender_id, body) values (p_conversation, me, body) returning id into mid;
  update public.conversation_members set last_read_at = now() where conversation_id = p_conversation and member_id = me;
  return mid;
end $$;

-- ---------- my conversations (the inbox) ----------
create or replace function public.my_conversations()
returns table (id uuid, title text, is_group boolean, participants jsonb, last_body text, last_sender text,
               last_sent_at timestamptz, last_deleted boolean, unread int)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public._msg_me();
begin
  return query
    select c.id, c.title, c.is_group,
           coalesce((select jsonb_agg(jsonb_build_object('id', p.member_id, 'name', pm.first_name || ' ' || pm.last_name)
                                      order by lower(pm.first_name), lower(pm.last_name))
                       from public.conversation_members p
                       join public.members pm on pm.id = p.member_id
                      where p.conversation_id = c.id and p.left_at is null and p.member_id <> me), '[]'::jsonb),
           case when lm.deleted_at is null then lm.body else null end,
           coalesce(sm.first_name, 'Former member'),
           coalesce(lm.sent_at, c.created_at),
           coalesce(lm.deleted_at is not null, false),
           (select count(*)::int from public.messages m
             where m.conversation_id = c.id
               and m.sender_id is distinct from me
               and m.deleted_at is null
               and (cm.last_read_at is null or m.sent_at > cm.last_read_at)
               and not exists (select 1 from public.message_blocks b where b.blocker_id = me and b.blocked_id = m.sender_id))
      from public.conversation_members cm
      join public.conversations c on c.id = cm.conversation_id
      left join lateral (
        select m.body, m.sent_at, m.deleted_at, m.sender_id
          from public.messages m
         where m.conversation_id = c.id
           and not exists (select 1 from public.message_blocks b where b.blocker_id = me and b.blocked_id = m.sender_id)
         order by m.sent_at desc, m.id desc limit 1) lm on true
      left join public.members sm on sm.id = lm.sender_id
     where cm.member_id = me and cm.left_at is null
     order by coalesce(lm.sent_at, c.created_at) desc;
end $$;

-- ---------- one conversation, with its messages ----------
create or replace function public.conversation_thread(p_conversation uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := public._msg_me(); j jsonb;
begin
  if not exists (select 1 from public.conversation_members
                  where conversation_id = p_conversation and member_id = me and left_at is null) then
    raise exception 'You are not part of that conversation.';
  end if;
  select jsonb_build_object(
    'id', c.id, 'title', c.title, 'is_group', c.is_group,
    'can_send', not exists (select 1 from public.member_messaging where member_id = me and suspended),
    'participants', coalesce((select jsonb_agg(jsonb_build_object('id', p.member_id, 'name', pm.first_name || ' ' || pm.last_name, 'me', p.member_id = me)
                                               order by lower(pm.first_name), lower(pm.last_name))
                                from public.conversation_members p
                                join public.members pm on pm.id = p.member_id
                               where p.conversation_id = c.id and p.left_at is null), '[]'::jsonb),
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'sender_id', t.sender_id,
               'sender', coalesce(t.first_name || ' ' || t.last_name, 'Former member'),
               'mine', t.sender_id = me,
               'body', case when t.deleted_at is null then t.body else null end,
               'sent_at', t.sent_at, 'deleted', t.deleted_at is not null, 'removed', t.removed_by_admin,
               'reported', exists (select 1 from public.message_reports r where r.message_id = t.id and r.reported_by = me))
             order by t.sent_at, t.id)
        from (select m.*, sm.first_name, sm.last_name
                from public.messages m
                left join public.members sm on sm.id = m.sender_id
               where m.conversation_id = c.id
                 and not exists (select 1 from public.message_blocks b where b.blocker_id = me and b.blocked_id = m.sender_id)
               order by m.sent_at desc, m.id desc limit 500) t), '[]'::jsonb))
    into j
    from public.conversations c where c.id = p_conversation;
  return j;
end $$;

create or replace function public.mark_conversation_read(p_conversation uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public._msg_me();
begin
  update public.conversation_members set last_read_at = now()
   where conversation_id = p_conversation and member_id = me and left_at is null;
end $$;

-- number for the Messages button on the member home page
create or replace function public.unread_message_count()
returns int language plpgsql stable security definer set search_path = public as $$
declare me uuid := public._msg_me();
begin
  return coalesce((
    select count(*)::int
      from public.conversation_members cm
      join public.messages m on m.conversation_id = cm.conversation_id
     where cm.member_id = me and cm.left_at is null
       and m.sender_id is distinct from me and m.deleted_at is null
       and (cm.last_read_at is null or m.sent_at > cm.last_read_at)
       and not exists (select 1 from public.message_blocks b where b.blocker_id = me and b.blocked_id = m.sender_id)), 0);
end $$;

-- ---------- delete my message / leave a group ----------
create or replace function public.delete_my_message(p_message uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public._msg_me(); n int;
begin
  update public.messages set deleted_at = now(), body = ''
   where id = p_message and sender_id = me and deleted_at is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'That message could not be deleted.'; end if;
end $$;

create or replace function public.leave_conversation(p_conversation uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public._msg_me(); n int;
begin
  update public.conversation_members cm set left_at = now()
   where cm.conversation_id = p_conversation and cm.member_id = me and cm.left_at is null
     and exists (select 1 from public.conversations c where c.id = p_conversation and c.is_group);
  get diagnostics n = row_count;
  if n = 0 then raise exception 'You can only leave a group conversation that you are in.'; end if;
end $$;

-- ---------- report a message ----------
create or replace function public.report_message(p_message uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me    uuid := public._msg_me();
  m     public.messages;
  snap  jsonb;
  why   text := nullif(btrim(coalesce(p_reason, '')), '');
  n     int;
begin
  select * into m from public.messages where id = p_message;
  if not found or not exists (select 1 from public.conversation_members
                               where conversation_id = m.conversation_id and member_id = me and left_at is null) then
    raise exception 'That message could not be found.';
  end if;
  if m.sender_id is not distinct from me then raise exception 'You cannot report your own message.'; end if;
  if m.deleted_at is not null then raise exception 'That message has been deleted.'; end if;
  if why is not null and length(why) > 1000 then raise exception 'Please keep the reason under 1000 characters.'; end if;

  -- save the message and the two before and after NOW, so deleting it later does not erase what the Administrators need
  with ordered as (
    select x.*, sm.first_name, sm.last_name, row_number() over (order by x.sent_at, x.id) rn
      from public.messages x left join public.members sm on sm.id = x.sender_id
     where x.conversation_id = m.conversation_id),
  target as (select rn from ordered where id = p_message)
  select jsonb_agg(jsonb_build_object(
           'sender', coalesce(o.first_name || ' ' || o.last_name, 'Former member'),
           'body', case when o.deleted_at is null then o.body else null end,
           'sent_at', o.sent_at, 'deleted', o.deleted_at is not null,
           'reported', o.id = p_message) order by o.rn)
    into snap
    from ordered o, target t where o.rn between t.rn - 2 and t.rn + 2;

  insert into public.message_reports (message_id, reported_by, reported_member_id, reason, snapshot)
  values (p_message, me, m.sender_id, why, coalesce(snap, '[]'::jsonb))
  on conflict (message_id, reported_by) do nothing;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'You have already reported that message.'; end if;
end $$;

-- ---------- Administrators: review reports ----------
create or replace function public.reported_messages_waiting()
returns int language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then (select count(*)::int from public.message_reports where status = 'waiting') else 0 end
$$;

create or replace function public.reported_messages_list(p_filter text default 'waiting')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only an Administrator or the Superuser can review reported messages.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'status', r.status, 'reason', r.reason, 'reported_at', r.reported_at,
             'reporter', coalesce(rp.first_name || ' ' || rp.last_name, 'A former member'),
             'member_id', r.reported_member_id,
             'member', coalesce(rm.first_name || ' ' || rm.last_name, 'A former member'),
             'messaging_off', coalesce(mm.suspended, false),
             'resolved_by', rs.first_name || ' ' || rs.last_name, 'resolved_at', r.resolved_at,
             'snapshot', r.snapshot) order by r.reported_at desc)
      from public.message_reports r
      left join public.members rp on rp.id = r.reported_by
      left join public.members rm on rm.id = r.reported_member_id
      left join public.members rs on rs.id = r.resolved_by
      left join public.member_messaging mm on mm.member_id = r.reported_member_id
     where p_filter = 'all'
        or (p_filter = 'resolved' and r.status <> 'waiting')
        or (coalesce(p_filter, 'waiting') = 'waiting' and r.status = 'waiting')), '[]'::jsonb);
end $$;

-- an Administrator may not turn off the messaging of another Administrator or the Superuser (only a Superuser may)
create or replace function public._msg_check_target(p_member uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only an Administrator or the Superuser can do this.'; end if;
  if exists (select 1 from public.member_roles where member_id = p_member and role_key in ('superuser', 'administrator'))
     and not public.is_superuser() then
    raise exception 'Only a Superuser can change messaging for an Administrator or Superuser.';
  end if;
end $$;
revoke all on function public._msg_check_target(uuid) from public, anon, authenticated;

create or replace function public.admin_set_messaging_suspended(p_member uuid, p_suspended boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id();
begin
  perform public._msg_check_target(p_member);
  if not exists (select 1 from public.members where id = p_member) then raise exception 'That member was not found.'; end if;
  insert into public.member_messaging (member_id, suspended, suspended_at, suspended_by)
  values (p_member, p_suspended, case when p_suspended then now() end, case when p_suspended then me end)
  on conflict (member_id) do update
    set suspended = excluded.suspended, suspended_at = excluded.suspended_at, suspended_by = excluded.suspended_by;
  insert into public.site_log (actor_member_id, action, details)
  values (me, case when p_suspended then 'member messaging turned off' else 'member messaging turned on' end,
          jsonb_build_object('member_id', p_member));
end $$;

-- p_action: 'dismiss' | 'remove' (erase the reported message) | 'messaging_off' | 'reopen'
create or replace function public.resolve_message_report(p_report uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.current_member_id();
  r  public.message_reports;
begin
  if not public.is_admin() then raise exception 'Only an Administrator or the Superuser can do this.'; end if;
  select * into r from public.message_reports where id = p_report;
  if not found then raise exception 'That report was not found.'; end if;

  if p_action = 'dismiss' then
    update public.message_reports set status = 'dismissed', resolved_by = me, resolved_at = now() where id = p_report;
  elsif p_action = 'remove' then
    update public.messages set deleted_at = coalesce(deleted_at, now()), body = '', removed_by_admin = true where id = r.message_id;
    update public.message_reports set status = 'removed', resolved_by = me, resolved_at = now() where id = p_report;
  elsif p_action = 'messaging_off' then
    if r.reported_member_id is null then raise exception 'That member no longer has a record.'; end if;
    perform public.admin_set_messaging_suspended(r.reported_member_id, true);
    update public.message_reports set status = 'messaging_off', resolved_by = me, resolved_at = now() where id = p_report;
  elsif p_action = 'reopen' then
    update public.message_reports set status = 'waiting', resolved_by = null, resolved_at = null where id = p_report;
  else
    raise exception 'Unknown action.';
  end if;
  -- the log records the decision, never the message text
  insert into public.site_log (actor_member_id, action, details)
  values (me, 'message report ' || p_action, jsonb_build_object('report_id', p_report));
end $$;

-- ---------- my own settings and blocks (My Profile) ----------
create or replace function public.my_messaging_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.current_member_id();
begin
  if me is null then raise exception 'No membership record is linked to this account.'; end if;
  return jsonb_build_object(
    'allowed',   coalesce((select allowed from public.member_messaging where member_id = me), true),
    'suspended', coalesce((select suspended from public.member_messaging where member_id = me), false),
    'blocked',   coalesce((select jsonb_agg(jsonb_build_object('id', b.blocked_id, 'name', m.first_name || ' ' || m.last_name)
                                            order by lower(m.first_name), lower(m.last_name))
                             from public.message_blocks b join public.members m on m.id = b.blocked_id
                            where b.blocker_id = me), '[]'::jsonb));
end $$;

create or replace function public.set_my_messaging_allowed(p_allowed boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id();
begin
  if me is null then raise exception 'No membership record is linked to this account.'; end if;
  insert into public.member_messaging (member_id, allowed) values (me, coalesce(p_allowed, true))
  on conflict (member_id) do update set allowed = excluded.allowed;
end $$;

create or replace function public.block_member(p_member uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id();
begin
  if me is null then raise exception 'No membership record is linked to this account.'; end if;
  if p_member is null or p_member = me then raise exception 'You cannot block yourself.'; end if;
  if not exists (select 1 from public.members where id = p_member) then raise exception 'That member was not found.'; end if;
  insert into public.message_blocks (blocker_id, blocked_id) values (me, p_member) on conflict do nothing;
end $$;

create or replace function public.unblock_member(p_member uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id();
begin
  if me is null then raise exception 'No membership record is linked to this account.'; end if;
  delete from public.message_blocks where blocker_id = me and blocked_id = p_member;
end $$;

-- ---------- tidy up: a conversation nobody belongs to any more is removed ----------
create or replace function public.messaging_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.conversations c
   where not exists (select 1 from public.conversation_members cm where cm.conversation_id = c.id);
  return null;
end $$;
drop trigger if exists members_messaging_cleanup on public.members;
create trigger members_messaging_cleanup after delete on public.members
  for each statement execute function public.messaging_cleanup();

-- ---------- who may call what ----------
revoke all on function
  public.messaging_directory(), public.start_conversation(uuid[], text, text), public.send_message(uuid, text),
  public.my_conversations(), public.conversation_thread(uuid), public.mark_conversation_read(uuid),
  public.unread_message_count(), public.delete_my_message(uuid), public.leave_conversation(uuid),
  public.report_message(uuid, text), public.reported_messages_waiting(), public.reported_messages_list(text),
  public.admin_set_messaging_suspended(uuid, boolean), public.resolve_message_report(uuid, text),
  public.my_messaging_settings(), public.set_my_messaging_allowed(boolean), public.block_member(uuid),
  public.unblock_member(uuid), public.messaging_cleanup()
  from public, anon;
grant execute on function
  public.messaging_directory(), public.start_conversation(uuid[], text, text), public.send_message(uuid, text),
  public.my_conversations(), public.conversation_thread(uuid), public.mark_conversation_read(uuid),
  public.unread_message_count(), public.delete_my_message(uuid), public.leave_conversation(uuid),
  public.report_message(uuid, text), public.reported_messages_waiting(), public.reported_messages_list(text),
  public.admin_set_messaging_suspended(uuid, boolean), public.resolve_message_report(uuid, text),
  public.my_messaging_settings(), public.set_my_messaging_allowed(boolean), public.block_member(uuid),
  public.unblock_member(uuid)
  to authenticated;
revoke all on function public.messaging_cleanup() from authenticated;

commit;
