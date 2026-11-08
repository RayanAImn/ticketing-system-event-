// Runs supabase/functions/invite-wallet-pass offline with a throwaway self-signed
// certificate (made with openssl), a stubbed serve() and a stubbed database call.
// Checks the .pkpass contents and verifies its signature with openssl.
// Run: deno run -A --import-map=supabase/tests/wallet_import_map.json supabase/tests/wallet_pass_test.ts
import { unzipSync } from "npm:fflate@0.8.2";

const dir = await Deno.makeTempDir();
const sh = async (...args: string[]) => {
  const r = await new Deno.Command("openssl", { args, cwd: dir, stderr: "piped", stdout: "piped" }).output();
  return { ok: r.success, out: new TextDecoder().decode(r.stdout) + new TextDecoder().decode(r.stderr) };
};
await sh("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "2", "-subj", "/CN=Test WWDR");
await sh("req", "-newkey", "rsa:2048", "-nodes", "-keyout", "pass.key", "-out", "pass.csr", "-subj", "/CN=Pass Type ID: pass.test");
await sh("x509", "-req", "-in", "pass.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "pass.pem", "-days", "2");
const read = (f: string) => Deno.readTextFileSync(`${dir}/${f}`);

const env: Record<string, string> = {
  SUPABASE_URL: "https://db.test", SUPABASE_ANON_KEY: "anon", INVITE_SITE_URL: "https://tickets.test/",
  APPLE_PASS_TYPE_ID: "pass.test", APPLE_TEAM_ID: "ABCDE12345",
  APPLE_PASS_CERT_PEM: read("pass.pem"), APPLE_PASS_KEY_PEM: read("pass.key"), APPLE_WWDR_PEM: read("ca.pem"),
};
Deno.env.get = (k: string) => env[k];

let ticket: Record<string, unknown> | null = {
  guest_name: "Sara Alqahtani", status: "active", qr_token: "q".repeat(64), redeemed_at: null,
  event_name: "Safety Day 2026", event_name_ar: "يوم السلامة 2026", venue: "JESCO Main Hall", venue_ar: null,
  starts_at: "2026-12-10T06:00:00+00:00", ends_at: "2026-12-10T12:00:00+00:00",
};
let rpcBody = "";
globalThis.fetch = (async (url: string, init: RequestInit) => {
  if (!String(url).startsWith("https://db.test/rest/v1/rpc/invite_get_ticket")) throw new Error("unexpected fetch " + url);
  rpcBody = String(init.body);
  return new Response(JSON.stringify(ticket ? [ticket] : []), { status: 200 });
}) as typeof fetch;

await import("../functions/invite-wallet-pass/index.ts");
const handler = (globalThis as any).__handler as (r: Request) => Promise<Response>;
const get = (q: string, method = "GET") => handler(new Request("https://fn.test/invite-wallet-pass" + q, { method }));

let pass = 0, fail = 0;
const ok = (c: unknown, m: string) => { console.log((c ? "PASS " : "FAIL ") + m); c ? pass++ : fail++; };
const token = "a".repeat(48);

ok((await get(`?t=${token}`, "POST")).status === 405, "POST refused (405)");
ok((await get("?t=../x")).status === 400, "bad token refused (400)");

const res = await get(`?t=${token}`);
ok(res.status === 200, "valid token gives 200, got " + res.status);
ok(res.headers.get("content-type") === "application/vnd.apple.pkpass", "pkpass content type");
ok(JSON.parse(rpcBody).p_link_token === token, "asks the database for this token");
const files = unzipSync(new Uint8Array(await res.arrayBuffer()));
const names = Object.keys(files).sort();
ok(["icon.png", "icon@2x.png", "icon@3x.png", "logo.png", "logo@2x.png", "logo@3x.png", "manifest.json", "pass.json", "signature"]
  .every((n) => names.includes(n)), "zip has pass.json, images, manifest, signature: " + names.join(","));

const pj = JSON.parse(new TextDecoder().decode(files["pass.json"]));
ok(pj.passTypeIdentifier === "pass.test" && pj.teamIdentifier === "ABCDE12345", "pass type and team");
ok(pj.barcodes[0].format === "PKBarcodeFormatQR" && pj.barcodes[0].message === "q".repeat(64), "QR holds the scanner token");
ok(pj.eventTicket.primaryFields[0].value === "Safety Day 2026", "event name");
ok(pj.eventTicket.secondaryFields[0].value === "Sara Alqahtani", "guest name");
ok(pj.eventTicket.auxiliaryFields[0].value === "2026-12-10T09:00:00+03:00", "date in Saudi time: " + pj.eventTicket.auxiliaryFields[0].value);
ok(pj.expirationDate === "2026-12-11T15:00:00+03:00", "expires a day after the end: " + pj.expirationDate);
ok(pj.eventTicket.backFields.some((f: any) => f.value === `https://tickets.test/t/${token}`), "back links to the ticket page");
ok(!pj.voided, "active ticket not voided");
ok(/^[0-9a-f]{32}$/.test(pj.serialNumber), "serial is a hash");

const manifest = JSON.parse(new TextDecoder().decode(files["manifest.json"]));
let hashesOk = true;
for (const n of names.filter((n) => n !== "manifest.json" && n !== "signature")) {
  const h = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-1", files[n])), (b) => b.toString(16).padStart(2, "0")).join("");
  if (manifest[n] !== h) hashesOk = false;
}
ok(hashesOk && Object.keys(manifest).length === names.length - 2, "manifest SHA-1s match every file");

Deno.writeFileSync(`${dir}/manifest.json`, files["manifest.json"]);
Deno.writeFileSync(`${dir}/signature`, files["signature"]);
const v = await sh("smime", "-verify", "-binary", "-inform", "der", "-in", "signature", "-content", "manifest.json", "-CAfile", "ca.pem", "-purpose", "any", "-out", "/dev/null");
ok(v.ok, "signature verifies against the certificate chain" + (v.ok ? "" : ": " + v.out));
const p7 = await sh("pkcs7", "-inform", "der", "-in", "signature", "-print_certs", "-noout");
ok(p7.out.includes("Test WWDR") && p7.out.includes("Pass Type ID"), "signature carries pass cert and WWDR");

ticket = { ...ticket, status: "redeemed" };
ok(JSON.parse(new TextDecoder().decode(unzipSync(new Uint8Array(await (await get(`?t=${token}`)).arrayBuffer()))["pass.json"])).voided === true, "redeemed ticket gives a voided pass");
ticket = { ...ticket, status: "cancelled", qr_token: null };
ok((await get(`?t=${token}`)).status === 410, "cancelled ticket refused (410)");
ticket = null;
ok((await get(`?t=${token}`)).status === 404, "unknown token (404)");
delete env.APPLE_PASS_CERT_PEM;
ok((await get(`?t=${token}`)).status === 503, "missing secrets (503)");

await Deno.remove(dir, { recursive: true });
console.log(`\n${pass} passed, ${fail} failed`);
Deno.exit(fail ? 1 : 0);
