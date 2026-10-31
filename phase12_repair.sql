-- Phase 12 REPAIR: run this instead of phase12.sql (your database already has phase 13). Then run phase14.sql.
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

-- remove the old 9-argument version so it cannot be used to skip checks
drop function if exists create_campaign(text,text,text,text,jsonb,text,int,boolean,int);
-- the current (phase 13) version stays; just lock its permissions
revoke execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean,int,jsonb) from public, anon;
grant execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean,int,jsonb) to authenticated;
