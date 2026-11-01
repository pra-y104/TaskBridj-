-- Phase 13 (safe to run again): full task catalogue (41 types in 6 groups), admin-managed. Run after phase12.sql. Keeps every existing task type.
alter table rates add column if not exists grp text not null default 'Other', add column if not exists description text,
  add column if not exists default_minutes int not null default 10, add column if not exists evidence_hint text,
  add column if not exists sort int not null default 1000, add column if not exists active boolean not null default true,
  add column if not exists quote_only boolean not null default false;

insert into rates(task_type,price,grp,description,default_minutes,evidence_hint,sort,quote_only) values
 ('App testing',600,'Testing & QA','Try a mobile or web app and report what works and what does not.',15,'Screenshots of the key screens you used',110,false),
 ('Website testing',450,'Testing & QA','Visit a website, complete a task and report any problems.',10,'Screenshot of the page you finished on',120,false),
 ('Usability test',600,'Testing & QA','Complete steps in a product and say what was confusing.',15,'Screenshot or screen recording of the steps',130,false),
 ('Prototype testing',600,'Testing & QA','Try an early version or design and give feedback.',15,'Screenshot or short recording',140,false),
 ('Bug report',800,'Testing & QA','Find a problem and describe the exact steps to repeat it.',20,'Screenshot or recording of the bug, plus numbered steps',150,false),
 ('Onboarding test',500,'Testing & QA','Sign up as a new user and describe the first-time experience.',10,'Screenshot of each onboarding step',160,false),
 ('Software testing',700,'Testing & QA','Test software features against a short checklist.',25,'Screenshots or recording for each checklist item',170,false),
 ('Cross-device testing',700,'Testing & QA','Check that a product works on your phone or computer.',15,'Screenshots showing your device and the result',180,false),
 ('Survey',200,'Research & Feedback','Answer a short survey honestly.',5,'Screenshot of the completion page',210,false),
 ('Market research',250,'Research & Feedback','Answer questions about products, brands or buying habits.',10,'Screenshot of the completion page',220,false),
 ('Product feedback',250,'Research & Feedback','Use a product and give honest opinions.',10,'Screenshot showing you used the product',230,false),
 ('Short interview',1500,'Research & Feedback','Answer interview questions by voice or video.',20,'Audio or video recording of your answers',240,false),
 ('Consumer research',300,'Research & Feedback','Share how you shop, choose and use products.',10,'Screenshot of the completion page',250,false),
 ('Competitor research',400,'Research & Feedback','Compare named products, services or websites.',20,'Screenshots of each item you compared',260,false),
 ('Focus group',1000,'Research & Feedback','Join a group discussion about a product or service.',45,'Attendance confirmation',270,true),
 ('Product trial',1000,'Research & Feedback','Try a product and report on it over time.',30,'Photos or a recording of your use',280,true),
 ('Language & content review',300,'Content & Language','Check wording, grammar and clarity.',10,'Screenshot or a marked-up copy',310,false),
 ('Translation testing',350,'Content & Language','Check that translated text is correct and natural.',15,'A list of the errors you found',320,false),
 ('Content evaluation',300,'Content & Language','Review articles, videos or posts and rate them.',10,'Screenshot of what you reviewed',330,false),
 ('Advertisement testing',350,'Content & Language','Watch or read an advert and say how clear and convincing it is.',10,'Screenshot of the advert you saw',340,false),
 ('Proofreading',300,'Content & Language','Find spelling and grammar mistakes in a text.',15,'A list of the corrections',350,false),
 ('Video and image review',350,'Content & Language','Look at media and answer questions about it.',10,'Screenshot of the item you reviewed',360,false),
 ('Data collection',300,'Data & AI','Collect specified information from approved sources.',20,'Screenshots of the sources',410,false),
 ('Data annotation',200,'Data & AI','Label items such as text or images by following the guide.',15,'Screenshot of your finished labels',420,false),
 ('Data verification',250,'Data & AI','Check whether supplied information is accurate.',10,'Screenshot of the source you checked',430,false),
 ('AI testing',500,'Data & AI','Try an AI tool and rate how well it works.',15,'Screenshot of your conversation',440,false),
 ('AI response evaluation',400,'Data & AI','Read AI answers and rate them for accuracy and quality.',15,'Screenshot of the answers you rated',450,false),
 ('Voice recording',500,'Data & AI','Record the words or sentences you are given.',10,'Audio file of your recording',460,false),
 ('Audio transcription',600,'Data & AI','Listen to audio and type what is said.',20,'Your typed transcript',470,false),
 ('Image classification',150,'Data & AI','Sort images into the categories you are given.',10,'Screenshot of your finished sorting',480,false),
 ('Advertisement feedback',300,'Marketing & Promotion','Give honest feedback on a draft advert.',10,'Screenshot of the advert you reviewed',510,false),
 ('Influencer research',400,'Marketing & Promotion','Answer questions about creators and what you follow.',10,'Screenshot of the completion page',520,false),
 ('Voluntary content sharing',1000,'Marketing & Promotion','Share genuine content about a product with a clear sponsorship note.',15,'Link and screenshot of your post',530,true),
 ('Creator campaign',1000,'Marketing & Promotion','Create content for a brand, following platform rules.',60,'Link to your published content',540,true),
 ('Product awareness campaign',1000,'Marketing & Promotion','Help people learn about a product honestly.',30,'Link and screenshot of your post',550,true),
 ('Content exposure campaign',1000,'Marketing & Promotion','Share content with real audiences, with no paid likes, follows or views.',30,'Link and screenshot of your post',560,true),
 ('Professional interview',1000,'Professional & Specialist','Interview with a qualified professional.',30,'Recording and notes',610,true),
 ('Expert review',1000,'Professional & Specialist','An expert reviews a product or document.',45,'Written review',620,true),
 ('Technical evaluation',1000,'Professional & Specialist','A technical assessment by a specialist.',60,'Written report',630,true),
 ('Industry research',1000,'Professional & Specialist','Research on a specific industry by someone with experience.',60,'Written findings and sources',640,true),
 ('Specialist consulting task',1000,'Professional & Specialist','A short consulting task for a qualified specialist.',60,'Written deliverable',650,true)
