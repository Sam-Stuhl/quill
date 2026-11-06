import 'dart:math';
import 'dart:ui';

/// Recognises a "scratch out" stroke: several sharp direction reversals over a
/// small area, as when scribbling over ink to erase it.
///
/// Works on the shape of the stroke alone (the points carry no timestamps),
/// so "short" means a small area and a path that doubles back on itself many
/// times, not a duration.
abstract final class ScribbleDetector {
  /// How far the pen must travel back against its heading to count as a
  /// reversal. This ignores jitter and the gentle retrace in a letter's curve.
  static const minReversalDistance = 8.0;

  /// Handwriting reverses at most four times in one stroke ("m", "w"):
  /// a scratch needs more (five turns, six quick passes).
  static const minReversals = 5;

  /// Path length divided by the size of the stroke. A scratch
  /// covers the same ground again and again, handwriting moves along.
  static const minPathRatio = 4.0;

  /// A scratch stays small, in page units.
  static const maxSize = 300.0;

  static bool isScribble(List<Offset> points) {
    if (points.length < 2 * minReversals) return false;

    var pathLength = 0.0;
    var sum = points.first;
    for (var i = 1; i < points.length; i++) {
      pathLength += (points[i] - points[i - 1]).distance;
      sum += points[i];
    }
    // Twice the farthest distance from the centre: the stroke's size,
    // however it is rotated.
    final centre = sum / points.length.toDouble();
    final size = 2 * points.map((p) => (p - centre).distance).reduce(max);
    if (size > maxSize) return false;
    if (pathLength < size * minPathRatio) return false;

    return countReversals(points) >= minReversals;
  }

  /// Counts how many times the stroke turns back by at least
  /// [minReversalDistance] against the direction it was heading.
  static int countReversals(List<Offset> points) {
    var reversals = 0;
    var extreme = points.first;
    Offset? heading;

    for (final p in points.skip(1)) {
      final delta = p - extreme;
      if (heading == null) {
        if (delta.distance >= minReversalDistance) {
          heading = delta / delta.distance;
          extreme = p;
        }
        continue;
      }
      final along = delta.dx * heading.dx + delta.dy * heading.dy;
      if (along > 0) {
        extreme = p;
      } else if (-along >= minReversalDistance) {
        reversals++;
        heading = delta / delta.distance;
        extreme = p;
      }
    }
    return reversals;
  }
}
