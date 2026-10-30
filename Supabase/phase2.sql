-- Phase 2 (safe to run once; adds columns only, deletes nothing)
alter table profiles
  add column if not exists onboarded boolean not null default false,
  add column if not exists country text, add column if not exists language text,
  add column if not exists device text, add column if not exists interests text,
  add column if not exists org_name text, add column if not exists industry text,
  add column if not exists org_description text, add column if not exists website text,
  add column if not exists contact_email text;
