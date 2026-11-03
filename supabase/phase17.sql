-- Phase 17: fix for suspended accounts (found by the money tests). Safe to run again.
-- A suspended account (or one with no profile) now gets an EMPTY role, so every "role is not X" rule refuses it.
create or replace function my_role() returns text language sql security definer stable set search_path=public as $$
  select coalesce((select case when suspended then '' else role end from profiles where id=auth.uid()), '') $$;
