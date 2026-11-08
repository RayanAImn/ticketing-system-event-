// Emails a guest their event ticket link. Called only by the database
// (public.invite_queue_email via pg_net), never by browsers.
// Same structure as visit's send-booking-email: shared-secret header, Resend,
// visit's sender address. Deploy with --no-verify-jwt.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
// visit's sender address, shown under the event's own name.
const FROM_ADDRESS = addressOf(Deno.env.get("RESEND_FROM_EMAIL") ?? "noreply@visitapp.sa");
const FROM_NAME = Deno.env.get("INVITE_FROM_NAME") ?? "JESCO & ArcelorMittal Events";
// Shared with the database via Vault (invite_email_secret).
const INVITE_EMAIL_SECRET = Deno.env.get("INVITE_EMAIL_SECRET") ?? "";
// Where the ticket pages live, e.g. https://tickets.example.com
const SITE_URL = (Deno.env.get("INVITE_SITE_URL") ?? "").replace(/\/+$/, "");

interface TicketPayload {
  ticketId: string;
  guestName: string;
  guestEmail: string;
  linkToken: string;
  eventName: string;
  eventNameAr: string | null;
  startsAt: string | null;
  endsAt: string | null;
  venue: string | null;
  city: string | null;
  cityAr: string | null;
  imageUrl: string | null;
}

function addressOf(from: string): string {
  const m = from.match(/<([^>]+)>/);
  return (m ? m[1] : from).trim();
}

