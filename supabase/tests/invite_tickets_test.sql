-- Tests for 0001_invite_tickets.sql against a full local copy of visit's database
-- (visit-app's migrations + the migration). Everything runs in one transaction
-- that is rolled back, so pg_net never sends a request.
--
--     npx supabase test db      (from a local project that has both migrations)

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select no_plan();

-- ---------------------------------------------------------------- fixtures

insert into auth.users (id, instance_id, aud, role, email, encrypted_password) values
  ('10000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mgr@test.local', ''),
  ('10000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'gate@test.local', ''),
  ('10000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'user@test.local', ''),
  ('10000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'visitadmin@test.local', '');
insert into public.admin_users (user_id) values ('10000000-0000-0000-0000-0000000000a4');
insert into public.user_roles (user_id, role_id)
  select '10000000-0000-0000-0000-0000000000a1'::uuid, id from public.roles where name = 'event_manager'
  union all
  select '10000000-0000-0000-0000-0000000000a2'::uuid, id from public.roles where name = 'ticket_scanner';

select vault.create_secret('https://proj.test.local/', 'project_url');
select vault.create_secret('s3cret', 'invite_email_secret');

-- Shared values the role-switched statements read.
create temp table ids (k text primary key, v text);
grant select, insert on ids to anon, authenticated;
insert into ids values ('city', (select id::text from public.cities where region_id is not null order by is_sharqia_core desc, id limit 1));

-- An ordinary visit app event and a paying app user's ticket.
insert into public.events (id, city_id, starts_at, booking_mode, status, price_from)
values ('20000000-0000-0000-0000-000000000001', (select v::uuid from ids where k = 'city'), now() + interval '5 days', 'ticket', 'Published', 50);
insert into public.event_translations (event_id, locale, title, summary, description)
values ('20000000-0000-0000-0000-000000000001', 'en', 'Concert', '', '');
insert into public.tickets (id, user_id, event_id, title)
values ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-0000000000a3', '20000000-0000-0000-0000-000000000001', 'Concert');

-- Our email requests (pg_net queue rows to invite-ticket-email), oldest first.
create function pg_temp.invite_calls() returns setof jsonb language sql as $$
  select convert_from(body, 'utf8')::jsonb || jsonb_build_object('_headers', headers)
  from net.http_request_queue where url like '%/functions/v1/invite-ticket-email' order by id $$;
create function pg_temp.event_json(o jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object(
    'name', 'Safety Day 2026', 'name_ar', 'يوم السلامة', 'description', 'Workshops', 'description_ar', 'ورش',
    'starts_at', now() + interval '7 days', 'ends_at', now() + interval '7 days 6 hours',
    'venue', 'Main Hall', 'city_id', (select v from ids where k = 'city'), 'capacity', '3',
    'image_url', 'https://proj.test.local/storage/v1/object/public/events/invite/x.jpg',
    'registration_open', true) || o $$;
grant execute on function pg_temp.event_json(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------- roles

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select is(public.invite_staff_role(), 'admin', 'event_manager = organiser');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a2', true);
set local role authenticated;
select is(public.invite_staff_role(), 'scanner', 'ticket_scanner = scanner');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a4', true);
set local role authenticated;
select is(public.invite_staff_role(), null, 'visit admin has no access');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json()) $$, null::char(5), 'not_admin', 'visit admin cannot create events');
select is((select count(*) from public.invite_list_events())::int, 0, 'visit admin lists no events');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a3', true);
set local role authenticated;
select is(public.invite_staff_role(), null, 'app user has no access');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json()) $$, null::char(5), 'not_admin', 'app user cannot create events');
select is((select count(*) from public.invite_list_cities())::int, 0, 'app user lists no cities');
reset role;
set local role anon;
select throws_ok($$ select public.invite_staff_role() $$, '42501', null, 'anon cannot call staff role');
select throws_ok($$ select public.invite_list_events() $$, '42501', null, 'anon cannot list events');
select throws_ok($$ select public.invite_insert_guests(gen_random_uuid(), '[]') $$, '42501', null, 'anon cannot call internal insert');
select throws_ok($$ select public.invite_queue_email(gen_random_uuid()) $$, '42501', null, 'anon cannot queue emails');
reset role;

-- ---------------------------------------------------------------- organiser: events

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a2', true);
set local role authenticated;
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json()) $$, null::char(5), 'not_admin', 'scanner cannot create events');
reset role;

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select throws_ok($$ select public.invite_queue_email(gen_random_uuid()) $$, '42501', null, 'organiser cannot queue emails directly');
select ok((select count(*) from public.invite_list_cities()) > 0, 'organiser lists cities');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json('{"name":" "}')) $$, null::char(5), 'name_required', 'name required');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json('{"city_id":""}')) $$, null::char(5), 'city_required', 'city required');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json('{"starts_at":null}')) $$, null::char(5), 'start_required', 'start required');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json(jsonb_build_object('ends_at', now()))) $$, null::char(5), 'ends_before_start', 'end before start refused');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json('{"capacity":"-1"}')) $$, null::char(5), 'bad_capacity', 'bad capacity refused');
select throws_ok($$ select public.invite_save_event(null, pg_temp.event_json('{"image_url":"javascript:alert(1)"}')) $$, null::char(5), 'bad_image_url', 'non-https image refused');
select throws_ok($$ select public.invite_save_event('20000000-0000-0000-0000-000000000001', pg_temp.event_json()) $$, null::char(5), 'event_not_found', 'cannot edit a visit app event');
select lives_ok($$ insert into ids select 'ev', public.invite_save_event(null, pg_temp.event_json())::text $$, 'organiser creates an event');
reset role;

