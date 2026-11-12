import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
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

  /// Durations of app work worth knowing about (a save's parts, a PDF
  /// render), recorded by the code that does it. Does nothing outside a run.
  static final _timers = <String, List<int>>{};
  static bool _running = false;
  static void time(String name, Stopwatch sw) {
    if (_running) (_timers[name] ??= []).add(sw.elapsedMilliseconds);
  }

  /// How late a 5 ms timer fires: the main isolate's stalls, whatever the cause.
  static Timer? _lagTimer;
  static final _lags = <int>[];
  static int _lastTick = 0;
  static void _startLagProbe() {
    _lastTick = _gapClock.elapsedMilliseconds;
    _lagTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = _gapClock.elapsedMilliseconds;
      _lags.add(now - _lastTick - 5);
      _lastTick = now;
    });
  }

  static void _lagSummary(String name, int from) {
    final lags = _lags.sublist(from);
    results['lag_$name'] = {
      'max_ms': lags.isEmpty ? 0 : lags.reduce(max),
      'over_30ms': lags.where((l) => l > 30).length,
      'over_100ms': lags.where((l) => l > 100).length,
    };
  }

  static final _frames = <FrameTiming>[];
  static final results = <String, Object?>{};

  static void _onTimings(List<FrameTiming> timings) => _frames.addAll(timings);

  /// Summarises the frames since [start], keyed by [name].
  static (int, int) _mark() => (_frames.length, _gaps.length);

  static Future<void> _summarise(String name, (int, int) from) async {
    final (start, gapStart) = from;
    // The engine reports frame timings in batches, a second or so late.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final gaps = _gaps.sublist(gapStart);
    final pacing = gaps.isEmpty
        ? null
        : {
            'frames': gaps.length,
            'gap_avg_ms': double.parse(
              (gaps.reduce((a, b) => a + b) / gaps.length).toStringAsFixed(2),
            ),
            'gap_max_ms': double.parse(gaps.reduce(max).toStringAsFixed(1)),
            'gaps_over_25ms': gaps.where((g) => g > 25).length,
            'gaps_over_50ms': gaps.where((g) => g > 50).length,
          };
    final frames = _frames.sublist(start);
    if (frames.isEmpty) {
      results[name] = {'frames': 0, 'pacing': pacing};
      return;
    }
    double ms(Duration d) => d.inMicroseconds / 1000;
    Map<String, Object> stats(List<double> v) {
      v.sort();
      double q(double p) => v[min(v.length - 1, (v.length * p).floor())];
      return {
        'avg': double.parse(
          (v.reduce((a, b) => a + b) / v.length).toStringAsFixed(2),
        ),
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

  /// Gaps between consecutive frames seen from Dart (ms). A gap well over
  /// 16.7 ms is a dropped frame, whatever thread caused it.
  static final _gaps = <double>[];
  static final _gapClock = Stopwatch()..start();
  static int _lastFrameUs = 0;

  static Future<void> _frame() async {
    // Frames stop while the screen is locked: say so rather than hang.
    await _frameRaw();
    final now = _gapClock.elapsedMicroseconds;
    if (_lastFrameUs != 0) _gaps.add((now - _lastFrameUs) / 1000);
    _lastFrameUs = now;
  }

  static Future<void> _frameRaw() async {
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
    await File(path)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
  }

  static const _notePath = '/quill-bench-heavy';

  static Future<void> run() async {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _running = true;
    _startLagProbe();
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
      final mark = _mark();
      await Future<void>.delayed(const Duration(seconds: 3));
      await _summarise('home_idle_3s', mark);

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
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _lagTimer?.cancel();
      results['timers_ms'] = _timers;
      _running = false;
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
    final mark = _mark();
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
    await _summarise('editor_open', mark);
  }

  static var _strokeCounter = 0;

  /// Synthetic pen: [strokes] strokes on page 0, four points per frame (an
  /// Apple Pencil reports at 240 Hz into a 60 Hz display), as the editor sees
  /// them through its own draw callbacks, with [pause] between strokes as in
  /// handwriting.
  static Future<void> _write(
    String name, {
    required int strokes,
    int points = 160,
    Duration pause = const Duration(milliseconds: 400),
  }) async {
    final editor = EditorState.benchInstance!;
    final page = editor.coreInfo.pages[0];
    final box = page.renderBox!;
    Offset global(double x, double y) => box.localToGlobal(Offset(x, y));

    final mark = _mark();
    final lagFrom = _lags.length;
    final frameCosts = <double>[];
    for (var n = 0; n < strokes; n++) {
      final s = _strokeCounter++;
      editor.dragPageIndex = 0;
      final y0 = 120.0 + (s % 18) * 70;
      final x0 = 80.0 + (s ~/ 18) * 20;
      Offset at(int i) => global(x0 + i * 4.5, y0 + sin(i / 8) * 30);
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
      final until = _gapClock.elapsed + pause;
      while (_gapClock.elapsed < until) {
        await _frame();
      }
    }
    await _summarise(name, mark);
    _lagSummary(name, lagFrom);
    frameCosts.sort();
    results['${name}_input_handler_ms_p90'] =
        frameCosts[(frameCosts.length * 0.9).floor()];
  }

  /// Handwriting: sentences and numbers as many short strokes (8 to 24
  /// points, one to a few letters' worth each), the pen lifted for 1 to 3
  /// frames between them and for longer between words, on page 1 of the
  /// open note. Records the time the editor's own stroke start and end
  /// handlers take (the work done each time the pen goes down and up), and
  /// how many of the strokes made it onto the page.
  static Future<void> _handwrite(String name, {int strokes = 260}) async {
    final editor = EditorState.benchInstance!;
    final page = editor.coreInfo.pages[1];
    final box = page.renderBox!;
    Offset global(double x, double y) => box.localToGlobal(Offset(x, y));
    final rng = Random(11);
    final before = page.strokes.length;
    final mark = _mark();
    final lagFrom = _lags.length;
    final starts = <double>[], ends = <double>[], moves = <double>[];
    var x = 60.0, y = 150.0;
    for (var n = 0; n < strokes; n++) {
      final pts = 8 + rng.nextInt(17);
      final x0 = x, y0 = y + rng.nextDouble() * 6;
      Offset at(int i) =>
          global(x0 + i * 1.6 + sin(i / 3) * 4, y0 + cos(i / 2.5) * 9);
      editor.dragPageIndex = 1;
      var t = Stopwatch()..start();
      editor.onDrawStart(
        ScaleStartDetails(focalPoint: at(0), localFocalPoint: at(0)),
      );
      starts.add(t.elapsedMicroseconds / 1000);
      // Two points per frame: letters are drawn fast.
      for (var i = 1; i < pts; i += 2) {
        await _frame();
        t = Stopwatch()..start();
        for (var k = 0; k < 2 && i + k < pts; k++) {
          editor.currentPressure = 0.4 + 0.3 * rng.nextDouble();
          editor.onDrawUpdate(
            ScaleUpdateDetails(
              focalPoint: at(i + k),
              localFocalPoint: at(i + k),
            ),
          );
        }
        moves.add(t.elapsedMicroseconds / 1000);
      }
      t = Stopwatch()..start();
      editor.onDrawEnd(ScaleEndDetails());
      ends.add(t.elapsedMicroseconds / 1000);
      x += 14 + rng.nextDouble() * 10;
      var lift = 1 + rng.nextInt(3);
      if (n % 6 == 5) {
        lift += 6; // between words
        x += 24;
      }
      if (x > 900) {
        x = 60;
        y += 70;
      }
      for (var f = 0; f < lift; f++) {
        await _frame();
      }
    }
    await _summarise(name, mark);
    _lagSummary(name, lagFrom);
    double q(List<double> v, double p) {
      v.sort();
      return v[min(v.length - 1, (v.length * p).floor())];
    }

    results['${name}_registered'] = {
      'attempted': strokes,
      'on_page': page.strokes.length - before,
    };
    results['${name}_handler_ms'] = {
      'pen_down_p50': q(starts, 0.5),
      'pen_down_max': starts.reduce(max),
      'pen_move_p90': q(moves, 0.9),
      'pen_up_p50': q(ends, 0.5),
      'pen_up_p90': q(ends, 0.9),
      'pen_up_max': ends.reduce(max),
    };
  }

  /// The same handwriting as [_handwrite], but as real stylus pointer events
  /// sent through Flutter's gesture arena, the path the Pencil takes. Counts
  /// the strokes that reach the page and how much of each stroke's start is
  /// lost: Flutter's scale recognizer starts a gesture only after the pointer
  /// has moved a slop distance.
  static Future<void> _handwriteReal(String name, {int strokes = 120}) async {
    final editor = EditorState.benchInstance!;
    // Page 0: pointer events only hit what is on screen.
    final page = editor.coreInfo.pages[0];
    final box = page.renderBox!;
    final binding = WidgetsBinding.instance;
    final rng = Random(5);
    final before = page.strokes.length;
    final mark = _mark();
    final lagFrom = _lags.length;
    const device = 7;
    binding.handlePointerEvent(
      const PointerAddedEvent(kind: PointerDeviceKind.stylus, device: device),
    );
    var x = 60.0, y = 1000.0;
    final lost = <double>[];
    var tiny = 0, tinyRegistered = 0;
    for (var n = 0; n < strokes; n++) {
      // A third of the strokes are small marks: dots, ticks, a digit's hook.
      final small = n % 3 == 0;
      final pts = small ? 3 + rng.nextInt(4) : 10 + rng.nextInt(15);
      final step = small ? 1.4 : 2.4;
      final x0 = x, y0 = y;
      Offset local(int i) => Offset(
        x0 + i * step + sin(i / 3) * (small ? 1 : 4),
        y0 + cos(i / 2.5) * (small ? 2 : 9),
      );
      Offset at(int i) => box.localToGlobal(local(i));
      final known = page.strokes.toSet();
      binding.handlePointerEvent(
        PointerDownEvent(
          pointer: n + 1,
          kind: PointerDeviceKind.stylus,
          device: device,
          position: at(0),
          pressure: 0.4,
          pressureMin: 0,
          pressureMax: 1,
        ),
      );
      for (var i = 1; i < pts; i += 2) {
        await _frame();
        for (var k = 0; k < 2 && i + k < pts; k++) {
          binding.handlePointerEvent(
            PointerMoveEvent(
              pointer: n + 1,
              kind: PointerDeviceKind.stylus,
              device: device,
              position: at(i + k),
              delta: at(i + k) - at(i + k - 1),
              pressure: 0.5,
              pressureMin: 0,
              pressureMax: 1,
            ),
          );
        }
      }
      binding.handlePointerEvent(
        PointerUpEvent(
          pointer: n + 1,
          kind: PointerDeviceKind.stylus,
          device: device,
          position: at(pts - 1),
        ),
      );
      await _frame();
      final added = page.strokes.where((st) => !known.contains(st)).toList();
      final registered = added.isNotEmpty;
      if (small) {
        tiny++;
        if (registered) tinyRegistered++;
      }
      if (registered) {
        // How far from where the pen went down the stroke begins.
        final first = box.localToGlobal(added.last.pointOffsets.first);
        lost.add((first - at(0)).distance);
      }
      x += 16 + rng.nextDouble() * 10;
      if (x > 900) {
        x = 60;
        y += 70;
      }
      for (var f = 0; f < 2 + rng.nextInt(3); f++) {
        await _frame();
      }
    }
    binding.handlePointerEvent(
      const PointerRemovedEvent(kind: PointerDeviceKind.stylus, device: device),
    );
    await _summarise(name, mark);
    _lagSummary(name, lagFrom);
    results['${name}_registered'] = {
      'attempted': strokes,
      'on_page': page.strokes.length - before,
      'small_marks_attempted': tiny,
      'small_marks_registered': tinyRegistered,
    };
    if (lost.isNotEmpty) {
      lost.sort();
      results['${name}_start_lost_px'] = {
        'p50': double.parse(lost[lost.length ~/ 2].toStringAsFixed(1)),
        'p90': double.parse(
          lost[(lost.length * 0.9).floor()].toStringAsFixed(1),
        ),
        'max': double.parse(lost.last.toStringAsFixed(1)),
      };
    }
  }

  /// Writing, then a pause long enough for the PDF render to start (it waits
  /// 2 s after the last save), then writing again while it runs.
  static Future<void> _drawStrokes() async {
    await _write('write_14_strokes', strokes: 14);
    final lagFrom = _lags.length;
    final mark = _mark();
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    await _summarise('pause_3s_pdf_starts', mark);
    _lagSummary('pause_3s_pdf_starts', lagFrom);
    await _write('write_8_strokes_during_pdf', strokes: 8);
    await Future<void>.delayed(const Duration(seconds: 8));
    // Sentences and numbers, on the next page, with saves and the PDF render
    // going on around them as they would be.
    await _handwrite('handwriting_260_strokes');
    await _handwriteReal('handwriting_real_pointer_120');
  }

  static Future<void> _scrollAndZoom() async {
    final editor = EditorState.benchInstance!;
    final controller = editor.benchTransform;
    final base = controller.value.clone();

    // Scroll: a swipe down the note over 90 frames, then back.
    var mark = _mark();
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i <= 90; i++) {
        final t = pass == 0 ? i / 90 : 1 - i / 90;
        controller.value = base.clone()..translateByDouble(0, -t * 9000, 0, 1);
        await _frame();
      }
    }
    await _summarise('scroll_9000px_x2', mark);
    controller.value = base;
    await _settle(10);

    // Zoom: 1x to 3x and back, twice.
    mark = _mark();
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i <= 60; i++) {
        final t = pass == 0 ? i / 60 : 1 - i / 60;
        final scale = 1 + 2 * t;
        controller.value = base.clone()..scaleByDouble(scale, scale, 1, 1);
        await _frame();
      }
    }
    await _summarise('zoom_1x_3x_x2', mark);
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
