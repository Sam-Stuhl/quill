# <img src="https://github.com/saber-notes/saber/raw/main/assets/icon/icon.png" width="30" height="30" alt="Logo"> Saber

[<img src='https://github.com/saber-notes/saber/blob/main/assets_raw/badges/google-play-badge.svg'
    alt='Get it on Google Play'
    height=50>][google_play]
&nbsp;
[<img src="https://github.com/saber-notes/saber/blob/main/assets_raw/badges/f-droid-badge.svg"
    alt="Get it on F-Droid"
    height=50>][f-droid]
&nbsp;
[<img src="https://github.com/saber-notes/saber/blob/main/assets_raw/badges/app-store-badge.svg"
    alt="Download on the App Store"
    height=50>][app_store]
&nbsp;
[<img src="https://github.com/saber-notes/saber/blob/main/assets_raw/badges/windows-badge.png"
    alt="Download for Windows"
    height=50>][download_windows]
&nbsp;
[<img src="https://github.com/saber-notes/saber/blob/main/assets_raw/badges/flathub-badge.svg"
    alt="Download on Flathub"
    height=50>][flathub]
&nbsp;
[<img src="https://github.com/saber-notes/saber/blob/main/assets_raw/badges/appimage-logo.svg"
    alt="Get it as an AppImage"
    height=50>][download_appimage]

