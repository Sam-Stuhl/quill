// End to end: the real editor and Quill sync against the live server on the
// mini, on an iOS simulator or device. Measures pen up to the note's PDF being
// current on the mini, and inbox files dropped on the mini becoming notes.
//
//   quill-sync/run-e2e-sim.sh      (builds the defines, drops inbox files)
//
// Writes into /_e2e/ in the app and on the mini; the run script cleans up.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/quill_sync/quill_sync.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pen up to PDF on the mini, and inbox to note', (tester) async {
    FlavorConfig.setupFromEnvironment();
    StrokeOptionsExtension.setDefaults();
    Stows.markAsOnMainIsolate();
    await FileManager.init();
    await workerManager.init(isolatesCount: 1);
    pdfrxFlutterInitialize();
    await QuillSync.startIfConfigured();
    final sync = QuillSync.instance;
    expect(sync, isNotNull, reason: 'build with QUILL_SYNC_URL and _TOKEN');

    Future<Map<String, dynamic>> manifest() async {
      final r = await http.get(
        sync!.baseUrl.replace(path: '/v1/manifest'),
        headers: {'Authorization': 'Bearer ${sync.token}'},
      );
      return jsonDecode(r.body) as Map<String, dynamic>;
    }

    final note = '/_e2e/sim ${DateTime.now().millisecondsSinceEpoch}';
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: Editor(path: note)),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final editor = tester.state<EditorState>(find.byType(Editor));
    expect(editor.coreInfo.readOnly, isFalse);

    final latencies = <int>[];
    var lastPdf = 0;
    for (var round = 0; round < 6; round++) {
      // A short handwritten line: about 40 points, like a word.
      final pen = Pen.currentPen;
      editor.currentTool = pen;
      editor.dragPageIndex = 0;
      final y = 120.0 + round * 60;
      pen.onDragStart(Offset(100, y), editor.coreInfo.pages[0], 0, 0.5);
      for (var x = 100.0; x < 500; x += 10) {
        pen.onDragUpdate(Offset(x, y + (x % 30)), 0.5);
      }
      editor.onDrawEnd(ScaleEndDetails());
      final penUp = DateTime.now();

      var done = false;
      while (!done) {
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final m = await manifest();
        final pdf = (m['pdfs'] as Map)[note] as int?;
        if (pdf != null && pdf > lastPdf) {
          lastPdf = pdf;
          done = true;
        }
        if (DateTime.now().difference(penUp) > const Duration(seconds: 30)) {
          fail('PDF not on the mini 30 s after pen up (round $round)');
        }
      }
      final ms = DateTime.now().difference(penUp).inMilliseconds;
      latencies.add(ms);
      // ignore: avoid_print
      print('QUILL_E2E pen up to PDF on mini: round $round: $ms ms');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    latencies.sort();
    // ignore: avoid_print
    print(
      'QUILL_E2E pen up to PDF on mini: n=${latencies.length} '
      'p50=${latencies[latencies.length ~/ 2]} ms max=${latencies.last} ms',
    );

    // The run script drops e2e-inbound.pdf and e2e-inbound.png into
    // Inbox/_e2e/ once it sees this note's PDF on the mini.
    final waitStart = DateTime.now();
    while (!(FileManager.doesFileExist('/_e2e/e2e-inbound.sbn2') &&
        FileManager.doesFileExist('/_e2e/e2e-inbound (2).sbn2'))) {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (DateTime.now().difference(waitStart) > const Duration(seconds: 90)) {
        fail('inbox files did not arrive as notes');
      }
    }
    // ignore: avoid_print
    print('QUILL_E2E inbox notes present');
    // Their PDFs come back to the mini like any note's.
    final back = DateTime.now();
    while (true) {
      final pdfs = (await manifest())['pdfs'] as Map;
      if (pdfs.containsKey('/_e2e/e2e-inbound') &&
          pdfs.containsKey('/_e2e/e2e-inbound (2)')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (DateTime.now().difference(back) > const Duration(seconds: 30)) {
        fail('PDFs of the imported notes did not reach the mini');
      }
    }
    // ignore: avoid_print
    print('QUILL_E2E imported notes rendered back to the mini');
    editor.cancelAutosaveAndMarkSaved();
  });
}
