#!/usr/bin/env bash
#
# Kept so old habits and notes still work: the iPad now gets Quill from
# TestFlight, built and uploaded on every merge to main (docs/ship-ios.md).
# This builds and uploads the checked-out commit by hand, with no USB, no
# unlocked keychain and no local signing certificate.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-ios.sh" "$@"
