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

Settings, Gestures, Palm rejection (on by default). Built after how other apps
do it (tldraw's pen mode, Xournal++, Notability) and tuned from an input trace
of Sam's hand on his iPad (2026-11-13), not guessed:

- The Pencil only draws. Once a pen has been seen, finger drawing turns off, so
  a touch can only scroll, zoom or tap.
- While the Pencil is on the screen, every new touch is ignored.
- A contact over 24 px radius is a palm and is always ignored. On the 10th gen
  iPad a fingertip reports 15.7, a palm 36.5 and the Pencil 0.1.
- A palm that was already down when the Pencil lands is cancelled, and what it
  did is undone: the page goes back to where it was and its stroke is dropped.
- Nothing is held back after the Pencil lifts, so a finger scrolls at once
  after writing. (A 0.8 s block after each stroke and a 90 ms hold on every
  scroll were tried first: the trace showed them eating scrolls and causing
  the lag.)
- A gesture made only of ignored touches neither draws nor pans. The gesture
  recognizer sees a touch before palm rejection does, and used to take an
  ignored finger for the pen it saw last, leaving a dot.
- A stroke never moves the page, and a lone pen after a palm is never taken
  for the tail of a pinch.

The 10th gen iPad has no Pencil hover, so a palm that lands first can only be
known for a palm once the pen arrives; on iPads with hover, a hovering pen
counts as in use. The logic is `lib/data/palm_rejection.dart`, applied in
`canvas_gesture_detector.dart`.

Test: `flutter test integration_test/palm_rejection_test.dart -d <simulator>`.

Input trace (for tuning): launch with the environment variable `QUILL_INPUT_TRACE` (`devicectl device process launch --environment-variables {"QUILL_INPUT_TRACE":"1"}`) or put a `.quill-input-trace` file in the documents folder. Every pointer event (kind, contact radius, pressure, time) and each draw or pan decision is appended to `input-trace.log` there. `lib/data/input_trace.dart`.
