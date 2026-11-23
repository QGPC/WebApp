-- =====================================================================
-- 60-block-of-the-month-release-date.sql  (run once in the Supabase SQL editor, after 59)
-- The Block of the Month Chair now chooses the date each month becomes available to members,
-- instead of the fixed "7 days before the month begins". Months already saved keep the date
-- they had (7 days before their month). A month with no date still falls back to that rule.
-- A year shows to members once one of its months is available (same as before).
-- No tables are added; one column is added. Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): column bom_months.release_date.
-- =====================================================================

alter table public.bom_months add column if not exists release_date date;
update public.bom_months set release_date = month_start - 7 where release_date is null;

-- True when a month is available to members today (Guild time, Central).
create or replace function public.bom_month_open(p_release date, p_month date)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_release, p_month - 7) <= public.guild_today()
$$;

create or replace function public.bom_year_open(p_year int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.bom_months m
    where extract(year from m.month_start)::int = p_year
      and public.bom_month_open(m.release_date, m.month_start))
$$;

-- Members read a month only when it is available; the chair, Administrators and the Superuser read all.
-- (The Storage rule from SQL 59 already follows this table's rule, so PDFs and photos follow too.)
drop policy if exists bom_months_select on public.bom_months;
create policy bom_months_select on public.bom_months
  for select to authenticated
  using (public.can_manage_bom()
         or (public.can_see_members_area() and public.bom_month_open(release_date, month_start)));