[English](https://github.com/saber-notes/saber/blob/main/README.md) |
[čeština](https://github.com/saber-notes/saber/blob/main/README-cs.md) |
[Deutsch](https://github.com/saber-notes/saber/blob/main/README-de.md) |
[中文 (简体中文, 中国)](https://github.com/saber-notes/saber/blob/main/README-zh-CN.md) |
[中文 (繁體, 台灣)](https://github.com/saber-notes/saber/blob/main/README-zh-TW.md) |
[العربية](https://github.com/saber-notes/saber/blob/main/README-ar.md) |
[Tiếng Việt](https://github.com/saber-notes/saber/blob/main/README-vi.md) |
[Bahasa Indonesia](https://github.com/saber-notes/saber/blob/main/README-id.md)

> **This is Sam Stuhl's fork of Saber** (`Sam-Stuhl/saber`, branch `touch-gestures`), built for his iPad. It is GPL-3.0 like upstream. Nothing here is sent upstream.
>
> ### What the fork adds
>
> - **Tap gestures, as in Notability.** A two-finger tap undoes, a three-finger tap redoes. A tap is a touch where no finger moves more than 10 px and everything lifts within 250 ms, so panning, pinch-zoom and drawing are not mistaken for one. Only finger touches count, never the Pencil or a mouse.
> - **Custom gestures (Settings, Gestures).** Every combination of 1 to 4 fingers and single, double or triple tap (11 in all; a lone one-finger tap is drawing) can be mapped to: undo, redo, eraser (toggles back to the previous tool), pen, highlighter, lasso select, toggle finger drawing, next page, previous page, or nothing. Defaults: 2 fingers = undo, 3 fingers = redo, 1-finger double tap = eraser toggle. A tap waits 300 ms only if a longer tap with the same fingers is mapped. One-finger gestures are ignored while finger drawing is on, since that finger is drawing.
> - **Scribble to erase** (Settings, Gestures, on by default). Scratching back and forth over ink with the pen (five or more sharp reversals in a small area) erases the strokes it touches and drops the scratch itself, as one undo step. Highlighter and shape pen are exempt, and a scratch that touches nothing stays as ink.
> - **reMarkable background patterns.** Two extra choices in the background picker, "reMarkable lined" and "reMarkable graph": full-page grey lines or squares, 27 across the page like the reMarkable's own templates, so no PDF import is needed. They ignore the line height setting. Notes using them show a blank background in upstream Saber.
> - Its own app: bundle id `com.samstuhl.saber`, name "Quill", so it installs next to the App Store Saber.
> - **Quill sync** to a folder on the Mac mini (`docs/quill-sync.md`). Every note lands in `~/quill/Notes/` as a PDF (plus a native copy in `~/quill/.quill/store/`) within a few seconds of each pause in writing, and anything put in `~/quill/Inbox/<folder>/` (PDF, image, `.sbn2`, `.sba`) shows up in Quill in that folder as a new note. No dialogs; it queues offline and catches up on its own. The server is `quill-sync/server.py` (LaunchAgent `com.samstuhl.quill-sync`, tailnet only); send a file from the mini with `python3 ~/repos/saber/quill-sync/server.py put FILE --to "School/CS 114"`. Each PDF also lands in the Obsidian vault with a companion note, in the course folder Notability's would (quill-sync/stage.py and a second notasync router, `notasync-quill`). To watch a note as it is written, open `https://sams-mac-mini.tail2add23.ts.net:8796/live` on a tailnet device: it redraws each note's PDF within about a second of it reaching the mini. Autosave in this fork is 1 s (at least every 4 s while writing), and the editor saves when the app is backgrounded.
>
> The code is in `lib/data/touch_gestures.dart` (tap classifier and mapping), `lib/data/scribble_erase.dart` (scribble detector), the pointer wiring in `lib/components/canvas/canvas_gesture_detector.dart` and `lib/pages/editor/editor.dart`, and the settings in `lib/pages/home/settings.dart`. Tests: `test/touch_gestures_test.dart`, `test/scribble_erase_test.dart`. The Gestures labels are English only.
>
> ### Build and install on the iPad
>
> Flutter 3.47 or newer (upstream's `submodules/flutter` pin is not needed), CocoaPods, Rust (rustup, for `super_native_extensions`) and Xcode signed in as team `W2X4GVG63F`. Plug the iPad in by USB, unlock and trust it, then in a Terminal window on the Mac's desktop (not over ssh, which cannot read the login keychain):
>
> ```bash
> scripts/install-on-ipad.sh            # Sam's iPad; pass a udid and devicectl id for another device
> ```
>
> The install script compiles in Quill sync's address and token (read from the mini over ssh); `QUILL_SYNC=off` builds without it.
>
> Tests: `flutter test test/touch_gestures_test.dart test/scribble_erase_test.dart test/quill_sync_test.dart` (with `PDFIUM_PATH=build/native_assets/macos/libpdfium.dylib` for the PDF tests), `python3 -m unittest test_server` in `quill-sync/`, and `quill-sync/run-e2e-sim.sh` for the real app on a simulator against the live server.
>
> `templates/` holds the two original reMarkable templates (graph and lined, 612 x 818 pt PDFs, exported from Notability) that the patterns above imitate.
>
> Sign in to Nextcloud in Settings the same way as the App Store Saber to get your notes back.

Saber is the notes app built for handwriting.

It's designed to be as simple and intuitive as possible, while still delivering unique features that you'll actually use. Additionally, Saber is available across all your devices, large and small, and syncs between them seamlessly.

Notably, it can invert your notes when you're in dark mode. This allows you to write with white ink on a black background, which is much easier on the eyes in low-light environments like when the teacher turns off the lights in class.
Images and PDFs are also inverted, so you can still use a digital printout or a textbook without the fuss.

Saber uses a dual-password system to protect your notes from anyone but you, even if they have complete control over the server. You can safely store your notes on the official Saber server, another server, or even host your own!

The app is completely open-source so that anyone can view the source code and see exactly what it's doing and how it handles your data. Many other note-taking apps are closed-source and proprietary, meaning that their inner workings are a mystery to the public.

As someone who studies maths, highlighting multi-line equations was always a hassle with other apps, where the highlighter would change color when it overlapped with itself. Another problem I had was that in some apps, the highlighter would render on top of the text, fading it out and making it hard to read.
Saber's highlighter has no such issues. It utilizes canvas compositing to render the highlighter in a way that is consistent with/better than traditional paper, where it handles overlaps and maintains color consistency.

Saber has everything you need to keep your notes organized. Create folders inside folders inside folders to your heart's content with no limit on the number of nested folders. And even though a note may be buried deep within a nested folder, you can still access it easily with your most recent notes always available on the home screen.

Discover a whole new way to capture and organize your thoughts with Saber. Whether you're a student, professional, or creative mind, Saber is your trusted companion for digital handwriting. Download now and let your ideas flow freely!

[![Latest release](https://img.shields.io/github/v/release/saber-notes/saber)](https://github.com/saber-notes/saber/releases/latest)
[![Flathub](https://img.shields.io/flathub/v/com.adilhanney.saber)](https://flathub.org/apps/details/com.adilhanney.saber)
[![F-Droid](https://img.shields.io/f-droid/v/com.adilhanney.saber)](https://f-droid.org/en/packages/com.adilhanney.saber/)
[![GitHub downloads](https://img.shields.io/github/downloads/saber-notes/saber/total?label=GitHub%20downloads)](https://github.com/saber-notes/saber/releases)
[![Flathub downloads](https://img.shields.io/flathub/downloads/com.adilhanney.saber?label=Flathub%20downloads)](https://flathub.org/apps/details/com.adilhanney.saber)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/adil192)](https://github.com/sponsors/adil192)
[![License](https://img.shields.io/github/license/saber-notes/saber)](https://github.com/saber-notes/saber/blob/main/LICENSE.md)
[![Translation status](https://hosted.weblate.org/widget/saber-notes/saber/svg-badge.svg)](https://hosted.weblate.org/engage/saber-notes/)
[![Codecov](https://codecov.io/gh/saber-notes/saber/branch/main/graph/badge.svg?token=EGQSN0THW2)](https://codecov.io/gh/saber-notes/saber)

<details open>
<summary>Tap to show/hide screenshots</summary>

<div>
<img src="https://github.com/saber-notes/saber/raw/main/metadata/en-US/images/phoneScreenshots/1_home.png" width="180">
<img src="https://github.com/saber-notes/saber/raw/main/metadata/en-US/images/phoneScreenshots/2_editor.png" width="180">
<img src="https://github.com/saber-notes/saber/raw/main/metadata/en-US/images/phoneScreenshots/3_login.png" width="180">
<img src="https://github.com/saber-notes/saber/raw/main/metadata/en-US/images/phoneScreenshots/4_settings.png" width="180">
</div>
</details>

## Features

Please see [#1 Saber progress][progress].

## Install

Please see
[Install Saber](https://github.com/saber-notes/saber/wiki/install)
on the wiki.

## Build from source

Please see
[Build Saber](https://github.com/saber-notes/saber/wiki/build)
on the wiki.

## Links

- [Nextcloud server][nextcloud]
- [Privacy policy][privacy]
- [License][license]
- [Releases][releases]

## Translating

All translations are thanks to our community of contributors.

If you'd like to help out translating Saber, head to [Weblate](https://hosted.weblate.org/engage/saber-notes/)!

[![Translation status](https://hosted.weblate.org/widget/saber-notes/multi-auto.svg)](https://hosted.weblate.org/engage/saber-notes/)

Note: To avoid falling back to English, any gaps in the translations are filled
in by machine translation until a human can contribute.

## Supporting Saber

If you like Saber, please consider supporting it by:
- Spreading the word!
- Starring the project on GitHub
- Sponsoring me on [GitHub Sponsors](https://github.com/sponsors/adil192)
- Donating via [PayPal](https://paypal.me/adilhanney)
- Buying more storage on the Nextcloud server: see [Pricing](pricing.md)

## Development notes

Please see
[Maintainer notes](https://github.com/saber-notes/saber/wiki/Maintainer-notes)
on the wiki.


[f-droid]: https://f-droid.org/packages/com.adilhanney.saber/
[flathub]: https://flathub.org/apps/details/com.adilhanney.saber
[google_play]: https://play.google.com/store/apps/details?id=com.adilhanney.saber
[snap]: https://snapcraft.io/saber
[app_store]: https://apps.apple.com/us/app/saber/id1671523739
[download_windows]: https://github.com/saber-notes/saber/releases/download/v1.37.1/SaberInstaller_v1.37.1.exe
[download_appimage]: https://github.com/saber-notes/saber/releases/download/v1.37.1/Saber-1.37.1-x86_64.AppImage

[nextcloud]: https://nc.saber.adil.hanney.org/

[privacy]: https://github.com/saber-notes/saber/blob/main/privacy_policy.md
[license]: https://github.com/saber-notes/saber/blob/main/LICENSE.md

[releases]: https://github.com/saber-notes/saber/releases
[issues]: https://github.com/saber-notes/saber/issues
[progress]: https://github.com/saber-notes/saber/discussions/1

[f-droid-manifest]: https://gitlab.com/fdroid/fdroiddata/-/blob/master/metadata/com.adilhanney.saber.yml
