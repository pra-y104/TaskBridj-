-- Phase 18: referral bonus and admin overview. Run after phase17.sql. Safe to run again.
alter table ledger alter column submission_id drop not null;
alter table ledger add column if not exists kind text not null default 'reward';
alter table ledger drop constraint if exists ledger_kind_check;
alter table ledger add constraint ledger_kind_check check (kind in ('reward','referral'));
insert into settings values('referral_bonus',100),('referral_threshold',1000),('referral_cap',50) on conflict do nothing;

create table if not exists referral_payouts(
  referred_id uuid primary key references profiles(id) on delete cascade,
  referrer_id uuid not null references profiles(id) on delete cascade,
  amount numeric not null, created_at timestamptz not null default now());
alter table referral_payouts enable row level security;
drop policy if exists rp_admin on referral_payouts;
create policy rp_admin on referral_payouts for select to authenticated using (is_admin());
revoke all on referral_payouts from anon;
revoke insert, update, delete on referral_payouts from authenticated;
grant select on referral_payouts to authenticated;

-- the bonus is paid ONCE per friend, only after the friend has earned the target amount from approved work,
-- so it always comes out of TaskBridj's share and never from tester pay
create or replace function trg_referral() returns trigger language plpgsql security definer set search_path=public as $$
declare ref uuid; tot numeric; bonus numeric := setting('referral_bonus'); thr numeric := setting('referral_threshold'); cap int := setting('referral_cap')::int;
begin
  if new.kind<>'reward' then return new; end if;
  select referred_by into ref from profiles where id=new.participant_id;
  if ref is null or ref=new.participant_id then return new; end if;
  select coalesce(sum(amount),0) into tot from ledger where participant_id=new.participant_id and kind='reward';
  if tot<thr then return new; end if;
  if (select count(*) from referral_payouts where referrer_id=ref)>=cap then return new; end if;
  if coalesce((select suspended from profiles where id=ref),true) then return new; end if;
  insert into referral_payouts(referred_id,referrer_id,amount) values(new.participant_id,ref,bonus) on conflict (referred_id) do nothing;
  if not found then return new; end if;
  insert into ledger(participant_id,amount,kind) values(ref,bonus,'referral');
  perform notify(ref,'reward','Referral bonus','A friend you invited reached the earnings target. Your bonus was added to your wallet.','wallet');
  return new;
end $$;
revoke execute on function trg_referral() from public, anon, authenticated;
drop trigger if exists referral_after_ledger on ledger;
create trigger referral_after_ledger after insert on ledger for each row execute function trg_referral();

create or replace function my_referrals() returns json language sql stable security definer set search_path=public as $$
  select json_build_object('invited',(select count(*) from profiles where referred_by=auth.uid()),
    'rewarded',(select count(*) from referral_payouts where referrer_id=auth.uid()),
    'earned',coalesce((select sum(amount) from referral_payouts where referrer_id=auth.uid()),0)) $$;
revoke execute on function my_referrals() from public, anon;
grant execute on function my_referrals() to authenticated;

create or replace function public_settings() returns json language sql security definer stable set search_path=public as $$
  select json_build_object('min_withdrawal',setting('min_withdrawal'),'max_tasks',setting('max_tasks_per_person'),
    'referral_bonus',setting('referral_bonus'),'referral_threshold',setting('referral_threshold')) $$;

create or replace function admin_overview() returns json language plpgsql security definer stable set search_path=public as $$
begin
  if not is_admin() then raise exception 'Not allowed'; end if;
  return json_build_object(
   'participants',(select count(*) from profiles where role='participant'),
   'businesses',(select count(*) from profiles where role='business'),
   'suspended',(select count(*) from profiles where suspended),
   'projects_live',(select count(*) from campaigns where status='active' and not paused and (deadline is null or deadline>now())),
   'projects_waiting',(select count(*) from campaigns where status='pending_review'),
   'funded_total',coalesce((select sum(budget) from campaigns where funded),0),
   'rewards_total',coalesce((select sum(amount) from ledger where kind='reward'),0),
   'referral_total',coalesce((select sum(amount) from ledger where kind='referral'),0),
   'withdrawn_paid',coalesce((select sum(amount) from withdrawals where status='paid'),0),
   'withdrawals_pending',coalesce((select sum(amount) from withdrawals where status='pending'),0),
   'refunds_pending',coalesce((select sum(net) from refund_requests where status='pending'),0),
   'tickets_open',(select count(*) from tickets where status<>'closed'),
   'appeals_pending',(select count(*) from appeals where status='pending'),
   'submissions_pending',(select count(*) from submissions where status='pending'));
end $$;
revoke execute on function admin_overview() from public, anon;
grant execute on function admin_overview() to authenticated;