// Guest-typed fields end up in HTML; escape them so a name can't inject markup.
function escapeHtml(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Event times are shown in Saudi time whatever the server's zone is.
function when(iso: string | null, end: string | null, locale: string): string {
  if (!iso) return "";
  const opt = { timeZone: "Asia/Riyadh" } as const;
  const d = new Date(iso);
  const day = d.toLocaleDateString(locale, { ...opt, weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const time = (x: Date) => x.toLocaleTimeString(locale, { ...opt, hour: "numeric", minute: "2-digit" });
  return `${day} · ${time(d)}${end ? " – " + time(new Date(end)) : ""}`;
}

function ticketEmailHtml(p: TicketPayload, ticketUrl: string): string {
  const e = escapeHtml;
  const cover = p.imageUrl && /^https:\/\//.test(p.imageUrl) ? p.imageUrl : `${SITE_URL}/brand/hero.webp`;
  const nameAr = p.eventNameAr || p.eventName;
  const whereEn = [p.venue, p.city].filter(Boolean).join(", ");
  const whereAr = [p.venue, p.cityAr || p.city].filter(Boolean).join("، ");
  const row = (label: string, value: string, dir: string) => value
    ? `<tr><td style="padding:6px 0;color:#66708a;width:90px;vertical-align:top;">${label}</td><td dir="${dir}" style="padding:6px 0;font-weight:bold;color:#1a2547;">${e(value)}</td></tr>`
    : "";
  return `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f2f4f8;font-family:'IBM Plex Sans Arabic',Tahoma,Arial,sans-serif;">
<div style="max-width:560px;margin:0 auto;padding:20px 12px;">
  <div style="background:#233D7C;border-radius:14px 14px 0 0;padding:16px 20px;">
    <table role="presentation" width="100%" style="border-collapse:collapse;"><tr>
      <td><img src="${SITE_URL}/brand/jesco.png" alt="JESCO" height="30" style="display:block;height:30px;"></td>
      <td align="right"><img src="${SITE_URL}/brand/arcelormittal.png" alt="ArcelorMittal Tubular Products Al-Jubail" height="36" style="display:block;height:36px;"></td>
    </tr></table>
  </div>
  <div style="background:#ffffff;border:1px solid #dde2ec;border-top:0;border-radius:0 0 14px 14px;overflow:hidden;">
    <img src="${e(cover)}" alt="" width="560" style="display:block;width:100%;height:auto;">
    <div style="padding:22px 24px 6px;" dir="rtl">
      <p style="margin:0 0 6px;font-size:15px;color:#1a2547;text-align:right;">مرحباً ${e(p.guestName)}،</p>
      <p style="margin:0;font-size:15px;color:#1a2547;line-height:1.7;text-align:right;">تذكرتك لفعالية <b>${e(nameAr)}</b> جاهزة. اعرض رمز QR عند الدخول.</p>
    </div>
    <div style="padding:14px 24px 6px;" dir="ltr">
      <p style="margin:0 0 6px;font-size:15px;color:#1a2547;">Hello ${e(p.guestName)},</p>
      <p style="margin:0;font-size:15px;color:#1a2547;line-height:1.6;">Your ticket for <b>${e(p.eventName)}</b> is ready. Show its QR code at the entrance.</p>
    </div>
    <div style="padding:16px 24px;text-align:center;">
      <a href="${e(ticketUrl)}" style="display:inline-block;background:#F05A22;color:#ffffff;text-decoration:none;font-weight:bold;font-size:16px;padding:13px 28px;border-radius:10px;">عرض تذكرتي · View my ticket</a>
    </div>
    <div style="margin:0 24px 20px;padding:12px 16px;background:#f2f4f8;border-radius:10px;">
      <table role="presentation" width="100%" style="border-collapse:collapse;font-size:14px;" dir="ltr">
        ${row("Event", p.eventName, "ltr")}
        ${row("الفعالية", p.eventNameAr ?? "", "rtl")}
        ${row("When", when(p.startsAt, p.endsAt, "en-GB"), "ltr")}
        ${row("الموعد", when(p.startsAt, p.endsAt, "ar-SA-u-nu-latn-ca-gregory"), "rtl")}
        ${row("Where", whereEn, "ltr")}
        ${p.cityAr ? row("المكان", whereAr, "rtl") : ""}
      </table>
    </div>
    <p style="margin:0 24px 22px;font-size:12px;color:#66708a;line-height:1.6;text-align:center;">
      This ticket is personal. Please don't share the link.<br>
      هذه التذكرة شخصية، يرجى عدم مشاركة الرابط.
    </p>
  </div>
  <p style="margin:14px 0 0;font-size:12px;color:#66708a;text-align:center;">JESCO &amp; ArcelorMittal Tubular Products Al-Jubail</p>
</div>
</body>
</html>`;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Resend allows a few requests per second, and a list import queues one call per
// guest, so wait and retry when it says "too many requests".
async function sendEmail(to: string, subject: string, html: string): Promise<boolean> {
  if (!RESEND_API_KEY) {
    console.error("RESEND_API_KEY not set");
    return false;
  }
  for (let attempt = 0; attempt < 8; attempt++) {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_API_KEY}` },
      body: JSON.stringify({ from: `${FROM_NAME} <${FROM_ADDRESS}>`, to: [to], subject, html }),
    });
    if (res.ok) return true;
    const err = await res.text();
    if (res.status !== 429 && res.status < 500) {
      console.error(`Resend error (${res.status}): ${err}`);
      return false;
    }
    const wait = Number(res.headers.get("retry-after")) * 1000 || 1000 * 2 ** Math.min(attempt, 4);
    await sleep(wait + Math.random() * 1000);
  }
  console.error(`Resend still refusing after retries for ${to}`);
  return false;
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  if (!INVITE_EMAIL_SECRET || !SITE_URL) {
    console.error("INVITE_EMAIL_SECRET or INVITE_SITE_URL not set");
    return new Response("Unconfigured", { status: 500 });
  }
  const provided = req.headers.get("x-invite-secret") ?? "";
  if (!constantTimeEquals(provided, INVITE_EMAIL_SECRET)) {
    return new Response("Unauthorized", { status: 401 });
  }

  let p: TicketPayload;
  try {
    p = await req.json();
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }
  if (!p.ticketId || !p.guestEmail || !/^[a-f0-9]{32,}$/.test(p.linkToken ?? "")) {
    return new Response("Missing ticket fields", { status: 400 });
  }

  const ticketUrl = `${SITE_URL}/t/${p.linkToken}`;
  const subject = `${p.eventNameAr ? p.eventNameAr + " · " : ""}${p.eventName} — تذكرتك · Your ticket`;
  const sent = await sendEmail(p.guestEmail, subject, ticketEmailHtml(p, ticketUrl));

  return new Response(JSON.stringify({ ok: sent }), {
    status: sent ? 200 : 502,
    headers: { "Content-Type": "application/json" },
  });
});
