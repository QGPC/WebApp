-- =====================================================================
-- 21-program-costs.sql  (run once, after 20-program-photos.sql)
-- Program and workshop costs, plus Workshop Settings.
--   program_month_costs  the two speaker fees for a month
--   program_costs        miscellaneous costs (Travel, Lodging, Meals...), shared
--                        between program and workshop by a percent, or workshop-only
--   workshop_settings    Maximum Workshop Subsidy percent (one row)
--   nonmember_fees       the non-member workshop fee, one per calendar year
-- Costs are for planners only (never shown to members or visitors).
-- Workshop Settings are changed by Administrators and the Superuser only.
-- Safe to run twice.
-- =====================================================================

-- Month key is the first of the month (same as program_months.month_on).
create table if not exists public.program_month_costs (
  month_on    date primary key check (extract(day from month_on) = 1),
  prog_fee    numeric(9,2) not null default 0 check (prog_fee >= 0),   -- the program speaker's fee
  ws_fee      numeric(9,2) not null default 0 check (ws_fee >= 0),     -- the workshop speaker's fee
  updated_at  timestamptz not null default now()
);

-- One row per miscellaneous cost.
--   pct_program = share of the cost that belongs to the program (0 to 100).
--   The workshop share is always 100 minus pct_program, never stored.
--   A cost only the workshop has is a row with workshop_only = true and pct_program = 0.
create table if not exists public.program_costs (
  id           uuid primary key default gen_random_uuid(),
  month_on     date not null check (extract(day from month_on) = 1),
  category     text not null check (length(btrim(category)) > 0),
  amount       numeric(9,2) not null default 0 check (amount >= 0),
  pct_program  numeric(5,2) not null default 100 check (pct_program between 0 and 100),
  workshop_only boolean not null default false,
  sort_order   int not null default 0,
  check (not workshop_only or pct_program = 0)
);
create index if not exists program_costs_by_month on public.program_costs (month_on, sort_order);

-- Settings (one row).
create table if not exists public.workshop_settings (
  id               int primary key default 1 check (id = 1),
  max_subsidy_pct  numeric(5,2) not null default 0 check (max_subsidy_pct between 0 and 100),
  avg_attendance   int check (avg_attendance is null or avg_attendance > 0),   -- used by the Fee Analysis
  updated_at       timestamptz not null default now()
);
insert into public.workshop_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.nonmember_fees (
  year  int primary key check (year between 2000 and 2100),
  fee   numeric(8,2) not null check (fee >= 0),
  updated_at timestamptz not null default now()
);

-- Who may read the settings: planners and Administrators. Who may change them: Administrators and Superuser.
alter table public.program_month_costs enable row level security;
alter table public.program_costs       enable row level security;
alter table public.workshop_settings   enable row level security;
alter table public.nonmember_fees      enable row level security;

grant select on public.program_month_costs, public.program_costs, public.workshop_settings, public.nonmember_fees to authenticated;
grant update on public.workshop_settings to authenticated;
grant insert, update, delete on public.nonmember_fees to authenticated;

drop policy if exists pmc_select on public.program_month_costs;
create policy pmc_select on public.program_month_costs for select to authenticated using (public.can_edit_programs());
drop policy if exists pc_select on public.program_costs;
create policy pc_select on public.program_costs for select to authenticated using (public.can_edit_programs());

drop policy if exists wset_select on public.workshop_settings;
create policy wset_select on public.workshop_settings for select to authenticated
  using (public.can_edit_programs() or public.is_admin());
drop policy if exists wset_update on public.workshop_settings;
create policy wset_update on public.workshop_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists nmf_select on public.nonmember_fees;
create policy nmf_select on public.nonmember_fees for select to authenticated
  using (public.can_edit_programs() or public.is_admin());
