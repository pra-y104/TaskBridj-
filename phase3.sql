-- Phase 3: budget split into micro-tasks, wallet, withdrawals, referral. Run once after phase2.sql.
create table if not exists settings(key text primary key, value numeric not null);
insert into settings values('tester_share',0.60),('min_withdrawal',500),('max_tasks_per_person',5),('min_budget',1000) on conflict do nothing;
alter table settings enable row level security;
create policy st_admin on settings for all using (is_admin()) with check (is_admin());
create function setting(k text) returns numeric language sql security definer stable set search_path=public as $$ select value from settings where key=k $$;
revoke execute on function setting(text) from public, anon, authenticated;

alter table campaigns drop constraint if exists campaigns_reward_naira_check;
alter table campaigns drop constraint if exists campaigns_slots_check;
alter table campaigns alter column reward_naira set default 0;
alter table campaigns add column if not exists budget numeric not null default 0, add column if not exists funded boolean not null default false;
drop policy if exists c_ins on campaigns;
revoke insert on campaigns from authenticated;
create function chk_funded() returns trigger language plpgsql as $$ begin
  if new.status='active' and not new.funded then raise exception 'Project is not funded yet'; end if; return new; end $$;
create trigger campaigns_funded before insert or update on campaigns for each row execute function chk_funded();

create table tasks(
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references campaigns(id) on delete cascade,
  tier text not null, amount numeric not null check (amount>0),
  claimed_by uuid references profiles(id), claimed_at timestamptz, created_at timestamptz default now());
create index on tasks(campaign_id, tier) where claimed_by is null;
alter table tasks enable row level security;
create policy t_own on tasks for select using (claimed_by=auth.uid() or is_admin());
grant select on tasks to authenticated;

alter table submissions add column if not exists task_id uuid unique references tasks(id);
alter table submissions drop constraint if exists submissions_campaign_id_participant_id_key;
drop trigger if exists submissions_slots on submissions;
drop policy if exists s_ins on submissions;
create policy s_ins on submissions for insert with check (participant_id=auth.uid() and my_role()='participant' and status='pending'
  and exists(select 1 from tasks t where t.id=task_id and t.claimed_by=auth.uid() and t.campaign_id=submissions.campaign_id));

create view tasks_open as
  select c.id as campaign_id, c.title, c.task_type, c.instructions, c.requirements, c.questions, c.evidence_required,
         t.tier, min(t.amount) as amount, count(*) as open_count
  from campaigns c join tasks t on t.campaign_id=c.id
  where c.status='active' and t.claimed_by is null group by c.id, t.tier;
create view my_tasks as
  select t.id as task_id, t.amount, t.tier, t.claimed_at, c.id as campaign_id, c.title, c.instructions, c.requirements,
         c.questions, c.evidence_required, s.status as sub_status, s.reject_reason
  from tasks t join campaigns c on c.id=t.campaign_id left join submissions s on s.task_id=t.id where t.claimed_by=auth.uid();
grant select on tasks_open, my_tasks to authenticated;

create function create_campaign(p_title text,p_type text,p_ins text,p_req text,p_q jsonb,p_ev text,p_budget numeric) returns uuid
language plpgsql security definer set search_path=public as $$
declare cid uuid; pool numeric; q int; s int; d int; rest numeric;
begin
  if my_role()<>'business' then raise exception 'Only businesses can create projects'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_ins),'')='' or coalesce(trim(p_ev),'')='' or jsonb_array_length(p_q)=0 then raise exception 'Fill in all required fields'; end if;
  if p_budget < setting('min_budget') then raise exception 'Minimum budget is % NGN', setting('min_budget'); end if;
  pool := floor(p_budget*setting('tester_share'));
  q := floor(pool*0.5/100); s := floor(pool*0.3/300); d := floor(pool*0.2/1000);
  rest := pool - q*100 - s*300 - d*1000; q := q + floor(rest/100);
  insert into campaigns(business_id,title,task_type,instructions,requirements,questions,evidence_required,slots,budget)
    values(auth.uid(),p_title,p_type,p_ins,p_req,p_q,p_ev,q+s+d,p_budget) returning id into cid;
  insert into tasks(campaign_id,tier,amount)
    select cid,'quick',100 from generate_series(1,q) union all
    select cid,'standard',300 from generate_series(1,s) union all
    select cid,'detailed',1000 from generate_series(1,d);
  return cid;
end $$;

create function claim_task(p_campaign uuid, p_tier text) returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid; cap int := setting('max_tasks_per_person');
begin
  if my_role()<>'participant' then raise exception 'Only participants can take tasks'; end if;
  perform 1 from profiles where id=auth.uid() for update;
  if not exists(select 1 from campaigns where id=p_campaign and status='active') then raise exception 'This project is not available'; end if;
  if (select count(*) from tasks where campaign_id=p_campaign and claimed_by=auth.uid()) >= cap then raise exception 'You have reached the limit of % tasks for this project', cap; end if;
  select id into tid from tasks where campaign_id=p_campaign and tier=p_tier and claimed_by is null limit 1 for update skip locked;
  if tid is null then raise exception 'No tasks left in this group'; end if;
  update tasks set claimed_by=auth.uid(), claimed_at=now() where id=tid;
  return tid;
