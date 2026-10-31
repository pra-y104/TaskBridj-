-- Phase 13: full task catalogue with groups, descriptions, ordering, custom-quote types. Run after phase12.sql. Keeps all existing types and prices.
alter table rates add column if not exists grp text not null default 'Other', add column if not exists sort int not null default 1000,
  add column if not exists active boolean not null default true, add column if not exists description text,
  add column if not exists default_minutes int, add column if not exists evidence_hint text, add column if not exists quote_only boolean not null default false;

insert into rates(task_type,price,grp,sort,description,default_minutes,evidence_hint,quote_only) values
('App testing',600,'Testing & Quality',110,'Try a mobile or desktop app and report what works and what does not.',15,'Screenshots or a screen recording of each step',false),
('Website testing',450,'Testing & Quality',120,'Use a website the way a normal visitor would and report problems.',15,'Screenshots of the pages you visited',false),
('Usability test',600,'Testing & Quality',130,'Complete set tasks and say how easy or confusing they were.',20,'Screenshots or a screen recording',false),
('Prototype testing',600,'Testing & Quality',140,'Try an early design or prototype and give honest feedback.',20,'Screenshots of each screen you tried',false),
('Bug report',800,'Testing & Quality',150,'Find a problem and describe exactly how to repeat it.',20,'Steps to repeat the bug, plus a screenshot or recording',false),
('Onboarding test',500,'Testing & Quality',160,'Go through sign-up and first use as a new user.',10,'Screenshots of each onboarding step',false),
('Software testing',700,'Testing & Quality',170,'Test software features against a checklist.',25,'Screenshots or recording for each checklist item',false),
('Cross-device testing',750,'Testing & Quality',180,'Check that a product works on your phone, browser or computer.',25,'Screenshots that show your device and browser',false),
('Survey',200,'Research & Feedback',210,'Answer a short set of questions honestly.',5,'Your answers (a screenshot of the completed survey if asked)',false),
('Market research',250,'Research & Feedback',220,'Share opinions about products, prices and brands.',10,'Your answers',false),
('Product feedback',250,'Research & Feedback',230,'Try a product and tell the business what you think.',10,'Your answers and a screenshot',false),
('Consumer research',300,'Research & Feedback',240,'Answer questions about how you shop and what you buy.',10,'Your answers',false),
('Competitor research',450,'Research & Feedback',250,'Compare given products, services or websites.',20,'Notes plus screenshots from each one',false),
('Short interview',1500,'Research & Feedback',260,'Answer interview questions by audio or video.',15,'Audio or video recording',false),
('Focus group',1000,'Research & Feedback',270,'Join a group discussion about a product or service. Priced by custom quote.',45,'Attendance proof set by the business',true),
('Product trial',1000,'Research & Feedback',280,'Try a product over time and report back. Priced by custom quote.',60,'Photos or notes set by the business',true),
('Language & content review',300,'Content & Language',310,'Read content and check the language, tone and accuracy.',10,'Your corrections or ratings',false),
('Translation testing',350,'Content & Language',320,'Check that translated text is correct and natural.',15,'Your corrections',false),
('Advertisement testing',400,'Content & Language',330,'Look at an advert and say how clear and convincing it is.',10,'Your answers',false),
('Proofreading',300,'Content & Language',340,'Find spelling and grammar mistakes.',15,'List of the mistakes you found',false),
('Video and image review',300,'Content & Language',350,'Look at media and answer questions about it.',10,'Your answers',false),
('Data collection',300,'Data & AI',410,'Collect specified information from approved sources.',15,'Screenshot or link for each item collected',false),
('Data annotation',200,'Data & AI',420,'Label items such as text or images using the instructions.',10,'Your labels in the answers',false),
('Data verification',250,'Data & AI',430,'Check whether supplied information is accurate.',10,'Screenshot of where you checked',false),
('AI testing',500,'Data & AI',440,'Try an AI tool and rate how it responds.',15,'Screenshots of the conversation',false),
('AI response evaluation',400,'Data & AI',450,'Compare or score AI answers using given guidelines.',15,'Your scores and short reasons',false),
('Voice recording',400,'Data & AI',460,'Record the words or sentences you are given.',10,'Audio recording',false),
('Audio transcription',500,'Data & AI',470,'Listen to audio and type exactly what is said.',20,'Your typed transcript',false),
('Image classification',200,'Data & AI',480,'Sort images into the categories given.',10,'Your categories in the answers',false),
('Advertisement feedback',350,'Marketing & Promotion',510,'Give honest feedback on a campaign before it launches.',10,'Your answers',false),
('Influencer research',450,'Marketing & Promotion',520,'Review creators and say who fits a brand.',15,'Links and notes',false),
('Voluntary content sharing',1000,'Marketing & Promotion',530,'Share genuine opinions about a product with a clear sponsorship disclosure. No fake likes, follows or views. Priced by custom quote and reviewed first.',20,'Link to your post and a screenshot',true),
('Content exposure campaign',1000,'Marketing & Promotion',540,'Real people view and react to content. Reviewed first and priced by custom quote.',20,'Set by the business',true),
('Creator campaign',1000,'Marketing & Promotion',550,'Creators make content about a product. Priced by custom quote.',30,'Link to the content',true),
('Product awareness campaign',1000,'Marketing & Promotion',560,'Genuine awareness activity that follows platform rules. Priced by custom quote.',20,'Set by the business',true),
('Professional interview',1000,'Specialist',610,'Interview a qualified professional. Priced by custom quote.',30,'Recording or notes',true),
('Expert review',1000,'Specialist',620,'A qualified person reviews a product or document. Priced by custom quote.',45,'Written review',true),
('Technical evaluation',1000,'Specialist',630,'A technical person evaluates a system or product. Priced by custom quote.',60,'Written report',true),
('Industry research',1000,'Specialist',640,'Research a specific industry. Priced by custom quote.',60,'Written report',true),
('Specialist consulting task',1000,'Specialist',650,'A short consulting task by a specialist. Priced by custom quote.',60,'Written output',true)
on conflict (task_type) do update set grp=excluded.grp, sort=excluded.sort, description=excluded.description,
  default_minutes=excluded.default_minutes, evidence_hint=excluded.evidence_hint;

create or replace function task_types() returns setof text language sql security definer stable set search_path=public as $$ select task_type from rates where active order by sort, task_type $$;
create function task_catalog() returns table(task_type text, grp text, description text, default_minutes int, evidence_hint text, quote_only boolean)
language sql stable security definer set search_path=public as $$
  select task_type,grp,description,default_minutes,evidence_hint,quote_only from rates where active order by sort, task_type $$;
revoke execute on function task_catalog() from public, anon;
grant execute on function task_catalog() to authenticated;

create or replace function quote_campaign(p_type text,p_count int,p_rec boolean) returns json language sql stable security definer set search_path=public as $$
  select case when r.quote_only then json_build_object('custom',true)
    else json_build_object('discount',discount_pct(x.c),'total',round(x.c*(r.price+case when p_rec then setting('recording_extra') else 0 end)*(1-discount_pct(x.c)))) end
  from rates r, (select coalesce(p_count,0) as c) x where r.task_type=p_type and r.active $$;

-- projects can only be created for active, automatically priced types
create function chk_task_type() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from rates where task_type=new.task_type and (not active or quote_only)) then raise exception 'This task type needs a custom quote or is not available'; end if;
  return new;
end $$;
create trigger campaigns_task_type before insert on campaigns for each row execute function chk_task_type();
