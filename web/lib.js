// Shared helpers for every page.
(function () {
  const cfg = window.APP_CONFIG;
  const db = window.DEMO_DB || window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
  if (window.DEMO_DB) {
    document.addEventListener('DOMContentLoaded', () => document.body.insertAdjacentHTML('afterbegin',
      '<div class="demo-bar">Demo mode: sample data, nothing is saved · <a href="?demo=off">exit</a></div>'));
  }

  const $ = (sel, root = document) => root.querySelector(sel);

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    })[c]);
  }

  function fmtDate(iso, locale = 'en-GB') {
    if (!iso) return '';
    return new Date(iso).toLocaleString(locale, {
      weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
      hour: '2-digit', minute: '2-digit',
    });
  }

  function ticketUrl(linkToken) {
    return `${location.origin}/t/${linkToken}`;
  }

  function eventUrl(slug) {
    return `${location.origin}/e/${slug}`;
  }

  // ISO timestamp <-> value of an <input type="datetime-local"> (browser's time zone).
  function toLocalInput(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  }
  function fromLocalInput(v) {
    return v ? new Date(v).toISOString() : null;
  }

  // Database error codes -> words people understand.
  const ERRORS = {
    not_admin: 'This account cannot manage events.',
    name_required: 'Enter the event name.',
    city_required: 'Choose a city.',
    start_required: 'Choose the start date and time.',
    ends_before_start: 'The end time is before the start time.',
    capacity_below_guests: 'Capacity is lower than the number of guests already invited.',
    event_has_guests: 'This event has guests, so it cannot be deleted. Cancel it instead.',
    event_sold_out: 'Not enough places left for these guests.',
    no_guests: 'No guests found.',
    bad_image_url: 'The cover image link is not valid.',
    bad_capacity: 'Capacity must be a whole number.',
    description_too_long: 'Each description can be at most 500 characters.',
    bad_email: 'One of the emails is not valid.',
    email_already_invited: 'This email already has a ticket for this event.',
    staff_id_already_invited: 'This staff ID already has a ticket for this event.',
    too_many_guests: 'Import at most 2000 guests at a time.',
    ticket_not_active: 'This ticket is no longer active.',
    no_email: 'This guest has no email address.',
    event_not_found: 'Event not found.',
  };
  // A request that reaches the database without a signed-in user means this
  // browser lost its login: say so and go back to the login form.
  const SIGNED_OUT = /permission denied for function|JWT expired|invalid JWT|not_authenticated/i;
  function errText(error) {
    const code = (error && error.message) || String(error);
    if (SIGNED_OUT.test(code)) {
      setTimeout(() => location.reload(), 0);
      return 'You were signed out. Please sign in again.';
    }
    return ERRORS[code] || code;
  }

  if (!window.DEMO_DB) {
    db.auth.onAuthStateChange((event) => {
      const app = document.getElementById('app');
      if (event === 'SIGNED_OUT' && app && !app.hidden) location.reload();
    });
  }

  // Signs in a staff user and resolves their role ('admin' | 'scanner'), or null.
  async function staffRole() {
    const { data: { session } } = await db.auth.getSession();
    if (!session) return null;
    const { data, error } = await db.rpc('invite_staff_role');
    if (error) throw error;
    return data;
  }

  // Wires a login form; calls onReady(role) once a staff user is signed in.
  function setupLogin({ form, app, onReady, allowed }) {
    const err = $('.login-error', form);
    async function check() {
      let role = null;
      try { role = await staffRole(); } catch (e) { err.textContent = e.message; }
      const { data: { session } } = await db.auth.getSession();
      if (session && !allowed.includes(role)) {
        err.textContent = 'This account has no access to this page.';
        // 'local': sign out this browser only, not the account's other devices.
        await db.auth.signOut({ scope: 'local' });
        role = null;
      }
      form.hidden = !!role;
      app.hidden = !role;
      if (role) onReady(role);
    }
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      err.textContent = '';
      const { error } = await db.auth.signInWithPassword({
        email: form.email.value.trim(),
        password: form.password.value,
      });
      if (error) { err.textContent = error.message; return; }
      check();
    });
    check();
  }

  async function signOut() {
    await db.auth.signOut({ scope: 'local' });
    location.reload();
  }

  window.T = { db, $, esc, fmtDate, ticketUrl, eventUrl, toLocalInput, fromLocalInput, errText, setupLogin, signOut };
})();
