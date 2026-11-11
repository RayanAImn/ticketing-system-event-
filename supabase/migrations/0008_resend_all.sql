-- "Email all" on the event page, for a database that already ran 0001-0007
-- (already in 0001 for new setups). Emails every active guest who has an email
-- their ticket again, the same as pressing Resend email on each row. Only adds
-- this site's own function. Run once in the Supabase SQL editor.

create or replace function public.invite_resend_all_emails(p_event_id uuid)
returns int
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_id uuid;
  v_n  int := 0;
begin
  if p_event_id is null then raise exception 'event_not_found'; end if;
  perform public.invite_require_event(p_event_id);
  for v_id in
    select t.id from public.tickets t
    join public.events e on e.id = t.event_id and e.invite_managed
    where t.event_id = p_event_id and t.status = 'active'
      and t.guest_name is not null and t.guest_email is not null
    order by t.created_at
  loop
    perform public.invite_queue_email(v_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.invite_resend_all_emails(uuid) from public, anon;
grant execute on function public.invite_resend_all_emails(uuid) to authenticated;