end $$;

create or replace function review_submission(p_id uuid, p_approve boolean, p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare s submissions; c campaigns; amt numeric;
begin
  select * into s from submissions where id=p_id;
  select * into c from campaigns where id=s.campaign_id;
  if c.business_id<>auth.uid() and not is_admin() then raise exception 'Not allowed'; end if;
  if s.status<>'pending' then raise exception 'Already reviewed'; end if;
  if not p_approve and coalesce(trim(p_reason),'')='' then raise exception 'A reason is required'; end if;
  update submissions set status=case when p_approve then 'approved' else 'rejected' end,
    reject_reason=case when p_approve then null else p_reason end, reviewed_at=now() where id=p_id;
  if p_approve then
    select coalesce((select amount from tasks where id=s.task_id), c.reward_naira) into amt;
    insert into ledger(participant_id,submission_id,amount) values(s.participant_id,s.id,amt);
  end if;
end $$;

create table withdrawals(
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references profiles(id), amount numeric not null check (amount>0),
  bank_name text not null, account_name text not null, account_number text not null,
  status text not null default 'pending' check (status in ('pending','paid','rejected')), created_at timestamptz default now());
alter table withdrawals enable row level security;
create policy w_read on withdrawals for select using (participant_id=auth.uid() or is_admin());
create policy w_admin on withdrawals for update using (is_admin()) with check (is_admin());
grant select, update on withdrawals to authenticated;

create function my_wallet() returns json language sql security definer stable set search_path=public as $$
  select json_build_object(
    'earned', coalesce((select sum(amount) from ledger where participant_id=auth.uid()),0),
    'withdrawn', coalesce((select sum(amount) from withdrawals where participant_id=auth.uid() and status<>'rejected'),0),
    'pending', coalesce((select sum(t.amount) from submissions s join tasks t on t.id=s.task_id where s.participant_id=auth.uid() and s.status='pending'),0)) $$;

create function request_withdrawal(p_amount numeric,p_bank text,p_name text,p_number text) returns uuid language plpgsql security definer set search_path=public as $$
declare avail numeric; wid uuid;
begin
  if my_role()<>'participant' then raise exception 'Only participants can withdraw'; end if;
  perform 1 from profiles where id=auth.uid() for update;
  if p_amount < setting('min_withdrawal') then raise exception 'Minimum withdrawal is % NGN', setting('min_withdrawal'); end if;
  if length(trim(p_bank))<2 or length(trim(p_name))<2 or p_number !~ '^[0-9]{10}$' then raise exception 'Enter valid bank details (10-digit account number)'; end if;
  select coalesce((select sum(amount) from ledger where participant_id=auth.uid()),0) - coalesce((select sum(amount) from withdrawals where participant_id=auth.uid() and status<>'rejected'),0) into avail;
  if p_amount > avail then raise exception 'Amount is more than your available balance'; end if;
  insert into withdrawals(participant_id,amount,bank_name,account_name,account_number) values(auth.uid(),p_amount,trim(p_bank),trim(p_name),p_number) returning id into wid;
  return wid;
end $$;

create function public_settings() returns json language sql security definer stable set search_path=public as $$
  select json_build_object('min_withdrawal',setting('min_withdrawal'),'max_tasks',setting('max_tasks_per_person')) $$;
create function my_campaign_progress() returns table(campaign_id uuid,total bigint,claimed bigint,approved bigint) language sql security definer stable set search_path=public as $$
  select c.id,(select count(*) from tasks t where t.campaign_id=c.id),(select count(*) from tasks t where t.campaign_id=c.id and t.claimed_by is not null),
         (select count(*) from submissions s where s.campaign_id=c.id and s.status='approved') from campaigns c where c.business_id=auth.uid() $$;

revoke execute on function create_campaign, claim_task, review_submission, my_wallet, request_withdrawal, public_settings, my_campaign_progress from public, anon;
grant execute on function create_campaign, claim_task, review_submission, my_wallet, request_withdrawal, public_settings, my_campaign_progress to authenticated;

-- referral code + safer profile updates
alter table profiles add column if not exists referral_code text unique, add column if not exists referred_by uuid references profiles(id);
update profiles set referral_code=substr(md5(id::text),1,8) where referral_code is null;
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,full_name,role,referral_code,referred_by) values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''),
    case when new.raw_user_meta_data->>'role'='business' then 'business' else 'participant' end,
    substr(md5(new.id::text),1,8),
    (select id from profiles where referral_code=lower(trim(new.raw_user_meta_data->>'ref'))));
  return new;
end $$;
revoke update on profiles from authenticated;
grant update(full_name,phone,country,language,device,interests,org_name,industry,org_description,website,contact_email,onboarded) on profiles to authenticated;
