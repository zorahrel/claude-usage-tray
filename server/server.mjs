// Aggregatore usage per la tray: un solo JSON con tutti i provider.
// Claude arriva da vdm (:3335, non toccato), gli altri da probe locali,
// i rinnovi da renewals.json manuale. Niente dipendenze.
import http from "node:http";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { probeCodex } from "./probes/codex.mjs";
import { probeCloudCredits, creditAccount, saveLastGood, loadLastGood,
         loadCreditMap, saveCreditMap, mergeCreditMap } from "./probes/cloud-credit.mjs";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const PORT = 3337;

function resetText(epochSec) {
  if (!epochSec) return "";
  const secs = epochSec - Math.floor(Date.now() / 1000);
  if (secs <= 0) return "now";
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `${d}d${h}h`;
  if (h > 0) return `${h}h${m}m`;
  return `${m}m`;
}

function statusFor(usedPct, override) {
  if (override) return override;
  if (usedPct >= 100) return "depleted";
  if (usedPct >= 95) return "critical";
  if (usedPct >= 80) return "warning";
  return "ok";
}

async function fetchVdm() {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 5000);
  try {
    const res = await fetch("http://localhost:3335/api/profiles", { signal: ctrl.signal });
    if (!res.ok) throw new Error(`vdm ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

// Codice menubar: prime 3 alfanumeriche in maiuscolo (ATT, COD, CUR, MUS).
function code3(label) {
  return String(label || "?").replace(/[^a-z0-9]/gi, "").slice(0, 3).toUpperCase().padEnd(3, "·");
}

const STATUS_RANK = { off: 0, ok: 1, warning: 2, error: 3, critical: 4, depleted: 5 };

function mapClaude(vdm) {
  const accounts = (vdm.profiles || []).map((p) => {
    const u5 = (p.rateLimits?.fiveH?.utilization ?? 0) * 100;
    const u7 = (p.rateLimits?.sevenD?.utilization ?? 0) * 100;
    const r5 = p.rateLimits?.fiveH?.reset ?? null;
    const r7 = p.rateLimits?.sevenD?.reset ?? null;
    const qStatus = (key, u) => {
      let override = null;
      if (p.disabled) override = "off";
      else if (p.blockKind === "quota-5h" && key === "5h") override = "depleted";
      else if (p.blockKind === "quota-7d" && key === "7d") override = "depleted";
      else if (p.blockKind === "model") override = "warning";
      else if (p.blockKind === "auth") override = "error";
      return statusFor(u, override);
    };
    const s5 = qStatus("5h", u5);
    const s7 = qStatus("7d", u7);
    return {
      id: p.label || p.name,
      label: String(p.label || p.name),
      code: code3(p.label || p.name),
      active: p.isActive === true,
      status: STATUS_RANK[s5] >= STATUS_RANK[s7] ? s5 : s7,
      quotas: [
        { key: "5h", usedPct: Math.round(u5), resetsAt: r5, resetText: resetText(r5), status: s5 },
        { key: "7d", usedPct: Math.round(u7), resetsAt: r7, resetText: resetText(r7), status: s7 },
      ],
    };
  });
  return { id: "claude", name: "Claude", accounts };
}

function runProbe(script) {
  return new Promise((resolve) => {
    execFile("python3", [path.join(DIR, script)], { timeout: 25000 }, (err, stdout) => {
      if (err) return resolve(null);
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve(null);
      }
    });
  });
}

function toEpoch(iso) {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : Math.floor(t / 1000);
}

function mapMuse(out) {
  if (!out || !Array.isArray(out.quotas) || out.quotas.length === 0) {
    return { id: "muse", name: "Muse", error: "no data" };
  }
  const quotas = out.quotas.map((q) => {
    const used = Math.round(100 - (q.percentRemaining ?? 0));
    const resetsAt = toEpoch(q.resetsAt);
    return { key: q.type === "session" ? "5h" : q.type === "weekly" ? "7d" : q.type,
             usedPct: used, resetsAt, resetText: resetText(resetsAt),
             status: statusFor(used, null) };
  });
  const worst = Math.max(...quotas.map((q) => q.usedPct));
  const email = out.email;
  const label = typeof email === "string" && email.includes("@") ? email : "Muse";
  return { id: "muse", name: "Muse",
           accounts: [{ id: "muse-code", label, code: code3("Muse"), active: true,
                        status: statusFor(worst, null), quotas }] };
}

function mapQuotas(out, id, name, accountId, accountLabel, email = null) {
  if (!out || !Array.isArray(out.quotas) || out.quotas.length === 0) {
    return { id, name, error: "no data" };
  }
  const quotas = out.quotas.map((q) => {
    const usedPct = Math.round(q.usedPct ?? 0);
    return { key: q.key, usedPct, resetsAt: q.resetsAt ?? null,
             resetText: resetText(q.resetsAt ?? null), status: statusFor(usedPct, null) };
  });
  const worst = Math.max(...quotas.map((q) => q.usedPct));
  const label = typeof email === "string" && email.includes("@") ? email : accountLabel;
  return { id, name, accounts: [{ id: accountId, label,
    code: code3(accountLabel),
    active: true, status: statusFor(worst, null), quotas }] };
}

// Decide la riga credito: live → salva e serve; in mancanza → stantio
// con età (anche se il tool è sparito: l'età dice quanto vale); senza
// niente → riga "in aggiornamento" o sezione nascosta.
export function mergeCredit(probe, last) {
  if (probe && !probe.unavailable && !probe.nobonus) return { credit: probe, save: probe };
  if (last) return { credit: last, save: null };
  if (probe?.unavailable) return { credit: probe, save: null };
  return { credit: null, save: null };
}

// Profili vdm con Max: il bonus cloud spetta a ognuno, la sonda li gira
// tutti via CLOUD_ACCOUNT. Senza vdm: un giro sul login corrente.
export function bonusTargets(vdm) {
  return (vdm?.profiles ?? [])
    .filter((p) => p?.subscriptionType === "max" && p?.name && p?.label)
    .map((p) => ({ name: p.name, email: p.label }));
}

async function overview() {
  let renewals = [];
  try {
    // Tutte, anche tray:false: le righe Abbonamento sotto gli account
    // live le usano comunque, la tray nasconde solo orfani e gruppi.
    const raw = JSON.parse(await readFile(path.join(DIR, "renewals.json"), "utf8"));
    renewals = Array.isArray(raw) ? raw : [];
  } catch { /* resta vuoto */ }
  // vdm prima (locale, millisecondi): i nomi dei profili servono alla
  // sonda multipla. Il resto in parallelo: in sequenza supera i 55s della tray.
  const vdm = await fetchVdm().catch(() => null);
  const [cx, museOut, probed] = await Promise.all([
    probeCodex(),
    runProbe("muse_probe.py"),
    probeCloudCredits(vdm ? bonusTargets(vdm) : []),
  ]);
  const providers = [];
  providers.push(vdm
    ? mapClaude(vdm)
    : { id: "claude", name: "Claude", error: "vdm offline" });
  providers.push(mapQuotas(cx, "codex", "Codex", "codex", "Codex", cx?.email));
  providers.push(mapMuse(museOut));
  const login = creditAccount();
  const merged = mergeCredit(probed.find((p) => p.account === login) ?? null, loadLastGood());
  if (merged.save) saveLastGood(merged.save);
  let cmap = mergeCreditMap(loadCreditMap(), null);
  const liveNow = new Set();
  for (const item of probed) {
    cmap = mergeCreditMap(cmap.map, item);
    if (cmap.changed) saveCreditMap(cmap.map);
    if (item && typeof item.remaining === "number" && !item.stale &&
        typeof item.account === "string" && item.account.includes("@")) liveNow.add(item.account);
  }
  // Ogni merge segna fresco solo il suo giro: il poll ne ha fatti tanti.
  for (const email of liveNow) {
    if (cmap.credits[email]) cmap.credits[email] = { ...cmap.credits[email], stale: false };
  }
  return { ok: true, at: Date.now(), providers, renewals,
           credit: merged.credit, credits: cmap.credits };
}

function filterRenewals(list) {
  return (Array.isArray(list) ? list : []).filter((r) => r.tray !== false);
}

let cache = { at: 0, body: null };
const CACHE_MS = 45000;
let inflight = null; // una sola overview in volo: niente probe doppie

const server = http.createServer(async (req, res) => {
  if (req.url === "/api/overview") {
    try {
      if (!cache.body || Date.now() - cache.at > CACHE_MS) {
        inflight ??= overview().then(
          (o) => { cache = { at: Date.now(), body: JSON.stringify(o) }; },
        ).finally(() => { inflight = null; });
        await inflight;
      }
      const body = cache.body;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
    } catch (e) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: false, error: String(e) }));
    }
    return;
  }
  res.writeHead(404);
  res.end("nope");
});

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  server.listen(PORT, "127.0.0.1", () => console.log(`usage-server :${PORT}`));
}

export { resetText, statusFor, mapClaude, mapMuse, mapQuotas, filterRenewals, toEpoch, overview, code3 };
