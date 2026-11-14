-- 40: a link to the retreat center's website on each retreat
alter table public.retreats add column if not exists website_url text;
alter table public.retreats drop constraint if exists retreats_website_url_check;
alter table public.retreats add constraint retreats_website_url_check
  check (website_url is null or website_url ~ '^https?://[^[:space:]]+$');

-- WHAT THIS ADDS (backup list): column retreats.website_url
