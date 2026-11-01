-- Read-only security check. Run each block and send me the results. Nothing is changed.
-- A) Tables with row security OFF (this list should be EMPTY)
select relname as table_without_row_security from pg_class
where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity;

-- B) What visitors who are not logged in can touch (this list should be EMPTY)
select table_name, privilege_type from information_schema.role_table_grants
where grantee='anon' and table_schema='public';

-- C) Policy count per table (every table should have at least one)
select tablename, count(*) as policies from pg_policies where schemaname='public' group by tablename order by tablename;

-- D) Evidence bucket limits
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id='evidence';
