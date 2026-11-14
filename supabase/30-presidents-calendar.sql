-- Rename the Board calendar to the President's Calendar.
-- It holds Board meetings and important events for the Board throughout the year.
update public.calendars set name = 'President''s Calendar' where slug = 'board';