drop policy if exists nmf_write on public.nonmember_fees;
create policy nmf_write on public.nonmember_fees for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- The average attendance is typed on the Fee Analysis by a planner, so planners may change that one column.
create or replace function public.set_avg_attendance(p_n int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_edit_programs() then raise exception 'not allowed'; end if;
  if p_n is not null and p_n <= 0 then raise exception 'attendance must be above zero'; end if;
  update public.workshop_settings set avg_attendance = p_n, updated_at = now() where id = 1;
end $$;
grant execute on function public.set_avg_attendance(int) to authenticated;

-- Save the program side: the speaker fee and the shared miscellaneous costs (workshop-only rows are left alone).
-- p_items: [{category, amount, pct}, ...]
create or replace function public.save_program_costs(p_month date, p_fee numeric, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare it jsonb; i int := 0;
begin
  if not public.can_edit_programs() then raise exception 'not allowed'; end if;
  if extract(day from p_month) <> 1 then raise exception 'bad month'; end if;
  insert into public.program_month_costs (month_on, prog_fee) values (p_month, greatest(coalesce(p_fee, 0), 0))
    on conflict (month_on) do update set prog_fee = excluded.prog_fee, updated_at = now();
  delete from public.program_costs where month_on = p_month and not workshop_only;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    i := i + 1;
    insert into public.program_costs (month_on, category, amount, pct_program, sort_order)
    values (p_month, btrim(it->>'category'), greatest(coalesce((it->>'amount')::numeric, 0), 0),
            least(greatest(coalesce((it->>'pct')::numeric, 0), 0), 100), i);
  end loop;
end $$;
grant execute on function public.save_program_costs(date, numeric, jsonb) to authenticated;

-- Save the workshop side: the workshop speaker's fee and the workshop-only costs (shared rows are left alone).
-- p_items: [{category, amount}, ...]
create or replace function public.save_workshop_costs(p_month date, p_fee numeric, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare it jsonb; i int := 1000;
begin
  if not public.can_edit_programs() then raise exception 'not allowed'; end if;
  if extract(day from p_month) <> 1 then raise exception 'bad month'; end if;
  insert into public.program_month_costs (month_on, ws_fee) values (p_month, greatest(coalesce(p_fee, 0), 0))
    on conflict (month_on) do update set ws_fee = excluded.ws_fee, updated_at = now();
  delete from public.program_costs where month_on = p_month and workshop_only;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    i := i + 1;
    insert into public.program_costs (month_on, category, amount, pct_program, workshop_only, sort_order)
    values (p_month, btrim(it->>'category'), greatest(coalesce((it->>'amount')::numeric, 0), 0), 0, true, i);
  end loop;
end $$;
grant execute on function public.save_workshop_costs(date, numeric, jsonb) to authenticated;

-- Totals, so every page (and later the registrations page) works them out the same way.
--   program  = program fee + sum(amount x pct_program / 100)
--   workshop = workshop fee + sum(amount x (100 - pct_program) / 100)
create or replace function public.program_total_cost(p_month date)
returns numeric language sql stable security definer set search_path = public as $$
  select case when public.can_edit_programs() then
    coalesce((select prog_fee from public.program_month_costs where month_on = p_month), 0)
    + coalesce((select sum(amount * pct_program / 100) from public.program_costs where month_on = p_month), 0)
  end
$$;
create or replace function public.workshop_total_cost(p_month date)
returns numeric language sql stable security definer set search_path = public as $$
  select case when public.can_edit_programs() then
    coalesce((select ws_fee from public.program_month_costs where month_on = p_month), 0)
    + coalesce((select sum(amount * (100 - pct_program) / 100) from public.program_costs where month_on = p_month), 0)
  end
$$;
grant execute on function public.program_total_cost(date), public.workshop_total_cost(date) to authenticated;

-- Deleting a month removes its costs.
create or replace function public.program_months_costs_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.program_costs where month_on = old.month_on;
  delete from public.program_month_costs where month_on = old.month_on;
  return old;
end $$;
drop trigger if exists program_months_costs_cleanup on public.program_months;
create trigger program_months_costs_cleanup after delete on public.program_months
  for each row execute function public.program_months_costs_cleanup();