select ok((select status = 'Draft' and booking_mode = 'ticket' and is_free and price_from = 0 and show_in_view_all = false
                  and invite_managed and region_id is not null and capacity = 3 and slug like 'event-%'
           from public.events where id = (select v::uuid from ids where k = 'ev')),
          'saved as Draft, ticket, free, hidden, region filled by visit''s trigger');
insert into ids select 'slug', slug from public.events where id = (select v::uuid from ids where k = 'ev');

set local role anon;
select is((select count(*) from public.events where id = (select v::uuid from ids where k = 'ev'))::int, 0, 'draft event not readable by the public');
select is((select count(*) from public.event_translations where event_id = (select v::uuid from ids where k = 'ev'))::int, 0, 'draft event text not readable by the public');
select is((select count(*) from public.mobile_events where id = (select v::uuid from ids where k = 'ev'))::int, 0, 'event not in the app''s mobile_events');
reset role;

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select results_eq($$ select name, name_ar, registration_open from public.invite_list_events() $$,
                  $$ values ('Safety Day 2026'::text, 'يوم السلامة'::text, true) $$, 'organiser lists only invite events');
select lives_ok($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json('{"name_ar":"","capacity":""}')) $$, 'edit: no Arabic name, no capacity');
select is((select name_ar from public.invite_list_events()), null, 'Arabic name removed');
select lives_ok($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json()) $$, 'edit back');
reset role;

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a2', true);
set local role authenticated;
select is((select count(*) from public.invite_list_events())::int, 1, 'scanner lists events');
select throws_ok($$ select public.invite_list_tickets((select v::uuid from ids where k = 'ev')) $$, null::char(5), 'not_admin', 'scanner cannot list guests');
reset role;

-- ---------------------------------------------------------------- organiser: guests

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select throws_ok($$ select public.invite_create_tickets('20000000-0000-0000-0000-000000000001', '[{"name":"X"}]') $$, null::char(5), 'event_not_found', 'cannot add guests to a visit app event');
select throws_ok($$ select public.invite_create_tickets((select v::uuid from ids where k = 'ev'), '[{"name":"A","email":"nope"}]') $$, null::char(5), 'bad_email', 'bad email refused');
select throws_ok($$ select public.invite_create_tickets((select v::uuid from ids where k = 'ev'), '[{"name":"A","email":"a@x.com"},{"name":"B","email":"A@x.com"}]') $$, null::char(5), 'email_already_invited', 'duplicate email in a list refused');
select is(public.invite_create_tickets((select v::uuid from ids where k = 'ev'),
            '[{"name":"Sara","phone":"055","email":" Sara@Example.com ","note":"VIP"},{"name":"Omar"},{"name":" "}]'), 2,
          'organiser adds 2 guests (blank name skipped)');
