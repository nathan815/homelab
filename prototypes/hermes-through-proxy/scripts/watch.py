#!/usr/bin/env python3
"""Host-side approval poller. usage: watch.py MODE [SECONDS] [ALLOW_HOSTS_COMMA]
MODE: deny | allow_once | always_allow | none (record only) | slow:N (allow_once after N seconds)
Prints one line per card: elapsed, method, url, decision."""
import json, sys, time, urllib.request
BASE = "http://127.0.0.1:8091"
mode = sys.argv[1]; dur = float(sys.argv[2]) if len(sys.argv) > 2 else 60
allow = set(filter(None, (sys.argv[3] if len(sys.argv) > 3 else "").split(",")))
seen = {}; t0 = time.time()
def post(i, d):
    r = urllib.request.Request(f"{BASE}/approvals/{i}/decision", json.dumps({"decision": d}).encode(), {"Content-Type": "application/json"})
    try: urllib.request.urlopen(r).read()
    except Exception as e: print("decide err", e)
while time.time() - t0 < dur:
    try: cards = json.load(urllib.request.urlopen(f"{BASE}/approvals"))
    except Exception: cards = []
    for c in cards:
        i = c["id"]
        if i not in seen:
            seen[i] = time.time(); print(f"[{time.time()-t0:5.1f}s] CARD {c['method']} {c['url']} :: {c['text']}", flush=True)
        host = c["url"].split("/")[2]
        d = None
        if host in allow: d = "always_allow"
        elif mode.startswith("slowchat:"): d = ("allow_once" if time.time()-seen[i] >= float(mode[9:]) else None) if "chat/completions" in c["url"] else "allow_once"
        elif mode == "holdchat": d = None if "chat/completions" in c["url"] else "allow_once"
        elif mode in ("deny", "allow_once", "always_allow"): d = mode
        elif mode.startswith("slow:") and time.time() - seen[i] >= float(mode[5:]): d = "allow_once"
        if d:
            post(i, d); print(f"[{time.time()-t0:5.1f}s]   -> {d} {c['url']}", flush=True); seen[i] = float("inf") if mode in ("deny","allow_once","always_allow") else seen[i]
    time.sleep(0.3)
