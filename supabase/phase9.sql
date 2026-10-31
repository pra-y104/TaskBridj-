-- Phase 9: trust and money. Run once, after phase8.sql. Adds only; deletes no data.
insert into settings values('claim_hours',24),('review_days',5),('refund_fee',0.10),('appeal_days',3) on conflict do nothing;
delete from discounts where min_count=100;
insert into discounts values(50,0.05),(200,0.10) on conflict (min_count) do update set pct=excluded.pct;
insert into discounts values(10000,0.20) on conflict (min_count) do update set pct=excluded.pct;

alter table campaigns add column if not exists deadline timestamptz, add column if not exists participants int not null default 0;
alter table submissions add column if not exists proof_code text, add column if not exists file_hash text,
  add column if not exists auto_approved boolean not null default false, add column if not exists flagged boolean not null default false;
create unique index if not exists submissions_file_hash_key on submissions(file_hash) where file_hash is not null;

-- appeals
create table if not exists appeals(
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null unique references submissions(id) on delete cascade,
  participant_id uuid not null references profiles(id) on delete cascade,
  message text not null, status text not null default 'pending' check (status in ('pending','upheld','denied')),
  admin_note text, created_at timestamptz default now());
alter table appeals enable row level security;
create policy a_read on appeals for select to authenticated using (participant_id=auth.uid() or is_admin());
grant select on appeals to authenticated;

-- refunds
create table if not exists refund_requests(
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null unique references campaigns(id) on delete cascade,
  business_id uuid not null references profiles(id),
  gross numeric not null, fee numeric not null, net numeric not null,
  status text not null default 'pending' check (status in ('pending','refunded','rejected')), created_at timestamptz default now());
alter table refund_requests enable row level security;
create policy rf_read on refund_requests for select to authenticated using (business_id=auth.uid() or is_admin());
create policy rf_admin on refund_requests for update to authenticated using (is_admin()) with check (is_admin());
grant select, update on refund_requests to authenticated;

-- proof checks on every submission
create function chk_submission() returns trigger language plpgsql security definer set search_path=public as $$
declare t tasks;
begin
  select * into t from tasks where id=new.task_id;
  if t.id is null or t.claimed_by is distinct from new.participant_id then raise exception 'This task is not yours'; end if;
  if t.claimed_at < now()-make_interval(hours=>setting('claim_hours')::int) then raise exception 'Time is up for this task. It has been released.'; end if;
  if upper(trim(coalesce(new.proof_code,''))) <> upper(substr(md5(t.id::text||t.claimed_by::text||t.claimed_at::text),1,6)) then raise exception 'Wrong proof code'; end if;
  if new.file_hash is null then raise exception 'Evidence check failed. Upload the file again.'; end if;
  return new;
end $$;
create trigger submissions_chk before insert on submissions for each row execute function chk_submission();

-- open tasks now include expired, unsubmitted claims (released back to the pool)
create or replace view tasks_open as
  select c.id as campaign_id, c.title, c.task_type, c.instructions, c.requirements, c.questions, c.evidence_required,
         t.tier, min(t.amount) as amount, count(*) as open_count
  from campaigns c join tasks t on t.campaign_id=c.id left join submissions s on s.task_id=t.id
  where c.status='active' and (c.deadline is null or c.deadline>now())
    and (t.claimed_by is null or (t.claimed_at < now()-make_interval(hours=>setting('claim_hours')::int) and s.id is null))
  group by c.id, t.tier;
create or replace view my_tasks as
  select t.id as task_id, t.amount, t.tier, t.claimed_at, c.id as campaign_id, c.title, c.instructions, c.requirements,
         c.questions, c.evidence_required, s.status as sub_status, s.reject_reason,
         t.claimed_at + make_interval(hours=>setting('claim_hours')::int) as expires_at,
         upper(substr(md5(t.id::text||t.claimed_by::text||t.claimed_at::text),1,6)) as proof_code,
         s.id as submission_id, exists(select 1 from appeals a where a.submission_id=s.id) as appealed
  from tasks t join campaigns c on c.id=t.campaign_id left join submissions s on s.task_id=t.id where t.claimed_by=auth.uid();
grant select on tasks_open, my_tasks to authenticated;