select throws_ok($$ select public.invite_create_tickets((select v::uuid from ids where k = 'ev'), '[{"name":"Again","email":"sara@example.com"}]') $$, null::char(5), 'email_already_invited', 'email already invited refused');
select throws_ok($$ select public.invite_create_tickets((select v::uuid from ids where k = 'ev'), '[{"name":"C"},{"name":"D"}]') $$, null::char(5), 'event_sold_out', 'capacity enforced');
select throws_ok($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json('{"capacity":"1"}')) $$, null::char(5), 'capacity_below_guests', 'capacity cannot go below guests');
select is((select count(*) from public.invite_list_tickets((select v::uuid from ids where k = 'ev')))::int, 2, 'organiser lists guests');
select is((select count(*) from public.invite_list_tickets('20000000-0000-0000-0000-000000000001'))::int, 0, 'visit app tickets never listed');
reset role;

insert into ids select 'sara', id::text from public.tickets where guest_name = 'Sara';
insert into ids select 'omar', id::text from public.tickets where guest_name = 'Omar';
insert into ids select 'sara_link', link_token from public.tickets where guest_name = 'Sara';
insert into ids select 'sara_qr', qr_token from public.tickets where guest_name = 'Sara';

select ok((select user_id is null and guest_email = 'sara@example.com' and title = 'Safety Day 2026'
                  and length(link_token) = 48 and length(qr_token) = 64 and email_sent_at is not null
           from public.tickets where guest_name = 'Sara'), 'guest stored in visit tickets, marked as emailed');
select is((select count(*) from pg_temp.invite_calls() c where c->>'guestEmail' = 'sara@example.com')::int, 1, 'invite email queued for Sara');
select is((select count(*) from pg_temp.invite_calls() c where c->>'guestName' = 'Omar')::int, 0, 'no email for a guest without one');
select ok((select c->>'eventNameAr' = 'يوم السلامة' and c->'_headers'->>'x-invite-secret' = 's3cret' and length(c->>'linkToken') = 48
           from pg_temp.invite_calls() c where c->>'guestEmail' = 'sara@example.com'), 'email request carries event, secret header and link');
select ok((select bool_and((convert_from(q.body, 'utf8')::jsonb->'record'->>'email_sent_at') is not null)
           from net.http_request_queue q
           where q.url like '%/send-ticket-email'
             and convert_from(q.body, 'utf8')::jsonb->'record'->>'guest_name' is not null),
          'visit''s send_ticket_email webhook gets guest rows already marked as emailed (so it skips them)');
select ok((select (convert_from(q.body, 'utf8')::jsonb->'record'->>'email_sent_at') is null
           from net.http_request_queue q
           where q.url like '%/send-ticket-email'
             and convert_from(q.body, 'utf8')::jsonb->'record'->>'id' = '30000000-0000-0000-0000-000000000001'),
          'app tickets still go to visit''s ticket email as before');

-- ---------------------------------------------------------------- app isolation

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a3', true);
set local role authenticated;
select results_eq($$ select title from public.tickets $$, $$ values ('Concert'::text) $$, 'app user still sees only own ticket');
select is((select count(*) from public.mobile_tickets)::int >= 0, true, 'app user mobile_tickets view still works');
reset role;
set local role anon;
select throws_ok($$ select count(*) from public.tickets $$, '42501', null, 'anon cannot read tickets');
reset role;
select throws_ok($$ insert into public.tickets (event_id, title) values ((select v::uuid from ids where k = 'ev'), 'x') $$,
                 '23514', null, 'a ticket with neither user nor guest is still refused');

