import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/routes.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/main.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

/// An on-device benchmark, run only when the app is launched with the
/// environment variable `QUILL_BENCH` set (`devicectl ... process launch
/// --environment-variables '{"QUILL_BENCH":"1"}'`). It builds a large note,
/// opens it, draws into it with synthetic pen input, scrolls and zooms it, and
/// writes frame timings to `quill-bench.json` in the app's documents folder.
///
/// It drives the same code real input does (`EditorState.onDrawStart`,
/// `onDrawUpdate`, `onDrawEnd`, the transformation controller), so the numbers
/// are the app's own: build and raster time per frame, as Flutter measures them.
class PerfBench {
  /// Env var `QUILL_BENCH`, or a file named `.quill-bench` in the documents
  /// folder (copied there with `devicectl device copy to`). The file is
  /// removed when the run starts so it does not repeat.
  static bool get enabled {
    if (Platform.environment.containsKey('QUILL_BENCH')) return true;
    final marker = File('${FileManager.documentsDirectory}/.quill-bench');
    if (!marker.existsSync()) return false;
    marker.deleteSync();
    return true;
  }

  static final _sinceMain = Stopwatch();
  static void markMain() => _sinceMain.start();

  static final _frames = <FrameTiming>[];
  static final results = <String, Object?>{};

  static void _onTimings(List<FrameTiming> timings) => _frames.addAll(timings);

  /// Summarises the frames since [start], keyed by [name].
  static void _summarise(String name, int start) {
    final frames = _frames.sublist(start);
    if (frames.isEmpty) {
      results[name] = {'frames': 0};
      return;
    }
    double ms(Duration d) => d.inMicroseconds / 1000;
    Map<String, Object> stats(List<double> v) {
      v.sort();
      double q(double p) => v[min(v.length - 1, (v.length * p).floor())];
      return {
        'avg': double.parse((v.reduce((a, b) => a + b) / v.length).toStringAsFixed(2)),
        'p50': q(0.5),
        'p90': q(0.9),
        'p99': q(0.99),
        'max': v.last,
      };
    }

    final total = [for (final f in frames) ms(f.totalSpan)];
    results[name] = {
      'frames': frames.length,
      'build_ms': stats([for (final f in frames) ms(f.buildDuration)]),
      'raster_ms': stats([for (final f in frames) ms(f.rasterDuration)]),
      'total_ms': stats(List.of(total)),
      'over_16_7ms': total.where((t) => t > 16.7).length,
      'over_33ms': total.where((t) => t > 33.4).length,
    };
  }

