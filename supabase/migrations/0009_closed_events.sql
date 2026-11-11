-- Closed events, for a database that already ran 0001-0008 (already in 0001 for
-- new setups). Once an event's end (or, without one, its start) has passed it is
-- read only: it can't be edited or deleted, guests can't be added, cancelled,
-- given a new link or emailed, and organisers can't be added or removed (all
-- refused with 'event_closed'). Its active tickets read as 'expired' on the
-- organiser page and the ticket page (no QR) and scan as ticket_expired.
-- Nothing is written to the tickets: the status is worked out from the time.
-- invite_list_events gains a 'closed' column. Only changes this site's own
-- functions. Run once in the Supabase SQL editor.

drop function if exists public.invite_list_events();

create or replace function public.invite_event_closed(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((select coalesce(e.ends_at, e.starts_at) <= now()
                   from public.events e where e.id = p_event_id), false);
$$;

create or replace function public.invite_require_open_event(p_event_id uuid)
returns void
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  perform public.invite_require_event(p_event_id);
  if public.invite_event_closed(p_event_id) then
    raise exception 'event_closed';
  end if;
end;
$$;

create or replace function public.invite_list_events()
returns table (
  id                uuid,
  slug              text,
  name              text,
  name_ar           text,
  description       text,
  description_ar    text,
  starts_at         timestamptz,
  ends_at           timestamptz,
  venue             text,
  location_url      text,
  city_id           uuid,
  capacity          integer,
  image_url         text,
  registration_open boolean,
  closed            boolean,
  invited           bigint,
  checked_in        bigint
)
language sql
stable
security definer
set search_path to ''
set row_security to 'off'
as $$
  select e.id, e.slug,
         coalesce(en.title, e.slug), ar.title,
         nullif(en.description, ''), nullif(ar.description, ''),
         e.starts_at, e.ends_at, e.venue, e.invite_location_url, e.city_id, e.capacity,
         nullif(e.image_url, ''), e.invite_registration_open,
         coalesce(e.ends_at, e.starts_at) <= now(),
         (select count(*) from public.tickets t where t.event_id = e.id and t.status <> 'cancelled'),
         (select count(*) from public.tickets t where t.event_id = e.id and t.status = 'redeemed')
  from public.events e
  left join public.event_translations en on en.event_id = e.id and en.locale = 'en'
  left join public.event_translations ar on ar.event_id = e.id and ar.locale = 'ar'
  where public.invite_staff_role() is not null
    and e.invite_managed
    and public.invite_event_allowed(e.id)
  order by e.starts_at desc nulls last, e.created_at desc;
$$;

create or replace function public.invite_save_event(p_event_id uuid, p_event jsonb)
returns uuid
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_id       uuid := p_event_id;
  v_name     text := left(trim(coalesce(p_event->>'name', '')), 200);
  v_name_ar  text := nullif(left(trim(coalesce(p_event->>'name_ar', '')), 200), '');
  -- visit caps event_translations: description 500, summary 160 characters.
  v_desc     text := trim(coalesce(p_event->>'description', ''));
  v_desc_ar  text := trim(coalesce(p_event->>'description_ar', ''));
  v_venue    text := nullif(left(trim(coalesce(p_event->>'venue', '')), 200), '');
  v_location text := nullif(trim(coalesce(p_event->>'location_url', '')), '');
  v_image    text := left(trim(coalesce(p_event->>'image_url', '')), 1000);
  v_cap_txt  text := trim(coalesce(p_event->>'capacity', ''));
  v_open     boolean := coalesce((p_event->>'registration_open')::boolean, false);
  v_city     uuid;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_capacity integer;
  v_live     integer;
begin
  perform public.invite_require_open_event(p_event_id);
  if p_event_id is null and public.invite_assigned_only() then
    raise exception 'not_admin' using errcode = '42501';
  end if;

  if v_name = '' then raise exception 'name_required'; end if;
  if nullif(p_event->>'city_id', '') is null then raise exception 'city_required'; end if;
  v_city := (p_event->>'city_id')::uuid;
  if not exists (select 1 from public.cities c where c.id = v_city and c.region_id is not null) then
    raise exception 'city_required';
  end if;
  v_starts := nullif(p_event->>'starts_at', '')::timestamptz;
  v_ends   := nullif(p_event->>'ends_at', '')::timestamptz;
  if v_starts is null then raise exception 'start_required'; end if;
  if v_ends < v_starts then raise exception 'ends_before_start'; end if;
  if v_cap_txt <> '' then
    if v_cap_txt !~ '^\d{1,6}$' then raise exception 'bad_capacity'; end if;
    v_capacity := v_cap_txt::integer;
  end if;
  if length(v_desc) > 500 or length(v_desc_ar) > 500 then raise exception 'description_too_long'; end if;
  if v_image <> '' and v_image !~ '^https://[^\s"<>]+$' then raise exception 'bad_image_url'; end if;
  if length(v_location) > 1000 or v_location !~ '^https://[^\s"<>]+$' then
    raise exception 'bad_location_url';
  end if;

  if v_id is null then
    insert into public.events
      (city_id, starts_at, ends_at, venue, invite_location_url, image_url, capacity, booking_mode, is_free,
       price_from, status, show_in_view_all, is_home_featured,
       invite_managed, invite_registration_open)
    values
      (v_city, v_starts, v_ends, v_venue, v_location, v_image, v_capacity, 'ticket', true,
       0, 'Draft', false, false, true, v_open)
    returning id into v_id;
  else
    perform 1 from public.events where id = v_id and invite_managed for update;
    if not found then raise exception 'event_not_found'; end if;
    select count(*) into v_live from public.tickets where event_id = v_id and status <> 'cancelled';
    if v_capacity < v_live then raise exception 'capacity_below_guests'; end if;
    update public.events
       set city_id = v_city, starts_at = v_starts, ends_at = v_ends, venue = v_venue,
           invite_location_url = v_location,
           image_url = v_image, capacity = v_capacity, invite_registration_open = v_open
     where id = v_id;
    -- Keep the ticket titles (shown in visit's dashboard) in step with the name.
    update public.tickets set title = v_name
     where event_id = v_id and guest_name is not null and title is distinct from v_name;
  end if;

  insert into public.event_translations (event_id, locale, title, summary, description)
  values (v_id, 'en', v_name, left(v_desc, 160), v_desc)
  on conflict (event_id, locale) do update
    set title = excluded.title, summary = excluded.summary, description = excluded.description;

  if v_name_ar is null then
    delete from public.event_translations where event_id = v_id and locale = 'ar';
  else
    insert into public.event_translations (event_id, locale, title, summary, description)
    values (v_id, 'ar', v_name_ar, left(v_desc_ar, 160), v_desc_ar)
    on conflict (event_id, locale) do update
      set title = excluded.title, summary = excluded.summary, description = excluded.description;
  end if;

  return v_id;
end;
$$;

create or replace function public.invite_delete_event(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_manager();
  if public.invite_assigned_only() then raise exception 'not_admin' using errcode = '42501'; end if;
  perform 1 from public.events where id = p_event_id and invite_managed for update;
  if not found then raise exception 'event_not_found'; end if;
  if public.invite_event_closed(p_event_id) then raise exception 'event_closed'; end if;
  if exists (select 1 from public.tickets where event_id = p_event_id) then
    raise exception 'event_has_guests';
  end if;
  delete from public.events where id = p_event_id;
end;
$$;

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
  perform public.invite_require_event(p_event_id);
  return query
  select t.id, t.guest_name, t.guest_phone, t.guest_email, t.guest_note, t.guest_staff_id, t.link_token,
         case when t.status = 'active' and coalesce(e.ends_at, e.starts_at) <= now() then 'expired'
              else t.status end,
         t.redeemed_at, t.created_at
  from public.tickets t
  join public.events e on e.id = t.event_id and e.invite_managed
  where t.event_id = p_event_id and t.guest_name is not null
  order by t.created_at desc;
end;
$$;

create or replace function public.invite_create_tickets(p_event_id uuid, p_guests jsonb)
returns integer
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_count integer;
begin
  perform public.invite_require_open_event(p_event_id);
  perform 1 from public.events where id = p_event_id and invite_managed for update;
  if not found then raise exception 'event_not_found'; end if;
  select count(*) into v_count from public.invite_insert_guests(p_event_id, p_guests);
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
  perform public.invite_require_open_event((select event_id from public.tickets where id = p_ticket_id));
  update public.tickets t set status = 'cancelled'
  from public.events e
  where t.id = p_ticket_id and e.id = t.event_id and e.invite_managed
    and t.guest_name is not null and t.status = 'active';
  if not found then raise exception 'ticket_not_active'; end if;
end;
$$;

create or replace function public.invite_regenerate_link(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_open_event((select event_id from public.tickets where id = p_ticket_id));
  update public.tickets t
     set link_token = encode(extensions.gen_random_bytes(24), 'hex'),
         qr_token   = encode(extensions.gen_random_bytes(32), 'hex')
  from public.events e
  where t.id = p_ticket_id and e.id = t.event_id and e.invite_managed
    and t.guest_name is not null and t.status = 'active';
  if not found then raise exception 'ticket_not_active'; end if;
  perform public.invite_queue_email(p_ticket_id);
end;
$$;

create or replace function public.invite_resend_email(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_open_event((select event_id from public.tickets where id = p_ticket_id));
  if not exists (
    select 1 from public.tickets t
    join public.events e on e.id = t.event_id and e.invite_managed
    where t.id = p_ticket_id and t.status = 'active'
  ) then
    raise exception 'ticket_not_active';
  end if;
  if not exists (select 1 from public.tickets where id = p_ticket_id and guest_email is not null) then
    raise exception 'no_email';
  end if;
  perform public.invite_queue_email(p_ticket_id);
end;
$$;

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
  perform public.invite_require_open_event(p_event_id);
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

create or replace function public.invite_add_organiser(p_event_id uuid, p_email text)
returns text
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_user  uuid;
begin
  perform public.invite_require_open_event(p_event_id);
  perform 1 from public.events where id = p_event_id and invite_managed;
  if not found then raise exception 'event_not_found'; end if;
  if length(v_email) > 200 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'bad_email';
  end if;

  select u.id into v_user from auth.users u where lower(u.email) = v_email limit 1;
  if v_user is null then return 'no_account'; end if;
  if exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
             where ur.user_id = v_user and r.name = 'event_manager') then
    return 'full_organiser';
  end if;

  insert into public.user_roles (user_id, role_id)
  select v_user, r.id from public.roles r
  where r.name = 'event_organiser'
    and not exists (select 1 from public.user_roles ur where ur.user_id = v_user and ur.role_id = r.id);
  insert into public.invite_event_staff (user_id, event_id) values (v_user, p_event_id)
  on conflict do nothing;
  return 'added';
end;
$$;

create or replace function public.invite_remove_organiser(p_event_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_open_event(p_event_id);
  if p_user_id = auth.uid() then raise exception 'cannot_remove_self'; end if;
  delete from public.invite_event_staff where event_id = p_event_id and user_id = p_user_id;
  if not found then raise exception 'organiser_not_found'; end if;
  if not exists (select 1 from public.invite_event_staff where user_id = p_user_id) then
    delete from public.user_roles ur using public.roles r
    where r.id = ur.role_id and ur.user_id = p_user_id and r.name = 'event_organiser';
  end if;
end;
$$;

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
         case when t.status = 'active' and coalesce(e.ends_at, e.starts_at) <= now() then 'expired'
              else t.status end,
         case when t.status = 'cancelled'
                or (t.status = 'active' and coalesce(e.ends_at, e.starts_at) <= now()) then null
              else t.qr_token end,
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

  if (p_event_id is not null and v_ticket.event_id is distinct from p_event_id)
     or not public.invite_event_allowed(v_ticket.event_id) then
    v_status := 'wrong_event';
  elsif v_ticket.status = 'cancelled' then
    v_status := 'ticket_cancelled';
  elsif v_ticket.status = 'redeemed' or v_ticket.redeemed_at is not null then
    v_status := 'ticket_already_redeemed';
  elsif v_ticket.status = 'expired' or public.invite_event_closed(v_ticket.event_id) then
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

revoke all on function public.invite_event_closed(uuid)       from public, anon, authenticated;
revoke all on function public.invite_require_open_event(uuid) from public, anon, authenticated;
revoke all on function public.invite_list_events()            from public, anon;
grant execute on function public.invite_list_events()         to authenticated;
