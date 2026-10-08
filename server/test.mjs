// node --test server/test.mjs — nessun framework, solo node:test.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resetText, statusFor, mapClaude, mapMuse, mapQuotas, filterRenewals, toEpoch, code3 } from "./server.mjs";
import { parseCloudCredit } from "./probes/cloud-credit.mjs";
import { EventEmitter } from "node:events";
import { rpc } from "./probes/codex.mjs";

describe("resetText", () => {
  it("rende ore+minuti e giorni", () => {
    const now = Math.floor(Date.now() / 1000);
    assert.equal(resetText(now + 4 * 3600 + 12 * 60), "4h12m");
    assert.equal(resetText(now + 2 * 86400 + 5 * 3600), "2d5h");
    assert.equal(resetText(now + 9 * 60), "9m");
    assert.equal(resetText(now - 5), "now");
    assert.equal(resetText(null), "");
  });
});

describe("statusFor", () => {
  it("soglie verde/arancio/rosso", () => {
    assert.equal(statusFor(10, null), "ok");
    assert.equal(statusFor(80, null), "warning");
    assert.equal(statusFor(95, null), "critical");
    assert.equal(statusFor(100, null), "depleted");
  });
  it("l'override vince", () => {
    assert.equal(statusFor(10, "depleted"), "depleted");
  });
});

describe("mapClaude", () => {
  const vdm = { profiles: [
    { name: "a", label: "ada@example.com", isActive: true, blockKind: null,
      rateLimits: { fiveH: { utilization: 0.12, reset: 1791319200 },
                    sevenD: { utilization: 1, reset: 1791345600 } } },
    { name: "b", label: "x@y.zz", blockKind: "quota-7d",
      rateLimits: { fiveH: { utilization: 0, reset: 1 }, sevenD: { utilization: 0.4, reset: 1 } } },
  ]};
  it("percentuali e peggiore dei due", () => {
    const [a] = mapClaude(vdm).accounts;
    assert.equal(a.quotas[0].usedPct, 12);
    assert.equal(a.quotas[1].usedPct, 100);
    assert.equal(a.status, "depleted");
    assert.equal(a.active, true);
  });
  it("blockKind quota forza depleted", () => {
    const [, b] = mapClaude(vdm).accounts;
    assert.equal(b.status, "depleted");
  });
  it("ogni quota ha il suo status, l'account il peggiore", () => {
    const [a, b] = mapClaude(vdm).accounts;
    assert.equal(a.quotas[0].status, "ok");
    assert.equal(a.quotas[1].status, "depleted");
    assert.equal(b.quotas[0].status, "ok");
    assert.equal(b.quotas[1].status, "depleted");
  });
});

describe("mapMuse", () => {
  it("converte remaining in used", () => {
    const p = mapMuse({ quotas: [
      { type: "session", percentRemaining: 94, resetsAt: "2026-10-06T21:10:18Z" },
      { type: "weekly", percentRemaining: 82, resetsAt: "2026-10-12T00:00:00Z" },
    ]});
    assert.equal(p.accounts[0].quotas[0].usedPct, 6);
    assert.equal(p.accounts[0].quotas[1].key, "7d");
    assert.equal(p.accounts[0].status, "ok");
  });
  it("senza dati segnala errore invece di inventare", () => {
    assert.equal(mapMuse({ quotas: [] }).error, "no data");
    assert.equal(mapMuse(null).error, "no data");
  });
  it("label dall'email o dal nome", () => {
    const p = mapMuse({ email: "io@x.it",
      quotas: [{ type: "session", percentRemaining: 50, resetsAt: null }] });
    assert.equal(p.accounts[0].label, "io@x.it");
    assert.equal(p.accounts[0].code, "MUS");
    const q = mapMuse({ quotas: [{ type: "session", percentRemaining: 50, resetsAt: null }] });
    assert.equal(q.accounts[0].label, "Muse");
  });
});