on conflict (task_type) do update set grp=excluded.grp, description=excluded.description, default_minutes=excluded.default_minutes,
  evidence_hint=excluded.evidence_hint, sort=excluded.sort, quote_only=excluded.quote_only;

create or replace function task_types() returns setof text language sql security definer stable set search_path=public as $$
  select task_type from rates where active order by sort, task_type $$;
create or replace function task_catalog() returns table(task_type text,grp text,description text,default_minutes int,evidence_hint text,quote_only boolean)
language sql security definer stable set search_path=public as $$
  select task_type,grp,description,default_minutes,evidence_hint,quote_only from rates where active order by sort, task_type $$;
revoke execute on function task_catalog() from public, anon;
grant execute on function task_catalog() to authenticated;

create or replace function quote_campaign(p_type text,p_count int,p_rec boolean) returns json language sql stable security definer set search_path=public as $$
  select case when r.quote_only then json_build_object('custom',true)
    else json_build_object('custom',false,'discount',discount_pct(x.c),'total',round(x.c*(r.price+case when p_rec then setting('recording_extra') else 0 end)*(1-discount_pct(x.c)))) end
  from rates r, (select coalesce(p_count,0) as c) x where r.task_type=p_type and r.active $$;

create or replace function create_campaign(p_title text,p_type text,p_ins text,p_req text,p_q jsonb,p_ev text,p_count int,p_rec boolean,p_days int,p_extra jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path=public as $$
declare cid uuid; per numeric; cq boolean; act boolean; lst numeric; budget numeric; pool numeric; q int; s int; d int; rest numeric;
        ctry text[]; dev text; ex text; mins int; lnk text; dsc text; sdays int; e jsonb; sat timestamptz;
begin
  if my_role()<>'business' then raise exception 'Only businesses can create projects'; end if;
  if coalesce(trim(p_title),'')='' or coalesce(trim(p_ins),'')='' or coalesce(trim(p_ev),'')='' then raise exception 'Fill in all required fields'; end if;
  if jsonb_typeof(p_q)<>'array' or jsonb_array_length(p_q) not between 1 and 20 then raise exception 'Add between 1 and 20 questions'; end if;
  for e in select value from jsonb_array_elements(p_q) loop
    if jsonb_typeof(e)='string' then
      if length(e#>>'{}')>300 then raise exception 'A question is too long'; end if;
    elsif jsonb_typeof(e)='object' then
      if length(coalesce(e->>'q',''))<2 or length(e->>'q')>300 or coalesce(e->>'t','text') not in ('text','long','yesno','rating','choice') then raise exception 'Invalid question'; end if;
      if e->>'t'='choice' and jsonb_array_length(coalesce(e->'o','[]'::jsonb))<2 then raise exception 'Multiple-choice questions need at least 2 options'; end if;
    else raise exception 'Invalid question'; end if;
  end loop;
  if p_count is null or p_count<10 then raise exception 'Choose at least 10 participants'; end if;
  if p_count>10000 then raise exception 'For more than 10000 participants, please request a custom quote'; end if;
  if p_days is null or p_days<3 or p_days>90 then raise exception 'Choose a deadline between 3 and 90 days'; end if;
  ctry := coalesce((select array_agg(lower(trim(x))) from jsonb_array_elements_text(coalesce(p_extra->'countries','[]'::jsonb)) x),'{}');
  if coalesce(array_length(ctry,1),0)>10 then raise exception 'Too many countries'; end if;
  dev := coalesce(p_extra->>'device','Any'); if dev not in ('Any','Android','iPhone','Desktop') then raise exception 'Invalid device'; end if;
  ex := coalesce(p_extra->>'experience','Any'); if ex not in ('Any','Experienced') then raise exception 'Invalid experience level'; end if;
  mins := coalesce((p_extra->>'minutes')::int,10); if mins<1 or mins>240 then raise exception 'Completion time must be 1 to 240 minutes'; end if;
  lnk := nullif(trim(coalesce(p_extra->>'link','')),''); if lnk is not null and lnk !~ '^https?://[^[:space:]]+$' then raise exception 'Enter a valid link starting with http'; end if;
  dsc := left(coalesce(p_extra->>'description',''),2000);
  sdays := coalesce((p_extra->>'start_days')::int,0); if sdays<0 or sdays>30 then raise exception 'Invalid start date'; end if;
  select price, quote_only, active into per, cq, act from rates where task_type=p_type;
  if act is not true then raise exception 'This task type is not available'; end if;
  if cq then raise exception 'This task type needs a custom quote. Please request one.'; end if;
  if p_rec then per := per + setting('recording_extra'); end if;
  lst := p_count*per; budget := round(lst*(1-discount_pct(p_count))); pool := floor(lst*setting('tester_share'));
  if budget-pool < budget*0.25 then raise exception 'Please request a custom quote for this order'; end if;
  q := floor(pool*0.5/100); s := floor(pool*0.3/300); d := floor(pool*0.2/1000);
  rest := pool - q*100 - s*300 - d*1000; q := q + floor(rest/100);
  sat := now()+make_interval(days=>sdays);
  insert into campaigns(business_id,title,task_type,instructions,requirements,questions,evidence_required,slots,budget,participants,deadline,
                        description,countries,device,experience,est_minutes,reference_link,start_at)
    values(auth.uid(),p_title,p_type,p_ins,p_req,p_q,p_ev,q+s+d,budget,p_count,sat+make_interval(days=>p_days),dsc,ctry,dev,ex,mins,lnk,sat) returning id into cid;
  insert into tasks(campaign_id,tier,amount)
    select cid,'quick',100 from generate_series(1,q) union all
    select cid,'standard',300 from generate_series(1,s) union all
    select cid,'detailed',1000 from generate_series(1,d);
  return cid;
end $$;

revoke execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean,int,jsonb) from public, anon;
grant execute on function create_campaign(text,text,text,text,jsonb,text,int,boolean,int,jsonb) to authenticated;
revoke execute on function quote_campaign(text,int,boolean) from public, anon;
grant execute on function quote_campaign(text,int,boolean) to authenticated;
