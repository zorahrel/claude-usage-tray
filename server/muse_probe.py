#!/usr/bin/env python3
"""Probe per la quota Muse Code (Muse Spark).

Legge l'access token OAuth del login `muse` dal Keychain e interroga
l'endpoint di key-mint, che riporta `subs_usage` con le finestre 5h e
settimanale. Cache su file da 5 minuti: l'endpoint è rate-limited.
Stampa sempre un JSON con chiave "quotas" su stdout.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

KEY_URL = "https://api.meta.ai/muse-code/key"
CACHE_PATH = "/tmp/usage-muse-subs.json"
CACHE_TTL = 300
# Dopo un fallimento (Keychain che chiede il prompt, rete, rate-limit) non
# riprovare per 15 minuti: ogni tentativo spawnerebbe un popup all'utente.
# Nel frattempo si serve la cache anche se vecchia.
FAIL_PATH = "/tmp/usage-muse-fail"
FAIL_QUIET = 900


def read_token():
    try:
        out = subprocess.run(
            ["security", "find-generic-password",
             "-s", "ai.meta.dev.credentials", "-a", "meta", "-w"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        payload = json.loads(out.stdout.strip())
    except ValueError:
        return None
    token = payload.get("access_token") if isinstance(payload, dict) else None
    return token.strip() if isinstance(token, str) and token.strip() else None


def fetch_subs(token):
    req = urllib.request.Request(
        KEY_URL, data=b"{}",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/json",
                 "Content-Type": "application/json",
                 "x-api-version": "1.0.0",
                 "User-Agent": "usage-muse-probe/1.0"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status != 200:
                return None
            payload = json.load(resp)
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def load_cached():
    try:
        with open(CACHE_PATH) as f:
            cached = json.load(f)
        if time.time() - cached.get("at", 0) < CACHE_TTL:
            return cached.get("payload")
    except (OSError, ValueError):
        pass
    return None


def save_cache(payload):
    try:
        with open(CACHE_PATH, "w") as f:
            json.dump({"at": time.time(), "payload": payload}, f)
    except OSError:
        pass


def load_stale():
    try:
        with open(CACHE_PATH) as f:
            cached = json.load(f)
        payload = cached.get("payload")
        return payload if isinstance(payload, dict) and payload else None
    except (OSError, ValueError):
        return None


def failing_quietly():
    try:
        with open(FAIL_PATH) as f:
            return time.time() - float(f.read().strip() or 0) < FAIL_QUIET
    except (OSError, ValueError):
        return False


def mark_failed():
    try:
        with open(FAIL_PATH, "w") as f:
            f.write(str(time.time()))
    except OSError:
        pass


def clear_failed():
    try:
        os.unlink(FAIL_PATH)
    except OSError:
        pass


def iso(ts):
    try:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OverflowError):
        return None


def main():
    payload = load_cached()
    if payload is None:
        if failing_quietly():
            payload = load_stale()
        else:
            token = read_token()
            payload = fetch_subs(token) if token else None
            if payload:
                save_cache(payload)
                clear_failed()
            else:
                mark_failed()
                payload = load_stale()
    quotas = []
    usage = (payload or {}).get("subs_usage")
    if isinstance(usage, dict):
        window = usage.get("window")
        if isinstance(window, dict) and window.get("used_percent") is not None:
            q = {"type": "session",
                 "percentRemaining": max(0.0, min(100.0,
                     100.0 - float(window["used_percent"])))}
            resets = iso(window.get("resets_at"))
            if resets:
                q["resetsAt"] = resets
            quotas.append(q)
        weekly = usage.get("weekly")
        if isinstance(weekly, dict) and weekly.get("used_percent") is not None:
            q = {"type": "weekly",
                 "percentRemaining": max(0.0, min(100.0,
                     100.0 - float(weekly["used_percent"])))}
            resets = iso(weekly.get("resets_at"))
            if resets:
                q["resetsAt"] = resets
            quotas.append(q)
    sys.stdout.write(json.dumps({"quotas": quotas,
                                 "email": (payload or {}).get("user_email")}))



if __name__ == "__main__":
    main()
