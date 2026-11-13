// Palm rejection in the real editor: a palm that rests and slides before the
// pen touches down must not leave the page moved or a stray stroke behind, and
// a deliberate finger scroll must still work.
//
//   flutter test integration_test/palm_rejection_test.dart -d <simulator>
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:quill/components/canvas/canvas_gesture_detector.dart';
import 'package:quill/data/file_manager/file_manager.dart';
import 'package:quill/data/flavor_config.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/tools/pen.dart';
import 'package:quill/data/tools/stroke_properties.dart';
import 'package:quill/i18n/strings.g.dart';
import 'package:quill/pages/editor/editor.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('palm before the pen', (tester) async {
    FlavorConfig.setupFromEnvironment();
    StrokeOptionsExtension.setDefaults();
    Stows.markAsOnMainIsolate();
    await FileManager.init();
    await workerManager.init(isolatesCount: 1);
    pdfrxFlutterInitialize();
    stows.editorFingerDrawing.value = true;
    stows.palmRejectionMs.value = 800;

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: '/_e2e/palm ${DateTime.now().millisecondsSinceEpoch}',
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final editor = tester.state<EditorState>(find.byType(Editor));
    final page = editor.coreInfo.pages[0];
    final detector = tester.state<CanvasGestureDetectorState>(
      find.byType(CanvasGestureDetector),
    );
    // zoomed in, so the page has room to pan
    for (var i = 0; i < 10; i++) {
      detector.zoomIn();
    }
    await tester.pump(const Duration(milliseconds: 300));
    final baseY = detector.transform.getTranslation().y;
    final start = tester.getCenter(find.byType(CanvasGestureDetector));

    // 1. a deliberate finger scroll still works
    stows.editorFingerDrawing.value = false;
    final finger = await tester.startGesture(
      start,
      kind: PointerDeviceKind.touch,
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 150));
    for (var i = 1; i <= 8; i++) {
      await finger.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await finger.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      detector.transform.getTranslation().y,
      lessThan(baseY - 50),
      reason: 'a finger scroll no longer pans',
    );
    // a palm lands, slides far, then the pen lands: nothing may remain
    var pointerId = 10;
    Future<void> palmThenPen() async {
      final palmId = pointerId++;
      final penId = pointerId++;
      final palm = await tester.startGesture(
        start,
        kind: PointerDeviceKind.touch,
        pointer: palmId,
      );
      await tester.pump(const Duration(milliseconds: 150));
      for (var i = 1; i <= 8; i++) {
        await palm.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final pen = await tester.startGesture(
        start + const Offset(120, 0),
        kind: PointerDeviceKind.stylus,
        pointer: penId,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await pen.up();
      await tester.pump(const Duration(milliseconds: 100));
      await palm.up();
      await tester.pump(const Duration(milliseconds: 1000));
    }

    // 2. finger drawing off: the palm would pan the page
    editor.currentTool = Pen.currentPen;
    final yBeforePalm = detector.transform.getTranslation().y;
    await palmThenPen();
    expect(
      detector.transform.getTranslation().y,
      closeTo(yBeforePalm, 0.5),
      reason: 'the palm moved the page',
    );

    // 3. finger drawing on: the palm would draw
    stows.editorFingerDrawing.value = true;
    final strokesBefore = page.strokes.length;
    await palmThenPen();
    expect(page.strokes.length, strokesBefore, reason: 'palm left a stroke');
  });
}
