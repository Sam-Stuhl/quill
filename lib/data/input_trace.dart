import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:quill/data/file_manager/file_manager.dart';

/// A diagnostic log of raw pointer input and what the editor did with it, for
/// tuning palm rejection on a real iPad. Off unless the app is launched with
/// the environment variable `QUILL_INPUT_TRACE`, or a file named
/// `.quill-input-trace` is in the documents folder (copied there with
/// `devicectl device copy to`). Writes `input-trace.log` in the documents
/// folder, flushed every second.
abstract final class InputTrace {
  static bool? _enabled;
  static bool get enabled => _enabled ??=
      Platform.environment.containsKey('QUILL_INPUT_TRACE') ||
      File('${FileManager.documentsDirectory}/.quill-input-trace').existsSync();

  static final _clock = Stopwatch()..start();
  static final _buffer = StringBuffer();
  static Timer? _flushTimer;

  /// Tests send the trace here instead of to the file.
  static void Function(String line)? sink;

  static void log(String message) {
    final sink = InputTrace.sink;
    if (sink != null) return sink('${_clock.elapsedMilliseconds} $message');
    if (!enabled) return;
    _buffer.writeln('${_clock.elapsedMilliseconds} $message');
    _flushTimer ??= Timer(const Duration(seconds: 1), _flush);
  }

  static void pointer(String where, PointerEvent e) {
    if (!enabled && sink == null) return;
    final type = switch (e) {
      PointerDownEvent() => 'down',
      PointerMoveEvent() => 'move',
      PointerUpEvent() => 'up',
      PointerCancelEvent() => 'cancel',
      PointerHoverEvent() => 'hover',
      _ => e.runtimeType.toString(),
    };
    log(
      '$where $type p${e.pointer} ${e.kind.name} '
      'at ${e.position.dx.toStringAsFixed(0)},${e.position.dy.toStringAsFixed(0)} '
      'r${e.radiusMajor.toStringAsFixed(1)}/${e.radiusMinor.toStringAsFixed(1)} '
      'rmax${e.radiusMax.toStringAsFixed(1)} '
      'pr${e.pressure.toStringAsFixed(2)} '
      'ts${e.timeStamp.inMilliseconds}',
    );
  }

  static void _flush() {
    _flushTimer = null;
    final text = _buffer.toString();
    _buffer.clear();
    File('${FileManager.documentsDirectory}/input-trace.log')
        .writeAsStringSync(text, mode: FileMode.append, flush: true);
  }
}
