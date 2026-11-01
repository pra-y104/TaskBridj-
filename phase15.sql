-- Phase 15: notifications, support tickets. Run after phase14.sql. Adds only.
create table if not exists notifications(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  kind text not null, title text not null, body text, link text,
  read boolean not null default false, created_at timestamptz not null default now());
create index if not exists notifications_user_idx on notifications(user_id, created_at desc);
alter table notifications enable row level security;
create policy n_read on notifications for select to authenticated using (user_id=auth.uid());
create policy n_upd on notifications for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
grant select on notifications to authenticated;
grant update(read) on notifications to authenticated;

create function notify(p_user uuid, p_kind text, p_title text, p_body text, p_link text) returns void language sql security definer set search_path=public as $$
  insert into notifications(user_id,kind,title,body,link) values(p_user,p_kind,p_title,left(p_body,300),p_link) $$;
revoke execute on function notify(uuid,text,text,text,text) from public, anon, authenticated;

create function trg_notify() returns trigger language plpgsql security definer set search_path=public as $$
declare t text;
begin
  if TG_TABLE_NAME='submissions' then
    select title into t from campaigns where id=new.campaign_id;
    if TG_OP='INSERT' then
      perform notify((select business_id from campaigns where id=new.campaign_id),'submission','New submission','Someone submitted work for '||t||'.','projects');
    elsif new.status='approved' then
      perform notify(new.participant_id,'reward','Submission approved','Your work for '||t||' was approved and your reward was added.','wallet');
    elsif new.status='rejected' then
      perform notify(new.participant_id,'rejected','Submission rejected','Your work for '||t||' was rejected. Reason: '||coalesce(new.reject_reason,'not given')||'. You can appeal.','tasks');
    end if;
  elsif TG_TABLE_NAME='withdrawals' then
    perform notify(new.participant_id,'withdrawal','Withdrawal '||new.status,'Your withdrawal request was marked '||new.status||'.','wallet');
  elsif TG_TABLE_NAME='refund_requests' then
    perform notify(new.business_id,'refund','Refund '||new.status,'Your refund request was marked '||new.status||'.','billing');
  elsif TG_TABLE_NAME='appeals' then
    perform notify(new.participant_id,'appeal','Appeal '||new.status,'Your appeal was '||new.status||'.'||coalesce(' '||nullif(new.admin_note,''),''),'tasks');
  elsif TG_TABLE_NAME='campaigns' then
    perform notify(new.business_id,'project','Project '||replace(new.status,'_',' '),'Your project "'||new.title||'" is now '||replace(new.status,'_',' ')||'.','projects');
  end if;
  return new;
end $$;
revoke execute on function trg_notify() from public, anon, authenticated;
create trigger notify_sub_ins after insert on submissions for each row execute function trg_notify();
create trigger notify_sub_upd after update on submissions for each row when (old.status is distinct from new.status) execute function trg_notify();
create trigger notify_wd after update on withdrawals for each row when (old.status is distinct from new.status) execute function trg_notify();
create trigger notify_rf after update on refund_requests for each row when (old.status is distinct from new.status) execute function trg_notify();
create trigger notify_ap after update on appeals for each row when (old.status is distinct from new.status) execute function trg_notify();
create trigger notify_camp after update on campaigns for each row when (old.status is distinct from new.status) execute function trg_notify();

create or replace function post_message(p_cid uuid, p_body text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from campaigns where id=p_cid and business_id=auth.uid()) then raise exception 'You cannot message this project'; end if;
  if length(trim(coalesce(p_body,''))) not between 2 and 1000 then raise exception 'Write a message of 2 to 1000 characters'; end if;
  if (select count(*) from project_messages where campaign_id=p_cid and created_at>now()-interval '1 day')>=20 then raise exception 'Daily message limit reached for this project'; end if;
  insert into project_messages(campaign_id,sender_id,body) values(p_cid,auth.uid(),trim(p_body));
  insert into notifications(user_id,kind,title,body,link)
    select distinct t.claimed_by,'message','Message from a business',left(trim(p_body),200),'tasks' from tasks t where t.campaign_id=p_cid and t.claimed_by is not null;
end $$;

-- support tickets
create sequence if not exists ticket_seq start 1001;
create table if not exists tickets(
  id uuid primary key default gen_random_uuid(), ref text not null unique,
  user_id uuid not null references profiles(id) on delete cascade,
  subject text not null check (length(subject) between 3 and 120),
  category text not null check (category in ('Account','Tasks and submissions','Payments and withdrawals','Projects','Refunds and disputes','Other')),
  status text not null default 'open' check (status in ('open','answered','closed')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table if not exists ticket_messages(
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references tickets(id) on delete cascade,
  sender_id uuid not null references profiles(id), is_staff boolean not null default false,
  body text not null check (length(body) between 2 and 2000), created_at timestamptz not null default now());
alter table tickets enable row level security; alter table ticket_messages enable row level security;
create policy tk_read on tickets for select to authenticated using (user_id=auth.uid() or is_admin());
create policy tm_read on ticket_messages for select to authenticated using (is_admin() or exists(select 1 from tickets t where t.id=ticket_id and t.user_id=auth.uid()));
grant select on tickets, ticket_messages to authenticated;

create function create_ticket(p_subject text, p_category text, p_body text) returns text language plpgsql security definer set search_path=public as $$
declare tid uuid; r text;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  if (select count(*) from tickets where user_id=auth.uid() and status<>'closed')>=5 then raise exception 'You already have 5 open tickets. Please close one first.'; end if;
  r := 'TB-'||nextval('ticket_seq');
  insert into tickets(ref,user_id,subject,category) values(r,auth.uid(),trim(p_subject),p_category) returning id into tid;
  insert into ticket_messages(ticket_id,sender_id,body) values(tid,auth.uid(),trim(p_body));
  insert into notifications(user_id,kind,title,body,link) select id,'ticket','New support ticket',r||': '||left(trim(p_subject),80),'support' from profiles where role='admin';
  return r;
end $$;
create function reply_ticket(p_tid uuid, p_body text) returns void language plpgsql security definer set search_path=public as $$
declare t tickets;
begin
  select * into t from tickets where id=p_tid;
  if t.id is null or (t.user_id<>auth.uid() and not is_admin()) then raise exception 'Not allowed'; end if;
  if t.status='closed' then raise exception 'This ticket is closed'; end if;
  if (select count(*) from ticket_messages where ticket_id=p_tid and sender_id=auth.uid() and created_at>now()-interval '1 day')>=30 then raise exception 'Daily reply limit reached'; end if;
  if is_admin() then
    insert into ticket_messages(ticket_id,sender_id,body,is_staff) values(p_tid,auth.uid(),trim(p_body),true);
    update tickets set status='answered', updated_at=now() where id=p_tid;
    perform notify(t.user_id,'ticket','Support replied',t.ref||': '||left(trim(p_body),150),'support');
  else
    insert into ticket_messages(ticket_id,sender_id,body) values(p_tid,auth.uid(),trim(p_body));
    update tickets set status='open', updated_at=now() where id=p_tid;
  end if;
end $$;
create function close_ticket(p_tid uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from tickets where id=p_tid and (user_id=auth.uid() or is_admin())) then raise exception 'Not allowed'; end if;
  update tickets set status='closed', updated_at=now() where id=p_tid;
end $$;
revoke execute on function create_ticket(text,text,text), reply_ticket(uuid,text), close_ticket(uuid) from public, anon;
grant execute on function create_ticket(text,text,text), reply_ticket(uuid,text), close_ticket(uuid) to authenticated;
