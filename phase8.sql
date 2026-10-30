-- Phase 8: automatic price for large orders (up to 10,000 participants). Run after phase7.sql.
insert into discounts values(1000,0.18),(5000,0.20) on conflict (min_count) do update set pct=excluded.pct;

create or replace function create_campaign(p_title text,p_type text,p_ins text,p_req text,p_q jsonb,p_ev text,p_count int,p_rec boolean) returns uuid
language plpgsql security definer set search_path=public as $$
declare cid uuid; per numeric; lst numeric; budget numeric; pool numeric; q int; s int; d int; rest numeric;
begin
  if my_role()<>'business' then raise exception 'Only businesses can create projects'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_ins),'')='' or coalesce(trim(p_ev),'')='' or jsonb_array_length(p_q)=0 then raise exception 'Fill in all required fields'; end if;
  if p_count is null or p_count<10 then raise exception 'Choose at least 10 participants'; end if;
  if p_count>10000 then raise exception 'For more than 10000 participants, please request a custom quote'; end if;
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
