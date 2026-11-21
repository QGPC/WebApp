-- 56-messages-unlisted.sql  (run once in the Supabase SQL editor, after 55)
-- A member who has chosen "Not listed in the Member Directory" can still receive private messages if they
-- have "Allow messages" on (decided with Rex 2026-11-21, option 1: the member's name, and only the name,
-- appears in the "Start a message" list; photo, email and phone stay hidden).
-- Only the two functions below change: the test "not m.directory_opt_out" is removed from each.
-- Everything else (Active/grace members only, the Allow messages choice, blocks) still applies.
-- No tables or columns change. Safe to run more than once.

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
       and public.membership_status(m.paid_through_year) in ('active', 'grace')
       and coalesce(mm.allowed, true)
       and not public._msg_blocked(me, m.id)
     order by lower(m.last_name), lower(m.first_name);
end $$;

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

  -- the same message as "cannot receive" for every reason (turned off, blocked, not a current member)
  select count(*) into bad from unnest(rec) r(rid)
   where not exists (
     select 1 from public.members m
       left join public.member_messaging mm on mm.member_id = m.id
      where m.id = r.rid
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
