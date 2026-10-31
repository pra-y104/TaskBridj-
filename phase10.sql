-- Phase 10: audit log. Run after phase9.sql. Adds only; deletes no data.
create table if not exists audit_log(
  id bigint generated always as identity primary key,
  actor uuid, action text not null, table_name text not null, row_id text, detail jsonb,
  created_at timestamptz not null default now());
alter table audit_log enable row level security;
create policy au_read on audit_log for select to authenticated using (is_admin());
grant select on audit_log to authenticated;

create function log_change() returns trigger language plpgsql security definer set search_path=public as $$
declare o jsonb := case when TG_OP<>'INSERT' then to_jsonb(OLD) end; n jsonb := case when TG_OP<>'DELETE' then to_jsonb(NEW) end;
        strip text[] := array['account_number','account_name','bank_name','answers','questions','instructions','requirements'];
begin
  insert into audit_log(actor,action,table_name,row_id,detail)
  values(auth.uid(),TG_OP,TG_TABLE_NAME,coalesce(n->>'id',o->>'id',n->>'key',o->>'key',n->>'task_type',o->>'task_type',n->>'min_count',o->>'min_count'),
         jsonb_build_object('old',o - strip,'new',n - strip));
  return coalesce(NEW,OLD);
end $$;
revoke execute on function log_change() from public, anon, authenticated;

create trigger audit_settings after insert or update or delete on settings for each row execute function log_change();
create trigger audit_rates after insert or update or delete on rates for each row execute function log_change();
create trigger audit_discounts after insert or update or delete on discounts for each row execute function log_change();
create trigger audit_withdrawals after update on withdrawals for each row execute function log_change();
create trigger audit_refunds after update on refund_requests for each row execute function log_change();
create trigger audit_appeals after update on appeals for each row execute function log_change();
create trigger audit_ledger after insert on ledger for each row execute function log_change();
create trigger audit_campaigns after update on campaigns for each row when (old.status is distinct from new.status or old.funded is distinct from new.funded) execute function log_change();
create trigger audit_submissions after update on submissions for each row when (old.status is distinct from new.status) execute function log_change();
create trigger audit_roles after update on profiles for each row when (old.role is distinct from new.role) execute function log_change();
