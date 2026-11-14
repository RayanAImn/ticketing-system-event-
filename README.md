# Event Tickets (JESCO)

A Luma-style event site whose data lives in the **visit app's own `events` and `tickets` tables** in the visit Supabase project (`vdsuwbpvpdzdmmexmgzz`). The site's code lives here, outside visit-app.

| Page | Who | What |
|---|---|---|
| `/` | organiser (`event_manager`) | create and edit events (cover, name EN/AR, dates, venue, city, capacity, public registration on/off), add or import guests, resend email (one guest or all), copy link, WhatsApp, new link, cancel, live counts, CSV |
| `/e/<slug>` | anyone with the link | event page with a sign-up form, until the capacity is full |
| `/t/<token>` | guest | the ticket with QR, Arabic + English |
| `/scan` | organiser, scanner (`ticket_scanner`) | camera scanner + manual entry |

Every guest with an email gets their ticket by email, sent from visit's sender (`noreply@visitapp.sa`) with this event's own content. Add `?demo` to any page to try it with sample data and no database.

## What the SQL changes in visit's database

`supabase/migrations/0001_invite_tickets.sql`:

- **`tickets`:** `user_id` may be empty for guest tickets; adds `guest_name`, `guest_phone`, `guest_email`, `guest_note`, `guest_staff_id`, `link_token`. A rule still requires every ticket to have an app user or a guest name. One live ticket per email per event.
- **`events`:** adds `invite_managed` (marks this site's events) and `invite_registration_open`. Events made here are saved as **Draft**, ticket mode, free, hidden from "view all", so the visit app never shows them. They do appear as Draft in the visit admin dashboard.
- **`roles`:** two new rows, `event_manager` and `ticket_scanner`. Visit admins get no access to this site.
- **Functions:** all named `invite_*`, each checking the role on the server.
- **Trigger:** `tickets_invite_email` runs after a guest ticket with an email is inserted. App tickets never trigger it.
- **Storage:** organisers may upload covers only to `events/invite/<their id>/`.
- **Not touched:** `ticket_payments`, visit's ticket, payment and scan functions, the `mobile_*` views, Moyasar, Tamara, visit's `send-booking-email`.

Every function only works on events with `invite_managed = true`, so visit app events and tickets cannot be read, changed or scanned from this site.

Once an event has ended (its end time, or its start time when it has no end, has passed) it is **closed**: the organiser page for it is read only (no editing or deleting the event, no adding, cancelling, re-linking or emailing guests, no adding or removing organisers), and its tickets show and scan as **expired**. The database enforces this, not just the page. A database set up before this change runs `supabase/migrations/0009_closed_events.sql` once.

**Daily attendance.** A ticket checks in **once per day** (Riyadh time): on the second day of an event the same QR checks in again, and only a second scan on the same day says "Already used". The ticket's check-in time stays the first one. The event page has an **Attendance by day** table: for each day, the guests scanned, a **By bus** count the organiser types in for people who came without being scanned, and the total. Bus counts can still be entered after the event has ended. A saved bus count is final: the page shows it as text and the database refuses any change (`bus_count_saved`). A database set up before this change runs `supabase/migrations/0010_daily_attendance.sql` and then `supabase/migrations/0013_lock_bus_counts.sql` once.

**Statistics.** Under it, a **Statistics · الإحصائيات** card shows guests scanned at least once, guests who came every day (events of more than one day), guests never scanned, the bus counts added up, and each day's busiest hour. A database set up before this change runs `supabase/migrations/0011_event_stats.sql` once.

**Expired tickets are saved.** A pg_cron job (`invite-expire-tickets`, every 5 minutes) saves the active tickets of this site's ended events as `expired` in the table, so visit's dashboard and any export show them as expired too. Checked-in and cancelled tickets, and visit app tickets, are left as they are. A database set up before this change runs `supabase/migrations/0012_expire_tickets.sql` once.

## Setup (one time)

1. **Run the SQL.** Paste `supabase/migrations/0001_invite_tickets.sql` into the SQL editor (https://supabase.com/dashboard/project/vdsuwbpvpdzdmmexmgzz/sql/new) and run it.
2. **Email secret.** Make one random value and store it in two places:
   ```sql
   select vault.create_secret('<random value>', 'invite_email_secret');
   ```
   ```
   npx supabase secrets set --project-ref vdsuwbpvpdzdmmexmgzz INVITE_EMAIL_SECRET=<random value> INVITE_SITE_URL=https://<this site's domain>
   ```
   `RESEND_API_KEY`, `RESEND_FROM_EMAIL` and the Vault secret `project_url` already exist for visit.
3. **Deploy the email function:**
   ```
   npx supabase functions deploy invite-ticket-email --project-ref vdsuwbpvpdzdmmexmgzz --no-verify-jwt
   ```
4. **Apple Wallet (optional).** Adds an **Add to Apple Wallet** button to the email and, on Apple devices, to the ticket page. It needs a Pass Type ID certificate from the Apple Developer account and Apple's WWDR G4 intermediate (https://www.apple.com/certificateauthority/AppleWWDRCAG4.cer).
   ```
   # From the certificate exported from Keychain as pass.p12:
   openssl pkcs12 -in pass.p12 -clcerts -nokeys -out pass-cert.pem
   openssl pkcs12 -in pass.p12 -nocerts -nodes -out pass-key.pem
   openssl x509 -inform der -in AppleWWDRCAG4.cer -out wwdr.pem
   npx supabase secrets set --project-ref vdsuwbpvpdzdmmexmgzz \
     APPLE_PASS_TYPE_ID=pass.<your.id> APPLE_TEAM_ID=<team id> \
     APPLE_PASS_CERT_PEM="$(cat pass-cert.pem)" APPLE_PASS_KEY_PEM="$(cat pass-key.pem)" APPLE_WWDR_PEM="$(cat wwdr.pem)"
   npx supabase functions deploy invite-wallet-pass --project-ref vdsuwbpvpdzdmmexmgzz --no-verify-jwt
   ```
   With OpenSSL 3, add `-legacy` to the two `pkcs12` commands if they fail. Then redeploy `invite-ticket-email`: the button appears only once `APPLE_PASS_TYPE_ID` is set. The site sends `/wallet/<token>` to this function (see `vercel.json`). A pass shows the ticket as it was when added; it doesn't update if the ticket is later cancelled or given a new link. Set `APPLE_WALLET: false` in `web/config.js` to hide the button on the ticket page. The images in `supabase/functions/invite-wallet-pass/images/` are embedded in `images.ts`; regenerate that file if they change.
5. **Roles.** Organisers and gate staff sign in with email and password:
   ```sql
   insert into public.user_roles (user_id, role_id)
   select u.id, r.id from auth.users u, public.roles r
   where u.email = 'organiser@example.com' and r.name = 'event_manager';   -- or 'ticket_scanner'
   ```
6. **Deploy the site:** import this folder into Vercel as a **new** project (not `visit-app`). The camera needs HTTPS, which Vercel provides.

## Run locally

```
npm run dev
```
Then open `http://localhost:5173/?demo`.

## Tests

- **Email function** (offline; nothing is sent): `npm install`, then `npm run test:email`.
- **Wallet pass** (offline; needs Deno and openssl): `npm run test:wallet`. Builds a pass with a throwaway certificate and checks its signature with openssl.
- **Database** (`supabase/tests/invite_tickets_test.sql`, pgTAP, 215 checks): run against a local copy of visit's database in Docker. Everything runs in one transaction that is rolled back.
  1. Start Docker Desktop.
  2. Make a folder outside visit-app with a `supabase/` folder holding a copy of visit-app's `supabase/config.toml`. Change its `project_id` and ports, and remove the `[functions.*]` sections.
  3. Copy in visit-app's `supabase/migrations/*`, then add `supabase/migrations/0001_invite_tickets.sql` as the newest migration and this test into `supabase/tests/database/`.
  4. Run `npx supabase@^2 start`, then `npx supabase@^2 test db`.

  Visit's migration history doesn't rebuild production on its own. The test copy needs:
  - `events.end_time` added before `20261025120000_event_venue_name.sql`
  - unique numbers for three pairs of migrations that share a version
  - production's `tickets.email_sent_at` column and `send_ticket_email` webhook added after the last visit migration

## Notes

- Emails share visit's Resend account and quota. Resend accepts a few emails per second; the function waits and retries, so a big list import is emailed over a minute or two.
- A failed email never blocks a ticket. Use **Resend email** on the guest's row, or **Email all** above the guest list to email every guest their ticket again.
- Someone signing up again with the same email doesn't see the ticket; it is emailed to that inbox again (at most 3 times an hour).
- Sign-ups are limited to 60 per 10 minutes per IP address (a whole office may share one).
- A guest link holds 48 random hex characters and the QR holds 64. If a link reaches the wrong person, use **New link**: the old link and QR stop working and the guest is emailed the new one.

## Removing it later

```sql
drop trigger if exists tickets_invite_email on public.tickets;
drop policy if exists "invite covers insert" on storage.objects;
drop policy if exists "invite covers update" on storage.objects;
drop policy if exists "invite covers delete" on storage.objects;
-- then drop the public.invite_* functions. The new columns can stay.
```

## Branding (JESCO & ArcelorMittal Safety Event)

From `JESCO & Mittal _Event_Identity_Print_Fonts.zip`:

- **Colours:** event blue `#233D7C` as the base, white, and safety orange `#F05A22` for small accents only.
- **Font:** IBM Plex Sans Arabic (SIL Open Font License), loaded from Google Fonts.
- **`web/brand/hero.webp`:** the original 4000أ—2000 branding wall artwork, rendered unchanged at 1400أ—700 for the top of the ticket. It includes both logos and the two-font slogan.
- **`web/brand/jesco.png`, `arcelormittal.png`:** the white marks, taken from the same artwork's vectors. They are used in the admin and scanner headers, JESCO left and ArcelorMittal right, without recolouring.
- **Lorian Xavien** (the handwritten font) is **not** used as a web font. Its licence is personal use only. The handwritten line appears only inside the original artwork image, as the guide recommends.
