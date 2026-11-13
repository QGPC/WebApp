-- 12-exports-and-reminders.sql
-- 1) log_member_export: writes a line to the site log when the Membership Chair or Superuser
--    downloads the member list (the website cannot write to the log directly).
-- 2) renewal_reminders: remembers which member was sent a renewal reminder for which year, and when,
--    so nobody is reminded twice in a row. Only the send-renewal-reminders Edge Function writes to it.
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

create or replace function public.log_member_export(p_what text, p_count int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_superuser() or public.has_role('membership_chair')) then
    raise exception 'Only the Membership Chair or the Superuser can export the member list.';
  end if;
  insert into public.site_log (actor_member_id, action, details)
  values (public.current_member_id(), 'member list exported',
          jsonb_build_object('what', left(coalesce(p_what, ''), 80), 'count', p_count));
end $$;

revoke all on function public.log_member_export(text, int) from public, anon;
grant execute on function public.log_member_export(text, int) to authenticated;

create table if not exists public.renewal_reminders (
  id          bigint generated always as identity primary key,
  member_id   uuid not null references public.members (id) on delete cascade,
  target_year smallint not null,
  sent_at     timestamptz not null default now(),
  sent_by     uuid references public.members (id) on delete set null
);

create index if not exists renewal_reminders_member_idx
  on public.renewal_reminders (member_id, target_year, sent_at desc);

alter table public.renewal_reminders enable row level security;
revoke all on public.renewal_reminders from anon;

-- the Membership Chair and the Superuser can read the history; nobody writes from the website
drop policy if exists renewal_reminders_select on public.renewal_reminders;
create policy renewal_reminders_select on public.renewal_reminders
  for select to authenticated
  using (public.is_superuser() or public.has_role('membership_chair'));
