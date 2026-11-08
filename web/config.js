// Visit Supabase project (vdsuwbpvpdzdmmexmgzz), the same public key the visit app ships.
// The anon/publishable key is safe to ship; the database rules protect the data.
window.APP_CONFIG = {
  SUPABASE_URL: 'https://vdsuwbpvpdzdmmexmgzz.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_m4TH5r2WpWUcGQSU-IYiLA_qcoRMvu1',
  // Text before the link in the WhatsApp message the admin page prepares.
  // Show "Add to Apple Wallet" on the ticket page (needs invite-wallet-pass deployed with its secrets).
  APPLE_WALLET: true,
  INVITE_MESSAGE: 'You are invited! Your personal ticket:\nأنت مدعو! تذكرتك الشخصية:',
};
