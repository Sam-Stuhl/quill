/// Decides which touches to ignore while the pen is in use, as Notability does.
///
/// While the pen is touching the screen, hovering over it, or was lifted less
/// than [holdMs] ago, finger and palm touches do nothing: no panning, zooming,
/// taps or drawing. A touch that was already down when the pen arrived (a palm
/// that landed first) is cancelled too.
///
/// [holdMs] is the sensitivity: 0 turns it off, a longer hold keeps a palm
/// ignored for longer after each stroke, at the cost of fingers taking a moment
/// to work again after writing.
class PalmRejection {
  new({required this.holdMs, Stopwatch? clock})
    : _clock = clock ?? (Stopwatch()..start());

  /// Read on every event, so changing the setting applies at once.
  final int Function() holdMs;
  final Stopwatch _clock;

  final Set<int> _stylusDown = {};
  int? _lastStylusMs;

  /// Touch pointers the pen has claimed, to ignore until they lift.
  final Set<int> rejected = {};

  bool get enabled => holdMs() > 0;

  /// The pen is touching, hovering, or only just lifted.
  bool get penActive {
    if (!enabled) return false;
    if (_stylusDown.isNotEmpty) return true;
    final last = _lastStylusMs;
    return last != null && _clock.elapsedMilliseconds - last < holdMs();
  }

  /// Any pen event, contact or hover.
  void stylusEvent(int pointer, {required bool down, required bool up}) {
    if (down) _stylusDown.add(pointer);
    if (up) _stylusDown.remove(pointer);
    _lastStylusMs = _clock.elapsedMilliseconds;
  }

  /// A new touch: true if it should be ignored.
  bool touchDown(int pointer) {
    if (!penActive) return false;
    rejected.add(pointer);
    return true;
  }

  bool isRejected(int pointer) => rejected.contains(pointer);

  /// A touch lifted or was cancelled.
  void touchEnded(int pointer) => rejected.remove(pointer);
}
