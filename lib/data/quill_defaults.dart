import 'package:material_ui/material_ui.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';

/// Sam's defaults for Quill: pens, paper, theme. Applied once on first launch
/// (and again whenever [version] goes up) by writing the same preferences the
/// settings screens write, so upstream Saber's own defaults, and merging them,
/// stay untouched, and anything Sam changes later in the app stays changed.
///
/// To change a taste: edit the value here and raise [version].
abstract class QuillDefaults {
  /// Raise to apply the values below again on the next launch.
  static const version = 1;

  /// Ink blue, the icon's colour (scripts/quill_icon.swift).
  static const accent = Color(0xFF3454A0);
  static const inkBlue = Color(0xFF1B3B8C);
  static const pencilGray = Color(0xFF3A3A3A);

  static Future<void> applyOnce() async {
    await stows.quillDefaultsVersion.waitUntilRead();
    if (stows.quillDefaultsVersion.value >= version) return;
    apply();
    stows.quillDefaultsVersion.value = version;
  }

  static void apply() {
    // Theme: follow the system (light by day, dark at night), in ink blue.
    stows.appTheme.value = .system;
    stows.accentColor.value = accent;

    // Paper: college ruled, white, for new notes.
    stows.lastBackgroundPattern.value = CanvasBackgroundPattern.collegeLtr;

    // Pens: a fine black fountain pen to start with, a blue ballpoint for
    // marking up, a slim yellow highlighter, a soft gray pencil.
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastFountainPenOptions.value = Pen.fountainPenOptions.copyWith(
      size: 3,
    );
    stows.lastFountainPenColor.value = Colors.black.toARGB32();
    stows.lastBallpointPenOptions.value = Pen.ballpointPenOptions.copyWith(
      size: 2.5,
    );
    stows.lastBallpointPenColor.value = inkBlue.toARGB32();
    stows.lastHighlighterOptions.value = Pen.highlighterOptions.copyWith(
      size: 30,
    );
    stows.lastHighlighterColor.value = Colors.yellow
        .withAlpha(Highlighter.alpha)
        .toARGB32();
    stows.lastPencilColor.value = pencilGray.toARGB32();
  }
}
