-- Bus counts are final once saved, for a database that already ran 0001-0012
-- (already in 0001 for new setups). invite_set_bus_count only saves a day that
-- has no count yet and refuses with 'bus_count_saved' otherwise, and
-- invite_event_attendance gains a 'saved' column so the page shows a saved count
-- as plain text. Only changes this site's own functions. Run once in the
-- Supabase SQL editor.

drop function if exists public.invite_event_attendance(uuid);

create or replace function public.invite_event_attendance(p_event_id uuid)
returns table (
  day       date,
  scanned   bigint,
  bus_count integer,
  total     bigint,
  saved     boolean
)
language plpgsql
stable
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_event(p_event_id);
  if not exists (select 1 from public.events e where e.id = p_event_id and e.invite_managed) then
    raise exception 'event_not_found';
  end if;
  return query
  with scans as (
    select (s.scanned_at at time zone 'Asia/Riyadh')::date as d, count(distinct s.ticket_id) as n
    from public.ticket_scans s
    join public.tickets t on t.id = s.ticket_id
    where t.event_id = p_event_id
      and s.scan_status in ('ticket_redeemed', 'ticket_already_redeemed')
    group by 1
  ), days as (
    select x as d from public.invite_event_days(p_event_id) x
    union select scans.d from scans
    union select c.day from public.invite_attendance_counts c where c.event_id = p_event_id
  )
  select days.d, coalesce(scans.n, 0), coalesce(c.bus_count, 0),
         coalesce(scans.n, 0) + coalesce(c.bus_count, 0), c.event_id is not null
  from days
  left join scans on scans.d = days.d
  left join public.invite_attendance_counts c on c.event_id = p_event_id and c.day = days.d
  order by 1;
end;
$$;

create or replace function public.invite_set_bus_count(p_event_id uuid, p_day date, p_count integer)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_event(p_event_id);
  if p_count is null or p_count < 0 then raise exception 'bad_count'; end if;
  if p_day is null or p_day not in (select public.invite_event_days(p_event_id)) then
    raise exception 'bad_day';
  end if;
  insert into public.invite_attendance_counts (event_id, day, bus_count, updated_by, updated_at)
  values (p_event_id, p_day, p_count, auth.uid(), now())
  on conflict (event_id, day) do nothing;
  if not found then raise exception 'bus_count_saved'; end if;
end;
$$;

revoke all on function public.invite_event_attendance(uuid) from public, anon;
grant execute on function public.invite_event_attendance(uuid) to authenticated;
