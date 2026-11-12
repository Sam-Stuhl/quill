import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:quill/components/canvas/_stroke.dart';
import 'package:quill/components/canvas/image/editor_image.dart';

/// One copy: the strokes and images that were selected.
///
/// Holds its own copies, so deleting or moving the originals afterwards
/// does not change what gets pasted.
class ClipboardEntry {
  new({
    required this.strokes,
    required this.images,
    required this.sourcePath,
    required this.bounds,
  }) : copiedAt = DateTime.now();

  final List<Stroke> strokes;
  final List<EditorImage> images;

  /// The note this was copied from. A PDF page image only works in its own note.
  final String sourcePath;

  /// Where the copy sat on its page.
  final Rect bounds;
  final DateTime copiedAt;

  int get itemCount => strokes.length + images.length;
}

/// The last few copies, newest first, so a copy can be pasted again later
/// and not only once (Notability's clipboard habit). Lives for the app's
/// session and is shared by every note.
class ClipboardShelf extends ChangeNotifier {
  new _();
  static final instance = ClipboardShelf._();

  static const maxEntries = 12;

  final List<ClipboardEntry> _entries = [];
  List<ClipboardEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  ClipboardEntry? get latest => _entries.isEmpty ? null : _entries.first;

  void add(ClipboardEntry entry) {
    _entries.insert(0, entry);
    if (_entries.length > maxEntries) _entries.removeLast();
    notifyListeners();
  }

  void remove(ClipboardEntry entry) {
    if (_entries.remove(entry)) notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}
