// Builds an Apple Wallet pass (.pkpass) for a guest ticket.
// GET /functions/v1/invite-wallet-pass?t=<link_token>  (the site proxies /wallet/<token> here)
// The link token is the same secret as the ticket page link, so whoever can open the
// ticket can add it to Wallet; nothing else is exposed. Deploy with --no-verify-jwt.
//
// Secrets (project-wide; the email function shows its Wallet button only when
// APPLE_PASS_TYPE_ID is set):
//   APPLE_PASS_TYPE_ID   e.g. pass.sa.visitapp.tickets
//   APPLE_TEAM_ID        10-character Apple team ID
//   APPLE_PASS_CERT_PEM  the Pass Type ID certificate (PEM)
//   APPLE_PASS_KEY_PEM   its private key (PEM)
//   APPLE_PASS_KEY_PASSWORD  only if that key is encrypted
//   APPLE_WWDR_PEM       Apple WWDR intermediate certificate, G4 (PEM)
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import forge from "npm:node-forge@1.3.1";
import { zipSync } from "npm:fflate@0.8.2";
import { IMAGES } from "./images.ts";

const env = (k: string) => (Deno.env.get(k) ?? "").trim();
// Secrets pasted through a dashboard sometimes arrive with literal "\n" for newlines.
const pem = (k: string) => env(k).replace(/\\n/g, "\n");

const SUPABASE_URL = env("SUPABASE_URL");
const SUPABASE_ANON_KEY = env("SUPABASE_ANON_KEY");
const SITE_URL = env("INVITE_SITE_URL").replace(/\/+$/, "");

interface Ticket {
  guest_name: string;
  staff_id?: string | null;
  status: string;
  qr_token: string | null;
  redeemed_at: string | null;
  event_name: string;
  event_name_ar: string | null;
  venue: string | null;
  venue_ar: string | null;
  starts_at: string | null;
  ends_at: string | null;
}

const enc = new TextEncoder();

async function sha1Hex(data: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-1", data));
  return Array.from(h, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(s: string): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s)));
  return Array.from(h, (b) => b.toString(16).padStart(2, "0")).join("");
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// Saudi Arabia is UTC+3 all year (no daylight saving). Wallet shows a date in the
// time zone written in the string when ignoresTimeZone is set, so guests abroad
// still see the event's local time.
function riyadhIso(iso: string): string {
  const d = new Date(new Date(iso).getTime() + 3 * 3600_000);
  return d.toISOString().replace(/\.\d{3}Z$/, "+03:00");
}

export function passJson(t: Ticket, cfg: { passTypeId: string; teamId: string; serial: string; ticketUrl: string }) {
  const field = (key: string, label: string, value: string, extra: Record<string, unknown> = {}) => ({ key, label, value, ...extra });
  const start = t.starts_at ? riyadhIso(t.starts_at) : null;
  // A pass is no longer useful a day after the event ends (or starts, if no end time).
  const endRef = t.ends_at ?? t.starts_at;
  const expires = endRef ? riyadhIso(new Date(new Date(endRef).getTime() + 24 * 3600_000).toISOString()) : undefined;
  const venue = [t.venue, t.venue_ar].filter(Boolean).join(" · ");

  const back = [
    t.event_name_ar ? field("event_ar", "الفعالية", t.event_name_ar) : null,
    cfg.ticketUrl ? field("ticket", "Ticket page · صفحة التذكرة", cfg.ticketUrl) : null,
    field("note", "Note · ملاحظة",
      "Personal ticket, valid for one entry. Do not share it.\nتذكرة شخصية صالحة لدخول واحد، لا تشاركها."),
  ].filter(Boolean);

  return {
    formatVersion: 1,
    passTypeIdentifier: cfg.passTypeId,
    teamIdentifier: cfg.teamId,
    serialNumber: cfg.serial,
    organizationName: "JESCO & ArcelorMittal",
    description: `Ticket: ${t.event_name}`,
    backgroundColor: "rgb(35,61,124)",
    foregroundColor: "rgb(255,255,255)",
    labelColor: "rgb(240,90,34)",
    sharingProhibited: true,
    // Redeemed or cancelled when downloaded: Wallet greys it out.
    ...(t.status === "redeemed" || t.status === "cancelled" ? { voided: true } : {}),
    ...(start ? { relevantDate: start } : {}),
    ...(expires ? { expirationDate: expires } : {}),
    barcodes: [{ format: "PKBarcodeFormatQR", message: t.qr_token, messageEncoding: "iso-8859-1" }],
    eventTicket: {
      primaryFields: [field("event", "EVENT · الفعالية", t.event_name)],
      secondaryFields: [
        field("guest", "GUEST · الضيف", t.guest_name),
        ...(t.staff_id ? [field("staff_id", "STAFF ID · الرقم الوظيفي", t.staff_id)] : []),
      ],
      auxiliaryFields: [
        ...(start ? [field("date", "DATE · الموعد", start, { dateStyle: "PKDateStyleMedium", timeStyle: "PKDateStyleShort", ignoresTimeZone: true })] : []),
        ...(venue ? [field("venue", "VENUE · المكان", venue)] : []),
      ],
      backFields: back,
    },
  };
}

