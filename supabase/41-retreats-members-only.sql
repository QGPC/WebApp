-- 41: Retreats are for members only (was public)
drop policy if exists retreats_select on public.retreats;
create policy retreats_select on public.retreats for select to authenticated
  using (public.can_see_members_area() or public.can_manage_retreats());
