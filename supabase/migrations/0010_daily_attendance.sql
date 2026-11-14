-- Daily attendance, for a database that already ran 0001-0009 (already in 0001
-- for new setups). A ticket now checks in once per day (Asia/Riyadh): on a later
-- day of the event the same QR checks in again instead of "already used".
-- tickets.redeemed_at keeps the first check-in. Organisers also enter, for each
-- day, how many people came without being scanned (by bus); this still works
-- after the event has ended. Only adds this site's own table and functions and
-- changes invite_scan_ticket. Run once in the Supabase SQL editor.

create table if not exists public.invite_attendance_counts (
  event_id   uuid not null references public.events (id) on delete cascade,
  day        date not null,
  bus_count  integer not null check (bus_count >= 0),
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (event_id, day)
);
alter table public.invite_attendance_counts enable row level security;
revoke all on table public.invite_attendance_counts from anon, authenticated;

-- The calendar days (Riyadh) from an event's start to its end.
create or replace function public.invite_event_days(p_event_id uuid)
returns setof date
language sql
stable
security definer
set search_path to ''
as $$
  select d::date
  from public.events e,
       generate_series((e.starts_at at time zone 'Asia/Riyadh')::date,
                       (coalesce(e.ends_at, e.starts_at) at time zone 'Asia/Riyadh')::date,
                       interval '1 day') d
  where e.id = p_event_id and e.invite_managed;
$$;

-- One row per event day: different tickets scanned in that day, the bus count
-- entered for it, and the two added up.
create or replace function public.invite_event_attendance(p_event_id uuid)
returns table (
  day       date,
  scanned   bigint,
  bus_count integer,
  total     bigint
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
         coalesce(scans.n, 0) + coalesce(c.bus_count, 0)
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
  on conflict (event_id, day) do update
    set bus_count = excluded.bus_count, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$$;

create or replace function public.invite_scan_ticket(p_qr_token text, p_event_id uuid default null)
returns table (
  status      text,
  ticket_id   uuid,
  guest_name  text,
  staff_id    text,
  note        text,
  redeemed_at timestamptz,
  scanned_at  timestamptz
)
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
#variable_conflict use_column
declare
  v_scanner_id uuid := auth.uid();
  v_ticket     public.tickets;
  v_status     text;
  v_now        timestamptz := now();
  v_today      date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if v_scanner_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if public.invite_staff_role() is null then
    raise exception 'not_scanner' using errcode = '42501';
  end if;

  select t.* into v_ticket
  from public.tickets t
  join public.events e on e.id = t.event_id and e.invite_managed
  where t.qr_token = trim(p_qr_token)
  for update of t;

  if v_ticket.id is null then
    return query select 'invalid_ticket'::text, null::uuid, null::text, null::text, null::text, null::timestamptz, v_now;
    return;
  end if;

  if (p_event_id is not null and v_ticket.event_id is distinct from p_event_id)
     or not public.invite_event_allowed(v_ticket.event_id) then
    v_status := 'wrong_event';
  elsif v_ticket.status = 'cancelled' then
    v_status := 'ticket_cancelled';
  elsif (v_ticket.redeemed_at at time zone 'Asia/Riyadh')::date = v_today
        or exists (select 1 from public.ticket_scans s
                   where s.ticket_id = v_ticket.id and s.scan_status = 'ticket_redeemed'
                     and (s.scanned_at at time zone 'Asia/Riyadh')::date = v_today) then
    v_status := 'ticket_already_redeemed';
  elsif v_ticket.status = 'expired' or public.invite_event_closed(v_ticket.event_id) then
    v_status := 'ticket_expired';
  elsif v_ticket.status = 'redeemed' or v_ticket.redeemed_at is not null then
    -- Checked in on an earlier day: in again today, first check-in kept.
    v_status := 'ticket_redeemed';
  else
    update public.tickets
       set status = 'redeemed', redeemed_at = v_now, redeemed_by = v_scanner_id
     where id = v_ticket.id;
    v_status := 'ticket_redeemed';
    v_ticket.redeemed_at := v_now;
  end if;

  insert into public.ticket_scans (ticket_id, scanned_by, scan_status, scanned_at)
  values (v_ticket.id, v_scanner_id, v_status, v_now);

  return query select v_status, v_ticket.id, coalesce(v_ticket.guest_name, v_ticket.title),
                      v_ticket.guest_staff_id, v_ticket.guest_note, v_ticket.redeemed_at, v_now;
end;
$$;

revoke all on function public.invite_event_days(uuid)                    from public, anon, authenticated;
revoke all on function public.invite_event_attendance(uuid)              from public, anon;
revoke all on function public.invite_set_bus_count(uuid, date, integer)  from public, anon;
grant execute on function public.invite_event_attendance(uuid)             to authenticated;
grant execute on function public.invite_set_bus_count(uuid, date, integer) to authenticated;