-- ---------------------------------------------------------------- public page + registration

set local role anon;
select results_eq($$ select name, spots_left, registration_open from public.invite_get_event((select v from ids where k = 'slug')) $$,
                  $$ values ('Safety Day 2026'::text, 1, true) $$, 'public sees the event and spots left');
select is((select count(*) from public.invite_get_event((select slug from public.events where id = '20000000-0000-0000-0000-000000000001')))::int, 0,
          'public page never shows a visit app event');
reset role;

select set_config('request.headers', '{"x-forwarded-for":"1.2.3.4, 10.0.0.1"}', true);
set local role anon;
select throws_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'Bot', 'bot@x.com', null, 'spam') $$, null::char(5), 'registration_closed', 'honeypot blocks bots');
select throws_ok($$ select public.invite_register((select v from ids where k = 'slug'), ' ', 'n@x.com') $$, null::char(5), 'name_required', 'register: name required');
select throws_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'N', 'nope') $$, null::char(5), 'bad_email', 'register: bad email');
select throws_ok($$ select public.invite_register('no-such-event', 'N', 'n@x.com') $$, null::char(5), 'event_not_found', 'register: unknown event');
select lives_ok($$ insert into ids select 'huda_link', public.invite_register((select v from ids where k = 'slug'), 'Huda', 'Huda@x.com', '0551112222') $$, 'anyone registers');
reset role;
select is(length((select v from ids where k = 'huda_link')), 48, 'registration returns the ticket link');
select is((select count(*) from pg_temp.invite_calls() c where c->>'guestEmail' = 'huda@x.com')::int, 1, 'registration email queued');
set local role anon;
select is((select guest_name from public.invite_get_ticket((select v from ids where k = 'huda_link'))), 'Huda', 'new guest opens the ticket');
select throws_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'Late', 'late@x.com') $$, null::char(5), 'event_sold_out', 'full event refuses registration');
select is((select spots_left from public.invite_get_event((select v from ids where k = 'slug'))), 0, 'spots left = 0');
reset role;

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json('{"capacity":"10"}')) $$, 'capacity raised to 10');
reset role;

set local role anon;
select is(public.invite_register((select v from ids where k = 'slug'), 'Huda again', 'HUDA@x.com'), 'already_registered', 'same email cannot register twice');
reset role;
select is((select count(*) from pg_temp.invite_calls() c where c->>'guestEmail' = 'huda@x.com')::int, 2, 'ticket re-sent to that inbox, not shown');
set local role anon;
select public.invite_register((select v from ids where k = 'slug'), 'h', 'huda@x.com');
select public.invite_register((select v from ids where k = 'slug'), 'h', 'huda@x.com');
select public.invite_register((select v from ids where k = 'slug'), 'h', 'huda@x.com');
reset role;
select is((select count(*) from pg_temp.invite_calls() c where c->>'guestEmail' = 'huda@x.com')::int, 4, 're-sends limited to 3 per hour');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json('{"capacity":"10","registration_open":false}')) $$, 'registration closed');
reset role;
set local role anon;
select throws_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'Z', 'z@x.com') $$, null::char(5), 'registration_closed', 'closed registration refused');
select is((select registration_open from public.invite_get_event((select v from ids where k = 'slug'))), false, 'page shows closed');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json('{"capacity":"10"}')) $$, 'registration reopened');
reset role;

insert into public.edge_rate_limits (bucket, window_start, count) values ('invite-register:9.9.9.9', now(), 60);
select set_config('request.headers', '{"x-forwarded-for":"9.9.9.9"}', true);
set local role anon;
select throws_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'Y', 'y@x.com') $$, null::char(5), 'too_many_attempts', 'rate limit per IP');
reset role;
select set_config('request.headers', '', true);
set local role anon;
select lives_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'Y', 'y@x.com') $$, 'no IP header still registers');
reset role;

