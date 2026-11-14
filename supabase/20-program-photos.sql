-- =====================================================================
-- 20-program-photos.sql  (run once, after 19-programs.sql)
-- Several photos per program and per workshop. Each is {path, alt};
-- the first is the main photo. Moves the single photos already saved.
-- Safe to run twice.
-- =====================================================================
alter table public.program_months
  add column if not exists prog_photos jsonb not null default '[]'::jsonb,
  add column if not exists ws_photos   jsonb not null default '[]'::jsonb;

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'program_months' and column_name = 'prog_photo') then
    update public.program_months
       set prog_photos = jsonb_build_array(jsonb_build_object('path', prog_photo, 'alt', coalesce(prog_photo_alt, '')))
     where prog_photo is not null and prog_photos = '[]'::jsonb;
    update public.program_months
       set ws_photos = jsonb_build_array(jsonb_build_object('path', ws_photo, 'alt', coalesce(ws_photo_alt, '')))
     where ws_photo is not null and ws_photos = '[]'::jsonb;
    alter table public.program_months
      drop column prog_photo, drop column prog_photo_alt,
      drop column ws_photo,   drop column ws_photo_alt;
  end if;
end $$;
