import 'dart:async';
import 'dart:ui';

/// What a touch gesture can be mapped to.
enum TouchAction {
  none('None'),
  undo('Undo'),
  redo('Redo'),
  eraser('Eraser (toggle)'),
  pen('Pen'),
  highlighter('Highlighter'),
  select('Lasso select'),
  toggleFingerDrawing('Toggle finger drawing'),
  nextPage('Next page'),
  previousPage('Previous page');

  new(this.label);
  final String label;
}

/// A tap gesture: [fingers] fingers touching at once, [taps] times in a row.
///
/// One finger tapping once is not a gesture (that is drawing a dot).
class TouchGesture {
  const new(this.fingers, this.taps);

  static const maxFingers = 4;
  static const maxTaps = 3;

  final int fingers;
  final int taps;

  /// Every gesture that can be mapped, fewest fingers and taps first.
  static final List<TouchGesture> values = [
    for (var fingers = 1; fingers <= maxFingers; fingers++)
      for (var taps = 1; taps <= maxTaps; taps++)
        if (fingers > 1 || taps > 1) TouchGesture(fingers, taps),
  ];

  /// Used as the pref key.
  String get id => 'f${fingers}t$taps';

  String get label {
    final f = fingers == 1 ? '1 finger' : '$fingers fingers';
    final t = switch (taps) {
      1 => 'tap',
      2 => 'double tap',
      _ => 'triple tap',
    };
    return '$f, $t';
  }

  TouchAction get defaultAction => switch ((fingers, taps)) {
    (2, 1) => TouchAction.undo,
    (3, 1) => TouchAction.redo,
    (1, 2) => TouchAction.eraser,
    _ => TouchAction.none,
  };

  @override
  bool operator ==(Object other) =>
      other is TouchGesture && other.fingers == fingers && other.taps == taps;

  @override
  int get hashCode => Object.hash(fingers, taps);

  @override
  String toString() => 'TouchGesture($id)';
}

/// Decides whether a series of touch pointer events was a tap
/// (as opposed to a pan, a pinch or a stroke) and with how many fingers.
///
/// Feed it every touch pointer event of the canvas. A "contact" starts when the
/// first finger lands and ends when the last one lifts. It is a tap if
/// no finger moved more than [maxMovement], it lasted at most [maxDuration],
/// and two or more fingers were down at once. Single-finger taps are
/// reported as a tap here, even with one finger: it is up to the caller to
/// decide whether one finger is drawing instead.
class TouchTapClassifier {
  new({
    this.maxMovement = 10,
    this.maxDuration = const Duration(milliseconds: 250),
  });

  final double maxMovement;
  final Duration maxDuration;

  final Map<int, Offset> _downPositions = {};
  Duration? _contactStart;
  int _maxPointers = 0;
  bool _invalid = false;

  /// Number of fingers currently down.
  int get pointerCount => _downPositions.length;

  void pointerDown(int pointer, Offset position, Duration timestamp) {
    if (_downPositions.isEmpty) {
      _contactStart = timestamp;
      _maxPointers = 0;
      _invalid = false;
    }
    _downPositions[pointer] = position;
    if (_downPositions.length > _maxPointers) {
      _maxPointers = _downPositions.length;
    }
    _checkDuration(timestamp);
  }

  void pointerMove(int pointer, Offset position, Duration timestamp) {
    final start = _downPositions[pointer];
    if (start == null) return;
    if ((position - start).distance > maxMovement) _invalid = true;
    _checkDuration(timestamp);
  }

  /// Returns the finger count if this was the end of a tap, otherwise null.
  int? pointerUp(int pointer, Duration timestamp) {
    if (!_downPositions.containsKey(pointer)) return null;
    _checkDuration(timestamp);
    _downPositions.remove(pointer);
    if (_downPositions.isNotEmpty) return null;

    final isTap = !_invalid && _maxPointers >= 1;
    final fingers = _maxPointers;
    _maxPointers = 0;
    return isTap ? fingers : null;
  }

  /// The system took the pointer away (e.g. palm rejection or a system gesture).
  void pointerCancel(int pointer) {
    if (!_downPositions.containsKey(pointer)) return;
    _invalid = true;
    _downPositions.remove(pointer);
    if (_downPositions.isEmpty) _maxPointers = 0;
  }

  void _checkDuration(Duration timestamp) {
    final start = _contactStart;
    if (start != null && timestamp - start > maxDuration) _invalid = true;
  }
}

/// Turns taps into [TouchAction]s using the user's mapping.
///
/// Consecutive taps with the same number of fingers, each within
/// [multiTapWindow] of the last, count as a double or triple tap. A tap only
/// waits for the window if a longer gesture with that many fingers is mapped,
/// so with nothing mapped to double taps, a tap fires at once.
class TouchGestureResolver {
  new({
    required this.actionFor,
    required this.onAction,
    this.multiTapWindow = const Duration(milliseconds: 300),
  });

  final TouchAction Function(TouchGesture gesture) actionFor;
  final void Function(TouchAction action) onAction;
  final Duration multiTapWindow;

  Timer? _timer;
  int _pendingFingers = 0;
  int _pendingTaps = 0;

  bool _isMapped(int fingers, int taps) =>
      taps <= TouchGesture.maxTaps &&
      (fingers > 1 || taps > 1) &&
      actionFor(TouchGesture(fingers, taps)) != TouchAction.none;

  bool _isLongerMapped(int fingers, int taps) {
    for (var t = taps + 1; t <= TouchGesture.maxTaps; t++) {
      if (_isMapped(fingers, t)) return true;
    }
    return false;
  }

  /// Call with the finger count of each tap from [TouchTapClassifier].
  void onTap(int fingers) {
    if (fingers < 1 || fingers > TouchGesture.maxFingers) {
      flush();
      return;
    }
    _timer?.cancel();
    _timer = null;

    if (_pendingTaps > 0 && _pendingFingers != fingers) flush();

    final taps = _pendingFingers == fingers ? _pendingTaps + 1 : 1;
    if (taps >= TouchGesture.maxTaps || !_isLongerMapped(fingers, taps)) {
      _pendingTaps = 0;
      _pendingFingers = 0;
      _fire(fingers, taps);
    } else {
      _pendingFingers = fingers;
      _pendingTaps = taps;
      _timer = Timer(multiTapWindow, flush);
    }
  }

  /// Fires the waiting tap(s), if any, as they are.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final fingers = _pendingFingers, taps = _pendingTaps;
    _pendingFingers = 0;
    _pendingTaps = 0;
    if (taps > 0) _fire(fingers, taps);
  }

  void _fire(int fingers, int taps) {
    if (!_isMapped(fingers, taps)) return;
    onAction(actionFor(TouchGesture(fingers, taps)));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pendingTaps = 0;
    _pendingFingers = 0;
  }
}
