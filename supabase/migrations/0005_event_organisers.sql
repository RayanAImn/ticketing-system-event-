-- Organisers limited to some events, for a database that already ran 0001-0004
-- (already in 0001 for new setups). An organiser listed in invite_event_staff sees
-- and manages only those events and cannot create or delete events; organisers
-- not listed keep full access. Starts with baeshen.fb@gmail.com -> Safety Day 2026.
-- Only changes this site's own objects. Run once in the Supabase SQL editor.

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
  select exists (select 1 from public.invite_event_staff s where s.user_id = auth.uid());
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
  city_id           uuid,
  capacity          integer,
  image_url         text,
  registration_open boolean,
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
         e.starts_at, e.ends_at, e.venue, e.city_id, e.capacity,
         nullif(e.image_url, ''), e.invite_registration_open,
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
  v_image    text := left(trim(coalesce(p_event->>'image_url', '')), 1000);
  v_cap_txt  text := trim(coalesce(p_event->>'capacity', ''));
  v_open     boolean := coalesce((p_event->>'registration_open')::boolean, false);
  v_city     uuid;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_capacity integer;
  v_live     integer;
begin
  perform public.invite_require_event(p_event_id);
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

  if v_id is null then
    insert into public.events
      (city_id, starts_at, ends_at, venue, image_url, capacity, booking_mode, is_free,
       price_from, status, show_in_view_all, is_home_featured,
       invite_managed, invite_registration_open)
    values
      (v_city, v_starts, v_ends, v_venue, v_image, v_capacity, 'ticket', true,
       0, 'Draft', false, false, true, v_open)
    returning id into v_id;
  else
    perform 1 from public.events where id = v_id and invite_managed for update;
    if not found then raise exception 'event_not_found'; end if;
    select count(*) into v_live from public.tickets where event_id = v_id and status <> 'cancelled';
    if v_capacity < v_live then raise exception 'capacity_below_guests'; end if;
    update public.events
       set city_id = v_city, starts_at = v_starts, ends_at = v_ends, venue = v_venue,
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
         t.status, t.redeemed_at, t.created_at
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
  perform public.invite_require_event(p_event_id);
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
  perform public.invite_require_event((select event_id from public.tickets where id = p_ticket_id));
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
  perform public.invite_require_event((select event_id from public.tickets where id = p_ticket_id));
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
  perform public.invite_require_event((select event_id from public.tickets where id = p_ticket_id));
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

revoke all on function public.invite_assigned_only()                       from public, anon;
revoke all on function public.invite_event_allowed(uuid)                   from public, anon, authenticated;
revoke all on function public.invite_require_event(uuid)                   from public, anon, authenticated;
grant execute on function public.invite_assigned_only()                       to authenticated;

-- Who is limited to which event. To add another organiser:
--   insert into public.invite_event_staff (user_id, event_id)
--   select u.id, '01102670-73e0-4d0c-9b4c-be4f88c03075' from auth.users u where u.email = '<email>';
insert into public.invite_event_staff (user_id, event_id)
select u.id, e.id
from auth.users u, public.events e
where lower(u.email) = 'baeshen.fb@gmail.com'
  and e.id = '01102670-73e0-4d0c-9b4c-be4f88c03075' and e.invite_managed
on conflict do nothing;
