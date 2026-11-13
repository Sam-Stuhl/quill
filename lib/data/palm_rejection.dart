/// Decides which touches to ignore so a palm never draws or moves the page,
/// after tldraw's pen mode, Xournal++ and Notability, and measured on Sam's
/// iPad with the input trace (2026-11-13: a fingertip reports a contact radius
/// of 15.7, a palm 36.5, the Pencil 0.1).
///
/// - While the pen is touching the screen (or hovering, on iPads that report
///   it), every new touch is ignored.
/// - A touch with a contact radius over [palmRadius] is a palm: always ignored.
/// - A touch that was already down when the pen arrives is a palm that landed
///   first: the caller cancels it and undoes what it did.
///
/// Touches are never held back after the pen lifts, so a finger scrolls at
/// once after writing. Whether a touch may draw at all is the editor's finger
/// drawing setting, which turns off when a pen is seen.
class PalmRejection {
  new({required this.enabled, Stopwatch? clock})
    : _clock = clock ?? (Stopwatch()..start());

  /// Set when the setting changes, so no event has to read the preference.
  bool enabled;
  final Stopwatch _clock;

  final Set<int> _stylusDown = {};
  int? _lastHoverMs;

  /// Touch pointers that were ignored, until they lift.
  final Set<int> rejected = {};

  /// A fingertip on the iPad reports 15.7, a palm 36.5 (logical pixels).
  static const palmRadius = 24.0;

  /// Hover events stop when the pen leaves the hover range; treat it as gone
  /// this long after the last one.
  static const hoverMs = 150;

  /// The pen is touching the screen, or hovering just above it.
  bool get penActive {
    if (!enabled) return false;
    if (_stylusDown.isNotEmpty) return true;
    final hover = _lastHoverMs;
    return hover != null && _clock.elapsedMilliseconds - hover < hoverMs;
  }

  /// Any pen event, contact or hover.
  void stylusEvent(int pointer, {required bool down, required bool up}) {
    if (down) _stylusDown.add(pointer);
    if (up) {
      _stylusDown.remove(pointer);
      _lastHoverMs = null;
      return;
    }
    if (!_stylusDown.contains(pointer)) {
      _lastHoverMs = _clock.elapsedMilliseconds;
    }
  }

  /// A new touch: true if it should be ignored. [radius] is the contact
  /// radius, when the device reports one.
  bool touchDown(int pointer, {double? radius}) {
    if (!enabled) return false;
    if (penActive || (radius != null && radius > palmRadius)) {
      rejected.add(pointer);
      return true;
    }
    return false;
  }

  bool isRejected(int pointer) => rejected.contains(pointer);

  /// A touch lifted or was cancelled.
  void touchEnded(int pointer) => rejected.remove(pointer);
}
