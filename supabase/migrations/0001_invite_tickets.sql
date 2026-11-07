-- Invite-only guest tickets, stored in visit's own public.tickets table.
--
-- Guests have no app account: an admin issues a free ticket for a named guest and
-- sends the guest a personal link (/t/<link_token>). Staff scan the ticket's
-- existing qr_token at the gate.
--
-- Changes to existing visit objects (all additive except one):
--   * tickets.user_id becomes nullable. Every existing reader compares it to a
--     specific user (RLS "users read own tickets", mobile_tickets, per-user limits,
--     supplier/cancellation functions), so rows with a null user are never matched.
--     A check constraint still requires every row to have a user OR a guest name.
--   * tickets gains guest_name, guest_phone, guest_email, guest_note, link_token.
--   * a 'ticket_scanner' row in public.roles (data only).
-- Not touched: events, ticket_payments, every create_ticket_* / payment / scan
-- function, mobile_* views, Moyasar and Tamara.
--
-- The event is an ordinary visit event created in the visit admin dashboard with
-- status 'Draft' (mobile_events only shows 'Published', so the app never lists it),
-- booking_mode 'ticket' and no price.
--
-- Admins  = existing visit admins (public.is_admin(), table admin_users).
-- Scanners = users given the 'ticket_scanner' role in public.user_roles, or admins.
--
-- Run once in the Supabase SQL editor.

-- ---------------------------------------------------------------- tickets: guest columns

alter table public.tickets alter column user_id drop not null;

alter table public.tickets
  add column if not exists guest_name  text,
  add column if not exists guest_phone text,
  add column if not exists guest_email text,
  add column if not exists guest_note  text,
  add column if not exists link_token  text;

alter table public.tickets
  add constraint tickets_user_or_guest check (user_id is not null or guest_name is not null);

create unique index if not exists tickets_link_token_uidx
  on public.tickets (link_token) where link_token is not null;

-- ---------------------------------------------------------------- scanner role (data)

insert into public.roles (name, description)
values ('ticket_scanner', 'Can scan invite tickets at the gate')
on conflict (name) do nothing;

-- ---------------------------------------------------------------- staff role

-- 'admin' | 'scanner' | null for the signed-in user.
create or replace function public.invite_staff_role()
returns text
language sql
stable
security definer
set search_path to ''
as $$
  select case
    when public.is_admin() then 'admin'
    when exists (
      select 1 from public.user_roles ur
      join public.roles r on r.id = ur.role_id
      where ur.user_id = auth.uid() and r.name = 'ticket_scanner'
    ) then 'scanner'
  end;
$$;

-- ---------------------------------------------------------------- events usable for invites

-- Draft, free, ticket-mode visit events, with guest counts. Staff only.
create or replace function public.invite_list_events()
returns table (
  id          uuid,
  name        text,
  starts_at   timestamptz,
  venue       text,
  capacity    integer,
  invited     bigint,
  checked_in  bigint
)
language sql
stable
security definer
set search_path to ''
as $$
  select e.id,
         coalesce(et.title, e.slug),
         e.starts_at,
         e.venue,
         e.capacity,
         count(t.id) filter (where t.guest_name is not null and t.status <> 'cancelled'),
         count(t.id) filter (where t.guest_name is not null and t.status = 'redeemed')
  from public.events e
  left join public.event_translations et on et.event_id = e.id and et.locale = 'en'
  left join public.tickets t on t.event_id = e.id
  where public.invite_staff_role() is not null
    and e.status = 'Draft'
    and e.booking_mode = 'ticket'
    and coalesce(e.price_from, 0) = 0
  group by e.id, et.title
  order by e.created_at desc;
$$;

-- ---------------------------------------------------------------- admin: guest tickets

