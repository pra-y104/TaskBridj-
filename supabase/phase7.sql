-- Phase 7: more task types, lower prices, volume discounts, custom quotes. Run after phase6.sql.
insert into rates values('Survey',200),('Product feedback',250),('Market research',250),('Language & content review',300),
 ('Website testing',450),('Onboarding test',500),('App testing',600),('Usability test',600),('Prototype testing',600),('Bug report',800),('Short interview',1500)
 on conflict (task_type) do update set price=excluded.price;
update settings set value=300 where key='recording_extra';

create table if not exists discounts(min_count int primary key, pct numeric not null check (pct>=0 and pct<=0.5));
alter table discounts enable row level security;
create policy d_admin on discounts for all to authenticated using (is_admin()) with check (is_admin());
grant select, insert, update, delete on discounts to authenticated;
insert into discounts values(100,0.10),(500,0.15) on conflict do nothing;

create table if not exists quote_requests(id uuid primary key default gen_random_uuid(), business_id uuid not null references profiles(id) on delete cascade,
  task_type text, participants int, note text, created_at timestamptz default now());
alter table quote_requests enable row level security;
create policy q_read on quote_requests for select to authenticated using (is_admin() or business_id=auth.uid());
grant select on quote_requests to authenticated;
create function request_quote(p_type text,p_count int,p_note text) returns void language plpgsql security definer set search_path=public as $$
begin
  if my_role()<>'business' then raise exception 'Only businesses can request quotes'; end if;
  insert into quote_requests(business_id,task_type,participants,note) values(auth.uid(),p_type,p_count,left(coalesce(p_note,''),500));
end $$;

create function discount_pct(n int) returns numeric language sql stable security definer set search_path=public as $$
  select coalesce((select pct from discounts where min_count<=n order by min_count desc limit 1),0) $$;
revoke execute on function discount_pct(int) from public, anon, authenticated;

drop function if exists quote_campaign(text,int,boolean);
create function quote_campaign(p_type text,p_count int,p_rec boolean) returns json language sql stable security definer set search_path=public as $$
  select json_build_object('discount',discount_pct(x.c),'total',round(x.c*(r.price+case when p_rec then setting('recording_extra') else 0 end)*(1-discount_pct(x.c))))
  from rates r, (select coalesce(p_count,0) as c) x where r.task_type=p_type $$;

create or replace function create_campaign(p_title text,p_type text,p_ins text,p_req text,p_q jsonb,p_ev text,p_count int,p_rec boolean) returns uuid
language plpgsql security definer set search_path=public as $$
declare cid uuid; per numeric; lst numeric; budget numeric; pool numeric; q int; s int; d int; rest numeric;
begin
  if my_role()<>'business' then raise exception 'Only businesses can create projects'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_ins),'')='' or coalesce(trim(p_ev),'')='' or jsonb_array_length(p_q)=0 then raise exception 'Fill in all required fields'; end if;
  if p_count is null or p_count<10 then raise exception 'Choose at least 10 participants'; end if;
  if p_count>=1000 then raise exception 'For 1000 or more participants, please request a custom quote'; end if;
  select price into per from rates where task_type=p_type;
  if per is null then raise exception 'This task type is not available'; end if;
  if p_rec then per := per + setting('recording_extra'); end if;
  lst := p_count*per;
  budget := round(lst*(1-discount_pct(p_count)));
  pool := floor(lst*setting('tester_share'));
  if budget-pool < budget*0.25 then raise exception 'Please request a custom quote for this order'; end if;
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
revoke execute on function request_quote(text,int,text), quote_campaign(text,int,boolean) from public, anon;
grant execute on function request_quote(text,int,text), quote_campaign(text,int,boolean) to authenticated;
