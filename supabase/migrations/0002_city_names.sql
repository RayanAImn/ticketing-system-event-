-- Fix: show city names from visit's city_translations (the name_en / name_ar
-- columns on cities are empty for some cities, e.g. Jubail).
-- Only replaces this site's own functions; already included in 0001 for new setups.
-- Run once in the Supabase SQL editor after 0001.

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

revoke all on function public.invite_city_name(uuid, text) from public, anon, authenticated;
