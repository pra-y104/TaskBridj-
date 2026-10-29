-- TaskBridj database. Run once in Supabase > SQL Editor.
create extension if not exists pgcrypto;

create table profiles(
  id uuid primary key references auth.users on delete cascade,
  full_name text, phone text,
  role text not null default 'participant' check (role in ('participant','business','admin')),
  created_at timestamptz default now());

create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,full_name,role) values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''),
    case when new.raw_user_meta_data->>'role'='business' then 'business' else 'participant' end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create function my_role() returns text language sql security definer stable set search_path=public as $$ select role from profiles where id=auth.uid() $$;
create function is_admin() returns boolean language sql security definer stable set search_path=public as $$ select coalesce(my_role()='admin',false) $$;

create table campaigns(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references profiles(id) on delete cascade,
  title text not null, task_type text not null, instructions text not null,
  requirements text, questions jsonb not null default '[]', evidence_required text,
  slots int not null check (slots between 1 and 1000),
  reward_naira numeric not null check (reward_naira >= 50),
  status text not null default 'pending_review' check (status in ('pending_review','active','rejected')),
  reject_reason text, created_at timestamptz default now());

create table submissions(
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references campaigns(id) on delete cascade,
  participant_id uuid not null references profiles(id) on delete cascade,
  answers jsonb not null default '[]', evidence_path text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reject_reason text, reviewed_at timestamptz, created_at timestamptz default now(),
  unique (campaign_id, participant_id));

create table ledger(
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references profiles(id) on delete cascade,
  submission_id uuid not null unique references submissions(id) on delete cascade,
  amount numeric not null, created_at timestamptz default now());

create view campaigns_public as
  select c.id,c.title,c.task_type,c.instructions,c.requirements,c.questions,c.evidence_required,c.slots,c.reward_naira,c.created_at,
         (select count(*) from submissions s where s.campaign_id=c.id) as taken
  from campaigns c where c.status='active';
grant select on campaigns_public to authenticated;

create function enforce_slots() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from campaigns where id=new.campaign_id and status='active') then raise exception 'Campaign is not available'; end if;
  if (select count(*) from submissions where campaign_id=new.campaign_id) >= (select slots from campaigns where id=new.campaign_id) then raise exception 'No slots left'; end if;
  return new;
end $$;
create trigger submissions_slots before insert on submissions for each row execute function enforce_slots();

create function review_submission(p_id uuid, p_approve boolean, p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare s submissions; c campaigns;
begin
  select * into s from submissions where id=p_id;
  select * into c from campaigns where id=s.campaign_id;
  if c.business_id<>auth.uid() and not is_admin() then raise exception 'Not allowed'; end if;
  if s.status<>'pending' then raise exception 'Already reviewed'; end if;
  if not p_approve and coalesce(trim(p_reason),'')='' then raise exception 'A reason is required'; end if;
  update submissions set status=case when p_approve then 'approved' else 'rejected' end,
    reject_reason=case when p_approve then null else p_reason end, reviewed_at=now() where id=p_id;
  if p_approve then insert into ledger(participant_id,submission_id,amount) values(s.participant_id,s.id,c.reward_naira); end if;
end $$;

-- Row level security
alter table profiles enable row level security;
alter table campaigns enable row level security;
alter table submissions enable row level security;
alter table ledger enable row level security;

create policy p_read on profiles for select using (id=auth.uid() or is_admin());
create policy p_upd on profiles for update using (id=auth.uid()) with check (id=auth.uid() and role=my_role());

create policy c_read on campaigns for select using (business_id=auth.uid() or is_admin());
create policy c_ins on campaigns for insert with check (business_id=auth.uid() and my_role()='business' and status='pending_review');
create policy c_admin on campaigns for update using (is_admin()) with check (is_admin());

create policy s_read on submissions for select using (participant_id=auth.uid() or is_admin()
  or exists(select 1 from campaigns c where c.id=campaign_id and c.business_id=auth.uid()));
create policy s_ins on submissions for insert with check (participant_id=auth.uid() and my_role()='participant' and status='pending');

create policy l_read on ledger for select using (participant_id=auth.uid() or is_admin());

-- Private evidence storage
insert into storage.buckets(id,name,public) values('evidence','evidence',false) on conflict do nothing;
create policy e_up on storage.objects for insert to authenticated
  with check (bucket_id='evidence' and (storage.foldername(name))[1]=auth.uid()::text);
create policy e_read on storage.objects for select to authenticated using (bucket_id='evidence' and (
  (storage.foldername(name))[1]=auth.uid()::text or is_admin()
  or exists(select 1 from submissions s join campaigns c on c.id=s.campaign_id where s.evidence_path=name and c.business_id=auth.uid())));
