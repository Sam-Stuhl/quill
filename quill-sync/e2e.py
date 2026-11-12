#!/usr/bin/env python3
"""End to end check of a running quill-sync over the tailnet, acting as the app.

    e2e.py [--url https://sams-mac-mini.tail2add23.ts.net:8796] [--rounds 20]

Run from any tailnet machine with `ssh mac-mini-sam` (the token is read from the
mini into memory, never printed). Measures upload round trips (native file and
PDF) and inbox delivery: a file dropped with `server.py put` on the mini, to this
client's long poll seeing it. Cleans up after itself (uploads go to trash).
"""
import argparse
import json
import statistics
import subprocess
import threading
import time
import urllib.request
from urllib.parse import quote

PDF = b"%PDF-1.4\n" + b"x" * 200_000  # about a 3 page handwritten note
SBN = b"\x00" * 60_000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="https://sams-mac-mini.tail2add23.ts.net:8796")
    ap.add_argument("--rounds", type=int, default=20)
    a = ap.parse_args()
    token = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "mac-mini-sam", "cat ~/.config/quill-sync/token"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()

    def req(method, path, body=None, headers=None, timeout=60):
        r = urllib.request.Request(a.url + path, data=body, method=method)
        r.add_header("Authorization", f"Bearer {token}")
        for k, v in (headers or {}).items():
            r.add_header(k, v)
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return json.loads(resp.read() or b"{}")

    note = "/_e2e/latency test"
    ups = {"file": [], "pdf": []}
    for i in range(a.rounds):
        now = str(int(time.time() * 1000))
        t0 = time.perf_counter()
        req("PUT", f"/v1/file?path={quote(note + '.sbn2')}", SBN,
            {"X-Mtime": now, "X-Quill-Written-At": now})
        ups["file"].append((time.perf_counter() - t0) * 1000)
        t0 = time.perf_counter()
        req("PUT", f"/v1/pdf?path={quote(note)}", PDF,
            {"X-Mtime": now, "X-Quill-Written-At": now})
        ups["pdf"].append((time.perf_counter() - t0) * 1000)

    v = req("GET", "/v1/inbox?wait=0")["version"]
    seen = {}

    def poll():
        nonlocal v
        deadline = time.time() + 60
        while time.time() < deadline and len(seen) < 3:
            body = req("GET", f"/v1/inbox?wait=25&since={v}", timeout=40)
            v = body["version"]
            for it in body["items"]:
                if it["name"].startswith("e2e-") and it["id"] not in seen:
                    seen[it["id"]] = (time.time(), it)
                    req("POST", f"/v1/inbox/{it['id']}/ack", json.dumps({"note": "/_e2e/x"}).encode())

    t = threading.Thread(target=poll)
    t.start()
    inbox = []
    for i in range(3):
        time.sleep(2)
        t0 = time.time()
        subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "mac-mini-sam",
             f"f=/tmp/e2e-{i}.pdf; printf '%%PDF-1.4 e2e {i}' > $f; "
             f"/usr/local/bin/python3 ~/repos/quill/quill-sync/server.py put $f --to _e2e >/dev/null; rm $f"],
            check=True,
        )
        put_done = time.time()
        while len(seen) <= i and time.time() - t0 < 30:
            time.sleep(0.02)
        if len(seen) > i:
            got = sorted(seen.values(), key=lambda s: s[0])[i][0]
            inbox.append(((got - put_done) * 1000, (got - t0) * 1000))
    t.join(timeout=5)
    req("DELETE", f"/v1/file?path={quote(note + '.sbn2')}")

    for k, xs in ups.items():
        print(f"upload {k:4} ({len(PDF if k == 'pdf' else SBN) // 1000} kB) n={len(xs)} "
              f"p50={statistics.median(xs):.0f} ms max={max(xs):.0f} ms")
    for put_to_seen, cmd_to_seen in inbox:
        print(f"inbox: put finished to app saw it {put_to_seen:.0f} ms "
              f"(incl. ssh round trip {cmd_to_seen:.0f} ms)")
    if len(inbox) < 3:
        print(f"inbox: only {len(inbox)} of 3 delivered")


if __name__ == "__main__":
    main()
