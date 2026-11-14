-- Ended events' tickets are saved as expired, for a database that already ran
-- 0001-0011 (already in 0001 for new setups). Until now an ended event's active
-- tickets only read as expired on this site; the row kept status 'active', so
-- anything reading tickets directly (visit's admin dashboard, exports) still
-- showed them as active. A pg_cron job now writes status 'expired' every 5
-- minutes for this site's events whose end (or, without one, start) has passed.
-- Checked-in and cancelled tickets are left as they are. Only this site's events
-- are touched. Run once in the Supabase SQL editor.

create or replace function public.invite_expire_ended_tickets()
returns integer
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_count integer;
begin
  update public.tickets t
     set status = 'expired'
    from public.events e
   where e.id = t.event_id
     and e.invite_managed
     and coalesce(e.ends_at, e.starts_at) <= now()
     and t.status = 'active'
     and t.guest_name is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.invite_expire_ended_tickets() from public, anon, authenticated;

select public.invite_expire_ended_tickets();

-- Same name again replaces the job, so running this file twice is fine.
select cron.schedule('invite-expire-tickets', '*/5 * * * *', 'select public.invite_expire_ended_tickets()');
