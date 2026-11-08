// Runs supabase/functions/invite-ticket-email offline: Deno and serve() are stubbed,
// fetch to Resend is intercepted (never sent). Writes the rendered email to email-preview.html.
// Run: npm run test:email
import fs from 'node:fs';
import { transformSync } from 'esbuild';

const src = fs.readFileSync(new URL('../functions/invite-ticket-email/index.ts', import.meta.url), 'utf8')
  .replace(/^import \{ serve \} from .*$/m, 'const serve = globalThis.__serve;');
const js = transformSync(src, { loader: 'ts', format: 'esm' }).code;

const env = { INVITE_EMAIL_SECRET: 'test-secret', INVITE_SITE_URL: 'http://localhost:5173/', RESEND_API_KEY: 'fake-key', RESEND_FROM_EMAIL: 'Visit Sharqia <noreply@visitapp.sa>' };
globalThis.Deno = { env: { get: (k) => env[k] } };
let handler;
globalThis.__serve = (h) => { handler = h; };
const sent = [];
let resendStatus = 200;
globalThis.fetch = async (url, init) => {
  if (!String(url).startsWith('https://api.resend.com/')) throw new Error('unexpected fetch ' + url);
  sent.push(JSON.parse(init.body));
  return new Response(resendStatus === 200 ? '{"id":"x"}' : '{"message":"bad"}', { status: resendStatus });
};
await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'));

let pass = 0, fail = 0;
const ok = (c, m) => { console.log((c ? 'PASS ' : 'FAIL ') + m); c ? pass++ : fail++; };
const req = (opts = {}) => handler(new Request('http://x/', { method: opts.method || 'POST',
  headers: { 'content-type': 'application/json', ...(opts.secret !== undefined ? { 'x-invite-secret': opts.secret } : {}) },
  body: opts.method === 'GET' ? undefined : (opts.body ?? '{}') }));
const payload = {
  ticketId: 't1', guestName: 'Sara <b>Alqahtani</b>', guestEmail: 'sara@example.com', linkToken: 'a'.repeat(48),
  eventName: 'Safety Day 2026', eventNameAr: 'يوم السلامة 2026', startsAt: '2026-12-10T06:00:00Z', endsAt: '2026-12-10T12:00:00Z',
  venue: 'JESCO Main Hall', city: 'Jubail', cityAr: 'الجبيل', imageUrl: null,
};

ok((await req({ method: 'GET' })).status === 405, 'GET refused (405)');
ok((await req({ body: JSON.stringify(payload) })).status === 401, 'no secret refused (401)');
ok((await req({ secret: 'wrong-secre', body: JSON.stringify(payload) })).status === 401, 'wrong secret refused (401)');
ok((await req({ secret: 'test-secret', body: 'not json' })).status === 400, 'bad JSON refused (400)');
ok((await req({ secret: 'test-secret', body: JSON.stringify({ ...payload, linkToken: '../x' }) })).status === 400, 'bad link token refused (400)');
ok(sent.length === 0, 'nothing sent for refused requests');

const res = await req({ secret: 'test-secret', body: JSON.stringify(payload) });
ok(res.status === 200 && sent.length === 1, 'valid request sends one email');
const m = sent[0];
ok(m.from === 'JESCO & ArcelorMittal Events <noreply@visitapp.sa>', 'from visit address with event name: ' + m.from);
ok(JSON.stringify(m.to) === '["sara@example.com"]', 'to the guest');
ok(m.html.includes('http://localhost:5173/t/' + 'a'.repeat(48)), 'button links to the ticket page');
ok(!m.html.includes('<b>Alqahtani</b>') && m.html.includes('&lt;b&gt;Alqahtani&lt;/b&gt;'), 'guest name is escaped');
ok(m.html.includes('9:00') || m.html.includes('09:00'), 'time shown in Saudi time (06:00Z = 09:00)');
ok(m.subject.includes('Safety Day 2026') && m.subject.includes('يوم السلامة 2026'), 'subject has both names');
fs.writeFileSync(new URL('./email-preview.html', import.meta.url), m.html.replaceAll('http://localhost:5173/brand/', '../../web/brand/'));

ok(!m.html.includes('Apple Wallet'), 'no Wallet button while Apple Wallet is not set up');

// Same function with Apple Wallet set up: the email gets the Wallet button.
env.APPLE_PASS_TYPE_ID = 'pass.test';
await import('data:text/javascript;base64,' + Buffer.from(js + '\n// wallet').toString('base64'));
await req({ secret: 'test-secret', body: JSON.stringify(payload) });
ok(sent[1].html.includes('href="http://localhost:5173/wallet/' + 'a'.repeat(48) + '"') && sent[1].html.includes('Add to Apple Wallet'),
  'Wallet button links to /wallet/<token> when set up');
delete env.APPLE_PASS_TYPE_ID;

resendStatus = 422;
ok((await req({ secret: 'test-secret', body: JSON.stringify(payload) })).status === 502, 'Resend refusal reported (502), no retry loop');

console.log(`\n${pass} passed, ${fail} failed`);
process.exitCode = fail ? 1 : 0;
