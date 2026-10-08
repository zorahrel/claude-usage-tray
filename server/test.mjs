// node --test server/test.mjs — nessun framework, solo node:test.
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resetText, statusFor, mapClaude, mapMuse, mapQuotas, filterRenewals, toEpoch, code3, mergeCredit, bonusTargets } from "./server.mjs";
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
  it("classifyCreditOutput: live, nobonus, failed", async () => {
    const { classifyCreditOutput } = await import("./probes/cloud-credit.mjs");
    assert.equal(classifyCreditOutput(JSON.stringify({ iguana_necktie: {
      remaining_dollars: 10, limit_dollars: 250,
      resets_at: "2026-11-05T00:00:00Z" } })).kind, "live");
    assert.equal(classifyCreditOutput('{"iguana_necktie":null}').kind, "nobonus");
    assert.equal(classifyCreditOutput("credito-cloud: HTTP 429").kind, "failed");
    assert.equal(classifyCreditOutput("").kind, "failed");
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
  it("lastGood: scrive e rilegge con stale+asOf, scade dopo 6h", async () => {
    const { saveLastGood, loadLastGood } = await import("./probes/cloud-credit.mjs");
    const fs = await import("node:fs");
    const os = await import("node:os");
    const path = await import("node:path");
    const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "tray-lg-")), "last.json");
    const v = { remaining: 74.4, limit: 250, renewsAt: "2026-11-05", account: "a@b.c" };
    assert.equal(loadLastGood(p), null);
    saveLastGood(v, p);
    const back = loadLastGood(p);
    assert.equal(back.remaining, 74.4);
    assert.equal(back.stale, true);
    assert.equal(typeof back.asOf, "number");
    assert.equal(loadLastGood(p, Date.now() + 7 * 3600 * 1000), null);
  });
  it("reasonForFailure: token, 429, generico", async () => {
    const { reasonForFailure } = await import("./probes/cloud-credit.mjs");
    assert.equal(reasonForFailure({ code: 3 }, "", ""), "token");
    assert.equal(reasonForFailure({ code: 1 }, "", "HTTP 429 da api"), "limited");
    assert.equal(reasonForFailure({ code: 1 }, "boom", ""), "error");
    assert.equal(reasonForFailure(null, "testo", ""), "error");
  });
  it("nobonusQuiet: vale solo per quel login", async () => {
    const { nobonusQuiet } = await import("./probes/cloud-credit.mjs");
    const fs = await import("node:fs");
    const os = await import("node:os");
    const path = await import("node:path");
    const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "tray-nb-")), "nb");
    fs.writeFileSync(p, `a@b.c|${Date.now()}`);
    assert.equal(nobonusQuiet("a@b.c", p), true);
    assert.equal(nobonusQuiet("x@y.z", p), false);
  });
  it("mergeCredit: live salva, stantio ripiega, il resto passa", () => {
    const live = { remaining: 10 };
    const stale = { remaining: 9, stale: true };
    const una = { unavailable: true };
    assert.deepEqual(mergeCredit(live, stale), { credit: live, save: live });
    assert.deepEqual(mergeCredit(una, stale), { credit: stale, save: null });
    assert.deepEqual(mergeCredit(una, null), { credit: una, save: null });
    assert.deepEqual(mergeCredit(null, stale), { credit: stale, save: null });
    assert.deepEqual(mergeCredit(null, null), { credit: null, save: null });
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

describe("creditMap", () => {
  const live = (account, remaining = 50) => ({ remaining, limit: 100, used: 100 - remaining,
    renewsAt: "2026-11-06", account });
  it("live fresco per un login, gli altri account stantii con età intatta", async () => {
    const { mergeCreditMap } = await import("./probes/cloud-credit.mjs");
    const before = { "a@example.com": { remaining: 10, limit: 100, used: 90,
      renewsAt: "2026-11-05", asOf: 1000 } };
    const { map, credits, changed } =
      mergeCreditMap(before, live("b@example.com"), 2000);
    assert.equal(changed, true);
    assert.equal(credits["b@example.com"].stale, false);
    assert.equal(credits["b@example.com"].asOf, 2000);
    assert.equal(credits["a@example.com"].stale, true);
    assert.equal(credits["a@example.com"].asOf, 1000);
    assert.equal(map["a@example.com"].remaining, 10);
  });
  it("nobonus segna solo quell'account, senza cancellare gli altri", async () => {
    const { mergeCreditMap } = await import("./probes/cloud-credit.mjs");
    const before = { "a@example.com": { remaining: 10, limit: 100, used: 90,
      renewsAt: "2026-11-05", asOf: 1000 } };
    const { map, credits, changed } =
      mergeCreditMap(before, { nobonus: true, account: "b@example.com" }, 2000);
    assert.equal(changed, true);
    assert.equal(credits["b@example.com"].nobonus, true);
    assert.equal(credits["b@example.com"].stale, true);
    assert.equal(map["a@example.com"].remaining, 10);
    assert.equal(credits["a@example.com"].stale, true);
  });
  it("sonda stantia non ringiovanisce né sovrascrive", async () => {
    const { mergeCreditMap } = await import("./probes/cloud-credit.mjs");
    const old = { remaining: 10, limit: 100, used: 90,
      renewsAt: "2026-11-05", asOf: 1000 };
    const same = mergeCreditMap({ "a@example.com": old },
      { ...live("a@example.com", 11), stale: true, asOf: 1500 }, 2000);
    assert.equal(same.changed, false);
    assert.equal(same.credits["a@example.com"].asOf, 1000);
    assert.equal(same.credits["a@example.com"].remaining, 10);
    const fresh = mergeCreditMap({},
      { ...live("a@example.com"), stale: true, asOf: 1500 }, 2000);
    assert.equal(fresh.changed, true);
    assert.equal(fresh.credits["a@example.com"].asOf, 1500);
    assert.equal(fresh.credits["a@example.com"].stale, true);
  });
  it("live senza account e fallimenti non toccano la mappa", async () => {
    const { mergeCreditMap } = await import("./probes/cloud-credit.mjs");
    const before = { "a@example.com": { remaining: 10, asOf: 1000 } };
    for (const probed of [{ ...live(null) }, { ...live("x") },
        { unavailable: true, account: "b@example.com" }, null]) {
      const r = mergeCreditMap(before, probed, 2000);
      assert.equal(r.changed, false);
      assert.deepEqual(r.map, before);
      assert.equal(r.credits["a@example.com"].stale, true);
    }
  });
  it("persistenza senza scadenza: si rilegge a qualsiasi età", async () => {
    const { saveCreditMap, loadCreditMap } = await import("./probes/cloud-credit.mjs");
    const fs = await import("node:fs");
    const os = await import("node:os");
    const path = await import("node:path");
    const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "tray-cm-")),
      "sub", "credit-last.json");
    assert.deepEqual(loadCreditMap(p), {});
    const map = { "a@example.com": { remaining: 10, limit: 100, used: 90,
      renewsAt: "2026-11-05", asOf: 1000 },
      "b@example.com": { nobonus: true, asOf: 1000 } };
    saveCreditMap(map, p);
    assert.deepEqual(loadCreditMap(p), map);
    fs.writeFileSync(p, "rotto{");
    assert.deepEqual(loadCreditMap(p), {});
  });
  it("mergeCredit: nobonus vale come assenza di live", () => {
    const stale = { remaining: 9, stale: true };
    const nb = { nobonus: true, account: "a@example.com" };
    assert.deepEqual(mergeCredit(nb, stale), { credit: stale, save: null });
    assert.deepEqual(mergeCredit(nb, null), { credit: null, save: null });
  });
  it("bonusTargets: solo i profili Max con nome ed email", () => {
    const vdm = { profiles: [
      { name: "auto-2", label: "a@example.com", subscriptionType: "max" },
      { name: "auto-3", label: "b@example.com", subscriptionType: "max" },
      { name: "auto-9", label: "c@example.com", subscriptionType: "pro" },
      { name: null, label: "d@example.com", subscriptionType: "max" },
    ] };
    assert.deepEqual(bonusTargets(vdm), [
      { name: "auto-2", email: "a@example.com" },
      { name: "auto-3", email: "b@example.com" },
    ]);
    assert.deepEqual(bonusTargets(null), []);
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
