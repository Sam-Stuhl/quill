/// When the pen was last in use (writing, or hovering over the page), so
/// background work (a note's PDF render for sync, its preview image) can wait
/// for a pause instead of stalling the app between strokes.
class PenActivity {
  const new _();

  static var _lastAt = DateTime(0);

  /// Call whenever the pen moves, goes down or comes up, or hovers.
  static void mark() => _lastAt = DateTime.now();

  static Duration get sinceLast => DateTime.now().difference(_lastAt);

  /// Completes once the pen has been idle for [quiet].
  static Future<void> untilQuiet([
    Duration quiet = const Duration(milliseconds: 1500),
  ]) async {
    while (sinceLast < quiet) {
      await Future<void>.delayed(
        quiet - sinceLast + const Duration(milliseconds: 50),
      );
    }
  }
}
