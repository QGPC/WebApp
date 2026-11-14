-- 25-workshop-reminder.sql
-- Remember when the Workshops Chair last sent a reminder email for a workshop, and to how many people.
-- Run after 24-workshop-cancel.sql. Safe to run twice.
alter table public.program_months
  add column if not exists ws_reminder_at    timestamptz,
  add column if not exists ws_reminder_count int;
