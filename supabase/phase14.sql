-- Phase 14: project page tools: pause/resume, safe edits, messages to participants. Run after phase13.sql. Adds only.
alter table campaigns add column if not exists paused boolean not null default false;

create or replace view tasks_open as
  select c.id as campaign_id, c.title, c.task_type, c.instructions, c.requirements, c.questions, c.evidence_required,
         t.tier, min(t.amount) as amount, count(*) as open_count, c.created_at,
         c.description, c.est_minutes, c.deadline, c.reference_link
  from campaigns c join tasks t on t.campaign_id=c.id left join submissions s on s.task_id=t.id
  where c.status='active' and not c.paused and (c.deadline is null or c.deadline>now()) and (c.start_at is null or c.start_at<=now()) and eligible(c.id)
    and (t.claimed_by is null or (t.claimed_at < now()-make_interval(hours=>setting('claim_hours')::int) and s.id is null))
  group by c.id, t.tier;
grant select on tasks_open to authenticated;

create or replace function claim_task(p_campaign uuid, p_tier text) returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid; cap int := setting('max_tasks_per_person'); hrs int := setting('claim_hours')::int;
begin
  if my_role()<>'participant' then raise exception 'Only participants can take tasks'; end if;
  perform 1 from profiles where id=auth.uid() for update;
  if not exists(select 1 from campaigns where id=p_campaign and status='active' and not paused and (deadline is null or deadline>now()) and (start_at is null or start_at<=now())) then raise exception 'This project is not available'; end if;
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

create function set_paused(p_cid uuid, p_paused boolean) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from campaigns where id=p_cid and business_id=auth.uid() and status='active') then raise exception 'You cannot pause or resume this project'; end if;
  update campaigns set paused=p_paused where id=p_cid;
end $$;

create function update_project(p_cid uuid, p_title text, p_desc text, p_req text, p_link text) returns void language plpgsql security definer set search_path=public as $$
declare lnk text := nullif(trim(coalesce(p_link,'')),'');
begin
  if not exists(select 1 from campaigns where id=p_cid and business_id=auth.uid() and status in ('pending_review','active')) then raise exception 'You cannot edit this project'; end if;
  if length(trim(coalesce(p_title,'')))<3 or length(p_title)>120 then raise exception 'Enter a title of 3 to 120 characters'; end if;
  if length(coalesce(p_desc,''))>2000 or length(coalesce(p_req,''))>1000 then raise exception 'Text is too long'; end if;
  if lnk is not null and lnk !~ '^https?://[^[:space:]]+$' then raise exception 'Enter a valid link starting with http'; end if;
  update campaigns set title=trim(p_title), description=trim(coalesce(p_desc,'')), requirements=trim(coalesce(p_req,'')), reference_link=lnk where id=p_cid;
end $$;

create table if not exists project_messages(
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references campaigns(id) on delete cascade,
  sender_id uuid not null references profiles(id) on delete cascade,
  body text not null check (length(body) between 2 and 1000),
  created_at timestamptz not null default now());
alter table project_messages enable row level security;
create policy pm_read on project_messages for select to authenticated using (
  is_admin()
  or exists(select 1 from campaigns c where c.id=campaign_id and c.business_id=auth.uid())
  or exists(select 1 from tasks t where t.campaign_id=project_messages.campaign_id and t.claimed_by=auth.uid()));
grant select on project_messages to authenticated;

create function post_message(p_cid uuid, p_body text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from campaigns where id=p_cid and business_id=auth.uid()) then raise exception 'You cannot message this project'; end if;
  if length(trim(coalesce(p_body,''))) not between 2 and 1000 then raise exception 'Write a message of 2 to 1000 characters'; end if;
  if (select count(*) from project_messages where campaign_id=p_cid and created_at>now()-interval '1 day')>=20 then raise exception 'Daily message limit reached for this project'; end if;
  insert into project_messages(campaign_id,sender_id,body) values(p_cid,auth.uid(),trim(p_body));
end $$;

revoke execute on function set_paused(uuid,boolean), update_project(uuid,text,text,text,text), post_message(uuid,text) from public, anon;
grant execute on function set_paused(uuid,boolean), update_project(uuid,text,text,text,text), post_message(uuid,text) to authenticated;
