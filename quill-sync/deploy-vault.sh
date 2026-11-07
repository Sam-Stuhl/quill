#!/usr/bin/env bash
# Quill's PDFs into the vault: install (or update) on the mini's console account.
#   cat quill-sync/deploy-vault.sh | ssh mac-mini-console bash -s -- [--status]
# Reads stage.py and notasync-quill.yaml from ~sam/repos/saber/quill-sync (sam's
# home is readable by console). Installs:
#   ~/opt/quill-stage/{stage.py,notasync-quill.yaml}
#   LaunchAgent com.samstuhl.quill-stage (gui domain, KeepAlive)
#   container notasync-quill: notasync's own image, a second router instance
set -euo pipefail
export PATH=/usr/local/bin:$PATH
SRC=/Users/sam/repos/saber/quill-sync
OPT=$HOME/opt/quill-stage
STATE=$HOME/.local/state/notasync-quill
STAGING=$HOME/Quill/staging
VAULT=$HOME/console-volumes/vault-ingest/ingest
LABEL=com.samstuhl.quill-stage
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist

status() {
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid) =' || echo "$LABEL not loaded"
  docker ps -a --filter name='^notasync-quill$' --format '{{.Names}}\t{{.Status}}'
  tail -n 3 "$HOME/.local/state/quill-stage/stage.log" 2>/dev/null || true
  tail -n 3 "$STATE/notasync.log" 2>/dev/null || true
}
if [ "${1:-}" = "--status" ]; then status; exit 0; fi

mkdir -p "$OPT" "$STATE" "$STAGING" "$HOME/.local/state/quill-stage"
cp "$SRC/stage.py" "$SRC/notasync-quill.yaml" "$OPT/"
docker image inspect notasync:local >/dev/null  # built by notasync's container.sh

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- quill-stage (saber quill-sync/stage.py): ~sam/quill/Notes to ~/Quill/staging for notasync-quill. -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>$OPT/stage.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/.local/state/quill-stage/stage.log</string>
  <key>StandardErrorPath</key><string>$HOME/.local/state/quill-stage/stage.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

docker rm -f notasync-quill >/dev/null 2>&1 || true
docker run -d --name notasync-quill --restart unless-stopped \
  -e NOTASYNC_STATE_DIR="$STATE" \
  -v "$STAGING":"$STAGING":ro \
  -v "$VAULT":"$VAULT" \
  -v "$STATE":"$STATE" \
  -v "$OPT/notasync-quill.yaml":"$OPT/notasync-quill.yaml":ro \
  notasync:local --config "$OPT/notasync-quill.yaml" watch >/dev/null
sleep 4
status
