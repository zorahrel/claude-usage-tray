// Hub crediti: usage dal vivo di OpenRouter, Resend, ElevenLabs — solo
// endpoint documentati, niente stime. Chiavi dal Keychain dell'utente
// (servizi sotto); senza chiave o senza permessi la sonda torna un
// codice errore e il menu dice cosa fare. Niente dipendenze.
import { execFile } from "node:child_process";

const TIMEOUT_MS = 12000;

function keychain(service) {
  return new Promise((resolve) => {
    execFile("/usr/bin/security", ["find-generic-password", "-s", service, "-w"],
      { timeout: 10000 }, (err, stdout) => {
        resolve(err ? null : String(stdout).trim() || null);
      });
  });
}

async function get(url, headers) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(url, { headers, signal: ctrl.signal });
    let data = null;
    try {
      data = await res.json();
    } catch { /* corpo non JSON: resta null */ }
    return { status: res.status, data };
  } catch {
    return { status: 0, data: null };
  } finally {
    clearTimeout(t);
  }
}

// --- OpenRouter: GET /api/v1/auth/key → spesa del mese sul tetto chiave.
// Senza tetto (pay-per-use puro) il limite è null: si mostra la spesa.
// Niente email nell'API: l'account è il nome della chiave.
export function parseOpenRouter(data) {
  const d = data?.data;
  if (!d || typeof d.usage !== "number") return null;
  const used = typeof d.usage_monthly === "number" ? d.usage_monthly : d.usage;
  return {
    label: typeof d.label === "string" && d.label ? d.label : "OpenRouter",
    quotas: [{
      key: "usd",
      used: Math.round(used * 100) / 100,
      limit: typeof d.limit === "number" ? d.limit : null,
      unit: "$",
      reset: null,
      resetWord: d.limit_reset === "monthly" ? "mensile" : null,
    }],
  };
}

export async function probeOpenRouter() {
  const key = await keychain("openrouter");
  if (!key) return { error: "nokey" };
  const { status, data } = await get("https://openrouter.ai/api/v1/auth/key",
    { Authorization: `Bearer ${key}` });
  if (status === 0) return { error: "timeout" };
  const parsed = status === 200 ? parseOpenRouter(data) : null;
  return parsed ?? { error: status === 401 ? "rejected" : `http${status}` };
}

// --- Resend: GET /usage → quote mensili (il tetto del piano) e giornaliere
// solo se hanno un tetto (senza sono trivia). L'account è il suffisso del
// servizio keychain (resend-<account>): l'API non dice email.
export function parseResendUsage(data, label) {
  if (!data || data.object !== "usage" || !data.emails?.monthly) return null;
  const quotas = [];
  const m = data.emails.monthly;
  if (typeof m.used === "number" && typeof m.limit === "number") {
    quotas.push({ key: "30g", used: m.used, limit: m.limit, unit: "",
                  reset: m.resets_at ?? null, resetWord: null });
  }
  const g = data.emails.daily;
  if (g && typeof g.used === "number" && typeof g.limit === "number") {
    quotas.push({ key: "24h", used: g.used, limit: g.limit, unit: "",
                  reset: g.resets_at ?? null, resetWord: null });
  }
  return quotas.length ? { label, quotas } : null;
}

export function classifyResendError(status, data) {
  if (status === 0) return "timeout";
  // Sul corpo serializzato, non sulle chiavi: il gateway ogni tanto
  // manda chiavi con caratteri invisibili (viste dal vivo: la chiave
  // c'è in Object.keys ma l'accesso per nome torna undefined).
  if (status === 401 && /restricted_api_key/.test(JSON.stringify(data) ?? "")) return "sendonly";
  if (status === 401) return "rejected";
  return `http${status}`;
}

export async function probeResend() {
  const svc = "resend-mooncircles";
  const key = await keychain(svc);
  if (!key) return { error: "nokey" };
  const { status, data } = await get("https://api.resend.com/usage",
    { Authorization: `Bearer ${key}` });
  const parsed = status === 200
    ? parseResendUsage(data, svc.replace(/^resend-/, ""))
    : null;
  return parsed ?? { error: classifyResendError(status, data) };
}

// --- ElevenLabs: /user/subscription → caratteri usati/limite + reset unix;
// /user in parallelo per l'email (stesso permesso: se manca, cade anche lei).
export function parseEleven(sub, user) {
  if (!sub || typeof sub.character_count !== "number" ||
      typeof sub.character_limit !== "number") return null;
  const email = user?.email;
  return {
    label: typeof email === "string" && email.includes("@")
      ? email
      : (typeof sub.tier === "string" && sub.tier ? sub.tier : "ElevenLabs"),
    quotas: [{
      key: "chr",
      used: sub.character_count,
      limit: sub.character_limit,
      unit: "",
      reset: typeof sub.next_character_count_reset_unix === "number"
        ? sub.next_character_count_reset_unix : null,
      resetWord: null,
    }],
  };
}

export function classifyElevenError(status, data) {
  if (status === 0) return "timeout";
  const d = data?.Detail ?? data?.Detail;
  if (d?.status === "missing_permissions") return "noperm";
  // Fallback sul corpo serializzato: chiavi con invisibili, viste dal vivo.
  if (/user_read|missing_permissions/.test(JSON.stringify(data) ?? "")) return "noperm";
  if (status === 401) return "rejected";
  return `http${status}`;
}

export async function probeEleven() {
  const key = await keychain("elevenlabs");
  if (!key) return { error: "nokey" };
  const headers = { "xi-api-key": key };
  const [sub, user] = await Promise.all([
    get("https://api.elevenlabs.io/v1/user/subscription", headers),
    get("https://api.elevenlabs.io/v1/user", headers),
  ]);
  const parsed = sub.status === 200
    ? parseEleven(sub.data, sub.status === 200 ? user.data : null)
    : null;
  return parsed ?? { error: classifyElevenError(sub.status, sub.data) };
}
