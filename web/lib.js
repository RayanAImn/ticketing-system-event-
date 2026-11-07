// Shared helpers for ticket.html, admin.html and scan.html.
(function () {
  const cfg = window.APP_CONFIG;
  const db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);

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
        await db.auth.signOut();
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
    await db.auth.signOut();
    location.reload();
  }

  window.T = { db, $, esc, fmtDate, ticketUrl, setupLogin, signOut };
})();
