/// Decides which touches to ignore while the pen is in use, as Notability does.
///
/// While the pen is touching the screen, hovering over it, or was lifted less
/// than [holdMs] ago, finger and palm touches do nothing: no panning, zooming,
/// taps or drawing. A touch that was already down when the pen arrived (a palm
/// that landed first) is cancelled too, and what it already did (a pan, a
/// stroke) is undone by the caller. A touch with a large contact radius is a
/// palm and is ignored outright, and every touch waits [confirmMs] before it
/// may pan or zoom.
///
/// [holdMs] is the sensitivity: 0 turns it off, a longer hold keeps a palm
/// ignored for longer after each stroke, at the cost of fingers taking a moment
/// to work again after writing.
class PalmRejection {
  new({required this.holdMs, Stopwatch? clock})
    : _clock = clock ?? (Stopwatch()..start());

  /// Set when the setting changes, so no event has to read the preference.
  int holdMs;
  final Stopwatch _clock;

  final Set<int> _stylusDown = {};
  int? _lastStylusMs;

  /// Touch pointers the pen has claimed, to ignore until they lift.
  final Set<int> rejected = {};

  bool get enabled => holdMs > 0;

  /// The pen is touching, hovering, or only just lifted.
  bool get penActive {
    if (!enabled) return false;
    if (_stylusDown.isNotEmpty) return true;
    final last = _lastStylusMs;
    return last != null && _clock.elapsedMilliseconds - last < holdMs;
  }

  /// Hover and move events arrive 120 times a second or more: they only
  /// refresh the pen's last-seen time this often.
  static const refreshMs = 100;

  /// Any pen event, contact or hover.
  void stylusEvent(int pointer, {required bool down, required bool up}) {
    if (down) _stylusDown.add(pointer);
    if (up) _stylusDown.remove(pointer);
    final now = _clock.elapsedMilliseconds;
    final last = _lastStylusMs;
    if (!down && !up && last != null && now - last < refreshMs) return;
    _lastStylusMs = now;
  }

  /// A touch whose contact radius (logical pixels) is above this is a palm or
  /// a fist, not a fingertip (a fingertip reports roughly 8 to 14).
  static const palmRadius = 24.0;

  /// A touch is held back from panning and zooming for this long after it
  /// lands: a palm that rests just before the pen touches down is cancelled
  /// before it ever moves the page. A deliberate scroll is delayed by this much.
  static const confirmMs = 90;

  final Map<int, int> _touchDownMs = {};

  /// A new touch: true if it should be ignored. [radius] is the contact radius,
  /// when the device reports one.
  bool touchDown(int pointer, {double? radius}) {
    final now = _clock.elapsedMilliseconds;
    if (enabled && radius != null && radius > palmRadius) {
      rejected.add(pointer);
      return true;
    }
    if (!penActive) {
      _touchDownMs[pointer] = now;
      return false;
    }
    rejected.add(pointer);
    return true;
  }

  /// The touches on the screen have all been down long enough to be a
  /// deliberate gesture rather than a palm landing. Always true when the
  /// setting is off.
  bool get touchesConfirmed {
    if (!enabled) return true;
    final now = _clock.elapsedMilliseconds;
    for (final down in _touchDownMs.values) {
      if (now - down < confirmMs) return false;
    }
    return true;
  }

  bool isRejected(int pointer) => rejected.contains(pointer);

  /// A touch lifted or was cancelled.
  void touchEnded(int pointer) {
    rejected.remove(pointer);
    _touchDownMs.remove(pointer);
  }

  /// The pen arrived: forget the pending touches (they are all rejected).
  void clearPending() => _touchDownMs.clear();
}
