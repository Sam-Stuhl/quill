# Shipping Quill to the iPad and iPhone

Every merge to `main` builds on the mini and uploads to TestFlight, which
installs it on the iPad and iPhone by itself. Nothing depends on a laptop, a USB
cable, an unlocked keychain, a tmux window or a local signing certificate.

    merge to main -> ship-ios workflow (runner `quill-ios`, mini, user sam)
                  -> scripts/ship-ios.sh: flutter, xcodebuild archive, export + upload
                  -> TestFlight (internal group, automatic distribution)
                  -> iPad and iPhone update (TestFlight, Automatic Updates on)

## Why it cannot break like install-on-ipad.sh did

Signing is Apple's cloud signing, driven by an App Store Connect API key
(`-authenticationKeyPath/ID/IssuerID` with `-allowProvisioningUpdates`). Xcode
needs no signed-in account, and the distribution certificate is managed by Apple
instead of living in a keychain, so revoking a Mac's Apple Development
certificate (which stopped Quill launching on 2026-11-08) no longer matters: a
TestFlight build is signed by Apple's distribution chain.

## Setup (done once)

1. App Store Connect, Users and Access, Integrations, App Store Connect API:
   create a team key named `quill-ship`, access App Manager. Download the `.p8`
   (once only), note the Key ID and Issuer ID.
2. On the mini, as `sam`:

       mkdir -p ~/.config/quill-ship && chmod 700 ~/.config/quill-ship
       printf 'ASC_KEY_ID=...\nASC_ISSUER_ID=...\n' > ~/.config/quill-ship/env
       # the .p8 goes to ~/.config/quill-ship/AuthKey.p8, mode 600

   The Key ID and Issuer ID are identifiers, not secrets (E18). The `.p8` is.
3. App Store Connect, Apps, New App: iOS, `Quill`, bundle ID `com.samstuhl.saber`
   (the App ID already exists), SKU `quill`. Apple offers no API for this step.
4. TestFlight, Internal Testing: a group `Sam` with Sam as tester and Enable
   automatic distribution on; install TestFlight on the iPad and iPhone and turn
   on Automatic Updates for the app.
5. A runner on the mini: `~/actions-runner-quill`, registered to
   `Sam-Stuhl/quill` with label `quill-ios`, as a LaunchAgent under `sam` (same
   shape as the atlas runner). The clone it builds from is `~/repos/quill-ship`.

## Running and checking

- By hand on the mini: `scripts/ship-ios.sh` (`QUILL_SHIP_DRY=1` exports without
  uploading). `scripts/install-on-ipad.sh` is a wrapper for it.
- From GitHub: Actions, ship-ios, Run workflow.
- State: the workflow's run, then TestFlight (a build shows "Processing" for a
  few minutes). The build number is the commit count on main.

## Failure modes

| Symptom | Cause |
| --- | --- |
| `ASC_KEY_ID missing` / key not found | setup step 2 not done on this Mac |
| `Authentication credentials are missing or invalid` | key revoked or expired (App Store Connect, Integrations) |
| `The bundle version must be higher` | built from a branch with fewer commits than an earlier upload: only main ships |
| Silent stall at `flutter pub get` | Gatekeeper prompt for `dartvm`, `docs/quill-sync.md` |
| No new runs on merge | the mini's `sam` session or the runner LaunchAgent is down |

Credential registry entry: `quill-ship/ASC_API_KEY` (network `map/secrets.yaml`).
