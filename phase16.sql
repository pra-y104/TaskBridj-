-- Phase 16: security hardening, suspended accounts, safer messages. Run after phase15.sql. Safe to run again.

-- 1. Visitors who are not logged in get no access to any table or view
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;

-- 2. Logged-in users cannot write directly to tables that only the system may change
revoke insert, update, delete on tasks, ledger, audit_log, tickets, ticket_messages, project_messages, quote_requests, appeals, refund_requests, withdrawals from authenticated;
grant update on refund_requests, withdrawals, appeals to authenticated;   -- admin-only by row policy
revoke delete on all tables in schema public from authenticated;
grant delete on project_drafts to authenticated;

-- 3. Evidence files: size and type limits
update storage.buckets set file_size_limit=20971520,
  allowed_mime_types=array['image/*','video/*','audio/*','application/pdf'] where id='evidence';

-- 4. Suspended accounts lose every role-based permission
alter table profiles add column if not exists suspended boolean not null default false, add column if not exists suspended_reason text;
create or replace function my_role() returns text language sql security definer stable set search_path=public as $$
  select case when suspended then null else role end from profiles where id=auth.uid() $$;
create or replace function set_suspended(p_uid uuid, p_on boolean, p_reason text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  if p_uid=auth.uid() then raise exception 'You cannot suspend your own account'; end if;
  if (select role from profiles where id=p_uid)='admin' then raise exception 'Admin accounts cannot be suspended here'; end if;
  update profiles set suspended=p_on, suspended_reason=case when p_on then left(coalesce(p_reason,''),300) else null end where id=p_uid;
  perform notify(p_uid,'account',case when p_on then 'Account suspended' else 'Account restored' end,
    case when p_on then 'Your account was suspended. Contact support from the Help page.' else 'Your account is active again.' end,'support');
end $$;
revoke execute on function set_suspended(uuid,boolean,text) from public, anon;
grant execute on function set_suspended(uuid,boolean,text) to authenticated;
drop trigger if exists audit_suspend on profiles;
create trigger audit_suspend after update on profiles for each row when (old.suspended is distinct from new.suspended) execute function log_change();

-- 5. Messages are announcements only: no phone numbers, emails or off-platform chat links
create or replace function post_message(p_cid uuid, p_body text) returns void language plpgsql security definer set search_path=public as $$
declare b text := trim(coalesce(p_body,''));
begin
  if not exists(select 1 from campaigns where id=p_cid and business_id=auth.uid()) then raise exception 'You cannot message this project'; end if;
  if length(b) not between 2 and 1000 then raise exception 'Write a message of 2 to 1000 characters'; end if;
  if b ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}'
     or regexp_replace(b,'[\s().-]','','g') ~ '((\+?234|0)[789][01][0-9]{8})|(\+[0-9]{10,})'
     or b ~* '(whatsapp|telegram|wa\.me|t\.me|discord|signal app|dm me|call me|text me|inbox me)'
  then raise exception 'Messages cannot include phone numbers, emails or other contact details. Keep communication on TaskBridj.'; end if;
  if (select count(*) from project_messages where campaign_id=p_cid and created_at>now()-interval '1 day')>=20 then raise exception 'Daily message limit reached for this project'; end if;
  insert into project_messages(campaign_id,sender_id,body) values(p_cid,auth.uid(),b);
  insert into notifications(user_id,kind,title,body,link)
    select distinct t.claimed_by,'message','Message from a business',left(b,200),'tasks' from tasks t where t.campaign_id=p_cid and t.claimed_by is not null;
end $$;
