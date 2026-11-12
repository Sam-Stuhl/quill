#!/usr/bin/env bash
# End to end on an iOS simulator against the live quill-sync on the mini
# (integration_test/quill_sync_e2e_test.dart). Run on a Mac on the tailnet with
# `ssh mac-mini-sam`, Xcode and Flutter:   quill-sync/run-e2e-sim.sh [simulator id]
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
sim="${1:-$(xcrun simctl list devices available | grep -m1 'iPad' | grep -oE '[0-9A-F-]{36}')}"
url="${QUILL_SYNC_URL:-https://sams-mac-mini.tail2add23.ts.net:8796}"

defines_file="$(mktemp -t quill-sync)"
cleanup() {
  rm -f "$defines_file"
  kill "${dropper:-}" 2>/dev/null || true
  ssh -o BatchMode=yes mac-mini-sam 'rm -rf /tmp/quill-e2e-last; cp -R ~/quill/Notes/_e2e /tmp/quill-e2e-last 2>/dev/null; rm -rf ~/quill/Notes/_e2e ~/quill/.quill/store/_e2e ~/quill/Inbox/_e2e' || true
}
trap cleanup EXIT
ssh -o BatchMode=yes mac-mini-sam 'cat ~/.config/quill-sync/token' | python3 -c '
import json, sys
json.dump({"QUILL_SYNC_URL": sys.argv[1], "QUILL_SYNC_TOKEN": sys.stdin.read().strip()}, open(sys.argv[2], "w"))
' "$url" "$defines_file"

xcrun simctl boot "$sim" 2>/dev/null || true
scp -q templates/*lined*.pdf mac-mini-sam:/tmp/e2e-inbound.pdf
scp -q assets/icon/icon.png mac-mini-sam:/tmp/e2e-inbound.png

# Once the app's first PDF from this run is on the mini, drop two inbox files.
start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
ssh -o BatchMode=yes mac-mini-sam "
  until grep '\"ev\": \"pdf\"' ~/quill/.quill/events.jsonl | grep -q '/_e2e/sim' \
    && [ \$(grep '\"ev\": \"pdf\"' ~/quill/.quill/events.jsonl | grep '/_e2e/sim' | tail -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"t\"])') -gt $start_ms ]; do sleep 0.5; done
  sleep 20
  for f in /tmp/e2e-inbound.pdf /tmp/e2e-inbound.png; do
    /usr/local/bin/python3 ~/repos/quill/quill-sync/server.py put \$f --to _e2e --wait --timeout 60
    rm -f \$f
  done" &
dropper=$!

flutter test integration_test/quill_sync_e2e_test.dart -d "$sim" --no-dds \
  --dart-define-from-file="$defines_file" 2>&1 | tee /tmp/qs-e2e-flutter.log | grep -E 'QUILL_E2E|All tests|Some tests|\[E\]|Expected|Error' || true
wait "$dropper" 2>/dev/null || true
ssh -o BatchMode=yes mac-mini-sam '/usr/local/bin/python3 ~/repos/quill/quill-sync/measure.py --since 15'
