-- Phase 12: guided project form, drafts, audience requirements. Run after phase11.sql. Adds only.
alter table campaigns add column if not exists description text, add column if not exists countries text[] not null default '{}',
  add column if not exists device text not null default 'Any', add column if not exists experience text not null default 'Any',
  add column if not exists est_minutes int, add column if not exists reference_link text, add column if not exists start_at timestamptz;

create table if not exists project_drafts(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references profiles(id) on delete cascade,
  title text, data jsonb not null default '{}', updated_at timestamptz not null default now(),
  check (octet_length(data::text) < 60000));
alter table project_drafts enable row level security;
create policy d_own on project_drafts for all to authenticated
  using (business_id=auth.uid() and my_role()='business') with check (business_id=auth.uid() and my_role()='business');
grant select, insert, update, delete on project_drafts to authenticated;

-- who may see and take a project (country, device, experience)
create function eligible(p_cid uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from campaigns c where c.id=p_cid
    and (coalesce(array_length(c.countries,1),0)=0 or exists(select 1 from profiles p where p.id=auth.uid() and (coalesce(trim(p.country),'')='' or lower(trim(p.country))=any(c.countries))))
    and (c.device='Any' or exists(select 1 from profiles p where p.id=auth.uid() and (coalesce(p.device,'')='' or p.device=c.device)))
    and (c.experience<>'Experienced' or (select count(*) from submissions s where s.participant_id=auth.uid() and s.status='approved')>=5)) $$;
revoke execute on function eligible(uuid) from public, anon, authenticated;

create or replace view tasks_open as
  select c.id as campaign_id, c.title, c.task_type, c.instructions, c.requirements, c.questions, c.evidence_required,
         t.tier, min(t.amount) as amount, count(*) as open_count, c.created_at,
         c.description, c.est_minutes, c.deadline, c.reference_link
  from campaigns c join tasks t on t.campaign_id=c.id left join submissions s on s.task_id=t.id
  where c.status='active' and (c.deadline is null or c.deadline>now()) and (c.start_at is null or c.start_at<=now()) and eligible(c.id)
    and (t.claimed_by is null or (t.claimed_at < now()-make_interval(hours=>setting('claim_hours')::int) and s.id is null))
  group by c.id, t.tier;
grant select on tasks_open to authenticated;

create or replace function claim_task(p_campaign uuid, p_tier text) returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid; cap int := setting('max_tasks_per_person'); hrs int := setting('claim_hours')::int;
begin
  if my_role()<>'participant' then raise exception 'Only participants can take tasks'; end if;
  perform 1 from profiles where id=auth.uid() for update;
  if not exists(select 1 from campaigns where id=p_campaign and status='active' and (deadline is null or deadline>now()) and (start_at is null or start_at<=now())) then raise exception 'This project is not available'; end if;
  if not eligible(p_campaign) then raise exception 'You do not meet the requirements for this project'; end if;
  if (select count(*) from tasks t where t.campaign_id=p_campaign and t.claimed_by=auth.uid()
      and (t.claimed_at>=now()-make_interval(hours=>hrs) or exists(select 1 from submissions s where s.task_id=t.id))) >= cap
    then raise exception 'You have reached the limit of % tasks for this project', cap; end if;
  select t.id into tid from tasks t where t.campaign_id=p_campaign and t.tier=p_tier
    and (t.claimed_by is null or (t.claimed_at<now()-make_interval(hours=>hrs) and not exists(select 1 from submissions s where s.task_id=t.id)))
    limit 1 for update skip locked;
  if tid is null then raise exception 'No tasks left in this group'; end if;
  update tasks set claimed_by=auth.uid(), claimed_at=now() where id=tid;
  return tid;
end $$;

