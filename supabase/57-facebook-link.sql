-- 57-facebook-link.sql  (run once in the Supabase SQL editor, after 56)
-- Lets an Administrator (and the Superuser) change the Guild's Facebook page address on the new
-- Facebook Link page (facebook-link.html, reached from Site Administration).
-- Only the Facebook address can be changed this way. The table's own rules are NOT loosened:
-- the mailing address, email and phone can still be changed only by the Superuser (Site Appearance).
-- An empty address means "use the Guild's standard link". An address must start with https:// and
-- have no spaces. No tables or columns change. Safe to run more than once.

create or replace function public.set_facebook_url(p_url text)
returns void language plpgsql security definer set search_path = public as $$
declare u text := btrim(coalesce(p_url, ''));
begin
  if not public.is_admin() then
    raise exception 'Only an Administrator or the Superuser can change the Facebook link.';
  end if;
  if length(u) > 300 then raise exception 'That address is too long.'; end if;
  if u <> '' and u !~* '^https://[^[:space:]]+$' then
    raise exception 'The Facebook address must start with https:// and have no spaces.';
  end if;
  insert into public.guild_contact (id, facebook_url) values (true, u)
  on conflict (id) do update set facebook_url = excluded.facebook_url;
end $$;

revoke all on function public.set_facebook_url(text) from public, anon;
grant execute on function public.set_facebook_url(text) to authenticated;
