-- Phase 19: payments (Paystack). Run after phase18.sql. Safe to run again.
create table if not exists payments(
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  campaign_id uuid not null references campaigns(id) on delete cascade,
  business_id uuid not null references profiles(id) on delete cascade,
  amount_kobo bigint not null check (amount_kobo > 0),
  currency text not null default 'NGN',
  status text not null default 'pending' check (status in ('pending','paid','failed','duplicate')),
  paid_at timestamptz, created_at timestamptz not null default now());
create index if not exists payments_campaign_idx on payments(campaign_id);
alter table payments enable row level security;
drop policy if exists pay_read on payments;
create policy pay_read on payments for select to authenticated using (business_id=auth.uid() or is_admin());
revoke all on payments from anon;
revoke insert, update, delete on payments from authenticated;
grant select on payments to authenticated;

-- Only the secure server function (service role) may confirm a payment.
-- The amount and currency must match what was recorded when the payment was started.
create or replace function mark_payment_paid(p_ref text, p_amount_kobo bigint, p_currency text) returns text language plpgsql security definer set search_path=public as $$
declare p payments; c campaigns;
begin
  select * into p from payments where reference=p_ref for update;
  if p.id is null then return 'unknown'; end if;
  if p.status in ('paid','duplicate') then return 'already'; end if;
  if p_amount_kobo <> p.amount_kobo or upper(p_currency) <> p.currency then
    update payments set status='failed' where id=p.id;
    return 'mismatch';
  end if;
  select * into c from campaigns where id=p.campaign_id for update;
  if c.funded then
    update payments set status='duplicate', paid_at=now() where id=p.id;
    insert into notifications(user_id,kind,title,body,link)
      select id,'payment','Duplicate payment','Payment '||p_ref||' arrived for a project that was already funded. It needs a refund.','overview' from profiles where role='admin';
    return 'duplicate';
  end if;
  update payments set status='paid', paid_at=now() where id=p.id;
  update campaigns set funded=true where id=p.campaign_id;
  perform notify(p.business_id,'payment','Payment received','We received your payment. Your project goes live after review.','billing');
  return 'paid';
end $$;
revoke execute on function mark_payment_paid(text,bigint,text) from public, anon, authenticated;
grant execute on function mark_payment_paid(text,bigint,text) to service_role;
