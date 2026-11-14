-- 42: Comfort Quilts kits: the chair marks a claimed kit as "handed out".
-- Claim = a kit is set aside for the member (it already counts against "kits left").
-- Handed out = the kit has left the shelf: "Kits available" (kits on hand) goes down by 1 and the claim stops counting as a reservation.
-- "Kits left" for members = kits_available minus claims that are not yet handed out.

alter table public.comfort_kit_claims
  add column if not exists handed_out_at timestamptz,
  add column if not exists handed_out_by uuid references public.members (id) on delete set null;

-- A member can give a kit back only until it has been handed out.
drop policy if exists comfort_kit_claims_delete on public.comfort_kit_claims;
create policy comfort_kit_claims_delete on public.comfort_kit_claims
  for delete to authenticated
  using ((member_id = public.current_member_id() and handed_out_at is null) or public.can_manage_comfort());

drop function if exists public.comfort_patterns_list();
create function public.comfort_patterns_list()
returns table (id uuid, name text, size_name text, level text, pdf_path text, photo_path text,
               kits_left int, mine boolean, is_new boolean, received boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.size_name, p.level, p.pdf_path, p.photo_path,
         greatest(0, p.kits_available - (select count(*) from public.comfort_kit_claims c
                                          where c.pattern_id = p.id and c.handed_out_at is null))::int,
         exists (select 1 from public.comfort_kit_claims c where c.pattern_id = p.id and c.member_id = public.current_member_id()),
         p.created_at > now() - interval '30 days',
         exists (select 1 from public.comfort_kit_claims c where c.pattern_id = p.id and c.member_id = public.current_member_id()
                   and c.handed_out_at is not null)
  from public.comfort_patterns p
  where public.can_see_members_area() or public.can_manage_comfort()
  order by p.name
$$;

create or replace function public.comfort_kit_claim(p_pattern uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_member_id(); pat public.comfort_patterns; taken int;
begin
  if me is null or not (public.can_see_members_area() or public.can_manage_comfort()) then
    raise exception 'Please sign in as a member to claim a kit.';
  end if;
  select * into pat from public.comfort_patterns where id = p_pattern for update;
  if not found then raise exception 'That pattern is no longer in the library.'; end if;
  if exists (select 1 from public.comfort_kit_claims where pattern_id = p_pattern and member_id = me) then return; end if;
  select count(*) into taken from public.comfort_kit_claims where pattern_id = p_pattern and handed_out_at is null;
  if pat.kits_available - taken <= 0 then raise exception 'All of the kits for this pattern have been claimed.'; end if;
  insert into public.comfort_kit_claims (pattern_id, member_id) values (p_pattern, me);
end $$;

create or replace function public.comfort_kit_release(p_pattern uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.comfort_kit_claims
   where pattern_id = p_pattern and member_id = public.current_member_id() and handed_out_at is null;
end $$;

drop function if exists public.comfort_kit_claims_list();
create function public.comfort_kit_claims_list()
returns table (id uuid, pattern_id uuid, pattern_name text, size_name text, level text,
               member_name text, claimed_at timestamptz, seen_by_chair boolean, handed_out_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.pattern_id, p.name, p.size_name, p.level,
         btrim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')), c.claimed_at, c.seen_by_chair, c.handed_out_at
  from public.comfort_kit_claims c
  join public.comfort_patterns p on p.id = c.pattern_id
  join public.members m on m.id = c.member_id
  where public.can_manage_comfort()
  order by c.claimed_at desc
$$;

-- The chair hands a claimed kit to the member: kits on hand go down by 1.
create or replace function public.comfort_kit_hand_out(p_claim uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c public.comfort_kit_claims; pat public.comfort_patterns;
begin
  if not public.can_manage_comfort() then raise exception 'Not allowed.'; end if;
  select * into c from public.comfort_kit_claims where id = p_claim for update;
  if not found then raise exception 'That claim is no longer there.'; end if;
  if c.handed_out_at is not null then return; end if;
  select * into pat from public.comfort_patterns where id = c.pattern_id for update;
  if pat.kits_available < 1 then
    raise exception 'There are no kits on hand for this pattern. Raise "Kits available" first.';
  end if;
  update public.comfort_patterns set kits_available = kits_available - 1 where id = pat.id;
  update public.comfort_kit_claims
     set handed_out_at = now(), handed_out_by = public.current_member_id(), seen_by_chair = true
   where id = p_claim;
end $$;

-- Undo a mistake: the kit goes back on the shelf and the claim is open again.
create or replace function public.comfort_kit_undo_hand_out(p_claim uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c public.comfort_kit_claims;
begin
  if not public.can_manage_comfort() then raise exception 'Not allowed.'; end if;
  select * into c from public.comfort_kit_claims where id = p_claim for update;
  if not found or c.handed_out_at is null then return; end if;
  update public.comfort_patterns set kits_available = kits_available + 1 where id = c.pattern_id;
  update public.comfort_kit_claims set handed_out_at = null, handed_out_by = null where id = p_claim;
end $$;

grant execute on function public.comfort_patterns_list(), public.comfort_kit_claim(uuid), public.comfort_kit_release(uuid),
  public.comfort_kit_claims_list(), public.comfort_kit_hand_out(uuid), public.comfort_kit_undo_hand_out(uuid) to authenticated;

-- WHAT THIS ADDS (backup list): columns comfort_kit_claims.handed_out_at, handed_out_by
