-- Phase 5: hide the rate card from businesses. Run after phase4.sql.
drop policy if exists r_read on rates;
create policy r_read on rates for select to authenticated using (is_admin());

create function task_types() returns setof text language sql security definer stable set search_path=public as $$ select task_type from rates order by 1 $$;
create function quote_campaign(p_type text,p_count int,p_rec boolean) returns numeric language sql security definer stable set search_path=public as $$
  select coalesce(p_count,0) * ((select price from rates where task_type=p_type) + case when p_rec then setting('recording_extra') else 0 end) $$;
revoke execute on function task_types(), quote_campaign(text,int,boolean) from public, anon;
grant execute on function task_types(), quote_campaign(text,int,boolean) to authenticated;

create or replace function public_settings() returns json language sql security definer stable set search_path=public as $$
  select json_build_object('min_withdrawal',setting('min_withdrawal'),'max_tasks',setting('max_tasks_per_person')) $$;
