-- Fix for a database that already ran 0001 and 0002 (already in 0001 for new setups):
-- visit app users can no longer book this site's events through visit's own
-- create_ticket_for_event (it doesn't check an event's status). Only this site's
-- guest tickets may be created for invite events; other events are unaffected.
-- Only adds this site's own objects. Run once in the Supabase SQL editor.

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

revoke all on function public.invite_block_app_ticket() from public, anon, authenticated;