-- ---------------------------------------------------------------- resend / new link / cancel

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok($$ select public.invite_resend_email((select v::uuid from ids where k = 'sara')) $$, 'organiser re-sends an email');
select throws_ok($$ select public.invite_resend_email((select v::uuid from ids where k = 'omar')) $$, null::char(5), 'no_email', 'resend without an email refused');
select throws_ok($$ select public.invite_resend_email('30000000-0000-0000-0000-000000000001') $$, null::char(5), 'ticket_not_active', 'cannot resend a visit app ticket');
select throws_ok($$ select public.invite_cancel_ticket('30000000-0000-0000-0000-000000000001') $$, null::char(5), 'ticket_not_active', 'cannot cancel a visit app ticket');
select throws_ok($$ select public.invite_regenerate_link('30000000-0000-0000-0000-000000000001') $$, null::char(5), 'ticket_not_active', 'cannot regenerate a visit app ticket');
select lives_ok($$ select public.invite_regenerate_link((select v::uuid from ids where k = 'sara')) $$, 'new link for Sara');
reset role;
select is((select status from public.tickets where id = '30000000-0000-0000-0000-000000000001'), 'active', 'visit app ticket untouched');
select is((select count(*) from pg_temp.invite_calls() c where c->>'guestEmail' = 'sara@example.com')::int, 3, 'resend and new link both email Sara');
select ok((select link_token <> (select v from ids where k = 'sara_link') and qr_token <> (select v from ids where k = 'sara_qr')
           from public.tickets where id = (select v::uuid from ids where k = 'sara')), 'new link and QR replace the old ones');
set local role anon;
select is((select count(*) from public.invite_get_ticket((select v from ids where k = 'sara_link')))::int, 0, 'old link stops working');
select is((select count(*) from public.invite_get_ticket('short'))::int, 0, 'bad link returns nothing');
reset role;

-- ---------------------------------------------------------------- scanning

-- Codes read here as admin: RLS rightly hides guest rows from the staff roles.
insert into ids select 'sara_qr2', qr_token from public.tickets where guest_name = 'Sara';
insert into ids select 'omar_qr', qr_token from public.tickets where guest_name = 'Omar';
insert into ids select 'omar_link', link_token from public.tickets where guest_name = 'Omar';
insert into ids select 'app_qr', qr_token from public.tickets where id = '30000000-0000-0000-0000-000000000001';

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a3', true);
set local role authenticated;
select throws_ok($$ select public.invite_scan_ticket('x') $$, null::char(5), 'not_scanner', 'app user cannot scan');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a4', true);
set local role authenticated;
select throws_ok($$ select public.invite_scan_ticket('x') $$, null::char(5), 'not_scanner', 'visit admin cannot scan');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a2', true);
set local role authenticated;
select is((select status from public.invite_scan_ticket((select v from ids where k = 'sara_qr'))), 'invalid_ticket', 'old QR is invalid');
select results_eq($$ select status, guest_name, note from public.invite_scan_ticket(
                       (select v from ids where k = 'sara_qr2'),
                       (select v::uuid from ids where k = 'ev')) $$,
                  $$ values ('ticket_redeemed'::text, 'Sara'::text, 'VIP'::text) $$, 'scanner checks the guest in');
select is((select status from public.invite_scan_ticket((select v from ids where k = 'sara_qr2'))), 'ticket_already_redeemed', 'second scan = already used');
select is((select status from public.invite_scan_ticket((select v from ids where k = 'app_qr'))), 'invalid_ticket', 'visit app ticket is invalid at this gate');
reset role;
select is((select status from public.tickets where id = '30000000-0000-0000-0000-000000000001'), 'active', 'visit app ticket not redeemed');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok($$ select public.invite_cancel_ticket((select v::uuid from ids where k = 'omar')) $$, 'organiser cancels Omar');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a2', true);
set local role authenticated;
select is((select status from public.invite_scan_ticket((select v from ids where k = 'omar_qr'))), 'ticket_cancelled', 'cancelled ticket refused at the gate');
reset role;
set local role anon;
select results_eq($$ select qr_token, status from public.invite_get_ticket((select v from ids where k = 'omar_link')) $$,
                  $$ values (null::text, 'cancelled'::text) $$, 'cancelled ticket page shows no QR');
