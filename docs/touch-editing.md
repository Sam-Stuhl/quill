# Touch editing in Quill

Quill is used on an iPad with a finger and Apple Pencil, with Notability as the
reference. These are the touch changes on top of Saber (2026-11-07).

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
