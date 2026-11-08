import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/clipboard_shelf.dart';
import 'package:saber/data/tools/select.dart';
import 'package:sbn/has_size.dart';
import 'package:sbn/tool_id.dart';

Stroke _line(Offset from, Offset to, {ToolId toolId = .fountainPen}) {
  final stroke = Stroke(
    color: const Color(0xFF000000),
    pressureEnabled: false,
    options: StrokeOptions(size: 4),
    pageIndex: 0,
    page: const HasSize(Size(1000, 1400)),
    toolId: toolId,
  );
  stroke.addPoint(from);
  stroke.addPoint(Offset.lerp(from, to, 0.5)!);
  stroke.addPoint(to);
  return stroke;
}

void main() {
  group('Select.selectAt (press and hold)', () {
    test('takes the stroke under the finger and its neighbours, not the line below', () {
      final word = [
        _line(const Offset(100, 100), const Offset(130, 100)),
        _line(const Offset(138, 100), const Offset(170, 100)),
      ];
      final nextLine = _line(const Offset(100, 200), const Offset(170, 200));
      final far = _line(const Offset(600, 100), const Offset(640, 100));

      final select = Select.currentSelect..unselect();
      final hit = select.selectAt(const Offset(110, 102), 0, [
        ...word,
        nextLine,
        far,
      ], []);

      expect(hit, isTrue);
      expect(select.doneSelecting, isTrue);
      expect(select.selectResult.strokes, containsAll(word));
      expect(select.selectResult.strokes, isNot(contains(nextLine)));
      expect(select.selectResult.strokes, isNot(contains(far)));
      expect(select.bounds!.contains(const Offset(150, 100)), isTrue);
    });

    test('a highlighter is selected alone', () {
      final highlight = _line(
        const Offset(100, 100),
        const Offset(200, 100),
        toolId: .highlighter,
      );
      final ink = _line(const Offset(120, 100), const Offset(180, 100));

      final select = Select.currentSelect..unselect();
      expect(
        select.selectAt(const Offset(150, 100), 0, [highlight, ink], []),
        isTrue,
      );
      expect(select.selectResult.strokes, hasLength(1));
    });

    test('empty paper selects nothing', () {
      final select = Select.currentSelect..unselect();
      final hit = select.selectAt(const Offset(400, 400), 0, [
        _line(const Offset(100, 100), const Offset(130, 100)),
      ], []);
      expect(hit, isFalse);
      expect(select.doneSelecting, isFalse);
    });
  });

  group('ClipboardShelf', () {
    ClipboardEntry entry(String path) => ClipboardEntry(
      strokes: const [],
      images: const [],
      sourcePath: path,
      bounds: const Rect.fromLTWH(0, 0, 10, 10),
    );

    test('keeps copies, newest first, and pasting does not use them up', () {
      final shelf = ClipboardShelf.instance..clear();
      final a = entry('/a'), b = entry('/b');
      shelf.add(a);
      shelf.add(b);
      expect(shelf.entries, [b, a]);
      expect(shelf.latest, b);
      expect(shelf.entries, [b, a]); // reading is not consuming
    });

    test('holds at most maxEntries and can drop one or all', () {
      final shelf = ClipboardShelf.instance..clear();
      for (var i = 0; i < ClipboardShelf.maxEntries + 5; i++) {
        shelf.add(entry('/$i'));
      }
      expect(shelf.entries, hasLength(ClipboardShelf.maxEntries));
      shelf.remove(shelf.entries.first);
      expect(shelf.entries, hasLength(ClipboardShelf.maxEntries - 1));
      shelf.clear();
      expect(shelf.isEmpty, isTrue);
    });
  });
}
