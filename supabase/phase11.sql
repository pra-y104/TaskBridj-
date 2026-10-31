-- Phase 11: adds a "newest" sort for tasks. Run after phase10.sql.
create or replace view tasks_open as
  select c.id as campaign_id, c.title, c.task_type, c.instructions, c.requirements, c.questions, c.evidence_required,
         t.tier, min(t.amount) as amount, count(*) as open_count, c.created_at
  from campaigns c join tasks t on t.campaign_id=c.id left join submissions s on s.task_id=t.id
  where c.status='active' and (c.deadline is null or c.deadline>now())
    and (t.claimed_by is null or (t.claimed_at < now()-make_interval(hours=>setting('claim_hours')::int) and s.id is null))
  group by c.id, t.tier;
grant select on tasks_open to authenticated;
