// Demo mode: open any page with ?demo to click through it with sample data and no
// database. Stays on for the browser tab until ?demo=off. Nothing is saved.
(function () {
  const q = new URLSearchParams(location.search);
  try {
    if (q.has('demo')) sessionStorage.setItem('demo', q.get('demo') === 'off' ? '' : '1');
    if (!sessionStorage.getItem('demo')) return;
  } catch { if (!q.has('demo') || q.get('demo') === 'off') return; }

  const hex = (n) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => b.toString(16).padStart(2, '0')).join('');
  const cities = [
    { id: 'c1', name: 'Jubail', name_ar: 'الجبيل' },
    { id: 'c2', name: 'Dammam', name_ar: 'الدمام' },
    { id: 'c3', name: 'Al Khobar', name_ar: 'الخبر' },
  ];
  const events = [{
    id: 'e1', slug: 'safety-day-2026', name: 'Safety Day 2026', name_ar: 'يوم السلامة 2026',
    description: 'A day of hands-on safety workshops, live demonstrations and recognition for the teams that keep our lines safe.\n\nLearn it, live it, prove it, take it back to the line.',
    description_ar: 'يوم من ورش العمل التطبيقية والعروض الحية وتكريم الفرق التي تحافظ على سلامة خطوط الإنتاج.',
    starts_at: '2026-12-10T06:00:00Z', ends_at: '2026-12-10T12:00:00Z', venue: 'JESCO Main Hall', location_url: 'https://maps.app.goo.gl/9bhjeu8xQ1PwZLbC9',
    city_id: 'c1', capacity: 150, image_url: '/brand/hero.webp', registration_open: true,
  }, {
    id: 'e2', slug: 'safety-day-2025', name: 'Safety Day 2025', name_ar: 'يوم السلامة 2025',
    description: 'Last year\'s safety day.', description_ar: null,
    starts_at: '2025-12-11T06:00:00Z', ends_at: '2025-12-11T12:00:00Z', venue: 'JESCO Main Hall', location_url: null,
    city_id: 'c1', capacity: null, image_url: '/brand/hero.webp', registration_open: false,
  }];
  const tickets = [
    { id: 't1', event_id: 'e1', guest_name: 'Sara Alqahtani', guest_phone: '0551234567', guest_email: 'sara@example.com', guest_note: 'VIP', guest_staff_id: '10234', status: 'redeemed', redeemed_at: '2026-12-10T06:12:00Z' },
    { id: 't2', event_id: 'e1', guest_name: 'Omar Alharbi', guest_phone: '0559876543', guest_email: 'omar@example.com', guest_note: null, guest_staff_id: '10587', status: 'active' },
    { id: 't3', event_id: 'e1', guest_name: 'Huda Alshehri', guest_phone: null, guest_email: 'huda@example.com', guest_note: 'Speaker', status: 'active' },
    { id: 't4', event_id: 'e2', guest_name: 'Faisal Aldossary', guest_phone: '0553334444', guest_email: 'faisal@example.com', guest_note: null, guest_staff_id: '9871', status: 'redeemed', redeemed_at: '2025-12-11T06:20:00Z' },
    { id: 't5', event_id: 'e2', guest_name: 'Noura Alotaibi', guest_phone: null, guest_email: 'noura@example.com', guest_note: null, guest_staff_id: '9902', status: 'active' },
  ].map((t) => ({ ...t, link_token: hex(24), qr_token: hex(32), created_at: new Date().toISOString() }));

  const live = (e) => tickets.filter((t) => t.event_id === e.id && t.status !== 'cancelled').length;
  // Same rules as the database: an ended event is read only and its active tickets are expired.
  const ended = (e) => new Date(e.ends_at || e.starts_at) <= new Date();
  const eventOf = (id) => events.find((e) => e.id === id);
  const shown = (t) => (t.status === 'active' && ended(eventOf(t.event_id)) ? { ...t, status: 'expired' } : t);
  const open = (id) => { if (ended(eventOf(id))) throw 'event_closed'; };
  const openTicket = (id) => open(tickets.find((t) => t.id === id).event_id);
  const fail = (code) => ({ data: null, error: { message: code } });
  const addGuests = (ev, guests) => {
    guests = guests.filter((g) => (g.name || '').trim());
    if (ev.capacity != null && live(ev) + guests.length > ev.capacity) return null;
    return guests.map((g) => {
      const t = { id: hex(8), event_id: ev.id, guest_name: g.name.trim(), guest_phone: g.phone || null,
        guest_email: (g.email || '').toLowerCase() || null, guest_note: g.note || null, guest_staff_id: g.staff_id || null, status: 'active',
        link_token: hex(24), qr_token: hex(32), created_at: new Date().toISOString() };
      tickets.unshift(t);
      return t;
    });
  };

  const handlers = {
    invite_staff_role: () => 'admin',
    invite_assigned_only: () => false,
    invite_list_organisers: () => [{ user_id: 'u1', email: 'organiser@example.com', signed_in: true, is_you: true }],
    invite_remove_organiser: ({ p_event_id }) => { open(p_event_id); return null; },
    invite_list_cities: () => cities,
    invite_list_events: () => events.map((e) => ({ ...e, closed: ended(e),
      invited: live(e), checked_in: tickets.filter((t) => t.event_id === e.id && t.status === 'redeemed').length })),
    invite_save_event: ({ p_event_id, p_event }) => {
      const fields = { ...p_event, capacity: p_event.capacity === '' || p_event.capacity == null ? null : +p_event.capacity };
      if (p_event_id) { open(p_event_id); Object.assign(events.find((e) => e.id === p_event_id), fields); return p_event_id; }
      const e = { ...fields, id: hex(8), slug: 'event-' + hex(3) };
      events.unshift(e);
      return e.id;
    },
    invite_delete_event: ({ p_event_id }) => {
      open(p_event_id);
      if (tickets.some((t) => t.event_id === p_event_id)) throw 'event_has_guests';
      events.splice(events.findIndex((e) => e.id === p_event_id), 1);
    },
    invite_list_tickets: ({ p_event_id }) => tickets.filter((t) => t.event_id === p_event_id).map(shown),
    invite_create_tickets: ({ p_event_id, p_guests }) => {
      open(p_event_id);
      const made = addGuests(events.find((e) => e.id === p_event_id), p_guests);
      if (!made) throw 'event_sold_out';
      return made.length;
    },
    invite_cancel_ticket: ({ p_ticket_id }) => { openTicket(p_ticket_id); tickets.find((t) => t.id === p_ticket_id).status = 'cancelled'; },
    invite_regenerate_link: ({ p_ticket_id }) => { openTicket(p_ticket_id); Object.assign(tickets.find((t) => t.id === p_ticket_id), { link_token: hex(24), qr_token: hex(32) }); },
    invite_resend_email: ({ p_ticket_id }) => { openTicket(p_ticket_id); return null; },
    invite_resend_all_emails: ({ p_event_id }) => {
      open(p_event_id);
      return tickets.filter((t) => t.event_id === p_event_id && t.status === 'active' && t.guest_email).length;
    },
    invite_get_event: ({ p_slug }) => events.filter((e) => e.slug === p_slug).map((e) => {
      const c = cities.find((x) => x.id === e.city_id) || {};
      return { ...e, city: c.name, city_ar: c.name_ar, spots_left: e.capacity == null ? null : Math.max(e.capacity - live(e), 0) };
    }),
    invite_register: ({ p_slug, p_name, p_email, p_phone }) => {
      const ev = events.find((e) => e.slug === p_slug);
      if (!ev) throw 'event_not_found';
      if (!ev.registration_open) throw 'registration_closed';
      if (tickets.some((t) => t.event_id === ev.id && t.guest_email === p_email.toLowerCase() && t.status !== 'cancelled')) return 'already_registered';
      const made = addGuests(ev, [{ name: p_name, email: p_email, phone: p_phone }]);
      if (!made) throw 'event_sold_out';
      return made[0].link_token;
    },
    invite_get_ticket: ({ p_link_token }) => tickets.filter((t) => t.link_token === p_link_token).map(shown).map((t) => {
      const e = events.find((x) => x.id === t.event_id);
      return { ...t, staff_id: t.guest_staff_id, qr_token: t.status === 'cancelled' || t.status === 'expired' ? null : t.qr_token, event_name: e.name, event_name_ar: e.name_ar,
        venue: e.venue, starts_at: e.starts_at, ends_at: e.ends_at };
    }),
    invite_scan_ticket: ({ p_qr_token, p_event_id }) => {
      const t = tickets.find((x) => x.qr_token === p_qr_token.trim());
      const now = new Date().toISOString();
      if (!t) return [{ status: 'invalid_ticket', scanned_at: now }];
      let status = 'ticket_redeemed';
      if (p_event_id && t.event_id !== p_event_id) status = 'wrong_event';
      else if (t.status === 'cancelled') status = 'ticket_cancelled';
      else if (t.status === 'redeemed') status = 'ticket_already_redeemed';
      else if (ended(eventOf(t.event_id))) status = 'ticket_expired';
      else Object.assign(t, { status: 'redeemed', redeemed_at: now });
      return [{ status, ticket_id: t.id, guest_name: t.guest_name, staff_id: t.guest_staff_id, note: t.guest_note, redeemed_at: t.redeemed_at, scanned_at: now }];
    },
  };

  // Persist across page loads in this tab so a registration shows up on the admin page.
  try {
    const saved = JSON.parse(sessionStorage.getItem('demo-data') || 'null');
    if (saved) { events.splice(0, events.length, ...saved.events); tickets.splice(0, tickets.length, ...saved.tickets); }
  } catch { /* first visit */ }
  const save = () => { try { sessionStorage.setItem('demo-data', JSON.stringify({ events, tickets })); } catch { /* ignore */ } };

  function rpc(name, args = {}) {
    let result;
    try { result = { data: handlers[name](args) ?? null, error: null }; save(); }
    catch (code) { result = fail(String(code)); }
    const p = new Promise((r) => setTimeout(() => r(result), 150));
    p.range = () => p;
    return p;
  }

  const session = { user: { id: 'demo-user', email: 'organiser@example.com' } };
  window.DEMO_DB = {
    rpc,
    auth: {
      getSession: async () => ({ data: { session } }),
      signInWithPassword: async () => ({ error: null }),
      signOut: async () => { try { sessionStorage.removeItem('demo'); } catch { /* ignore */ } },
    },
    // invite-organiser: pretends the organiser was added and emailed.
    functions: { invoke: async () => ({ data: { result: 'added', emailed: true }, error: null }) },
    storage: {
      from: () => ({
        // Shows the picked image without uploading it anywhere.
        upload: async (path, file) => ({ data: { path: URL.createObjectURL(file) }, error: null }),
        getPublicUrl: (path) => ({ data: { publicUrl: path } }),
      }),
    },
  };
})();
