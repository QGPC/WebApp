-- =====================================================================
-- 17-email-members.sql  (run once in the Supabase SQL editor)
-- Email Members: one email from the President, Vice President, Program
-- Chair, an Administrator or the Superuser to every current member.
-- The Edge Function "send-member-email" does the sending and writes
-- these tables; the website only reads the history.
-- Safe to run twice.
-- =====================================================================

create or replace function public.can_email_members()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('president') or public.has_role('vice_president')
         or public.has_role('program_chair')
$$;

create table if not exists public.member_emails (
  id           uuid primary key default gen_random_uuid(),
  sent_by      uuid references public.members (id) on delete set null,
  sender_name  text,
  sender_role  text,
  subject      text not null,
  body         text not null,
  reply_to     text not null default 'guild' check (reply_to in ('guild','sender')),
  is_test      boolean not null default false,
  recipients   int not null default 0,     -- how many this send was planned for
  sent         int not null default 0,
  failed       int not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists member_emails_created on public.member_emails (created_at desc);

create table if not exists public.member_email_recipients (
  email_id   uuid not null references public.member_emails (id) on delete cascade,
  member_id  uuid not null references public.members (id) on delete cascade,
  status     text not null check (status in ('sent','failed')),
  error      text,
  sent_at    timestamptz not null default now(),
  primary key (email_id, member_id)
);

alter table public.member_emails enable row level security;
alter table public.member_email_recipients enable row level security;
revoke all on public.member_emails, public.member_email_recipients from anon;
revoke insert, update, delete on public.member_emails, public.member_email_recipients from authenticated;
grant select on public.member_emails to authenticated;

drop policy if exists member_emails_select on public.member_emails;
create policy member_emails_select on public.member_emails
  for select to authenticated using (public.can_email_members());

-- How many emails the site has sent today (Guild time), toward Gmail's daily limit.
-- Counts member emails (and test copies) plus renewal reminders. Other one-off emails
-- (invites, approvals, declines) are few and are not counted.
create or replace function public.emails_sent_today()
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select sum(sent + failed) from public.member_emails
                    where (created_at at time zone 'America/Chicago')::date = public.guild_today()), 0)::int
       + coalesce((select count(*) from public.renewal_reminders
                    where (sent_at at time zone 'America/Chicago')::date = public.guild_today()), 0)::int
$$;
revoke all on function public.emails_sent_today() from public, anon;
grant execute on function public.emails_sent_today() to authenticated;
