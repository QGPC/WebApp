-- =====================================================================
-- 54-workshop-chair-add.sql  (run once; safe to run twice)
-- Lets the Workshop Manager (Workshops Chair, Program Chair, Administrators, Superuser)
-- ADD a registration to a workshop for someone who signed up some other way
-- (at a meeting, by phone, by mail).
--
-- Unlike the public sign-up (workshop_signup) this deliberately:
--   * works even when the workshop's "Non-member sign-up allowed" switch is OFF,
--   * works after the workshop's "Last date to register" has passed,
--   * does not use the spam limits (only the Workshop Manager can call it).
-- It still keeps the one-registration-per-email rule, and it still counts spots the same way:
--   not paid                       -> waitlist, not paid
--   paid and a spot is open        -> waiting (holds a spot, ready to accept)
--   paid and the workshop is full  -> waitlist, paid
-- Fees are worked out the same way as the public sign-up (workshop fee + non-member fee
-- for a non-member + kit fee when the Guild collects it).
-- Adds no tables or columns. Two new functions.
-- =====================================================================

-- Names of current (active or grace) members, for the "Choose a member" list.
-- Names only: the chair does not need other members' contact details to pick one.
create or replace function public.workshop_member_choices()
returns table (id uuid, name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;
  return query
    select m.id, btrim(m.last_name || ', ' || m.first_name)
      from public.members m
     where public.membership_status(m.paid_through_year) in ('active', 'grace')
     order by lower(m.last_name), lower(m.first_name);
end $$;
grant execute on function public.workshop_member_choices() to authenticated;

create or replace function public.workshop_chair_add(
  p_month_id uuid,
  p_member_id uuid,            -- a current member, or null for a non-member
  p_name text, p_email text, p_phone text,   -- used for a non-member only
  p_paid boolean,
  p_method text default null,  -- cash, check or online (when paid)
  p_ref text default null)     -- check number (optional)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.program_months%rowtype;
  mem public.members%rowtype;
  v_is_member boolean := (p_member_id is not null);
  v_name text; v_email text; v_phone text;
  v_fee numeric; v_nm numeric := 0; v_kit numeric := 0; v_total numeric;
  v_method text := lower(btrim(coalesce(p_method, '')));
  v_status text := 'waitlist'; v_paid boolean := coalesce(p_paid, false); v_id uuid; v_year int;
begin
  if not public.can_manage_workshops() then raise exception 'not allowed'; end if;

  -- Lock the month so two chairs adding at once cannot both take the last spot.
  select * into m from public.program_months where id = p_month_id and has_workshop for update;
  if not found then raise exception 'There is no workshop for that month.'; end if;

  if v_is_member then
    select * into mem from public.members where id = p_member_id;
    if not found then raise exception 'Please choose a member.'; end if;
    if public.membership_status(mem.paid_through_year) not in ('active', 'grace') then
      raise exception 'That person is not a current member. Add them as a non-member instead.';
    end if;
    v_name := btrim(coalesce(mem.first_name, '') || ' ' || coalesce(mem.last_name, ''));
    v_email := mem.email; v_phone := null;
  else
    v_name := btrim(coalesce(p_name, '')); v_email := btrim(coalesce(p_email, ''));
    v_phone := nullif(btrim(coalesce(p_phone, '')), '');
    if v_name = '' then raise exception 'Please type the person''s name.'; end if;
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please type a valid email address.'; end if;
    v_year := extract(year from coalesce(m.ws_date, m.month_on));
    select fee into v_nm from public.nonmember_fees where year = v_year;
    v_nm := coalesce(v_nm, 0);
  end if;

  v_fee := coalesce(m.ws_fee, 0);
  if m.ws_kit_guild then v_kit := coalesce(m.ws_kit_fee, 0); end if;
  v_total := v_fee + v_nm + v_kit;

  if v_paid then
    if v_method not in ('cash', 'check', 'online') then raise exception 'Please choose how it was paid.'; end if;
    if m.ws_spots is null or public.workshop_held(p_month_id) < m.ws_spots then v_status := 'waiting'; end if;
  end if;

  begin
    insert into public.workshop_registrations
      (month_id, member_id, is_member, name, email, phone, fee, nonmember_fee, kit_fee, total_due,
       paid, paid_at, status, pay_method, pay_ref)
    values (p_month_id, case when v_is_member then p_member_id end, v_is_member, v_name, v_email, v_phone,
            v_fee, v_nm, v_kit, v_total,
            v_paid, case when v_paid then now() end, v_status,
            case when v_paid then v_method end,
            case when v_paid and v_method = 'check' then nullif(btrim(coalesce(p_ref, '')), '') end)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'That email address is already registered for this workshop.';
  end;

  return jsonb_build_object('id', v_id, 'name', v_name, 'status', v_status, 'paid', v_paid,
                            'total_due', v_total, 'is_member', v_is_member);
end $$;
grant execute on function public.workshop_chair_add(uuid, uuid, text, text, text, boolean, text, text) to authenticated;
