#!/usr/bin/env bash
#
# Build this fork (bundle id com.samstuhl.saber, team W2X4GVG63F) signed with
# Sam's Apple Development identity and install it on a device plugged in by USB.
# Needs a Mac with Flutter, CocoaPods and Xcode signed in as the team
# (sam@stuhlfamily.com), the device trusted and unlocked.
# Run it in a Terminal window on that Mac's desktop, not over ssh: signing needs
# the login keychain ("User interaction is not allowed" over ssh).
#
#   scripts/install-on-ipad.sh [<device udid> [<devicectl id>]]
#
# Defaults are Sam's iPad (docs/ipad.md in atlas). The profile is valid for a
# year (paid individual team), so nothing needs refreshing before then.
set -euo pipefail
udid="${1:-00008101-000434103A47001E}"
coredevice="${2:-D97107A5-B0A8-5681-A0C0-B42ABBFEA38B}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
derived="${SABER_DEVICE_BUILD_DIR:-/tmp/saber-device-dd}"

flutter pub get
# Generates ios/Flutter/Generated.xcconfig and runs pod install, no build.
flutter build ios --release --config-only
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination "id=$udid" -derivedDataPath "$derived" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=W2X4GVG63F CODE_SIGN_STYLE=Automatic build
xcrun devicectl device install app --device "$coredevice" \
  "$derived/Build/Products/Release-iphoneos/Runner.app"
xcrun devicectl device process launch --device "$coredevice" com.samstuhl.saber
