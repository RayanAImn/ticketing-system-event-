// Adds an organiser to one invite event and emails them. Called by the organiser
// page with the signed-in organiser's token; the database decides whether that
// organiser may manage the event (public.invite_add_organiser). A person without
// an account gets one, and every added organiser is emailed a link to the
// organiser page plus a link to set a password. Deploy with --no-verify-jwt
// (the token is checked by the database on every call).
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM_ADDRESS = addressOf(Deno.env.get("RESEND_FROM_EMAIL") ?? "noreply@visitapp.sa");
const FROM_NAME = Deno.env.get("INVITE_FROM_NAME") ?? "JESCO & ArcelorMittal Events";
const SITE_URL = (Deno.env.get("INVITE_SITE_URL") ?? "").replace(/\/+$/, "");

const CORS = {
  "Access-Control-Allow-Origin": SITE_URL || "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function addressOf(from: string): string {
  const m = from.match(/<([^>]+)>/);
  return (m ? m[1] : from).trim();
}

function escapeHtml(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

// Database call as the signed-in organiser. Returns [data, error message].
async function rpc(token: string, fn: string, args: unknown): Promise<[unknown, string | null]> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  let json: unknown = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  if (!res.ok) return [null, (json as { message?: string })?.message ?? `error ${res.status}`];
  return [json, null];
}

async function authAdmin(path: string, body: unknown): Promise<Record<string, unknown> | null> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    console.error(`auth admin ${path} failed (${res.status}): ${await res.text()}`);
    return null;
  }
  return await res.json();
}

export function organiserEmailHtml(eventName: string, siteUrl: string, passwordUrl: string | null, isNew: boolean): string {
  const e = escapeHtml;
  const btn = (href: string, text: string, bg: string) =>
    `<a href="${e(href)}" style="display:inline-block;background:${bg};color:#ffffff;text-decoration:none;font-weight:bold;font-size:15px;padding:12px 24px;border-radius:10px;margin:4px;">${text}</a>`;
  const pwText = isNew
    ? { en: "Set your password to sign in:", ar: "عيّن كلمة المرور لتسجيل الدخول:", btn: "Set password · تعيين كلمة المرور" }
    : { en: "Forgot your password? Set a new one:", ar: "نسيت كلمة المرور؟ عيّن كلمة جديدة:", btn: "Set password · تعيين كلمة المرور" };
  return `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f2f4f8;font-family:'IBM Plex Sans Arabic',Tahoma,Arial,sans-serif;">
<div style="max-width:560px;margin:0 auto;padding:20px 12px;">
  <div style="background:#233D7C;border-radius:14px 14px 0 0;padding:16px 20px;">
    <table role="presentation" width="100%" style="border-collapse:collapse;"><tr>
      <td><img src="${siteUrl}/brand/jesco.png" alt="JESCO" height="30" style="display:block;height:30px;"></td>
      <td align="right"><img src="${siteUrl}/brand/arcelormittal.png" alt="ArcelorMittal Tubular Products Al-Jubail" height="36" style="display:block;height:36px;"></td>
    </tr></table>
  </div>
  <div style="background:#ffffff;border:1px solid #dde2ec;border-top:0;border-radius:0 0 14px 14px;padding:22px 24px;">
    <p dir="rtl" style="margin:0 0 8px;font-size:15px;color:#1a2547;line-height:1.7;text-align:right;">تمت إضافتك منظّماً لفعالية <b>${e(eventName)}</b>. يمكنك إدارة الضيوف ومسح التذاكر من صفحة المنظّم.</p>
    <p style="margin:0 0 16px;font-size:15px;color:#1a2547;line-height:1.6;">You were added as an organiser of <b>${e(eventName)}</b>. You can manage guests and scan tickets from the organiser page.</p>
    <div style="text-align:center;">${btn(siteUrl + "/", "Organiser page · صفحة المنظّم", "#F05A22")}</div>
    ${passwordUrl ? `<p style="margin:18px 0 4px;font-size:14px;color:#1a2547;">${pwText.en}<br><span dir="rtl">${pwText.ar}</span></p>
    <div style="text-align:center;">${btn(passwordUrl, pwText.btn, "#233D7C")}</div>
    <p style="margin:8px 0 0;font-size:12px;color:#66708a;text-align:center;">This link works once and expires soon.<br>هذا الرابط يعمل مرة واحدة وينتهي قريباً.</p>` : ""}
  </div>
</div>
</body>
</html>`;
}

async function sendEmail(to: string, subject: string, html: string): Promise<boolean> {
  if (!RESEND_API_KEY) {
    console.error("RESEND_API_KEY not set");
    return false;
  }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_API_KEY}` },
    body: JSON.stringify({ from: `${FROM_NAME} <${FROM_ADDRESS}>`, to: [to], subject, html }),
  });
  if (!res.ok) console.error(`Resend error (${res.status}): ${await res.text()}`);
  return res.ok;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SERVICE_ROLE_KEY || !SITE_URL) {
    console.error("SUPABASE_* or INVITE_SITE_URL not set");
    return reply({ error: "unconfigured" }, 500);
  }

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return reply({ error: "not_authenticated" }, 401);

  let body: { eventId?: string; email?: string };
  try { body = await req.json(); } catch { return reply({ error: "bad_request" }, 400); }
  const email = String(body.email ?? "").trim().toLowerCase();
  const eventId = String(body.eventId ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(eventId)) return reply({ error: "event_not_found" }, 400);

  // The database checks that the caller may manage this event, and the email.
  let [result, err] = await rpc(token, "invite_add_organiser", { p_event_id: eventId, p_email: email });
  if (err) return reply({ error: err }, 400);

  let isNew = false;
  if (result === "no_account") {
    const user = await authAdmin("users", { email, email_confirm: true });
    if (!user) return reply({ error: "could_not_create_account" }, 500);
    isNew = true;
    [result, err] = await rpc(token, "invite_add_organiser", { p_event_id: eventId, p_email: email });
    if (err) return reply({ error: err }, 400);
  }
  if (result !== "added") return reply({ result });

  const [events] = await rpc(token, "invite_list_events", {});
  const ev = (events as { id: string; name: string }[] | null)?.find((x) => x.id === eventId);
  const eventName = ev?.name ?? "the event";

  // A one-time link the organiser page turns into a session to set a password.
  const link = await authAdmin("generate_link", { type: "recovery", email });
  const hash = (link?.hashed_token ?? (link?.properties as Record<string, unknown> | undefined)?.hashed_token) as string | undefined;
  const passwordUrl = hash ? `${SITE_URL}/?token_hash=${encodeURIComponent(hash)}&type=recovery` : null;

  const sent = await sendEmail(email, `${eventName} — Organiser access · صلاحية المنظّم`,
    organiserEmailHtml(eventName, SITE_URL, passwordUrl, isNew));
  return reply({ result, newAccount: isNew, emailed: sent });
});
