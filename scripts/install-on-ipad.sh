#!/usr/bin/env bash
#
# Build this fork (bundle id com.samstuhl.saber, team W2X4GVG63F) signed with
# Sam's Apple Development identity and install it on a device on USB or the same
# Wi-Fi as this Mac. Needs a Mac with Flutter, CocoaPods and Xcode signed in as the
# team (sam@stuhlfamily.com), the device trusted and unlocked. The mini can do all of
# this at home; the MacBook's Xcode has no account since 2026-11-08 ("No Accounts").
# Run it in a Terminal window on that Mac's desktop, or on the mini in a window
# of the mini-host tmux session, not over a plain ssh: signing needs the
# unlocked login keychain ("User interaction is not allowed" over ssh).
#
#   scripts/install-on-ipad.sh [<device udid> [<devicectl id>]]
#
# Defaults are Sam's iPad (docs/ipad.md in atlas). The profile is valid for a year
# (paid individual team), but revoking the certificate that signed a build stops the
# installed app launching at once ("Launchd job spawn failed", POSIX error 85):
# docs/quill-sync.md, Building and installing.
set -euo pipefail
udid="${1:-00008101-000434103A47001E}"
coredevice="${2:-D97107A5-B0A8-5681-A0C0-B42ABBFEA38B}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
derived="${QUILL_DEVICE_BUILD_DIR:-/tmp/quill-device-dd}"
# A dependency builds Rust code through rustup, which lives in ~/.cargo/bin and
# is not on a non-login shell's PATH.
export PATH="$HOME/.cargo/bin:$PATH"
# On the mini, CocoaPods is a private gem under Homebrew's portable Ruby, because
# brew's formula compiles all of Rust and LLVM there.
pods="$HOME/.local/share/cocoapods-gems"
if [[ -x "$pods/bin/pod" ]]; then
  export GEM_HOME="$pods" LANG="${LANG:-en_US.UTF-8}"
  export PATH="$pods/bin:/usr/local/bin:/usr/local/Homebrew/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH"
fi

# A Gatekeeper prompt on a screen nobody is watching stalls Flutter's first exec
# forever, with no output (16 minutes on the mini, 2026-11-08). Fail instead.
dartvm="$(dirname "$(readlink -f "$(command -v flutter)")")/cache/dart-sdk/bin/dartvm"
if [[ -x "$dartvm" ]]; then
  "$dartvm" --version >/dev/null 2>&1 &
  dart_pid=$!
  for _ in {1..20}; do kill -0 "$dart_pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$dart_pid" 2>/dev/null; then
    kill -9 "$dart_pid" 2>/dev/null || true
    echo "Flutter's dartvm did not start in 20 s: see docs/quill-sync.md, Building and installing" >&2
    exit 1
  fi
  wait "$dart_pid" 2>/dev/null || true
fi

# Quill sync (docs/quill-sync.md): the server's address and token are compiled
# in. The token is read (locally on the mini, over ssh elsewhere) straight into
# a mode 600 file and never printed or passed as an argument. QUILL_SYNC=off builds without sync.
defines=()
if [[ "${QUILL_SYNC:-on}" != off ]]; then
  defines_file="$(mktemp -t quill-sync)"
  trap 'rm -f "$defines_file"; sed -i "" "/^DART_DEFINES=/d" ios/Flutter/Generated.xcconfig 2>/dev/null || true' EXIT
  # On the mini itself the token is a local file; elsewhere it comes over ssh.
  if [[ -r ~/.config/quill-sync/token ]]; then
    read_token() { cat ~/.config/quill-sync/token; }
  else
    read_token() { ssh -o BatchMode=yes mac-mini-sam 'cat ~/.config/quill-sync/token'; }
  fi
  read_token | python3 -c '
import json, sys
token = sys.stdin.read().strip()
if not token:
    sys.exit("no quill-sync token on the mini (~/.config/quill-sync/token)")
json.dump({"QUILL_SYNC_URL": sys.argv[1], "QUILL_SYNC_TOKEN": token}, open(sys.argv[2], "w"))
' "${QUILL_SYNC_URL:-https://sams-mac-mini.tail2add23.ts.net:8796}" "$defines_file"
  defines=(--dart-define-from-file="$defines_file")
fi

flutter pub get
# Generates ios/Flutter/Generated.xcconfig (with the defines) and runs pod
# install, no build. The defines are removed from it again on exit.
flutter build ios --release --config-only ${defines[@]+"${defines[@]}"}
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination "id=$udid" -derivedDataPath "$derived" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=W2X4GVG63F CODE_SIGN_STYLE=Automatic build
# A build signed by a revoked certificate installs fine and then will not launch.
app="$derived/Build/Products/Release-iphoneos/Runner.app"
if ! codesign --verify --deep --strict "$app"; then
  echo "the build's signature is not valid (a revoked certificate?), not installing" >&2
  exit 1
fi
# Installing replaces the running app, closing it under Sam's pen:
# QUILL_BUILD_ONLY=1 stops here so the install can wait for a pause.
if [ -n "${QUILL_BUILD_ONLY:-}" ]; then
  echo "built, not installed: $app"
  exit 0
fi
xcrun devicectl device install app --device "$coredevice" "$app"
xcrun devicectl device process launch --device "$coredevice" com.samstuhl.saber
