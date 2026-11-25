-- =====================================================================
-- 68-news-programs-no-president.sql  (run once, after 67)
-- The President and Vice President no longer change In the News or
-- Programs & Workshops (including program drafts and costs, which only
-- the editors can see). Notices, calendars, charities, Email Members and
-- the Board To-Do List are not affected.
-- If 19-programs.sql or 39-news-retreats.sql is ever run again, run this
-- file again afterwards, or it is undone.
-- Safe to run more than once. Adds no tables or columns.
-- =====================================================================

-- Who may plan programs: Program Chair, Administrators, Superuser.
create or replace function public.can_edit_programs()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('program_chair')
$$;

-- Who may edit In the News: Publicity Chair, Administrators, Superuser.
create or replace function public.can_edit_news()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.has_role('publicity_chair')
$$;