drop function if exists create_campaign(text,text,text,text,jsonb,text,int,boolean,int);
create function create_campaign(p_title text,p_type text,p_ins text,p_req text,p_q jsonb,p_ev text,p_count int,p_rec boolean,p_days int,p_extra jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path=public as $$
declare cid uuid; per numeric; lst numeric; budget numeric; pool numeric; q int; s int; d int; rest numeric;
        ctry text[]; dev text; ex text; mins int; lnk text; dsc text; sdays int; e jsonb; sat timestamptz;
begin
  if my_role()<>'business' then raise exception 'Only businesses can create projects'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_ins),'')='' or coalesce(trim(p_ev),'')='' then raise exception 'Fill in all required fields'; end if;
  if jsonb_typeof(p_q)<>'array' or jsonb_array_length(p_q) not between 1 and 20 then raise exception 'Add between 1 and 20 questions'; end if;
  for e in select value from jsonb_array_elements(p_q) loop
    if jsonb_typeof(e)='string' then
      if length(e#>>'{}')>300 then raise exception 'A question is too long'; end if;
    elsif jsonb_typeof(e)='object' then
      if length(coalesce(e->>'q',''))<2 or length(e->>'q')>300 or coalesce(e->>'t','text') not in ('text','long','yesno','rating','choice') then raise exception 'Invalid question'; end if;
      if e->>'t'='choice' and jsonb_array_length(coalesce(e->'o','[]'::jsonb))<2 then raise exception 'Multiple-choice questions need at least 2 options'; end if;
    else raise exception 'Invalid question'; end if;
  end loop;
  if p_count is null or p_count<10 then raise exception 'Choose at least 10 participants'; end if;
  if p_count>10000 then raise exception 'For more than 10000 participants, please request a custom quote'; end if;
  if p_days is null or p_days<3 or p_days>90 then raise exception 'Choose a deadline between 3 and 90 days'; end if;
  ctry := coalesce((select array_agg(lower(trim(x))) from jsonb_array_elements_text(coalesce(p_extra->'countries','[]'::jsonb)) x),'{}');
  if coalesce(array_length(ctry,1),0)>10 then raise exception 'Too many countries'; end if;
  dev := coalesce(p_extra->>'device','Any'); if dev not in ('Any','Android','iPhone','Desktop') then raise exception 'Invalid device'; end if;
  ex := coalesce(p_extra->>'experience','Any'); if ex not in ('Any','Experienced') then raise exception 'Invalid experience level'; end if;
  mins := coalesce((p_extra->>'minutes')::int,10); if mins<1 or mins>240 then raise exception 'Completion time must be 1 to 240 minutes'; end if;
  lnk := nullif(trim(coalesce(p_extra->>'link','')),''); if lnk is not null and lnk !~ '^https?://[^[:space:]]+$' then raise exception 'Enter a valid link starting with http'; end if;
  dsc := left(coalesce(p_extra->>'description',''),2000);
  sdays := coalesce((p_extra->>'start_days')::int,0); if sdays<0 or sdays>30 then raise exception 'Invalid start date'; end if;
  select price into per from rates where task_type=p_type;
  if per is null then raise exception 'This task type is not available'; end if;
  if p_rec then per := per + setting('recording_extra'); end if;
  lst := p_count*per; budget := round(lst*(1-discount_pct(p_count))); pool := floor(lst*setting('tester_share'));
  if budget-pool < budget*0.25 then raise exception 'Please request a custom quote for this order'; end if;
  q := floor(pool*0.5/100); s := floor(pool*0.3/300); d := floor(pool*0.2/1000);
  rest := pool - q*100 - s*300 - d*1000; q := q + floor(rest/100);
  sat := now()+make_interval(days=>sdays);
  insert into campaigns(business_id,title,task_type,instructions,requirements,questions,evidence_required,slots,budget,participants,deadline,
                        description,countries,device,experience,est_minutes,reference_link,start_at)
    values(auth.uid(),p_title,p_type,p_ins,p_req,p_q,p_ev,q+s+d,budget,p_count,sat+make_interval(days=>p_days),dsc,ctry,dev,ex,mins,lnk,sat) returning id into cid;
  insert into tasks(campaign_id,tier,amount)
    select cid,'quick',100 from generate_series(1,q) union all
    select cid,'standard',300 from generate_series(1,s) union all
    select cid,'detailed',1000 from generate_series(1,d);
  return cid;
end $$;
revoke execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean,int,jsonb) from public, anon;
grant execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean,int,jsonb) to authenticated;