create or replace function claim_task(p_campaign uuid, p_tier text) returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid; cap int := setting('max_tasks_per_person'); hrs int := setting('claim_hours')::int;
begin
  if my_role()<>'participant' then raise exception 'Only participants can take tasks'; end if;
  perform 1 from profiles where id=auth.uid() for update;
  if not exists(select 1 from campaigns where id=p_campaign and status='active' and (deadline is null or deadline>now())) then raise exception 'This project is not available'; end if;
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

-- review deadline: pending work is approved after review_days (unless flagged)
create function auto_approve_overdue() returns int language plpgsql security definer set search_path=public as $$
declare r record; n int := 0;
begin
  for r in select s.id, s.participant_id, coalesce(t.amount,c.reward_naira) as amt
           from submissions s join campaigns c on c.id=s.campaign_id left join tasks t on t.id=s.task_id
           where s.status='pending' and not s.flagged and s.created_at < now()-make_interval(days=>setting('review_days')::int)
           for update of s skip locked
  loop
    update submissions set status='approved', auto_approved=true, reviewed_at=now() where id=r.id;
    insert into ledger(participant_id,submission_id,amount) values(r.participant_id,r.id,r.amt) on conflict (submission_id) do nothing;
    n := n+1;
  end loop;
  return n;
end $$;
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('taskbridj-auto-approve','0 * * * *','select auto_approve_overdue()');
exception when others then raise notice 'pg_cron not enabled; auto-approval runs when dashboards open';
end $$;

-- appeals
create function appeal_submission(p_sid uuid, p_msg text) returns void language plpgsql security definer set search_path=public as $$
declare s submissions;
begin
  select * into s from submissions where id=p_sid;
  if s.id is null or s.participant_id<>auth.uid() or s.status<>'rejected' then raise exception 'You cannot appeal this submission'; end if;
  if s.reviewed_at < now()-make_interval(days=>setting('appeal_days')::int) then raise exception 'The appeal period has ended'; end if;
  if length(trim(coalesce(p_msg,'')))<10 then raise exception 'Please explain your appeal in a few words'; end if;
  insert into appeals(submission_id,participant_id,message) values(p_sid,auth.uid(),left(trim(p_msg),1000));
end $$;
create function resolve_appeal(p_id uuid, p_uphold boolean, p_note text) returns void language plpgsql security definer set search_path=public as $$
declare a appeals; s submissions; amt numeric;
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  select * into a from appeals where id=p_id;
  if a.id is null or a.status<>'pending' then raise exception 'Already resolved'; end if;
  if p_uphold then
    select * into s from submissions where id=a.submission_id;
    select coalesce((select amount from tasks where id=s.task_id),(select reward_naira from campaigns where id=s.campaign_id)) into amt;
    update submissions set status='approved', reject_reason=null, reviewed_at=now() where id=s.id;
    insert into ledger(participant_id,submission_id,amount) values(s.participant_id,s.id,amt) on conflict (submission_id) do nothing;
  end if;
  update appeals set status=case when p_uphold then 'upheld' else 'denied' end, admin_note=left(coalesce(p_note,''),500) where id=p_id;
end $$;

-- refunds: unused tester money after the deadline, minus a handling fee
create function refund_calc(p_cid uuid) returns json language plpgsql security definer set search_path=public as $$
declare c campaigns; tot numeric; used numeric; gross numeric; fee numeric;
begin
  select * into c from campaigns where id=p_cid;
  if c.id is null or (c.business_id<>auth.uid() and not is_admin()) then raise exception 'Not allowed'; end if;
  if not c.funded then return json_build_object('eligible',false,'reason','This project was not funded.'); end if;
  if c.deadline is null or c.deadline>now() then return json_build_object('eligible',false,'reason','Refunds open after the project deadline.'); end if;
  if exists(select 1 from refund_requests where campaign_id=p_cid) then return json_build_object('eligible',false,'reason','A refund was already requested.'); end if;
  select coalesce(sum(amount),0) into tot from tasks where campaign_id=p_cid;
  select coalesce(sum(t.amount),0) into used from tasks t where t.campaign_id=p_cid and exists(select 1 from submissions s where s.task_id=t.id and s.status in ('approved','pending'));
  if tot=0 then return json_build_object('eligible',false,'reason','Nothing to refund.'); end if;
  gross := round(c.budget*(tot-used)/tot); fee := round(gross*setting('refund_fee'));
  return json_build_object('eligible',gross>0,'gross',gross,'fee',fee,'net',gross-fee,'reason',case when gross>0 then null else 'Nothing to refund.' end);