  static Future<void> _frame() async {
    // Frames stop while the screen is locked: say so rather than hang.
    await SchedulerBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        results['stalled_at'] = _stage;
        throw TimeoutException('no frame for 20 s (screen locked?)');
      },
    );
  }

  static String _stage = 'start';
  static Future<void> _stageDone(String name) async {
    _stage = name;
    results['last_stage'] = name;
    await _flush();
  }

  static Future<void> _settle([int frames = 20]) async {
    for (var i = 0; i < frames; i++) {
      await _frame();
    }
  }

  static Future<void> _flush() async {
    final path = '${FileManager.documentsDirectory}/quill-bench.json';
    results['path'] = path;
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(results),
    );
  }

  static const _notePath = '/quill-bench-heavy';

  static Future<void> run() async {
    PlatformDispatcher.instance.onReportTimings = _onTimings;
    try {
      await _stageDone('begin');
      await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
      results['startup_main_to_first_frame_ms'] =
          _sinceMain.elapsedMilliseconds;
      await _settle(60);
      results['device'] = Platform.operatingSystemVersion;
      results['refresh_hz'] =
          PlatformDispatcher.instance.views.first.display.refreshRate;

      // Home screen idle: how much the app does by itself.
      final mark = _frames.length;
      await Future<void>.delayed(const Duration(seconds: 3));
      _summarise('home_idle_3s', mark);

      await _makeHeavyNote();
      await _stageDone('note');
      await _openEditor();
      await _stageDone('open');
      await _drawStrokes();
      await _stageDone('draw');
      await _scrollAndZoom();
      await _stageDone('scroll');
      await _closeEditor();
      await FileManager.deleteFile('$_notePath${Editor.extension}');
      results['done'] = true;
    } catch (e, st) {
      results['error'] = '$e\n$st';
    } finally {
      PlatformDispatcher.instance.onReportTimings = null;
      await _flush();
    }
  }

  /// A note like a long lecture: [pages] pages, [strokesPerPage] strokes of
  /// about 120 points each, a mix of fountain pen, pencil and highlighter.
  static Future<void> _makeHeavyNote({
    int pages = 12,
    int strokesPerPage = 150,
  }) async {
    final rng = Random(7);
    // ignore: invalid_use_of_visible_for_testing_member
    final info = EditorCoreInfo(filePath: _notePath);
    for (var p = 0; p < pages; p++) {
      final page = EditorPage(size: EditorPage.defaultSize);
      info.pages.add(page);
      for (var s = 0; s < strokesPerPage; s++) {
        final kind = s % 10 == 0
            ? ToolId.highlighter
            : s % 3 == 0
            ? ToolId.pencil
            : ToolId.fountainPen;
        final tool = switch (kind) {
          ToolId.highlighter => Highlighter.currentHighlighter,
          ToolId.pencil => Pencil.currentPencil,
          _ => Pen.currentPen,
        };
        final stroke = Stroke(
          color: tool.color,
          pressureEnabled: tool.pressureEnabled,
          options: tool.options.copyWith(isComplete: true),
          pageIndex: p,
          page: page,
          toolId: kind,
        );
        final x0 = 60 + rng.nextDouble() * 700;
        final y0 = 60 + rng.nextDouble() * 1250;
        final amp = 10 + rng.nextDouble() * 40;
        for (var i = 0; i < 120; i++) {
          stroke.addPoint(
            Offset(x0 + i * 2.2, y0 + sin(i / 9) * amp),
            0.3 + 0.5 * (sin(i / 14) + 1) / 2,
          );
        }
        page.insertStroke(stroke);
      }
    }
    final save = Stopwatch()..start();
    final (bson, _) = info.saveToBinary(currentPageIndex: 0);
    results['note_serialize_ms'] = save.elapsedMilliseconds;
    results['note_bytes'] = bson.length;
    results['note_pages'] = pages;
    results['note_strokes'] = pages * strokesPerPage;
    await FileManager.writeFile(
      '$_notePath${Editor.extension}',
      bson,
      awaitWrite: true,
    );
    info.dispose();

    final load = Stopwatch()..start();
    final loaded = await EditorCoreInfo.loadFromFilePath(_notePath);
    results['note_load_ms'] = load.elapsedMilliseconds;
    loaded.dispose();
  }

  static Future<void> _openEditor() async {
    final mark = _frames.length;
    final open = Stopwatch()..start();
    EditorState.benchInstance = null;
    App.router.push(RoutePaths.editFilePath(_notePath));
    while (EditorState.benchInstance == null ||
        EditorState.benchInstance!.coreInfo.pages.length < 2) {
      await _frame();
    }
    // First frame that painted the loaded note.
    await _frame();
    await _frame();
    results['editor_open_to_painted_ms'] = open.elapsedMilliseconds;
    await _settle(30);
    _summarise('editor_open', mark);
  }

  /// Synthetic pen: [strokes] strokes on page 0, four points per frame (an
  /// Apple Pencil reports at 240 Hz into a 60 Hz display), as the editor sees
  /// them through its own draw callbacks.
  static Future<void> _drawStrokes({int strokes = 14, int points = 160}) async {
    final editor = EditorState.benchInstance!;
    final page = editor.coreInfo.pages[0];
    final box = page.renderBox!;
    Offset global(double x, double y) => box.localToGlobal(Offset(x, y));

    var mark = _frames.length;
    final frameCosts = <double>[];
    for (var s = 0; s < strokes; s++) {
      editor.dragPageIndex = 0;
      final y0 = 120.0 + s * 70;
      Offset at(int i) => global(80 + i * 4.5, y0 + sin(i / 8) * 30);
      editor.onDrawStart(
        ScaleStartDetails(focalPoint: at(0), localFocalPoint: at(0)),
      );
      await _frame();
      for (var i = 1; i < points; i += 4) {
        final t = Stopwatch()..start();
        for (var k = 0; k < 4 && i + k < points; k++) {
          editor.currentPressure = 0.5;
          editor.onDrawUpdate(
            ScaleUpdateDetails(
              focalPoint: at(i + k),
              localFocalPoint: at(i + k),
            ),
          );
        }
        t.stop();
        frameCosts.add(t.elapsedMicroseconds / 1000);
        await _frame();
      }
      editor.onDrawEnd(ScaleEndDetails());
      await _frame();
    }
    _summarise('draw_14_strokes', mark);
    frameCosts.sort();
    results['draw_input_handler_ms_p90'] =
        frameCosts[(frameCosts.length * 0.9).floor()];

    // The saves and syncing that follow the last stroke.
    mark = _frames.length;
    await Future<void>.delayed(const Duration(seconds: 6));
    _summarise('after_draw_6s_autosave', mark);
  }

  static Future<void> _scrollAndZoom() async {
    final editor = EditorState.benchInstance!;
    final controller = editor.benchTransform;
    final base = controller.value.clone();

    // Scroll: a swipe down the note over 90 frames, then back.
    var mark = _frames.length;
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i <= 90; i++) {
        final t = pass == 0 ? i / 90 : 1 - i / 90;
        controller.value = base.clone()..translateByDouble(0, -t * 9000, 0, 1);
        await _frame();
      }
    }
    _summarise('scroll_9000px_x2', mark);
    controller.value = base;
    await _settle(10);

    // Zoom: 1x to 3x and back, twice.
    mark = _frames.length;
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i <= 60; i++) {
        final t = pass == 0 ? i / 60 : 1 - i / 60;
        final scale = 1 + 2 * t;
        controller.value = base.clone()..scaleByDouble(scale, scale, 1, 1);
        await _frame();
      }
    }
    _summarise('zoom_1x_3x_x2', mark);
    controller.value = base;
    await _settle(10);
  }

  static Future<void> _closeEditor() async {
    final close = Stopwatch()..start();
    App.router.pop();
    await _settle(10);
    results['editor_close_ms'] = close.elapsedMilliseconds;
  }
}
