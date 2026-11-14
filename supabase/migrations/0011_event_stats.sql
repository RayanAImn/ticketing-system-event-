-- Statistics card on the event page, for a database that already ran 0001-0010
-- (already in 0001 for new setups). Read only: guests going, guests scanned on at
-- least one day, guests scanned on every day of the event, the bus counts added
-- up, and each day's busiest hour (Asia/Riyadh). Only adds this site's own
-- function. Run once in the Supabase SQL editor.

create or replace function public.invite_event_stats(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_stats jsonb;
begin
  perform public.invite_require_event(p_event_id);
  if not exists (select 1 from public.events e where e.id = p_event_id and e.invite_managed) then
    raise exception 'event_not_found';
  end if;
  with live as (
    select t.id from public.tickets t
    where t.event_id = p_event_id and t.guest_name is not null and t.status <> 'cancelled'
  ), sc as (
    -- Each guest once per day, at their first scan that day.
    select s.ticket_id, (s.scanned_at at time zone 'Asia/Riyadh')::date as d,
           min(s.scanned_at at time zone 'Asia/Riyadh') as first_at
    from public.ticket_scans s
    join live on live.id = s.ticket_id
    where s.scan_status in ('ticket_redeemed', 'ticket_already_redeemed')
    group by 1, 2
  ), per_ticket as (
    select sc.ticket_id, count(*) as days from sc group by 1
  ), hours as (
    select sc.d, extract(hour from sc.first_at)::int as h, count(*) as n,
           row_number() over (partition by sc.d order by count(*) desc, extract(hour from sc.first_at)) as rk
    from sc group by sc.d, extract(hour from sc.first_at)
  ), ev as (
    select count(*) as days from public.invite_event_days(p_event_id)
  )
  select jsonb_build_object(
    'going',      (select count(*) from live),
    'scanned',    (select count(*) from per_ticket),
    'event_days', (select days from ev),
    'every_day',  (select count(*) from per_ticket where per_ticket.days >= (select days from ev)),
    'bus',        (select coalesce(sum(c.bus_count), 0) from public.invite_attendance_counts c where c.event_id = p_event_id),
    'busiest',    coalesce((select jsonb_agg(jsonb_build_object('day', hours.d, 'hour', hours.h, 'count', hours.n) order by hours.d)
                            from hours where hours.rk = 1), '[]'::jsonb)
  ) into v_stats;
  return v_stats;
end;
$$;

revoke all on function public.invite_event_stats(uuid) from public, anon;
grant execute on function public.invite_event_stats(uuid) to authenticated;
