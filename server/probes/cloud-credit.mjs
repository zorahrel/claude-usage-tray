// Bonus cloud Max ($250 una tantum): saldo vivo da `credito-cloud --json`
// (tool personale in ~/bin, non committato). Vivo o niente: il bucket in
// ~/.claude.json è fermo da giorni (verificato 08/10: $229 contro $118
// veri), quindi niente fallback su file stantio. Tutto assente → null e
// la tray nasconde la sezione. Niente dipendenze.
import { execFile } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// L'endpoint dietro credito-cloud è rate-limited: dopo un fallimento non
// ritentare il live per 10 minuti.
const QUIET_PATH = "/tmp/usage-credit-fail";
const QUIET_MS = 600000;

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

export function liveQuiet(failPath = QUIET_PATH, now = Date.now()) {
  try {
    return now - Number(readFileSync(failPath, "utf8")) < QUIET_MS;
  } catch {
    return false;
  }
}

function markLiveFailed(failPath = QUIET_PATH) {
  try {
    writeFileSync(failPath, String(Date.now()));
  } catch { /* tmp non scrivibile: si riprova sempre, nessun danno */ }
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

export async function probeCloudCredit() {
  const bin = path.join(os.homedir(), "bin", "credito-cloud");
  if (!existsSync(bin)) return null; // tool assente: sezione nascosta
  const account = creditAccount();
  if (liveQuiet()) return { unavailable: true, account };
  const out = await new Promise((resolve) => {
    execFile(bin, ["--json"], { timeout: 25000 }, (err, stdout) => {
      resolve(err ? null : stdout);
    });
  });
  const c = out === null ? { kind: "failed" } : classifyCreditOutput(out);
  if (c.kind === "live") return { ...c.value, account };
  if (c.kind === "nobonus") return null;
  markLiveFailed();
  return { unavailable: true, account };
}
