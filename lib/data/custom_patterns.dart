import 'dart:convert';

import 'package:quill/data/prefs.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// A saved paper: a built-in pattern with its own spacing and thickness.
/// Choosing one for a note sets the note's pattern, line height and line
/// thickness, so notes stay readable by any build of the app.
class const CustomPattern({
  required final String id,
  required final String name,
  required final CanvasBackgroundPattern pattern,
  required final int lineHeight,
  required final int lineThickness,
}) {
  static const minLineHeight = 20;
  static const maxLineHeight = 100;
  static const minLineThickness = 1;
  static const maxLineThickness = 5;

  String toJsonString() => jsonEncode({
    'id': id,
    'n': name,
    'p': pattern.name,
    'l': lineHeight,
    'lt': lineThickness,
  });

  static CustomPattern? tryParse(String source) {
    try {
      final json = jsonDecode(source) as Map<String, dynamic>;
      return CustomPattern(
        id: json['id'] as String,
        name: json['n'] as String,
        pattern: CanvasBackgroundPattern.fromName(json['p'] as String?),
        lineHeight: (json['l'] as int).clamp(minLineHeight, maxLineHeight),
        lineThickness: (json['lt'] as int).clamp(
          minLineThickness,
          maxLineThickness,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static List<CustomPattern> get all => [
    for (final source in stows.customBackgroundPatterns.value)
      ?tryParse(source),
  ];

  static void add(CustomPattern pattern) {
    stows.customBackgroundPatterns.value = [
      ...stows.customBackgroundPatterns.value,
      pattern.toJsonString(),
    ];
  }

  static void remove(String id) {
    stows.customBackgroundPatterns.value = [
      for (final source in stows.customBackgroundPatterns.value)
        if (tryParse(source)?.id != id) source,
    ];
  }

  /// Makes this the paper for new notes.
  void setAsDefault() {
    stows.lastBackgroundPattern.value = pattern;
    stows.lastLineHeight.value = lineHeight;
    stows.lastLineThickness.value = lineThickness;
  }

  bool get isDefault =>
      stows.lastBackgroundPattern.value == pattern &&
      stows.lastLineHeight.value == lineHeight &&
      stows.lastLineThickness.value == lineThickness;
}
