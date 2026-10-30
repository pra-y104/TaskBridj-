-- Phase 4: automatic pricing. Run after phase3.sql.
create table if not exists rates(task_type text primary key, price numeric not null check (price>0));
insert into rates values('Survey',300),('Website testing',700),('App testing',1000),('Usability test',1000),('Bug report',1200),('Market research',400) on conflict do nothing;
insert into settings values('recording_extra',500) on conflict do nothing;
alter table rates enable row level security;
create policy r_read on rates for select to authenticated using (true);
create policy r_admin on rates for all to authenticated using (is_admin()) with check (is_admin());
grant select, insert, update, delete on rates to authenticated;

create or replace function public_settings() returns json language sql security definer stable set search_path=public as $$
  select json_build_object('min_withdrawal',setting('min_withdrawal'),'max_tasks',setting('max_tasks_per_person'),'recording_extra',setting('recording_extra')) $$;

drop function if exists create_campaign(text,text,text,text,jsonb,text,numeric);
create function create_campaign(p_title text,p_type text,p_ins text,p_req text,p_q jsonb,p_ev text,p_count int,p_rec boolean) returns uuid
language plpgsql security definer set search_path=public as $$
declare cid uuid; per numeric; budget numeric; pool numeric; q int; s int; d int; rest numeric;
begin
  if my_role()<>'business' then raise exception 'Only businesses can create projects'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_ins),'')='' or coalesce(trim(p_ev),'')='' or jsonb_array_length(p_q)=0 then raise exception 'Fill in all required fields'; end if;
  if p_count is null or p_count<10 or p_count>100000 then raise exception 'Choose between 10 and 100000 participants'; end if;
  select price into per from rates where task_type=p_type;
  if per is null then raise exception 'This task type is not available'; end if;
  if p_rec then per := per + setting('recording_extra'); end if;
  budget := p_count*per;
  pool := floor(budget*setting('tester_share'));
  q := floor(pool*0.5/100); s := floor(pool*0.3/300); d := floor(pool*0.2/1000);
  rest := pool - q*100 - s*300 - d*1000; q := q + floor(rest/100);
  insert into campaigns(business_id,title,task_type,instructions,requirements,questions,evidence_required,slots,budget)
    values(auth.uid(),p_title,p_type,p_ins,p_req,p_q,p_ev,q+s+d,budget) returning id into cid;
  insert into tasks(campaign_id,tier,amount)
    select cid,'quick',100 from generate_series(1,q) union all
    select cid,'standard',300 from generate_series(1,s) union all
    select cid,'detailed',1000 from generate_series(1,d);
  return cid;
end $$;
revoke execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean) from public, anon;
grant execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean) to authenticated;

create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,full_name,role,referral_code,referred_by) values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''),
    case when new.raw_user_meta_data->>'role'='business' then 'business' else 'participant' end,
    substr(md5(new.id::text),1,8),
    (select id from profiles where referral_code=replace(lower(trim(new.raw_user_meta_data->>'ref')),'tb-','')));
  return new;
end $$;
