-- Phase 17: suspended accounts are blocked from every money or project action. Run after phase16.sql. Safe to run again.
create or replace function guard_active() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is not null and exists(select 1 from profiles where id=auth.uid() and suspended) then
    raise exception 'Your account is suspended. Contact support from the Help page.';
  end if;
  return new;
end $$;
revoke execute on function guard_active() from public, anon, authenticated;

drop trigger if exists guard_active_t on campaigns;        create trigger guard_active_t before insert or update on campaigns        for each row execute function guard_active();
drop trigger if exists guard_active_t on tasks;            create trigger guard_active_t before insert or update on tasks            for each row execute function guard_active();
drop trigger if exists guard_active_t on submissions;      create trigger guard_active_t before insert or update on submissions      for each row execute function guard_active();
drop trigger if exists guard_active_t on ledger;           create trigger guard_active_t before insert or update on ledger           for each row execute function guard_active();
drop trigger if exists guard_active_t on withdrawals;      create trigger guard_active_t before insert or update on withdrawals      for each row execute function guard_active();
drop trigger if exists guard_active_t on refund_requests;  create trigger guard_active_t before insert or update on refund_requests  for each row execute function guard_active();
drop trigger if exists guard_active_t on project_messages; create trigger guard_active_t before insert or update on project_messages for each row execute function guard_active();
drop trigger if exists guard_active_t on quote_requests;   create trigger guard_active_t before insert or update on quote_requests   for each row execute function guard_active();
drop trigger if exists guard_active_t on appeals;          create trigger guard_active_t before insert or update on appeals          for each row execute function guard_active();
