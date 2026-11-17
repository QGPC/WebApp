-- =====================================================================
-- 48-format-and-limits.sql  (run once in the Supabase SQL editor, after 47)
-- Tidies contact details and puts a ceiling on text length, in the database,
-- so it holds no matter which page (or script) sends the data.
--
-- TIDYING (members, membership requests, workshop registrations):
--   phone   8175550103 / 817-555-0103 / 1 817 555 0103  ->  (817) 555-0103
--           (anything with letters, such as an extension, is left as typed)
--   ZIP     760861234 -> 76086-1234
--   state   tx -> TX
-- LIMITS (a friendly message is shown if a field is too long):
--   first and last name 80, email 200, phone 30, Facebook name 120,
--   street 120, city 80, state 20, ZIP 10, "other interests" 300,
--   "other ways to help" 300; workshop sign-up name 120, email 200, phone 30.
--
-- Also tidies the rows already in the tables (one time).
-- A member import that contains a too-long value stops with the message
-- naming the field (it does not say which row).
-- Safe to run twice.
--
-- WHAT THIS ADDS (for the backup list): no new tables or columns, only
-- functions and triggers.
-- =====================================================================

begin;

create or replace function public.fmt_phone(p text)
returns text language plpgsql immutable as $$
declare t text := btrim(coalesce(p, '')); d text;
begin
  if t = '' then return null; end if;
  if t ~ '[A-Za-z]' then return t; end if;
  d := regexp_replace(t, '\D', '', 'g');
  if length(d) = 11 and left(d, 1) = '1' then d := substr(d, 2); end if;
  if length(d) = 10 then
    return '(' || substr(d, 1, 3) || ') ' || substr(d, 4, 3) || '-' || substr(d, 7, 4);
  end if;
  return t;
end $$;

create or replace function public.fmt_zip(p text)
returns text language plpgsql immutable as $$
declare t text := btrim(coalesce(p, '')); d text;
begin
  if t = '' then return null; end if;
  d := regexp_replace(t, '\D', '', 'g');
  if length(d) = 5 then return d; end if;
  if length(d) = 9 then return substr(d, 1, 5) || '-' || substr(d, 6, 4); end if;
  return t;
end $$;

create or replace function public.fmt_state(p text)
returns text language plpgsql immutable as $$
declare t text := btrim(coalesce(p, ''));
begin
  if t = '' then return null; end if;
  if t ~ '^[A-Za-z]{2}$' then return upper(t); end if;
  return t;
end $$;

-- trims, turns empty into null, and refuses text longer than the limit
create or replace function public.fmt_text(p text, p_max int, p_label text)
returns text language plpgsql immutable as $$
declare t text := nullif(btrim(coalesce(p, '')), '');
begin
  if t is not null and length(t) > p_max then
    raise exception 'Please keep the % to % characters or fewer.', p_label, p_max;
  end if;
  return t;
end $$;

-- length check only (for required fields: leaves empty and null exactly as they are)
create or replace function public.chk_len(p text, p_max int, p_label text)
returns void language plpgsql immutable as $$
begin
  if p is not null and length(btrim(p)) > p_max then
    raise exception 'Please keep the % to % characters or fewer.', p_label, p_max;
  end if;
end $$;

-- ---------- members ----------
create or replace function public.format_member()
returns trigger language plpgsql as $$
begin
  perform public.chk_len(new.first_name, 80, 'first name');
  perform public.chk_len(new.last_name, 80, 'last name');
  perform public.chk_len(new.email, 200, 'email address');
  new.first_name      := btrim(new.first_name);
  new.last_name       := btrim(new.last_name);
  new.cell_phone      := public.fmt_phone(new.cell_phone);
  perform public.chk_len(new.cell_phone, 30, 'phone number');
  new.facebook_name   := public.fmt_text(new.facebook_name, 120, 'Facebook name');
  new.street_address  := public.fmt_text(new.street_address, 120, 'street address');
  new.city            := public.fmt_text(new.city, 80, 'city');
  new.state           := public.fmt_state(new.state);
  perform public.chk_len(new.state, 20, 'state');
  new.zip             := public.fmt_zip(new.zip);
  perform public.chk_len(new.zip, 10, 'ZIP code');
  new.interests_other := public.fmt_text(new.interests_other, 300, '"other interests" box');
  return new;
end $$;

drop trigger if exists members_c_format on public.members;
create trigger members_c_format
  before insert or update on public.members
  for each row execute function public.format_member();

-- ---------- membership requests (join and renew forms) ----------
create or replace function public.format_membership_request()
returns trigger language plpgsql as $$
begin
  perform public.chk_len(new.first_name, 80, 'first name');
  perform public.chk_len(new.last_name, 80, 'last name');
  perform public.chk_len(new.email, 200, 'email address');
  new.first_name      := btrim(new.first_name);
  new.last_name       := btrim(new.last_name);
  new.cell_phone      := public.fmt_phone(new.cell_phone);
  perform public.chk_len(new.cell_phone, 30, 'phone number');
  new.facebook_name   := public.fmt_text(new.facebook_name, 120, 'Facebook name');
  new.street_address  := public.fmt_text(new.street_address, 120, 'street address');
  new.city            := public.fmt_text(new.city, 80, 'city');
  new.state           := public.fmt_state(new.state);
  perform public.chk_len(new.state, 20, 'state');
  new.zip             := public.fmt_zip(new.zip);
  perform public.chk_len(new.zip, 10, 'ZIP code');
  new.interests_other := public.fmt_text(new.interests_other, 300, '"other interests" box');
  new.help_other      := public.fmt_text(new.help_other, 300, '"other ways to help" box');
  return new;
end $$;

drop trigger if exists membership_requests_format on public.membership_requests;
create trigger membership_requests_format
  before insert or update on public.membership_requests
  for each row execute function public.format_membership_request();

-- ---------- workshop sign-ups ----------
create or replace function public.format_workshop_registration()
returns trigger language plpgsql as $$
begin
  perform public.chk_len(new.name, 120, 'name');
  perform public.chk_len(new.email, 200, 'email address');
  new.name  := btrim(new.name);
  new.email := btrim(new.email);
  new.phone := public.fmt_phone(new.phone);
  perform public.chk_len(new.phone, 30, 'phone number');
  return new;
end $$;

drop trigger if exists wreg_format on public.workshop_registrations;
create trigger wreg_format
  before insert or update on public.workshop_registrations
  for each row execute function public.format_workshop_registration();

-- ---------- tidy what is already there (one time) ----------
-- Setting a column to itself runs the tidy-up above on every existing row.
update public.members               set cell_phone = cell_phone;
update public.membership_requests   set cell_phone = cell_phone;
update public.workshop_registrations set phone = phone;

commit;