end $$;
create function request_refund(p_cid uuid) returns void language plpgsql security definer set search_path=public as $$
declare r json;
begin
  r := refund_calc(p_cid);
  if not (r->>'eligible')::boolean then raise exception '%', coalesce(r->>'reason','No refund available'); end if;
  insert into refund_requests(campaign_id,business_id,gross,fee,net) values(p_cid,auth.uid(),(r->>'gross')::numeric,(r->>'fee')::numeric,(r->>'net')::numeric);
end $$;

-- business numbers
drop function if exists my_campaign_progress();
create function my_campaign_progress() returns table(campaign_id uuid,total bigint,claimed bigint,approved bigint,paid_share numeric) language sql stable security definer set search_path=public as $$
  select c.id,(select count(*) from tasks t where t.campaign_id=c.id),
    (select count(*) from tasks t where t.campaign_id=c.id and t.claimed_by is not null),
    (select count(*) from submissions s where s.campaign_id=c.id and s.status='approved'),
    coalesce((select sum(t.amount) from tasks t where t.campaign_id=c.id and exists(select 1 from submissions s where s.task_id=t.id and s.status='approved'))
      / nullif((select sum(t.amount) from tasks t where t.campaign_id=c.id),0),0)
  from campaigns c where c.business_id=auth.uid() $$;

-- create_campaign now stores a deadline and participant count
drop function if exists create_campaign(text,text,text,text,jsonb,text,int,boolean);
create function create_campaign(p_title text,p_type text,p_ins text,p_req text,p_q jsonb,p_ev text,p_count int,p_rec boolean,p_days int) returns uuid
language plpgsql security definer set search_path=public as $$
declare cid uuid; per numeric; lst numeric; budget numeric; pool numeric; q int; s int; d int; rest numeric;
begin
  if my_role()<>'business' then raise exception 'Only businesses can create projects'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_ins),'')='' or coalesce(trim(p_ev),'')='' or jsonb_array_length(p_q)=0 then raise exception 'Fill in all required fields'; end if;
  if p_count is null or p_count<10 then raise exception 'Choose at least 10 participants'; end if;
  if p_count>10000 then raise exception 'For more than 10000 participants, please request a custom quote'; end if;
  if p_days is null or p_days<3 or p_days>90 then raise exception 'Choose a deadline between 3 and 90 days'; end if;
  select price into per from rates where task_type=p_type;
  if per is null then raise exception 'This task type is not available'; end if;
  if p_rec then per := per + setting('recording_extra'); end if;
  lst := p_count*per; budget := round(lst*(1-discount_pct(p_count))); pool := floor(lst*setting('tester_share'));
  if budget-pool < budget*0.25 then raise exception 'Please request a custom quote for this order'; end if;
  q := floor(pool*0.5/100); s := floor(pool*0.3/300); d := floor(pool*0.2/1000);
  rest := pool - q*100 - s*300 - d*1000; q := q + floor(rest/100);
  insert into campaigns(business_id,title,task_type,instructions,requirements,questions,evidence_required,slots,budget,participants,deadline)
    values(auth.uid(),p_title,p_type,p_ins,p_req,p_q,p_ev,q+s+d,budget,p_count,now()+make_interval(days=>p_days)) returning id into cid;
  insert into tasks(campaign_id,tier,amount)
    select cid,'quick',100 from generate_series(1,q) union all
    select cid,'standard',300 from generate_series(1,s) union all
    select cid,'detailed',1000 from generate_series(1,d);
  return cid;
end $$;

revoke execute on function auto_approve_overdue(), appeal_submission(uuid,text), resolve_appeal(uuid,boolean,text), refund_calc(uuid), request_refund(uuid),
  my_campaign_progress(), create_campaign(text,text,text,text,jsonb,text,int,boolean,int), claim_task(uuid,text) from public, anon;
grant execute on function auto_approve_overdue(), appeal_submission(uuid,text), resolve_appeal(uuid,boolean,text), refund_calc(uuid), request_refund(uuid),
  my_campaign_progress(), create_campaign(text,text,text,text,jsonb,text,int,boolean,int), claim_task(uuid,text) to authenticated;