describe("mapQuotas", () => {
  it("forma unificata per codex", () => {
    const p = mapQuotas({ quotas: [
      { key: "5h", usedPct: 42, resetsAt: 1791318908 },
      { key: "7d", usedPct: 68, resetsAt: null },
    ]}, "codex", "Codex", "codex", "CODEX");
    assert.equal(p.accounts[0].quotas[0].usedPct, 42);
    assert.equal(p.accounts[0].status, "ok");
    assert.equal(p.accounts[0].quotas[0].status, "ok");
    assert.equal(p.accounts[0].quotas[1].resetText, "");
  });
  it("vuoto diventa errore", () => {
    assert.equal(mapQuotas(null, "x", "X", "x", "X").error, "no data");
  });
  it("label dall'email, codice dal nome", () => {
    const p = mapQuotas({ quotas: [{ key: "5h", usedPct: 1, resetsAt: null }] },
                        "codex", "Codex", "codex", "Codex", "io@x.it");
    assert.equal(p.accounts[0].label, "io@x.it");
    assert.equal(p.accounts[0].code, "COD");
    const q = mapQuotas({ quotas: [{ key: "5h", usedPct: 1, resetsAt: null }] },
                        "codex", "Codex", "codex", "Codex", "spazzatura");
    assert.equal(q.accounts[0].label, "Codex");
  });
});

describe("filterRenewals", () => {
  it("nasconde solo tray:false, il resto passa", () => {
    const out = filterRenewals([
      { service: "A", provider: "claude" },
      { service: "B", provider: "infra", tray: false },
    ]);
    assert.equal(out.length, 1);
    assert.equal(out[0].service, "A");
    assert.deepEqual(filterRenewals(null), []);
  });
});

describe("code3", () => {
  it("tre lettere maiuscole", () => {
    assert.equal(code3("ada@example.com"), "ADA");
    assert.equal(code3("Codex"), "COD");
    assert.equal(code3("Opus"), "OPU");
    assert.equal(code3("Muse"), "MUS");
  });
});

describe("parseCloudCredit", () => {
  const live = { iguana_necktie: { limit_dollars: 250, used_dollars: 130.584522,
    remaining_dollars: 119.41547800000001, resets_at: "2026-11-05T07:59:00+00:00" } };
  it("saldo arrotondato e data corta", () => {
    assert.deepEqual(parseCloudCredit(live),
      { remaining: 119.42, limit: 250, used: 130.58, renewsAt: "2026-11-05" });
  });
  it("senza bucket o rotto dà null, mai eccezioni", () => {
    assert.equal(parseCloudCredit({}), null);
    assert.equal(parseCloudCredit({ iguana_necktie: null }), null);
    assert.equal(parseCloudCredit({ iguana_necktie: {} }), null);
    assert.equal(parseCloudCredit(null), null);
    assert.equal(parseCloudCredit("xx"), null);
  });
  it("creditAccount: legge l'email loggata o null", async () => {
    const { creditAccount } = await import("./probes/cloud-credit.mjs");
    const fs = await import("node:fs");
    const os = await import("node:os");
    const path = await import("node:path");
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "tray-home-"));
    fs.writeFileSync(path.join(home, ".claude.json"),
      JSON.stringify({ oauthAccount: { emailAddress: "ada@example.com" } }));
    assert.equal(creditAccount(home), "ada@example.com");
    assert.equal(creditAccount(home + "-missing"), null);
  });
  it("liveQuiet: fresco tace, vecchio o mancante riprova", async () => {
    const { liveQuiet } = await import("./probes/cloud-credit.mjs");
    const { writeFileSync } = await import("node:fs");
    const p = `${process.env.TMPDIR || "/tmp/"}tray-quiet-test`;
    writeFileSync(p, String(Date.now()));
    assert.equal(liveQuiet(p), true);
    writeFileSync(p, "1");
    assert.equal(liveQuiet(p), false);
    assert.equal(liveQuiet(p + "-missing"), false);
  });
});

describe("codex rpc", () => {
  const fakeProc = () => ({ stdout: new EventEmitter(), stdin: { write() {} } });
  it("ricuce i chunk spezzati e risponde all'id giusto", async () => {
    const proc = fakeProc();
    const p = rpc(proc, { id: 2 });
    proc.stdout.emit("data", '{"id":1,"result":"no"}\n{"id":2,"res');
    proc.stdout.emit("data", 'ult":"sì"}\n');
    assert.equal((await p).result, "sì");
  });
  it("ignora righe vuote e JSON a metà", async () => {
    const proc = fakeProc();
    const p = rpc(proc, { id: 7 });
    proc.stdout.emit("data", '\n{"id":7');
    proc.stdout.emit("data", ',"ok":true}\n');
    assert.equal((await p).ok, true);
  });
});

describe("toEpoch", () => {
  it("ISO o null", () => {
    assert.equal(toEpoch("2026-10-06T21:10:18Z"), Date.parse("2026-10-06T21:10:18Z") / 1000);
    assert.equal(toEpoch(null), null);
    assert.equal(toEpoch("xx"), null);
  });
});