// Detached PKCS#7 signature of manifest.json, signed with the Pass Type ID
// certificate and carrying Apple's WWDR intermediate, as Wallet requires.
function sign(manifest: Uint8Array): Uint8Array {
  const cert = forge.pki.certificateFromPem(pem("APPLE_PASS_CERT_PEM"));
  const wwdr = forge.pki.certificateFromPem(pem("APPLE_WWDR_PEM"));
  const keyPem = pem("APPLE_PASS_KEY_PEM");
  const pass = env("APPLE_PASS_KEY_PASSWORD");
  const key = pass ? forge.pki.decryptRsaPrivateKey(keyPem, pass) : forge.pki.privateKeyFromPem(keyPem);
  if (!key) throw new Error("APPLE_PASS_KEY_PEM could not be read (wrong password?)");

  const p7 = forge.pkcs7.createSignedData();
  p7.content = forge.util.createBuffer(String.fromCharCode(...manifest));
  p7.addCertificate(cert);
  p7.addCertificate(wwdr);
  p7.addSigner({
    key,
    certificate: cert,
    digestAlgorithm: forge.pki.oids.sha256,
    authenticatedAttributes: [
      { type: forge.pki.oids.contentType, value: forge.pki.oids.data },
      { type: forge.pki.oids.messageDigest },
      { type: forge.pki.oids.signingTime, value: new Date() },
    ],
  });
  p7.sign({ detached: true });
  const der = forge.asn1.toDer(p7.toAsn1()).getBytes();
  const out = new Uint8Array(der.length);
  for (let i = 0; i < der.length; i++) out[i] = der.charCodeAt(i);
  return out;
}

export async function buildPkpass(t: Ticket, cfg: Parameters<typeof passJson>[1]): Promise<Uint8Array> {
  const files: Record<string, Uint8Array> = { "pass.json": enc.encode(JSON.stringify(passJson(t, cfg))) };
  for (const [name, b64] of Object.entries(IMAGES)) files[name] = b64ToBytes(b64);
  const manifest: Record<string, string> = {};
  for (const [name, data] of Object.entries(files)) manifest[name] = await sha1Hex(data);
  const manifestBytes = enc.encode(JSON.stringify(manifest));
  files["manifest.json"] = manifestBytes;
  files["signature"] = sign(manifestBytes);
  return zipSync(files);
}

const text = (body: string, status: number) =>
  new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });

serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") return text("Method not allowed", 405);

  const passTypeId = env("APPLE_PASS_TYPE_ID");
  const teamId = env("APPLE_TEAM_ID");
  if (!passTypeId || !teamId || !env("APPLE_PASS_CERT_PEM") || !env("APPLE_PASS_KEY_PEM") || !env("APPLE_WWDR_PEM")) {
    console.error("Apple Wallet secrets are not set");
    return text("Apple Wallet is not set up yet.", 503);
  }

  const url = new URL(req.url);
  const token = url.searchParams.get("t") ?? "";
  if (!/^[a-f0-9]{32,}$/i.test(token)) return text("Ticket link is not valid.", 400);

  // Same public RPC the ticket page uses: it only answers for this site's events.
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/invite_get_ticket`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
    body: JSON.stringify({ p_link_token: token }),
  });
  if (!res.ok) {
    console.error(`invite_get_ticket failed (${res.status}): ${await res.text()}`);
    return text("Could not load the ticket. Try again.", 502);
  }
  const t: Ticket | undefined = (await res.json())[0];
  if (!t) return text("This ticket link is not valid.", 404);
  if (t.status === "cancelled" || !t.qr_token) return text("This ticket was cancelled.", 410);

  try {
    const pkpass = await buildPkpass(t, {
      passTypeId,
      teamId,
      // Stable per QR code: a "New link" makes a new QR and so a new pass.
      serial: (await sha256Hex(t.qr_token)).slice(0, 32),
      ticketUrl: SITE_URL ? `${SITE_URL}/t/${token}` : "",
    });
    return new Response(req.method === "HEAD" ? null : pkpass, {
      headers: {
        "Content-Type": "application/vnd.apple.pkpass",
        "Content-Disposition": 'attachment; filename="ticket.pkpass"',
        "Cache-Control": "no-store",
      },
    });
  } catch (e) {
    console.error("pkpass build failed:", e);
    return text("Could not create the Wallet pass.", 500);
  }
});
