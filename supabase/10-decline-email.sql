-- 10-decline-email.sql
-- Remembers when the "declined" email was sent, so it is sent only once per request.
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

alter table public.membership_requests
  add column if not exists decline_emailed_at timestamptz;
