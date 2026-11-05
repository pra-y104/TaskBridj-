-- TaskBridj money-rule and isolation tests.
-- Run this whole file in the Supabase SQL Editor. It ENDS WITH AN "ERROR" THAT CONTAINS THE REPORT. That is on purpose:
-- the error cancels everything, so no test users or test data are kept. Read the PASS / FAIL lines in the message.

create temp table res(n text, ok boolean, d text) on commit drop;
create function pg_temp.chk(n text, ok boolean, d text default '') returns void language sql as $f$ insert into res values(n, coalesce(ok,false), d) $f$;
create function pg_temp.report() returns text language sql as $f$
  select 'PASSED '||count(*) filter (where ok)||' / '||count(*)||E'\n'||string_agg((case when ok then 'PASS  ' else 'FAIL  ' end)||n||case when ok or d='' then '' else '  -> '||d end, E'\n') from res $f$;
-- run a statement as a logged-in user (u), as a visitor (u null) and return its first value or 'ERR: ...'
create function pg_temp.q(u uuid, sqltext text) returns text language plpgsql as $f$
declare v text;
begin
  if u is not null then
    perform set_config('request.jwt.claim.sub', u::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub',u,'role','authenticated')::text, true);
    execute 'set local role authenticated';
  else
    execute 'set local role anon';
  end if;
  begin
    execute sqltext into v;
    execute 'reset role'; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','',true);
    return coalesce(v,'null');
  exception when others then
    execute 'reset role'; perform set_config('request.jwt.claim.sub','',true); perform set_config('request.jwt.claims','',true);
    return 'ERR: '||SQLERRM;
  end;
end $f$;

do $t$
declare
  biz uuid := gen_random_uuid(); p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid(); adm uuid := gen_random_uuid(); rf1 uuid := gen_random_uuid(); rf2 uuid := gen_random_uuid(); cid2 uuid; kb bigint;
  cid uuid; r text; t1 uuid; t2 uuid; t3 uuid; sid uuid; code text; code2 text; amt numeric; tamt numeric;
  share numeric; extra numeric; lst numeric; bud numeric; pool numeric; rec record; c int; k int; bad text := '';
  uidq text := '00000000-0000-0000-0000-000000000000';
begin
  share := setting('tester_share'); extra := setting('recording_extra');

  ------------------------------------------------ PRICING
  for rec in select task_type, price from rates where active and not quote_only loop
    foreach c in array array[10,49,50,199,200,499,500,999,1000,4999,5000,10000] loop
      for k in 0..1 loop
        lst := c*(rec.price + case when k=1 then extra else 0 end);
        bud := round(lst*(1-discount_pct(c))); pool := floor(lst*share);
        if bud-pool < bud*0.25 then bad := bad||rec.task_type||'@'||c||' '; end if;
      end loop;
    end loop;
  end loop;
  perform pg_temp.chk('TaskBridj keeps at least 25% on every task type, order size and extra', bad='', left(bad,300));
  perform pg_temp.chk('No volume discount is larger than the safe maximum', (select coalesce(max(pct),0) from discounts) <= 1 - share/0.75 + 0.0001, 'max discount '||(select max(pct) from discounts));
  perform pg_temp.chk('Discounts never go down as orders get bigger', (select bool_and(d1.pct<=d2.pct) from discounts d1 join discounts d2 on d2.min_count=(select min(min_count) from discounts where min_count>d1.min_count)), '');
  select price into amt from rates where task_type='App testing';
  perform pg_temp.chk('Quote matches the pricing formula (100 App testing)', (quote_campaign('App testing',100,false)->>'total')::numeric = round(100*amt*(1-discount_pct(100))), quote_campaign('App testing',100,false)::text);
  perform pg_temp.chk('Custom-quote types are never priced automatically', coalesce((quote_campaign('Focus group',50,false)->>'custom')::boolean,false), quote_campaign('Focus group',50,false)::text);

  ------------------------------------------------ TEST USERS
  insert into auth.users(id,instance_id,aud,role,email,raw_user_meta_data,email_confirmed_at,created_at,updated_at) values
   (biz,uidq::uuid,'authenticated','authenticated','t-biz@example.test','{"role":"business","full_name":"T Biz"}',now(),now(),now()),
   (p1,uidq::uuid,'authenticated','authenticated','t-p1@example.test','{"role":"participant","full_name":"T One"}',now(),now(),now()),
   (p2,uidq::uuid,'authenticated','authenticated','t-p2@example.test','{"role":"participant","full_name":"T Two"}',now(),now(),now()),
   (adm,uidq::uuid,'authenticated','authenticated','t-adm@example.test','{"role":"participant","full_name":"T Admin"}',now(),now(),now());
  update profiles set role='admin' where id=adm;
  update settings set value=50 where key='min_withdrawal';
  perform pg_temp.chk('Sign-up trigger gives the right roles', (select role from profiles where id=biz)='business' and (select role from profiles where id=p1)='participant', '');

  ------------------------------------------------ PROJECT CREATION RULES
  r := pg_temp.q(biz, $q$ select create_campaign('Test project','App testing','Do it','','[{"q":"Works?","t":"yesno"}]'::jsonb,'Screenshot',20,false,7,'{}'::jsonb)::text $q$);
  perform pg_temp.chk('Business can create a project', r not like 'ERR:%', r);
  if r like 'ERR:%' then raise exception E'TEST REPORT (stopped early)\n%', pg_temp.report(); end if;
  cid := r::uuid;
  perform pg_temp.chk('Server stores the price it calculated', (select budget from campaigns where id=cid) = round(20*amt*(1-discount_pct(20))), (select budget::text from campaigns where id=cid));
  perform pg_temp.chk('Tester pool is never above the allowed share of the price', (select coalesce(sum(amount),0) from tasks where campaign_id=cid) <= floor(20*amt*share), (select sum(amount)::text from tasks where campaign_id=cid));
  r := pg_temp.q(biz, $q$ select create_campaign('Quote only','Focus group','Do it','','[{"q":"x","t":"text"}]'::jsonb,'Proof',20,false,7,'{}'::jsonb)::text $q$);
  perform pg_temp.chk('Custom-quote task type cannot be created automatically', r like 'ERR:%', r);
  r := pg_temp.q(p1, $q$ select create_campaign('By participant','App testing','Do it','','[{"q":"x","t":"text"}]'::jsonb,'Proof',20,false,7,'{}'::jsonb)::text $q$);
  perform pg_temp.chk('Participant cannot create a project', r like 'ERR:%', r);
  r := pg_temp.q(biz, $q$ select create_campaign('Too few','App testing','Do it','','[{"q":"x","t":"text"}]'::jsonb,'Proof',3,false,7,'{}'::jsonb)::text $q$);
  perform pg_temp.chk('Fewer than 10 participants is refused', r like 'ERR:%', r);
  begin update campaigns set status='active' where id=cid; perform pg_temp.chk('Unfunded project cannot be activated', false, 'it was activated'); exception when others then perform pg_temp.chk('Unfunded project cannot be activated', true, ''); end;
  update campaigns set funded=true, status='active' where id=cid;

  ------------------------------------------------ TAKING TASKS AND PROOF
  r := pg_temp.q(biz, format($q$ select claim_task(%L::uuid,'quick')::text $q$, cid));
  perform pg_temp.chk('Business cannot take tasks', r like 'ERR:%', r);
  r := pg_temp.q(p1, format($q$ select claim_task(%L::uuid,'quick')::text $q$, cid));
  perform pg_temp.chk('Participant can take a task', r not like 'ERR:%', r);
  select id into t1 from tasks where campaign_id=cid and claimed_by=p1 limit 1;
  r := pg_temp.q(p1, format($q$ select claim_task(%L::uuid,'quick')::text $q$, cid));
  select id into t2 from tasks where campaign_id=cid and claimed_by=p1 and id<>t1 limit 1;
  r := pg_temp.q(p2, format($q$ select claim_task(%L::uuid,'quick')::text $q$, cid));
  select id into t3 from tasks where campaign_id=cid and claimed_by=p2 limit 1;
  perform pg_temp.chk('Two people never get the same task', t1<>t3 and t2<>t3, '');
  select upper(substr(md5(id::text||claimed_by::text||claimed_at::text),1,6)) into code from tasks where id=t1;
  select upper(substr(md5(id::text||claimed_by::text||claimed_at::text),1,6)) into code2 from tasks where id=t3;
  r := pg_temp.q(p1, format($q$ insert into submissions(campaign_id,task_id,participant_id,answers,evidence_path,proof_code,file_hash) values(%L,%L,%L,'["Works? — Yes"]','x/a.png','ZZZZZZ','hash-wrong') returning id::text $q$, cid, t2, p1));
  perform pg_temp.chk('Wrong proof code is refused', r like 'ERR:%', r);
  r := pg_temp.q(p1, format($q$ insert into submissions(campaign_id,task_id,participant_id,answers,evidence_path,proof_code,file_hash) values(%L,%L,%L,'["Works? — Yes"]','x/a.png',%L,'hash-one') returning id::text $q$, cid, t1, p1, code));
  perform pg_temp.chk('Correct submission is accepted', r not like 'ERR:%', r);
  if r like 'ERR:%' then raise exception E'TEST REPORT (stopped early)\n%', pg_temp.report(); end if;
  sid := r::uuid;
  r := pg_temp.q(p2, format($q$ insert into submissions(campaign_id,task_id,participant_id,answers,evidence_path,proof_code,file_hash) values(%L,%L,%L,'["Works? — Yes"]','x/b.png',%L,'hash-one') returning id::text $q$, cid, t3, p2, code2));
  perform pg_temp.chk('Same file cannot be used again by another account', r like 'ERR:%', r);
  r := pg_temp.q(p2, format($q$ insert into submissions(campaign_id,task_id,participant_id,answers,evidence_path,proof_code,file_hash) values(%L,%L,%L,'["x"]','x/c.png',%L,'hash-two') returning id::text $q$, cid, t1, p2, code));
  perform pg_temp.chk('Participant cannot submit on someone else''s task', r like 'ERR:%', r);

  ------------------------------------------------ REVIEW AND REWARDS
  r := pg_temp.q(p2, format($q$ select review_submission(%L::uuid,true,null)::text $q$, sid));
  perform pg_temp.chk('Participants cannot approve work', r like 'ERR:%', r);
  r := pg_temp.q(biz, format($q$ select review_submission(%L::uuid,false,'')::text $q$, sid));
  perform pg_temp.chk('Rejecting needs a written reason', r like 'ERR:%', r);
  r := pg_temp.q(biz, format($q$ select review_submission(%L::uuid,true,null)::text $q$, sid));
  perform pg_temp.chk('Business can approve its own submission', r not like 'ERR:%', r);
  select amount into amt from ledger where submission_id=sid; select amount into tamt from tasks where id=t1;
  perform pg_temp.chk('Reward equals the task amount', amt is not null and amt=tamt, coalesce(amt::text,'no credit'));
  r := pg_temp.q(biz, format($q$ select review_submission(%L::uuid,true,null)::text $q$, sid));
  perform pg_temp.chk('Reviewing twice is refused', r like 'ERR:%', r);
  perform pg_temp.chk('Reward is credited exactly once', (select count(*) from ledger where submission_id=sid)=1, (select count(*)::text from ledger where submission_id=sid));
  perform pg_temp.chk('Participant is notified of the reward', exists(select 1 from notifications where user_id=p1 and kind='reward'), '');
  r := pg_temp.q(p1, 'insert into ledger(participant_id,submission_id,amount) values(null,null,1) returning id::text');
  perform pg_temp.chk('Nobody can add wallet money directly', r like 'ERR:%', r);

  ------------------------------------------------ WITHDRAWALS (minimum set to 50 for this test; balance is the task amount)
  r := pg_temp.q(p1, $q$ select request_withdrawal(100000,'Test Bank','T One','0123456789')::text $q$);
  perform pg_temp.chk('Cannot withdraw more than the balance', r like 'ERR:%', r);
  r := pg_temp.q(p1, $q$ select request_withdrawal(10,'Test Bank','T One','0123456789')::text $q$);
  perform pg_temp.chk('Cannot withdraw below the minimum', r like 'ERR:%', r);
  r := pg_temp.q(p1, $q$ select request_withdrawal(60,'Test Bank','T One','0123456789')::text $q$);
  perform pg_temp.chk('Valid withdrawal is accepted', r not like 'ERR:%', r);
  r := pg_temp.q(p1, $q$ select request_withdrawal(60,'Test Bank','T One','0123456789')::text $q$);
  perform pg_temp.chk('Balance cannot be spent twice', r like 'ERR:%', r);
  r := pg_temp.q(p1, $q$ select request_withdrawal(50,'Test Bank','T One','123')::text $q$);
  perform pg_temp.chk('Bad account number is refused', r like 'ERR:%', r);
  r := pg_temp.q(p1, 'with x as (update withdrawals set status=''paid'' returning 1) select count(*)::text from x');
  perform pg_temp.chk('Participant cannot mark own withdrawal as paid', r like 'ERR:%' or r='0', r);

  ------------------------------------------------ PRIVACY BETWEEN ROLES
  perform pg_temp.chk('Another participant cannot see a submission', pg_temp.q(p2, format('select count(*)::text from submissions where id=%L',sid))='0', '');
  perform pg_temp.chk('Business cannot read participant profiles', pg_temp.q(biz, format('select count(*)::text from profiles where id=%L',p1))='0', '');
  perform pg_temp.chk('Participant cannot read business projects directly', pg_temp.q(p1, format('select count(*)::text from campaigns where id=%L',cid))='0', '');
  perform pg_temp.chk('Business cannot see tester reward amounts', pg_temp.q(biz, format('select count(*)::text from tasks where campaign_id=%L',cid))='0', '');
  perform pg_temp.chk('Business cannot read the price list', pg_temp.q(biz, 'select count(*)::text from rates')='0', '');
  perform pg_temp.chk('Participant cannot read admin settings', pg_temp.q(p1, 'select count(*)::text from settings')='0', '');
  perform pg_temp.chk('Participant cannot read the audit log', pg_temp.q(p1, 'select count(*)::text from audit_log')='0', '');
  r := pg_temp.q(p1, format('with x as (update profiles set role=''admin'' where id=%L returning 1) select count(*)::text from x',p1));
  perform pg_temp.chk('Nobody can make themselves admin', r like 'ERR:%', r);
  perform pg_temp.chk('Visitors who are not logged in see no profiles', pg_temp.q(null,'select count(*)::text from profiles') like 'ERR:%', pg_temp.q(null,'select count(*)::text from profiles'));
  perform pg_temp.chk('Visitors who are not logged in see no projects', pg_temp.q(null,'select count(*)::text from tasks_open') like 'ERR:%', pg_temp.q(null,'select count(*)::text from tasks_open'));

  ------------------------------------------------ MESSAGES AND SUSPENSION
  r := pg_temp.q(biz, format($q$ select post_message(%L::uuid,'Call me on 08012345678')::text $q$, cid));
  perform pg_temp.chk('Messages with phone numbers are refused', r like 'ERR:%', r);
  r := pg_temp.q(biz, format($q$ select post_message(%L::uuid,'Please send me a WhatsApp message')::text $q$, cid));
  perform pg_temp.chk('Messages pointing to other chat apps are refused', r like 'ERR:%', r);
  r := pg_temp.q(biz, format($q$ select post_message(%L::uuid,'Please finish by Friday, thank you.')::text $q$, cid));
  perform pg_temp.chk('A normal announcement is accepted', r not like 'ERR:%', r);
  r := pg_temp.q(p1, format($q$ select set_suspended(%L::uuid,true,'x')::text $q$, p2));
  perform pg_temp.chk('Only admin can suspend', r like 'ERR:%', r);
  r := pg_temp.q(adm, format($q$ select set_suspended(%L::uuid,true,'test')::text $q$, p2));
  perform pg_temp.chk('Admin can suspend an account', r not like 'ERR:%', r);
  r := pg_temp.q(p2, format($q$ select claim_task(%L::uuid,'quick')::text $q$, cid));
  perform pg_temp.chk('A suspended participant cannot take tasks', r like 'ERR:%', r);

  r := pg_temp.q(adm, format($q$ select set_suspended(%L::uuid,true,'test')::text $q$, biz));
  r := pg_temp.q(biz, format($q$ select post_message(%L::uuid,'Please finish by Friday, thank you.')::text $q$, cid));
  perform pg_temp.chk('A suspended business cannot send messages', r like 'ERR:%', r);
  r := pg_temp.q(biz, $q$ select create_campaign('Suspended project','App testing','Do it','','[{"q":"x","t":"text"}]'::jsonb,'Proof',20,false,7,'{}'::jsonb)::text $q$);
  perform pg_temp.chk('A suspended business cannot create projects', r like 'ERR:%', r);
  r := pg_temp.q(adm, format($q$ select set_suspended(%L::uuid,true,'test')::text $q$, p1));
  r := pg_temp.q(p1, $q$ select request_withdrawal(50,'Test Bank','T One','0123456789')::text $q$);
  perform pg_temp.chk('A suspended participant cannot withdraw', r like 'ERR:%', r);


  ------------------------------------------------ REFERRAL BONUS AND ADMIN OVERVIEW
  insert into auth.users(id,instance_id,aud,role,email,raw_user_meta_data,email_confirmed_at,created_at,updated_at) values
   (rf1,uidq::uuid,'authenticated','authenticated','t-rf1@example.test','{"role":"participant","full_name":"Ref One"}',now(),now(),now());
  insert into auth.users(id,instance_id,aud,role,email,raw_user_meta_data,email_confirmed_at,created_at,updated_at) values
   (rf2,uidq::uuid,'authenticated','authenticated','t-rf2@example.test',('{"role":"participant","full_name":"Ref Two","ref":"TB-'||upper((select referral_code from profiles where id=rf1))||'"}')::jsonb,now(),now(),now());
  perform pg_temp.chk('Invited friend is linked to the referrer', (select referred_by from profiles where id=rf2)=rf1, '');
  insert into ledger(participant_id,amount,kind) values(rf2, setting('referral_threshold')/2, 'reward');
  perform pg_temp.chk('No referral bonus below the earnings target', not exists(select 1 from ledger where participant_id=rf1 and kind='referral'), '');
  insert into ledger(participant_id,amount,kind) values(rf2, setting('referral_threshold'), 'reward');
  perform pg_temp.chk('Referral bonus is paid when the target is reached', (select count(*) from ledger where participant_id=rf1 and kind='referral')=1 and (select amount from ledger where participant_id=rf1 and kind='referral')=setting('referral_bonus'), '');
  insert into ledger(participant_id,amount,kind) values(rf2, 900, 'reward');
  perform pg_temp.chk('Referral bonus is paid only once per friend', (select count(*) from ledger where participant_id=rf1 and kind='referral')=1, '');
  perform pg_temp.chk('Referrer sees own referral counts', pg_temp.q(rf1, $q$ select (my_referrals()->>'invited') $q$)='1', pg_temp.q(rf1, $q$ select (my_referrals()->>'invited') $q$));
  r := pg_temp.q(p1, $q$ select admin_overview()::text $q$);
  perform pg_temp.chk('Participants cannot open the admin overview', r like 'ERR:%', r);
  r := pg_temp.q(adm, $q$ select admin_overview()::text $q$);
  perform pg_temp.chk('Admin can open the overview', r not like 'ERR:%', left(r,120));


  ------------------------------------------------ PAYMENTS
  r := pg_temp.q(biz, $q$ select create_campaign('Pay test','App testing','Do it','','[{"q":"x","t":"text"}]'::jsonb,'Proof',20,false,7,'{}'::jsonb)::text $q$);
  perform pg_temp.chk('Business can create the project to be paid', r not like 'ERR:%', r);
  if r like 'ERR:%' then raise exception E'TEST REPORT (stopped early)\n%', pg_temp.report(); end if;
  cid2 := r::uuid; select round(budget*100) into kb from campaigns where id=cid2;
  insert into payments(reference,campaign_id,business_id,amount_kobo) values ('T-OK',cid2,biz,kb),('T-BAD',cid2,biz,kb),('T-DUP',cid2,biz,kb);
  r := pg_temp.q(biz, format($q$ select mark_payment_paid('T-OK',%s,'NGN') $q$, kb));
  perform pg_temp.chk('A business cannot confirm its own payment', r like 'ERR:%', r);
  perform pg_temp.chk('A payment with the wrong amount is rejected', mark_payment_paid('T-BAD', kb-100, 'NGN')='mismatch', '');
  perform pg_temp.chk('A wrong-amount payment does not fund the project', not (select funded from campaigns where id=cid2), '');
  perform pg_temp.chk('A payment in the wrong currency is rejected', mark_payment_paid('T-OK', kb, 'USD')='mismatch', '');
  update payments set status='pending' where reference='T-OK';
  perform pg_temp.chk('The correct payment funds the project', mark_payment_paid('T-OK', kb, 'NGN')='paid' and (select funded from campaigns where id=cid2), '');
  perform pg_temp.chk('Confirming the same payment twice changes nothing', mark_payment_paid('T-OK', kb, 'NGN')='already', '');
  perform pg_temp.chk('A second payment for a funded project is flagged as a duplicate', mark_payment_paid('T-DUP', kb, 'NGN')='duplicate', '');
  perform pg_temp.chk('Another business cannot see this payment', pg_temp.q(p1, 'select count(*)::text from payments')='0', '');
  perform pg_temp.chk('Visitors who are not logged in see no payments', pg_temp.q(null,'select count(*)::text from payments') like 'ERR:%', '');

  raise exception E'TEST REPORT (all test data was rolled back)\n%', pg_temp.report();
end $t$;
