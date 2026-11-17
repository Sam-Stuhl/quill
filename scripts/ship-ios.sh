#!/usr/bin/env bash
#
# Build this fork (com.samstuhl.saber, team W2X4GVG63F) and upload it to
# TestFlight, signed by Apple's cloud signing through an App Store Connect API
# key. No Xcode sign-in, no local signing certificate, no keychain: a revoked or
# missing certificate on any Mac cannot stop it. TestFlight then installs the
# build on the iPad and iPhone by itself (automatic updates).
#
# Runs on every merge to main on the mini (.github/workflows/ship-ios.yml); run
# it by hand the same way. Setup and troubleshooting: docs/ship-ios.md.
#
#   scripts/ship-ios.sh            build and upload the checked-out commit
#   QUILL_SHIP_DRY=1 scripts/ship-ios.sh   build and export, do not upload
#
# Reads ~/.config/quill-ship/env (ASC_KEY_ID, ASC_ISSUER_ID) and the key file
# ~/.config/quill-ship/AuthKey.p8, both set up once (docs/ship-ios.md).
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

conf="${QUILL_SHIP_CONF:-$HOME/.config/quill-ship}"
[[ -r "$conf/env" ]] && source "$conf/env"
: "${ASC_KEY_ID:?ASC_KEY_ID missing: see docs/ship-ios.md}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID missing: see docs/ship-ios.md}"
key="${ASC_KEY_PATH:-$conf/AuthKey.p8}"
[[ -r "$key" ]] || { echo "App Store Connect key not found at $key: see docs/ship-ios.md" >&2; exit 1; }

work="${QUILL_SHIP_DIR:-$HOME/Library/Caches/quill-ship}"
archive="$work/Runner.xcarchive"
export_dir="$work/export"
rm -rf "$archive" "$export_dir"
mkdir -p "$work"

# A dependency builds Rust code through rustup, which is not on a non-login PATH.
export PATH="$HOME/.cargo/bin:/usr/local/bin:$PATH"
# On the mini, CocoaPods is a private gem under Homebrew's portable Ruby.
pods="$HOME/.local/share/cocoapods-gems"
if [[ -x "$pods/bin/pod" ]]; then
  export GEM_HOME="$pods" LANG="${LANG:-en_US.UTF-8}"
  export PATH="$pods/bin:/usr/local/Homebrew/Library/Homebrew/vendor/portable-ruby/current/bin:$PATH"
fi

# A Gatekeeper prompt on a screen nobody watches stalls Flutter's first exec
# forever with no output. Fail instead (docs/quill-sync.md, Building and installing).
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

# Quill sync (docs/quill-sync.md): address and token are compiled in, read into a
# mode 600 file and never printed or passed as an argument. QUILL_SYNC=off skips.
defines=()
defines_file=""
cleanup() {
  [[ -n "$defines_file" ]] && rm -f "$defines_file"
  sed -i "" "/^DART_DEFINES=/d" ios/Flutter/Generated.xcconfig 2>/dev/null || true
}
trap cleanup EXIT
if [[ "${QUILL_SYNC:-on}" != off ]]; then
  defines_file="$(mktemp -t quill-sync)"
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

# TestFlight wants a build number higher than every earlier upload: the commit
# count on main only ever grows.
build_number="$(git rev-list --count HEAD)"

flutter pub get
flutter build ios --release --config-only --build-number "$build_number" ${defines[@]+"${defines[@]}"}

auth=(-allowProvisioningUpdates
  -authenticationKeyPath "$key"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$archive" \
  DEVELOPMENT_TEAM=W2X4GVG63F CODE_SIGN_STYLE=Automatic "${auth[@]}" archive

plist="$work/ExportOptions.plist"
destination=upload
[[ -n "${QUILL_SHIP_DRY:-}" ]] && destination=export
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>${destination}</string>
  <key>teamID</key><string>W2X4GVG63F</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist "$plist" "${auth[@]}"

sha="$(git rev-parse --short HEAD)"
if [[ -n "${QUILL_SHIP_DRY:-}" ]]; then
  echo "exported, not uploaded: $export_dir (build $build_number, $sha)"
else
  echo "uploaded to TestFlight: build $build_number ($sha)"
fi
