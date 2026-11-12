# Quill performance benchmark

An on-device benchmark, `lib/data/perf_bench.dart`, measures the app on the
iPad itself (release build). It does nothing unless asked.

## Running it

1. Build and install with `scripts/install-on-ipad.sh` (on the mini, in a
   `mini-host` window, see quill-sync.md, Building and installing).
2. Put a marker file in the app's documents folder, then launch the app (the
   iPad must be unlocked and stay awake for about 2 minutes):

   ```bash
   touch /tmp/.quill-bench
   xcrun devicectl device copy to --device <coredevice id> \
     --domain-type appDataContainer --domain-identifier com.samstuhl.saber \
     --source /tmp/.quill-bench --destination Documents/Saber/.quill-bench
   xcrun devicectl device process launch --device <coredevice id> com.samstuhl.saber
   ```

   Setting the environment variable `QUILL_BENCH` at launch works too.
3. Read the result:

   ```bash
   xcrun devicectl device copy from --device <coredevice id> \
     --domain-type appDataContainer --domain-identifier com.samstuhl.saber \
     --source Documents/Saber/quill-bench.json --destination quill-bench.json
   ```

## What it does

Builds a 12-page note of 1800 strokes, then times: saving and loading it, opening
it in the editor, 14 synthetic pen strokes written with 400 ms pauses (four
points per frame, through the editor's own draw callbacks), a 3 s pause long
enough for the sync PDF render to start, 8 more strokes written while it runs,
scrolling 9000 px and zooming 1x to 3x. It also records how late a 5 ms timer
fires (`lag_*`: the main isolate's stalls, whatever the cause) and the time of
each save's serialise and thumbnail steps and each PDF render (`timers_ms`). Per phase it records build and raster time per frame (Flutter's
frame timings) and the gaps between frames seen from Dart. The test note is
deleted when the run ends.

## What the first measurements found (2026-11-11, iPad 10th gen, release)

On the 12-page, 1800-stroke note, drawing, scrolling and zooming cost about
20 ms of raster time per frame (about 30 fps) and under 2 ms of build time:
the engine re-rasterises every visible stroke each frame, and Flutter's raster
cache does not help. Splitting the page into a finished-strokes layer and a
live layer (`CanvasLayer`) changed nothing by itself (raster 19.2 ms drawing,
22.1 ms scrolling). So the editor on screen (`cacheStrokes`) draws each page's
finished strokes from a bitmap kept on the page (`EditorPage.strokeBitmap`),
redrawn only when `strokesRevision` or the stroke count changes or the zoom
needs a sharper one. It falls back to vectors above 12 megapixels, while a
selection is being moved, and in exports and previews. Code that changes
strokes without changing their count must bump `strokesRevision` (undo and
redo do, for every page).
