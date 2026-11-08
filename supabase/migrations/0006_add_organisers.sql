-- Organisers add organisers, for a database that already ran 0001-0005 (already
-- in 0001 for new setups).
--   * new role 'event_organiser': manages only the events listed for them in
--     invite_event_staff. 'event_manager' keeps managing every event.
--   * organisers list, add and remove the organisers of their event; the
--     invite-organiser edge function creates accounts and sends the email.
--   * a limited organiser's scanner only checks in guests of their own events.
--   * organisers already limited by 0005 move from event_manager to event_organiser
--     (same access as now).
-- Only changes this site's own objects and roles. Run once in the Supabase SQL editor.

insert into public.roles (name, description) values
  ('event_organiser', 'Manages only the JESCO invite events they were added to')
on conflict (name) do nothing;

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
  perform public.invite_require_event(p_event_id);
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
  perform public.invite_require_event(p_event_id);
  if p_user_id = auth.uid() then raise exception 'cannot_remove_self'; end if;
  delete from public.invite_event_staff where event_id = p_event_id and user_id = p_user_id;
  if not found then raise exception 'organiser_not_found'; end if;
  if not exists (select 1 from public.invite_event_staff where user_id = p_user_id) then
    delete from public.user_roles ur using public.roles r
    where r.id = ur.role_id and ur.user_id = p_user_id and r.name = 'event_organiser';
  end if;
end;
$$;

revoke all on function public.invite_list_organisers(uuid)                 from public, anon;
revoke all on function public.invite_add_organiser(uuid, text)             from public, anon;
revoke all on function public.invite_remove_organiser(uuid, uuid)          from public, anon;
grant execute on function public.invite_list_organisers(uuid)                 to authenticated;
grant execute on function public.invite_add_organiser(uuid, text)             to authenticated;
grant execute on function public.invite_remove_organiser(uuid, uuid)          to authenticated;

-- 0005 limited organisers by listing them; now the role does it.
insert into public.user_roles (user_id, role_id)
select distinct s.user_id, r.id
from public.invite_event_staff s
cross join public.roles r
where r.name = 'event_organiser'
  and not exists (select 1 from public.user_roles ur where ur.user_id = s.user_id and ur.role_id = r.id);

delete from public.user_roles ur
using public.roles r
where r.id = ur.role_id and r.name = 'event_manager'
  and ur.user_id in (select user_id from public.invite_event_staff);
