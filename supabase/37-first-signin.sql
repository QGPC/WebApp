-- 37-first-signin.sql
-- Supports "first sign-in link" emails for members who were added by the CSV import (or any member
-- without a website account yet). The Edge Function request-signin-link keeps its rate-limit record here.
-- Nobody can read or write this table from the website; only the function (service role) uses it.
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

begin;

create table if not exists public.signin_link_requests (
  id    bigint generated always as identity primary key,
  email text not null,
  at    timestamptz not null default now()
);
create index if not exists signin_link_requests_email_at on public.signin_link_requests (email, at desc);
create index if not exists signin_link_requests_at on public.signin_link_requests (at desc);

alter table public.signin_link_requests enable row level security;
revoke all on public.signin_link_requests from anon, authenticated;

commit;
