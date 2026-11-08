-- Fixes for a database that already ran 0001 (both are already in 0001 for new setups):
--   * city names come from visit's city_translations (name_en / name_ar on cities
--     are empty for some cities, e.g. Jubail);
--   * event text fits visit's caps: summary 160, description 500 characters.
-- Only replaces this site's own functions. Run once in the Supabase SQL editor.

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
  perform public.invite_require_manager();

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

revoke all on function public.invite_city_name(uuid, text) from public, anon, authenticated;