reset role;
select is((select count(*) from public.ticket_scans where ticket_id in (select id from public.tickets where guest_name in ('Sara', 'Omar')))::int, 3,
          'scans logged in visit ticket_scans');

-- ---------------------------------------------------------------- rename, delete

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json('{"name":"Safety Day 2027","capacity":"10"}')) $$, 'rename event');
reset role;
select is((select count(*) from public.tickets where event_id = (select v::uuid from ids where k = 'ev') and title <> 'Safety Day 2027')::int, 0, 'rename updates guest ticket titles');
select is((select title from public.tickets where id = '30000000-0000-0000-0000-000000000001'), 'Concert', 'app ticket title untouched');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select throws_ok($$ select public.invite_delete_event((select v::uuid from ids where k = 'ev')) $$, null::char(5), 'event_has_guests', 'event with guests cannot be deleted');
select throws_ok($$ select public.invite_delete_event('20000000-0000-0000-0000-000000000001') $$, null::char(5), 'event_not_found', 'cannot delete a visit app event');
select lives_ok($$ insert into ids select 'empty', public.invite_save_event(null, pg_temp.event_json('{"name":"Empty"}'))::text $$, 'create an empty event');
select lives_ok($$ select public.invite_delete_event((select v::uuid from ids where k = 'empty')) $$, 'empty event deleted');
reset role;
select is((select count(*) from public.event_translations where event_id = (select v::uuid from ids where k = 'empty'))::int, 0, 'its translations deleted');
select is((select count(*) from public.events where id = '20000000-0000-0000-0000-000000000001')::int, 1, 'visit app event still there');

-- ---------------------------------------------------------------- cover upload policy (real storage)

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('events', 'invite/10000000-0000-0000-0000-0000000000a1/1.jpg') $$, 'organiser uploads to own invite folder');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('events', 'invite/10000000-0000-0000-0000-0000000000a2/1.jpg') $$, '42501', null, 'not into another user''s folder');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('events', 'banners/1.jpg') $$, '42501', null, 'not outside invite/');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a2', true);
set local role authenticated;
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('events', 'invite/10000000-0000-0000-0000-0000000000a2/1.jpg') $$, '42501', null, 'scanner cannot upload');
reset role;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a3', true);
set local role authenticated;
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('events', 'invite/10000000-0000-0000-0000-0000000000a3/1.jpg') $$, '42501', null, 'app user cannot upload');
reset role;

-- ---------------------------------------------------------------- email problems never block tickets

delete from vault.secrets where name = 'invite_email_secret';
set local role anon;
select lives_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'NoMail', 'nomail@x.com') $$, 'missing secret: ticket still made');
reset role;
select is((select count(*) from pg_temp.invite_calls() c where c->>'guestEmail' = 'nomail@x.com')::int, 0, 'missing secret: email skipped');

-- ---------------------------------------------------------------- last place goes to one person

insert into ids select 'live_plus_one', (count(*) + 1)::text from public.tickets
  where event_id = (select v::uuid from ids where k = 'ev') and status <> 'cancelled';
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-0000000000a1', true);
set local role authenticated;
select lives_ok(format($$ select public.invite_save_event((select v::uuid from ids where k = 'ev'), pg_temp.event_json('{"name":"Safety Day 2027","capacity":"%s"}')) $$,
                       (select v from ids where k = 'live_plus_one')),
                'one place left');
reset role;
set local role anon;
select lives_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'Last1', 'last1@x.com') $$, 'first person gets the last place');
select throws_ok($$ select public.invite_register((select v from ids where k = 'slug'), 'Last2', 'last2@x.com') $$, null::char(5), 'event_sold_out', 'second person is refused');
reset role;

select * from finish();
rollback;
