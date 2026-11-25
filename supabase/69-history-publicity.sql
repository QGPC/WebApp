-- =====================================================================
-- 69-history-publicity.sql  (run once, after 68)
-- The Publicity Chair may now change Guild History (the introduction and
-- the timeline), along with Administrators and the Superuser. Everyone can
-- still read it.
-- If 33-about-history.sql is ever run again, run this file again
-- afterwards, or it is undone.
-- Safe to run more than once. Adds no tables or columns.
-- =====================================================================

do $$
declare
  t text;
  w text := 'public.is_admin() or public.has_role(''publicity_chair'')';
begin
  foreach t in array array['guild_history_settings', 'guild_history_entries'] loop
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (%s)', t || '_insert', t, w);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)', t || '_update', t, w, w);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using (%s)', t || '_delete', t, w);
  end loop;
end $$;
