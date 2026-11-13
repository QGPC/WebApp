-- 11-renewal-email.sql
-- Remembers when the "membership renewed" email was sent, so it is not sent twice by accident.
-- Safe to run more than once.
-- Run in Supabase: SQL Editor > New query > paste this whole file > Run.

alter table public.membership_requests
  add column if not exists approval_emailed_at timestamptz;
