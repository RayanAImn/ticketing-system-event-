-- Staff ID for guests, for a database that already ran 0001 (already in 0001 for new setups).
-- Adds tickets.guest_staff_id (one live ticket per staff ID per event) and shows it
-- to organisers, on the ticket page, in the ticket email and to the scanner.
-- Only changes this site's own objects. Run once in the Supabase SQL editor.

alter table public.tickets add column if not exists guest_staff_id text;

-- One live ticket per staff ID per event.
create unique index if not exists tickets_guest_staff_id_uidx
  on public.tickets (event_id, guest_staff_id)
  where guest_staff_id is not null and status <> 'cancelled';

create or replace function public.invite_queue_email(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_project_url text;
  v_secret      text;
  v_body        jsonb;
begin
  begin
    select decrypted_secret into v_project_url from vault.decrypted_secrets where name = 'project_url';
    select decrypted_secret into v_secret      from vault.decrypted_secrets where name = 'invite_email_secret';
    if v_project_url is null or v_secret is null then
      raise warning 'invite_queue_email: vault secrets missing, email skipped for ticket %', p_ticket_id;
      return;
    end if;

    select jsonb_build_object(
             'ticketId',    t.id,
             'guestName',   t.guest_name,
             'guestEmail',  t.guest_email,
             'staffId',     t.guest_staff_id,
             'linkToken',   t.link_token,
             'eventName',   coalesce(en.title, e.slug),
             'eventNameAr', ar.title,
             'startsAt',    e.starts_at,
             'endsAt',      e.ends_at,
             'venue',       e.venue,
             'city',        public.invite_city_name(e.city_id, 'en'),
             'cityAr',      public.invite_city_name(e.city_id, 'ar'),
             'imageUrl',    e.image_url)
      into v_body
    from public.tickets t
    join public.events e on e.id = t.event_id and e.invite_managed
    left join public.event_translations en on en.event_id = e.id and en.locale = 'en'
    left join public.event_translations ar on ar.event_id = e.id and ar.locale = 'ar'
    where t.id = p_ticket_id
      and t.guest_email is not null and t.link_token is not null and t.status = 'active';

    if v_body is null then return; end if;

    perform net.http_post(
      url     := rtrim(v_project_url, '/') || '/functions/v1/invite-ticket-email',
      body    := v_body,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-invite-secret', v_secret),
      timeout_milliseconds := 60000
    );
  exception when others then
    raise warning 'invite_queue_email failed for ticket %: %', p_ticket_id, sqlerrm;
  end;
end;
$$;

drop function if exists public.invite_list_tickets(uuid);
create or replace function public.invite_list_tickets(p_event_id uuid)
returns table (
  id          uuid,
  guest_name  text,
  guest_phone text,
  guest_email text,
  guest_note  text,
  guest_staff_id text,
  link_token  text,
  status      text,
  redeemed_at timestamptz,
  created_at  timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_manager();
  return query
  select t.id, t.guest_name, t.guest_phone, t.guest_email, t.guest_note, t.guest_staff_id, t.link_token,
         t.status, t.redeemed_at, t.created_at
  from public.tickets t
  join public.events e on e.id = t.event_id and e.invite_managed
  where t.event_id = p_event_id and t.guest_name is not null
  order by t.created_at desc;
end;
$$;

create or replace function public.invite_insert_guests(p_event_id uuid, p_guests jsonb)
returns setof text
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_title    text;
  v_capacity integer;
  v_live     integer;
  v_count    integer;
begin
  if jsonb_typeof(p_guests) <> 'array' or jsonb_array_length(p_guests) = 0 then
    raise exception 'no_guests';
  end if;
  if jsonb_array_length(p_guests) > 2000 then raise exception 'too_many_guests'; end if;

  select coalesce(en.title, e.slug), e.capacity into v_title, v_capacity
  from public.events e
  left join public.event_translations en on en.event_id = e.id and en.locale = 'en'
  where e.id = p_event_id and e.invite_managed;
  if v_title is null then raise exception 'event_not_found'; end if;

  create temp table if not exists pg_temp.invite_new_guests
    (name text, phone text, email text, note text, staff_id text) on commit drop;
  truncate pg_temp.invite_new_guests;
  insert into pg_temp.invite_new_guests
  select left(trim(g->>'name'), 120),
         nullif(left(trim(coalesce(g->>'phone', '')), 40), ''),
         nullif(lower(trim(coalesce(g->>'email', ''))), ''),
         nullif(left(trim(coalesce(g->>'note', '')), 300), ''),
         nullif(left(trim(coalesce(g->>'staff_id', '')), 40), '')
  from jsonb_array_elements(p_guests) g
  where length(trim(coalesce(g->>'name', ''))) > 0;

  select count(*) into v_count from pg_temp.invite_new_guests;
  if v_count = 0 then raise exception 'no_guests'; end if;

  if exists (select 1 from pg_temp.invite_new_guests
             where email is not null
               and (length(email) > 200 or email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')) then
    raise exception 'bad_email';
  end if;
  if exists (select 1 from pg_temp.invite_new_guests where email is not null
             group by email having count(*) > 1)
     or exists (select 1 from pg_temp.invite_new_guests n
                join public.tickets t on t.event_id = p_event_id and lower(t.guest_email) = n.email
                                     and t.status <> 'cancelled') then
    raise exception 'email_already_invited';
  end if;
  if exists (select 1 from pg_temp.invite_new_guests where staff_id is not null
             group by staff_id having count(*) > 1)
     or exists (select 1 from pg_temp.invite_new_guests n
                join public.tickets t on t.event_id = p_event_id and t.guest_staff_id = n.staff_id
                                     and t.status <> 'cancelled') then
    raise exception 'staff_id_already_invited';
  end if;

  if v_capacity is not null then
    select count(*) into v_live from public.tickets
    where event_id = p_event_id and status <> 'cancelled';
    if v_live + v_count > v_capacity then raise exception 'event_sold_out'; end if;
  end if;

  -- email_sent_at is set so visit's own send_ticket_email webhook skips guest
  -- tickets (it has no user to send to); this site sends its own email instead.
  return query
  insert into public.tickets
    (user_id, event_id, title, guest_name, guest_phone, guest_email, guest_note, guest_staff_id, link_token, email_sent_at)
  select null::uuid, p_event_id, v_title, n.name, n.phone, n.email, n.note, n.staff_id,
         encode(extensions.gen_random_bytes(24), 'hex'), now()
  from pg_temp.invite_new_guests n
  returning link_token;
end;
$$;

drop function if exists public.invite_get_ticket(text);
create or replace function public.invite_get_ticket(p_link_token text)
returns table (
  guest_name    text,
  staff_id      text,
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
         t.guest_staff_id,
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
  join public.events e on e.id = t.event_id and e.invite_managed
  left join public.event_translations en on en.event_id = e.id and en.locale = 'en'
  left join public.event_translations ar on ar.event_id = e.id and ar.locale = 'ar'
  where t.link_token = p_link_token
    and length(p_link_token) >= 32;
$$;

drop function if exists public.invite_scan_ticket(text, uuid);
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
                      v_ticket.guest_staff_id, v_ticket.guest_note, v_ticket.redeemed_at, v_now;
end;
$$;

revoke all on function public.invite_list_tickets(uuid)                    from public, anon;
revoke all on function public.invite_get_ticket(text)                      from public;
revoke all on function public.invite_scan_ticket(text, uuid)               from public, anon;
grant execute on function public.invite_list_tickets(uuid)                    to authenticated;
grant execute on function public.invite_get_ticket(text)                      to anon, authenticated;
grant execute on function public.invite_scan_ticket(text, uuid)               to authenticated;
