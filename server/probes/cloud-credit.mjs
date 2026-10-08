// Bonus cloud Max ($250 una tantum): saldo vivo da `credito-cloud --json`
// (tool personale in ~/bin, non committato). Vivo o niente: il bucket in
// ~/.claude.json è fermo da giorni, quindi niente fallback su file stantio.
// Ultimo buono su /tmp (max 6h) con età; assente → sezione nascosta.
// Niente dipendenze.
import { execFile } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const QUIET_PATH = "/tmp/usage-credit-fail"; // live fallito: riprova tra 10'
const QUIET_MS = 600000;
const FRESH_PATH = "/tmp/usage-credit-fresh"; // live ok: non richiamare per 15'
const FRESH_MS = 900000;
const NOBONUS_PATH = "/tmp/usage-credit-nobonus"; // "email|ts": login senza bonus
const NOBONUS_MS = 900000;
const LAST_PATH = "/tmp/usage-credit-last.json"; // ultimo buono, max 6h
const LAST_TTL_MS = 6 * 3600 * 1000;

export function parseCloudCredit(out) {
  const b = out?.iguana_necktie;
  if (!b || typeof b.remaining_dollars !== "number") return null;
  const m = typeof b.resets_at === "string" && b.resets_at.match(/^(\d{4}-\d{2}-\d{2})/);
  const r2 = (n) => Math.round(n * 100) / 100;
  return {
    remaining: r2(b.remaining_dollars),
    limit: typeof b.limit_dollars === "number" ? r2(b.limit_dollars) : null,
    used: typeof b.used_dollars === "number" ? r2(b.used_dollars) : null,
    renewsAt: m ? m[1] : null,
  };
}

// Il bonus è dell'account loggato (quello attivo in vdm): stessa sorgente
// che usa credito-cloud, l'email in ~/.claude.json → oauthAccount.
export function creditAccount(home = os.homedir()) {
  try {
    const j = JSON.parse(readFileSync(path.join(home, ".claude.json"), "utf8"));
    const email = j?.oauthAccount?.emailAddress;
    return typeof email === "string" && email.includes("@") ? email : null;
  } catch {
    return null;
  }
}

// Tre esiti, tre comportamenti in menu: live → riga col saldo; nobonus
// (login senza bonus, es. dopo rotazione vdm) → sezione nascosta;
// failed (429, rete) → riga "in aggiornamento".
export function classifyCreditOutput(stdout) {
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return { kind: "failed" };
  }
  if (parsed && typeof parsed === "object" && parsed.iguana_necktie == null) {
    return { kind: "nobonus" };
  }
  const value = parseCloudCredit(parsed);
  return value ? { kind: "live", value } : { kind: "failed" };
}

// Perché il live è fallito: exit 3 = token scaduto (contratto di
// credito-cloud), 429 = throttle, il resto = errore generico.
export function reasonForFailure(err, stdout, stderr) {
  if (err?.code === 3) return "token";
  if (/429/.test(`${stdout ?? ""}${stderr ?? ""}`)) return "limited";
  return "error";
}

function freshStamp(p) {
  try {
    return Number(readFileSync(p, "utf8")) || 0;
  } catch {
    return 0;
  }
}
const isFresh = (p, ttl, now = Date.now()) => now - freshStamp(p) < ttl;

function mark(p, content = null) {
  try {
    writeFileSync(p, content ?? String(Date.now()));
  } catch { /* tmp non scrivibile: si riprova sempre, nessun danno */ }
}

export function liveQuiet(failPath = QUIET_PATH, now = Date.now()) {
  return isFresh(failPath, QUIET_MS, now);
}

// Il nobonus vale solo per quel login: se vdm ha ruotato si riprova subito.
export function nobonusQuiet(login, p = NOBONUS_PATH, now = Date.now()) {
  try {
    const [email, ts] = readFileSync(p, "utf8").split("|");
    return email === login && now - Number(ts) < NOBONUS_MS;
  } catch {
    return false;
  }
}

export function saveLastGood(value, lastPath = LAST_PATH) {
  try {
    writeFileSync(lastPath, JSON.stringify({ at: Date.now(), value }));
  } catch { /* tmp non scrivibile: niente stantio, nessun danno */ }
}

export function loadLastGood(lastPath = LAST_PATH, now = Date.now()) {
  try {
    const m = JSON.parse(readFileSync(lastPath, "utf8"));
    if (!m || typeof m.at !== "number" || now - m.at > LAST_TTL_MS) return null;
    if (!m.value || typeof m.value.remaining !== "number") return null;
    return { ...m.value, stale: true, asOf: Math.floor(m.at / 1000) };
  } catch {
    return null;
  }
}

// Il bonus è di chi l'ha riscosso (lastGood): se il login corrente è un
// altro e il live fallisce, non mostrargli una riga "in aggiornamento"
// per un bonus che non ha — si nasconde e basta.
function ownedByOther(login) {
  if (!login) return false;
  const last = loadLastGood();
  return !!(last?.account && last.account !== login);
}

export async function probeCloudCredit() {
  const bin = path.join(os.homedir(), "bin", "credito-cloud");
  if (!existsSync(bin)) return null; // tool assente: sezione nascosta
  const login = creditAccount();
  if (isFresh(FRESH_PATH, FRESH_MS)) {
    const lg = loadLastGood(); // saldo di pochi minuti fa, con età
    if (lg) return lg;
  }
  if (login && nobonusQuiet(login)) return null;
  if (liveQuiet()) {
    return ownedByOther(login) ? null : { unavailable: true, account: login };
  }
  const res = await new Promise((resolve) => {
    execFile(bin, ["--json"], { timeout: 25000 }, (err, stdout, stderr) => {
      resolve(err ? { err, stdout, stderr } : { err: null, stdout, stderr });
    });
  });
  // Attribuzione al login pre-fetch: il token letto dal tool è il suo anche
  // se vdm ruota in questi millisecondi (race accettata, si corregge al poll).
  if (res.err) {
    mark(QUIET_PATH);
    if (ownedByOther(login)) return null;
    return { unavailable: true, account: login,
             reason: reasonForFailure(res.err, res.stdout, res.stderr) };
  }
  const c = classifyCreditOutput(res.stdout);
  if (c.kind === "live") {
    mark(FRESH_PATH);
    return { ...c.value, account: login };
  }
  if (c.kind === "nobonus") {
    if (login) mark(NOBONUS_PATH, `${login}|${Date.now()}`);
    return null;
  }
  mark(QUIET_PATH);
  if (ownedByOther(login)) return null;
  return { unavailable: true, account: login,
           reason: reasonForFailure(null, res.stdout, res.stderr) };
}
