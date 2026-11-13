# Touch editing in Quill

Quill is used on an iPad with a finger and Apple Pencil, with Notability as the
reference. These are the touch changes on top of Quill (2026-11-07).

- **Press and hold** a finger on writing or an image to select it. A word is
  taken as a group (strokes written next to each other, narrow gaps between
  lines so one line is not merged with the next); a highlighter stroke is
  selected alone. Works with finger drawing on or off. The tool you had comes
  back when the selection is dismissed (tap elsewhere, cut, delete).
- **Floating menu** next to the selection: Cut, Copy, Paste (when the shelf has
  something), Duplicate, Color, Delete. It follows the selection while the
  page is panned or zoomed and hides while it is dragged. A finger can drag a
  selection it is holding. This replaced the delete and duplicate icons in the
  toolbar.
- **Clipboard shelf** (`lib/data/clipboard_shelf.dart`): every Copy or Cut is
  kept (last 12, newest first, across notes) and can be pasted again and
  again. Press and hold on empty paper: Paste here, or Clipboard to pick an
  older copy. Lives for the app session only: it is not written to disk, so a
  restart clears it. A PDF page image only pastes into its own note.
- **Touch targets**: toolbar buttons, color swatches, the pen size slider and
  the zoom and pan lock buttons are at least 44 pt.

Test: `flutter test integration_test/touch_selection_test.dart -d <simulator>`
drives the real editor with touch input (hold, menu, copy, delete, paste twice
from the shelf, dismiss).

## Palm rejection

While the Pencil is touching the screen, hovering over it, or was lifted less
than a hold time ago, finger and palm touches are ignored: no panning, zooming,
taps, press and hold or drawing. A palm that was already down when the Pencil
arrived is cancelled. Settings, Gestures, Palm rejection sets the hold time (Off,
Low 0.4 s, Medium 0.8 s by default, High 1.5 s). The logic is
`lib/data/palm_rejection.dart`, applied in `canvas_gesture_detector.dart`.

How the touch and pen input is arbitrated (2026-11-13). The 10th gen iPad has no Pencil hover, so the pen
cannot be sensed before it touches: a palm that lands first is only known to be
a palm once the pen arrives. So:

- A touch with a contact radius over 24 px is a palm and is ignored outright
 .
- A touch waits 90 ms before it may pan or zoom, and the page position from
  before the touches landed is kept: when the Pencil arrives while those
  touches are still down, the page snaps back and any stroke they drew is
  dropped.
- A stroke never moves the page. When the pen joined a palm's gesture it became
  a zoom with scale 0 (a zoom collapse in release builds) and the pen's first
  stroke was swallowed as the tail of a pinch. Both are fixed.

Test: `flutter test integration_test/palm_rejection_test.dart -d <simulator>`.