create or replace function public.invite_list_tickets(p_event_id uuid)
returns table (
  id          uuid,
  guest_name  text,
  guest_phone text,
  guest_email text,
  guest_note  text,
  link_token  text,
  status      text,
  redeemed_at timestamptz,
  created_at  timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
  return query
  select t.id, t.guest_name, t.guest_phone, t.guest_email, t.guest_note, t.link_token,
         t.status, t.redeemed_at, t.created_at
  from public.tickets t
  where t.event_id = p_event_id and t.guest_name is not null
  order by t.created_at desc;
end;
$$;

-- p_guests: [{"name": "...", "phone": "...", "email": "...", "note": "..."}, ...]
-- Same event rules as create_ticket_for_event (ticket mode, free, capacity), with the
-- ticket owned by a named guest instead of the caller.
create or replace function public.invite_create_tickets(p_event_id uuid, p_guests jsonb)
returns integer
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_title    text;
  v_mode     text;
  v_status   text;
  v_price    numeric;
  v_capacity integer;
  v_sold     integer;
  v_count    integer;
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
  if jsonb_typeof(p_guests) <> 'array' or jsonb_array_length(p_guests) = 0 then
    raise exception 'no_guests';
  end if;
  if jsonb_array_length(p_guests) > 2000 then
    raise exception 'too_many_guests';
  end if;

  perform 1 from public.events where id = p_event_id for update;

  select e.booking_mode, e.status, e.price_from, e.capacity, coalesce(et.title, e.slug)
    into v_mode, v_status, v_price, v_capacity, v_title
  from public.events e
  left join public.event_translations et on et.event_id = e.id and et.locale = 'en'
  where e.id = p_event_id;

  if v_title is null then raise exception 'event_not_found'; end if;
  if v_mode <> 'ticket' then raise exception 'event_not_ticketed'; end if;
  if coalesce(v_price, 0) > 0 then raise exception 'event_requires_payment'; end if;
  if v_status <> 'Draft' then raise exception 'event_not_draft'; end if;

  select count(*) into v_count
  from jsonb_array_elements(p_guests) g
  where length(trim(coalesce(g->>'name', ''))) > 0;

  if v_capacity is not null then
    select count(*) into v_sold
    from public.tickets
    where event_id = p_event_id and status <> 'cancelled';
    if v_sold + v_count > v_capacity then raise exception 'event_sold_out'; end if;
  end if;

  insert into public.tickets
    (user_id, event_id, title, guest_name, guest_phone, guest_email, guest_note, link_token)
  select null, p_event_id, v_title,
         trim(g->>'name'),
         nullif(trim(g->>'phone'), ''),
         nullif(trim(g->>'email'), ''),
         nullif(trim(g->>'note'), ''),
         encode(extensions.gen_random_bytes(24), 'hex')
  from jsonb_array_elements(p_guests) g
  where length(trim(coalesce(g->>'name', ''))) > 0;

  return v_count;
end;
$$;

create or replace function public.invite_cancel_ticket(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
  update public.tickets set status = 'cancelled'
  where id = p_ticket_id and guest_name is not null and status = 'active';
  if not found then raise exception 'ticket_not_active'; end if;
end;
$$;

-- For a link sent to the wrong person: the old link and the old QR stop working.
create or replace function public.invite_regenerate_link(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  if not public.is_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
  update public.tickets
     set link_token = encode(extensions.gen_random_bytes(24), 'hex'),
         qr_token   = encode(extensions.gen_random_bytes(32), 'hex')
   where id = p_ticket_id and guest_name is not null and status = 'active';
  if not found then raise exception 'ticket_not_active'; end if;
end;
$$;

-- ---------------------------------------------------------------- guest: open ticket by link

create or replace function public.invite_get_ticket(p_link_token text)
returns table (
  guest_name    text,
  status        text,
  qr_token      text,
  redeemed_at   timestamptz,
  event_name    text,
  event_name_ar text,
  venue         text,
  venue_ar      text,
  starts_at     timestamptz,
  ends_at       timestamptz
)
language sql
stable
security definer
set search_path to ''
set row_security to 'off'
as $$
  select t.guest_name,
         t.status,
         case when t.status = 'cancelled' then null else t.qr_token end,
         t.redeemed_at,
         coalesce(en.title, e.slug),
         ar.title,
         e.venue,
         null::text,
         e.starts_at,
         e.ends_at
  from public.tickets t
  join public.events e on e.id = t.event_id
  left join public.event_translations en on en.event_id = e.id and en.locale = 'en'
  left join public.event_translations ar on ar.event_id = e.id and ar.locale = 'ar'
  where t.link_token = p_link_token
    and length(p_link_token) >= 32;
$$;

-- ---------------------------------------------------------------- scanner

-- Same outcome codes as scan_ticket_qr and logs to the same ticket_scans table,
-- but checks the staff role on the server and returns the guest's name.
-- (scan_ticket_qr and the visit dashboard's /admin/scan also work on these tickets.)
create or replace function public.invite_scan_ticket(p_qr_token text, p_event_id uuid default null)
returns table (
  status      text,
  ticket_id   uuid,
  guest_name  text,
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
begin
  if v_scanner_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if public.invite_staff_role() is null then
    raise exception 'not_scanner' using errcode = '42501';
  end if;

  select * into v_ticket from public.tickets t where t.qr_token = trim(p_qr_token) for update;

  if v_ticket.id is null then
    return query select 'invalid_ticket'::text, null::uuid, null::text, null::text, null::timestamptz, v_now;
    return;
  end if;

  if p_event_id is not null and v_ticket.event_id is distinct from p_event_id then
    v_status := 'wrong_event';
  elsif v_ticket.status = 'cancelled' then
    v_status := 'ticket_cancelled';
  elsif v_ticket.status = 'redeemed' or v_ticket.redeemed_at is not null then
    v_status := 'ticket_already_redeemed';
  elsif v_ticket.status = 'expired' then
    v_status := 'ticket_expired';
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
                      v_ticket.guest_note, v_ticket.redeemed_at, v_now;
end;
$$;

-- ---------------------------------------------------------------- grants

revoke all on function public.invite_staff_role()                   from public, anon;
revoke all on function public.invite_list_events()                  from public, anon;
revoke all on function public.invite_list_tickets(uuid)             from public, anon;
revoke all on function public.invite_create_tickets(uuid, jsonb)    from public, anon;
revoke all on function public.invite_cancel_ticket(uuid)            from public, anon;
revoke all on function public.invite_regenerate_link(uuid)          from public, anon;
revoke all on function public.invite_get_ticket(text)               from public;
revoke all on function public.invite_scan_ticket(text, uuid)        from public, anon;

grant execute on function public.invite_staff_role()                to authenticated;
grant execute on function public.invite_list_events()               to authenticated;
grant execute on function public.invite_list_tickets(uuid)          to authenticated;
grant execute on function public.invite_create_tickets(uuid, jsonb) to authenticated;
grant execute on function public.invite_cancel_ticket(uuid)         to authenticated;
grant execute on function public.invite_regenerate_link(uuid)       to authenticated;
grant execute on function public.invite_get_ticket(text)            to anon, authenticated;
grant execute on function public.invite_scan_ticket(text, uuid)     to authenticated;
