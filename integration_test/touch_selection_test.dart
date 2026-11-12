// The real editor on an iOS simulator or device: press and hold selects,
// the floating menu appears next to the selection, copy keeps the copy on the
// clipboard shelf, and the shelf pastes it again and again.
//
//   flutter test integration_test/touch_selection_test.dart -d <simulator>
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:quill/components/toolbar/selection_menu.dart';
import 'package:quill/data/clipboard_shelf.dart';
import 'package:quill/data/file_manager/file_manager.dart';
import 'package:quill/data/flavor_config.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/tools/pen.dart';
import 'package:quill/data/tools/select.dart';
import 'package:quill/data/tools/stroke_properties.dart';
import 'package:quill/i18n/strings.g.dart';
import 'package:quill/pages/editor/editor.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('press and hold, menu, clipboard shelf', (tester) async {
    FlavorConfig.setupFromEnvironment();
    StrokeOptionsExtension.setDefaults();
    Stows.markAsOnMainIsolate();
    await FileManager.init();
    await workerManager.init(isolatesCount: 1);
    pdfrxFlutterInitialize();
    stows.editorFingerDrawing.value = false;
    ClipboardShelf.instance.clear();

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: '/_e2e/touch ${DateTime.now().millisecondsSinceEpoch}',
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final editor = tester.state<EditorState>(find.byType(Editor));
    final page = editor.coreInfo.pages[0];

    // two strokes close together (a "word") and one far away
    void write(double x0, double y, double x1) {
      final pen = Pen.currentPen;
      editor.currentTool = pen;
      editor.dragPageIndex = 0;
      pen.onDragStart(Offset(x0, y), page, 0, 0.5);
      for (var x = x0; x < x1; x += 8) {
        pen.onDragUpdate(Offset(x, y + (x % 24)), 0.5);
      }
      editor.onDrawEnd(ScaleEndDetails());
    }

    write(100, 200, 220);
    write(228, 200, 340);
    write(100, 600, 260);
    await tester.pump(const Duration(milliseconds: 300));
    expect(page.strokes, hasLength(3));

    // press and hold on the first stroke, as a finger
    final rb = page.renderBox!;
    final onWord = rb.localToGlobal(const Offset(120, 206));
    final gesture = await tester.startGesture(
      onWord,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(editor.currentTool, isA<Select>());
    expect(Select.currentSelect.selectResult.strokes, hasLength(2));
    expect(find.byType(SelectionMenu), findsOneWidget);
    await Future<void>.delayed(const Duration(seconds: 3)); // screenshot window

    // copy keeps it on the shelf
    await tester.tap(find.text('Copy'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(ClipboardShelf.instance.entries, hasLength(1));

    // delete the original: the copy is still there
    await tester.tap(find.text('Delete'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(page.strokes, hasLength(1));
    expect(Pen.currentStroke, isNull, reason: 'a dot is left in progress');
    expect(ClipboardShelf.instance.entries.first.itemCount, 2);
    expect(find.byType(SelectionMenu), findsNothing);

    // press and hold on empty paper: paste menu, open the shelf, paste twice
    for (var i = 0; i < 2; i++) {
      final empty = rb.localToGlobal(Offset(400.0 + i * 150, 900.0 + i * 250));
      final hold = await tester.startGesture(
        empty,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 700));
      await hold.up();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(
        const Duration(milliseconds: 300),
      ); // menu is placed a frame later
      expect(
        find.byType(PasteMenu),
        findsOneWidget,
        reason:
            'hold $i tool ${editor.currentTool} selecting ${Select.currentSelect.doneSelecting} strokes ${page.strokes.length}',
      );
      if (i == 0) await Future<void>.delayed(const Duration(seconds: 3));
      await tester.tap(find.text('Clipboard'));
      await tester.pumpAndSettle();
      if (i == 0) await Future<void>.delayed(const Duration(seconds: 3));
      await tester.tap(find.text('2 items'));
      await tester.pumpAndSettle();
      expect(page.strokes, hasLength(1 + 2 * (i + 1)));
      expect(ClipboardShelf.instance.entries, hasLength(1));
    }
    await Future<void>.delayed(const Duration(seconds: 3));

    // tapping elsewhere dismisses the selection and the tool comes back
    await tester.tapAt(rb.localToGlobal(const Offset(700, 1200)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SelectionMenu), findsNothing);
    expect(editor.currentTool, isNot(isA<Select>()));

    editor.cancelAutosaveAndMarkSaved();
    binding.reportData = {'ok': true};
  });
}
