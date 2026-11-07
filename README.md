# Event Tickets (invite-only)

Invite-only guest tickets for one event, stored in the **visit app's own `tickets` table** in the visit Supabase project (`vdsuwbpvpdzdmmexmgzz`). Guest tickets are free tickets with a guest name instead of an app account. The site's code lives here, outside visit-app.

- **Admins** add guests, one at a time or from a pasted list or CSV. Each guest gets a ticket.
- **Guests** never sign up. They open a personal link `/t/<token>` that shows their name, the event details and a QR code.
- **Staff** scan the QR at the entrance on `/scan`. Each ticket gets in once. A second scan shows "Already used".

| Page | Who | What |
|---|---|---|
| `/admin` (also `/`) | admin | create event, add/import guests, copy link / WhatsApp, new link, cancel, live check-in counts, CSV export |
| `/t/<token>` | guest | the ticket with QR, Arabic + English |
| `/scan` | admin, scanner | camera scanner + manual entry |

## What the SQL changes in visit's database

- **`tickets`:** `user_id` may now be empty for guest tickets, and 5 columns are added: `guest_name`, `guest_phone`, `guest_email`, `guest_note`, `link_token`. A rule still requires every ticket to have an app user or a guest name.
- **`roles`:** one new row, `ticket_scanner`.
- **8 new functions:** `invite_staff_role`, `invite_list_events`, `invite_list_tickets`, `invite_create_tickets`, `invite_cancel_ticket`, `invite_regenerate_link`, `invite_get_ticket`, `invite_scan_ticket`.
- **No new tables.** `events`, `ticket_payments`, the payment and ticket functions, the `mobile_*` views, Moyasar and Tamara are untouched.

App users still see only their own tickets, so guest tickets never appear in anyone's app wallet. visit's own scanner (`scan_ticket_qr` and the dashboard's `/admin/scan`) also accepts guest tickets.

## Setup (one time)

1. **Run the SQL.** Paste `supabase/migrations/0001_invite_tickets.sql` into the SQL editor (https://supabase.com/dashboard/project/vdsuwbpvpdzdmmexmgzz/sql/new) and run it.
2. **Create the event** in the visit admin dashboard with status **Draft**, booking mode **Ticket** and no price. Draft events never show in the app. Set a capacity if there is a limit.
3. **Admins** are the existing visit admins (`admin_users`). **Gate staff** need the scanner role:
   ```sql
   insert into public.user_roles (user_id, role_id)
   select u.id, r.id from auth.users u, public.roles r
   where u.email = 'gate1@example.com' and r.name = 'ticket_scanner';
   ```
   Staff sign in with email and password.
4. **Config:** `web/config.js` already has the visit project URL and public key.
5. **Deploy:** import this folder into Vercel as a **new** project (not `visit-app`). The camera needs HTTPS, which Vercel provides.

## Run locally

```
npm run dev
```
Then open `http://localhost:5173`. It opens the admin page at `/`, and `/t/<token>` ticket links work locally too.

## Removing it later

```sql
drop function if exists public.invite_scan_ticket(text, uuid), public.invite_get_ticket(text),
  public.invite_regenerate_link(uuid), public.invite_cancel_ticket(uuid),
  public.invite_create_tickets(uuid, jsonb), public.invite_list_tickets(uuid),
  public.invite_list_events(), public.invite_staff_role();
-- The guest columns can stay. To drop them, delete the guest tickets first,
-- then drop the tickets_user_or_guest constraint and restore user_id NOT NULL.
```

## Security notes

- Guest rows have no user, so visit's rule that app users read only their own tickets keeps them hidden from every app user.
- Tickets are created only by `invite_create_tickets`, which checks visit's admin role on the server and accepts only Draft, free, ticket-mode events.
- `invite_scan_ticket` checks the admin or ticket_scanner role on the server. visit's `scan_ticket_qr` lets any signed-in user scan; that gap is unchanged for the app's own scanner.
- A guest link holds 48 random hex characters and the QR holds 64. Neither can be guessed. Anyone who has the link can show the ticket, but it can be scanned only once.
- If a link reaches the wrong person, use **New link**. The old link and QR stop working, so send the guest the new one.
- **Cancel** blocks the ticket at the gate, and the guest's page shows it as cancelled.

## Branding (JESCO & ArcelorMittal Safety Event)

From `JESCO & Mittal _Event_Identity_Print_Fonts.zip`:

- **Colours:** event blue `#233D7C` as the base, white, and safety orange `#F05A22` for small accents only.
- **Font:** IBM Plex Sans Arabic (SIL Open Font License), loaded from Google Fonts.
- **`web/brand/hero.webp`:** the original 4000أ—2000 branding wall artwork, rendered unchanged at 1400أ—700 for the top of the ticket. It includes both logos and the two-font slogan.
- **`web/brand/jesco.png`, `arcelormittal.png`:** the white marks, taken from the same artwork's vectors. They are used in the admin and scanner headers, JESCO left and ArcelorMittal right, without recolouring.
- **Lorian Xavien** (the handwritten font) is **not** used as a web font. Its licence is personal use only. The handwritten line appears only inside the original artwork image, as the guide recommends.
