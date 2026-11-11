-- JESCO event tickets, stored in visit's own public.events and public.tickets.
--
-- Organisers (role 'event_manager') create events and add guests on this site.
-- Anyone with an event's public link (/e/<slug>) can register while places are
-- left. Each guest gets a ticket page (/t/<link_token>) and, if they gave an
-- email, the ticket by email (sent by the invite-ticket-email edge function
-- through visit's Resend sender). Gate staff (role 'ticket_scanner') scan the
-- ticket's qr_token on /scan.
--
-- Changes to existing visit objects (all additive except one):
--   * tickets.user_id becomes nullable. Every existing reader compares it to a
--     specific user (RLS "users read own tickets", mobile_tickets, per-user limits,
--     supplier/cancellation functions), so rows with a null user are never matched.
--     A check constraint still requires every row to have a user OR a guest name.
--   * tickets gains guest_name, guest_phone, guest_email, guest_note, guest_staff_id, link_token.
--   * events gains invite_managed and invite_registration_open. Events made here
--     are saved as status 'Draft' (visit's public reads and the app only show
--     'Published'), ticket mode, free, not in "view all".
--   * 'event_manager' and 'ticket_scanner' rows in public.roles (data only).
--   * insert/update/delete policies on storage.objects for the 'events' bucket,
--     limited to the folder invite/<organiser id>/ (cover images).
--   * an AFTER INSERT trigger on tickets that only fires for guest rows.
--   * guest tickets are saved with email_sent_at already set, so visit's existing
--     send_ticket_email webhook skips them (it would otherwise fall back to a
--     default inbox, as a guest ticket has no app user).
-- Not touched: ticket_payments, every create_ticket_* / payment / scan function,
-- mobile_* views, Moyasar and Tamara. Visit admins get no access to this site.
--
-- Email needs one new Vault secret (project_url already exists for visit's
-- booking email):
--   select vault.create_secret('<random value>', 'invite_email_secret');
-- with the same value set as the INVITE_EMAIL_SECRET function secret.
--
-- Run once in the Supabase SQL editor.

-- ---------------------------------------------------------------- tickets: guest columns

alter table public.tickets alter column user_id drop not null;

alter table public.tickets
  add column if not exists guest_name  text,
  add column if not exists guest_phone text,
  add column if not exists guest_email text,
  add column if not exists guest_note  text,
  add column if not exists guest_staff_id text,
  add column if not exists link_token  text;

alter table public.tickets drop constraint if exists tickets_user_or_guest;
alter table public.tickets
  add constraint tickets_user_or_guest check (user_id is not null or guest_name is not null);

create unique index if not exists tickets_link_token_uidx
  on public.tickets (link_token) where link_token is not null;

-- One live ticket per email per event (cancelled ones don't count).
create unique index if not exists tickets_guest_email_uidx
  on public.tickets (event_id, lower(guest_email))
  where guest_email is not null and status <> 'cancelled';

-- One live ticket per staff ID per event.
create unique index if not exists tickets_guest_staff_id_uidx
  on public.tickets (event_id, guest_staff_id)
  where guest_staff_id is not null and status <> 'cancelled';

-- ---------------------------------------------------------------- events: invite columns

alter table public.events
  add column if not exists invite_managed           boolean not null default false,
  add column if not exists invite_registration_open boolean not null default false,
  add column if not exists invite_location_url      text;

-- ---------------------------------------------------------------- roles (data)

insert into public.roles (name, description) values
  ('event_manager',  'Creates and manages JESCO invite events'),
  ('ticket_scanner', 'Can scan invite tickets at the gate'),
  ('event_organiser', 'Manages only the JESCO invite events they were added to')
on conflict (name) do nothing;

-- 'admin' (event_manager) | 'scanner' (ticket_scanner) | null for the signed-in user.
create or replace function public.invite_staff_role()
returns text
language sql
stable
security definer
set search_path to ''
as $$
  select case
    when bool_or(r.name in ('event_manager', 'event_organiser')) then 'admin'
    when bool_or(r.name = 'ticket_scanner') then 'scanner'
  end
  from public.user_roles ur
  join public.roles r on r.id = ur.role_id
  where ur.user_id = auth.uid()
    and r.name in ('event_manager', 'event_organiser', 'ticket_scanner');
$$;

create or replace function public.invite_require_manager()
returns void
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if public.invite_staff_role() is distinct from 'admin' then
    raise exception 'not_admin' using errcode = '42501';
  end if;
end;
$$;

-- Events an 'event_organiser' may manage. Such an organiser sees and manages only
-- these events and cannot create or delete events. 'event_manager' manages all.
-- Organisers add each other from the event page (invite_add_organiser).
create table if not exists public.invite_event_staff (
  user_id  uuid not null references auth.users (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  primary key (user_id, event_id)
);
alter table public.invite_event_staff enable row level security;
revoke all on table public.invite_event_staff from anon, authenticated;

create or replace function public.invite_assigned_only()
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(bool_or(r.name = 'event_organiser') and not bool_or(r.name = 'event_manager'), false)
  from public.user_roles ur
  join public.roles r on r.id = ur.role_id
  where ur.user_id = auth.uid()
    and r.name in ('event_manager', 'event_organiser');
$$;

create or replace function public.invite_event_allowed(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select not public.invite_assigned_only()
      or exists (select 1 from public.invite_event_staff s
                 where s.user_id = auth.uid() and s.event_id = p_event_id);
$$;

-- Organiser who may manage this event (an unknown event passes here and is
-- reported as event_not_found by the caller).
create or replace function public.invite_require_event(p_event_id uuid)
returns void
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  perform public.invite_require_manager();
  if p_event_id is not null and not public.invite_event_allowed(p_event_id) then
    raise exception 'not_admin' using errcode = '42501';
  end if;
end;
$$;

-- An event is closed once its end (or, without one, its start) has passed. A
-- closed event is read only: no edits, no guests added, cancelled or emailed,
-- no organisers added or removed, and its tickets show and scan as expired.
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

-- invite_require_event, and the event must not be closed.
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

-- ---------------------------------------------------------------- city names

-- City name in 'en' or 'ar'. visit keeps city names in city_translations; the
-- name_en / name_ar columns on cities are empty for some cities (e.g. Jubail).
create or replace function public.invite_city_name(p_city_id uuid, p_locale text)
returns text
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(
    (select nullif(ct.name, '') from public.city_translations ct
     where ct.city_id = p_city_id and ct.locale = p_locale),
    (select case when p_locale = 'ar' then c.name_ar else coalesce(c.name_en, c.slug) end
     from public.cities c where c.id = p_city_id));
$$;

-- ---------------------------------------------------------------- ticket email

-- Asks the invite-ticket-email edge function to email this ticket. Same pattern
-- as visit's notify_booking_email: config from Vault, pg_net, and best-effort
-- (a failure is a warning and never blocks the ticket). pg_net sends after the
-- transaction commits, so a rolled-back ticket is never emailed.
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
             'locationUrl', e.invite_location_url,
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

create or replace function public.invite_ticket_email_trg()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform public.invite_queue_email(new.id);
  return new;
end;
$$;

drop trigger if exists tickets_invite_email on public.tickets;
create trigger tickets_invite_email
  after insert on public.tickets
  for each row
  when (new.guest_email is not null and new.link_token is not null)
  execute function public.invite_ticket_email_trg();

-- ---------------------------------------------------------------- organiser: events

create or replace function public.invite_list_cities()
returns table (id uuid, name text, name_ar text)
language sql
stable
security definer
set search_path to ''
as $$
  select c.id, public.invite_city_name(c.id, 'en'), public.invite_city_name(c.id, 'ar')
  from public.cities c
  where public.invite_staff_role() = 'admin'
    and c.region_id is not null
  order by c.is_sharqia_core desc, 2;
$$;

-- This site's events with guest counts. Organisers and scanners.
drop function if exists public.invite_list_events();
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

-- Creates (p_event_id null) or edits an event. Returns its id.
-- p_event: {name, name_ar, description, description_ar, starts_at, ends_at,
--           venue, location_url, city_id, capacity, image_url, registration_open}
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

-- Only events without any tickets can be deleted (tickets keep the event).
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

-- ---------------------------------------------------------------- organiser: guests

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

-- Internal (no grants): adds guests to an invite event the caller has locked.
-- Checks capacity, email format and duplicates. Returns the new link tokens.
-- The tickets_invite_email trigger emails every new guest that has an email.
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

-- p_guests: [{"name": "...", "phone": "...", "email": "...", "note": "...", "staff_id": "..."}, ...]
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

-- For a link sent to the wrong person: the old link and the old QR stop working,
-- and the guest is emailed the new link.
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

-- Email every active guest of the event who has an email their ticket again
-- (same link and QR). Returns how many were queued.
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

-- ---------------------------------------------------------------- organiser: other organisers

-- Organisers added to this event (not the event_managers, who manage every event).
create or replace function public.invite_list_organisers(p_event_id uuid)
returns table (user_id uuid, email text, signed_in boolean, is_you boolean)
language plpgsql
stable
security definer
set search_path to ''
set row_security to 'off'
as $$
begin
  perform public.invite_require_event(p_event_id);
  return query
  select u.id, u.email::text, u.last_sign_in_at is not null, u.id = auth.uid()
  from public.invite_event_staff s
  join auth.users u on u.id = s.user_id
  where s.event_id = p_event_id
  order by lower(u.email);
end;
$$;

-- Adds an existing account as an organiser of this event only. Returns 'added',
-- 'full_organiser' (already manages every event: nothing to do) or 'no_account'
-- (the invite-organiser edge function then creates the account and calls again).
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

-- Removes an organiser from this event; with no events left they lose the role.
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

-- ---------------------------------------------------------------- no app bookings

-- visit's create_ticket_for_event doesn't check an event's status, so a signed-in
-- app user with the id could book these Draft events. Only this site's guest
-- tickets may be created for them; every other event is unaffected.
create or replace function public.invite_block_app_ticket()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if exists (select 1 from public.events e where e.id = new.event_id and e.invite_managed) then
    raise exception 'invite_event_not_bookable';
  end if;
  return new;
end;
$$;

drop trigger if exists tickets_invite_guests_only on public.tickets;
create trigger tickets_invite_guests_only
  before insert on public.tickets
  for each row
  when (new.event_id is not null and new.guest_name is null)
  execute function public.invite_block_app_ticket();

-- ---------------------------------------------------------------- public: event page

create or replace function public.invite_get_event(p_slug text)
returns table (
  slug              text,
  name              text,
  name_ar           text,
  description       text,
  description_ar    text,
  starts_at         timestamptz,
  ends_at           timestamptz,
  venue             text,
  city              text,
  city_ar           text,
  image_url         text,
  registration_open boolean,
  spots_left        integer
)
language sql
stable
security definer
set search_path to ''
set row_security to 'off'
as $$
  select e.slug,
         coalesce(en.title, e.slug), ar.title,
         nullif(en.description, ''), nullif(ar.description, ''),
         e.starts_at, e.ends_at, e.venue,
         public.invite_city_name(e.city_id, 'en'), public.invite_city_name(e.city_id, 'ar'),
         nullif(e.image_url, ''),
         e.invite_registration_open and coalesce(e.ends_at, e.starts_at) > now(),
         case when e.capacity is null then null
              else greatest(e.capacity - (select count(*) from public.tickets t
                                          where t.event_id = e.id and t.status <> 'cancelled'), 0)::integer
         end
  from public.events e
  left join public.event_translations en on en.event_id = e.id and en.locale = 'en'
  left join public.event_translations ar on ar.event_id = e.id and ar.locale = 'ar'
  where e.slug = p_slug and e.invite_managed;
$$;

-- Public sign-up. Returns the new ticket's link token, so the page can open the
-- ticket straight away, or 'already_registered' when that email already has a
-- ticket. p_website is a hidden field people never fill (bots do).
create or replace function public.invite_register(
  p_slug    text,
  p_name    text,
  p_email   text,
  p_phone   text default null,
  p_website text default null
)
returns text
language plpgsql
security definer
set search_path to ''
set row_security to 'off'
as $$
declare
  v_name     text := left(trim(coalesce(p_name, '')), 120);
  v_email    text := lower(trim(coalesce(p_email, '')));
  v_ip       text;
  v_event    public.events;
  v_existing uuid;
  v_token    text;
begin
  if coalesce(p_website, '') <> '' then raise exception 'registration_closed'; end if;
  if v_name = '' then raise exception 'name_required'; end if;
  if length(v_email) > 200 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'bad_email';
  end if;

  -- Per-IP limit, generous because a whole office can share one IP.
  begin
    v_ip := trim(split_part(
      nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ',', 1));
  exception when others then
    v_ip := null;
  end;
  if coalesce(v_ip, '') <> ''
     and not public.check_and_bump_rate_limit('invite-register:' || v_ip, 60, 600) then
    raise exception 'too_many_attempts';
  end if;

  select * into v_event from public.events e
  where e.slug = p_slug and e.invite_managed
  for update;
  if v_event.id is null then raise exception 'event_not_found'; end if;
  if not v_event.invite_registration_open
     or coalesce(v_event.ends_at, v_event.starts_at) <= now() then
    raise exception 'registration_closed';
  end if;

  select t.id into v_existing from public.tickets t
  where t.event_id = v_event.id and lower(t.guest_email) = v_email and t.status <> 'cancelled';
  if v_existing is not null then
    -- Send the ticket to that inbox again (never show it here: anyone can type
    -- anyone's email). Limited so the form can't be used to flood an inbox.
    -- Returned, not raised: raising would roll back the queued email.
    if public.check_and_bump_rate_limit('invite-resend:' || v_existing::text, 3, 3600) then
      perform public.invite_queue_email(v_existing);
    end if;
    return 'already_registered';
  end if;

  select tok into v_token
  from public.invite_insert_guests(v_event.id,
         jsonb_build_array(jsonb_build_object('name', v_name, 'email', v_email, 'phone', p_phone))) tok;
  return v_token;
end;
$$;

-- ---------------------------------------------------------------- guest: open ticket by link

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

-- ---------------------------------------------------------------- scanner

-- Same outcome codes as scan_ticket_qr and logs to the same ticket_scans table.
-- Only tickets of this site's events are accepted; visit app tickets are invalid here.
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

-- ---------------------------------------------------------------- cover images

-- Organisers upload covers to the public 'events' bucket, only under invite/<own id>/.
-- (The bucket itself limits files to 10 MB of jpeg/png/webp.)
drop policy if exists "invite covers insert" on storage.objects;
create policy "invite covers insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'events'
              and (storage.foldername(name))[1] = 'invite'
              and (storage.foldername(name))[2] = (select auth.uid())::text
              and (select public.invite_staff_role()) = 'admin');

drop policy if exists "invite covers update" on storage.objects;
create policy "invite covers update" on storage.objects for update to authenticated
  using (bucket_id = 'events'
         and (storage.foldername(name))[1] = 'invite'
         and (storage.foldername(name))[2] = (select auth.uid())::text
         and (select public.invite_staff_role()) = 'admin');

drop policy if exists "invite covers delete" on storage.objects;
create policy "invite covers delete" on storage.objects for delete to authenticated
  using (bucket_id = 'events'
         and (storage.foldername(name))[1] = 'invite'
         and (storage.foldername(name))[2] = (select auth.uid())::text
         and (select public.invite_staff_role()) = 'admin');

-- ---------------------------------------------------------------- grants

revoke all on function public.invite_staff_role()                          from public, anon;
revoke all on function public.invite_require_manager()                     from public, anon, authenticated;
revoke all on function public.invite_queue_email(uuid)                     from public, anon, authenticated;
revoke all on function public.invite_assigned_only()                       from public, anon;
revoke all on function public.invite_event_allowed(uuid)                   from public, anon, authenticated;
revoke all on function public.invite_require_event(uuid)                   from public, anon, authenticated;
revoke all on function public.invite_event_closed(uuid)                    from public, anon, authenticated;
revoke all on function public.invite_require_open_event(uuid)              from public, anon, authenticated;
revoke all on function public.invite_list_organisers(uuid)                 from public, anon;
revoke all on function public.invite_add_organiser(uuid, text)             from public, anon;
revoke all on function public.invite_remove_organiser(uuid, uuid)          from public, anon;
revoke all on function public.invite_city_name(uuid, text)                 from public, anon, authenticated;
revoke all on function public.invite_ticket_email_trg()                    from public, anon, authenticated;
revoke all on function public.invite_insert_guests(uuid, jsonb)            from public, anon, authenticated;
revoke all on function public.invite_list_cities()                         from public, anon;
revoke all on function public.invite_list_events()                         from public, anon;
revoke all on function public.invite_save_event(uuid, jsonb)               from public, anon;
revoke all on function public.invite_delete_event(uuid)                    from public, anon;
revoke all on function public.invite_list_tickets(uuid)                    from public, anon;
revoke all on function public.invite_create_tickets(uuid, jsonb)           from public, anon;
revoke all on function public.invite_cancel_ticket(uuid)                   from public, anon;
revoke all on function public.invite_regenerate_link(uuid)                 from public, anon;
revoke all on function public.invite_resend_email(uuid)                    from public, anon;
revoke all on function public.invite_resend_all_emails(uuid)               from public, anon;
revoke all on function public.invite_block_app_ticket()                    from public, anon, authenticated;
revoke all on function public.invite_get_event(text)                       from public;
revoke all on function public.invite_register(text, text, text, text, text) from public;
revoke all on function public.invite_get_ticket(text)                      from public;
revoke all on function public.invite_scan_ticket(text, uuid)               from public, anon;

grant execute on function public.invite_staff_role()                          to authenticated;
grant execute on function public.invite_assigned_only()                       to authenticated;
grant execute on function public.invite_list_organisers(uuid)                 to authenticated;
grant execute on function public.invite_add_organiser(uuid, text)             to authenticated;
grant execute on function public.invite_remove_organiser(uuid, uuid)          to authenticated;
grant execute on function public.invite_list_cities()                         to authenticated;
grant execute on function public.invite_list_events()                         to authenticated;
grant execute on function public.invite_save_event(uuid, jsonb)               to authenticated;
grant execute on function public.invite_delete_event(uuid)                    to authenticated;
grant execute on function public.invite_list_tickets(uuid)                    to authenticated;
grant execute on function public.invite_create_tickets(uuid, jsonb)           to authenticated;
grant execute on function public.invite_cancel_ticket(uuid)                   to authenticated;
grant execute on function public.invite_regenerate_link(uuid)                 to authenticated;
grant execute on function public.invite_resend_email(uuid)                    to authenticated;
grant execute on function public.invite_resend_all_emails(uuid)               to authenticated;
grant execute on function public.invite_get_event(text)                       to anon, authenticated;
grant execute on function public.invite_register(text, text, text, text, text) to anon, authenticated;
grant execute on function public.invite_get_ticket(text)                      to anon, authenticated;
grant execute on function public.invite_scan_ticket(text, uuid)               to authenticated;
