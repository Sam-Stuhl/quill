import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/scribble_erase.dart';

/// Points along the polyline through [corners], one every ~[step] px.
List<Offset> polyline(List<Offset> corners, {double step = 2}) {
  final points = <Offset>[corners.first];
  for (var i = 1; i < corners.length; i++) {
    final a = corners[i - 1], b = corners[i];
    final n = max(1, ((b - a).distance / step).ceil());
    for (var k = 1; k <= n; k++) {
      points.add(Offset.lerp(a, b, k / n)!);
    }
  }
  return points;
}

/// A back-and-forth scratch: [passes] passes of [amplitude] px, moving on by
/// [advance] px each time.
List<Offset> zigzag({
  int passes = 8,
  double amplitude = 30,
  double advance = 5,
  bool vertical = true,
}) {
  final corners = <Offset>[];
  for (var i = 0; i <= passes; i++) {
    final along = i.isEven ? 0.0 : amplitude;
    final across = i * advance;
    corners.add(vertical ? Offset(across, along) : Offset(along, across));
  }
  return polyline(corners);
}

void main() {
  group('scribble detector: scratches', () {
    test('a tight vertical zigzag is a scribble', () {
      expect(ScribbleDetector.isScribble(zigzag()), isTrue);
    });

    test('a short scratch of six passes is a scribble', () {
      expect(ScribbleDetector.isScribble(zigzag(passes: 6)), isTrue);
    });

    test('a horizontal and a diagonal scratch are scribbles', () {
      expect(ScribbleDetector.isScribble(zigzag(vertical: false)), isTrue);
      final rotated = [
        for (final p in zigzag())
          Offset((p.dx - p.dy) * 0.7071, (p.dx + p.dy) * 0.7071),
      ];
      expect(ScribbleDetector.isScribble(rotated), isTrue);
    });

    test('a scratch with a bit of hand jitter is still a scribble', () {
      final random = Random(1);
      final noisy = [
        for (final p in zigzag(passes: 10, amplitude: 40, advance: 4))
          p + Offset(random.nextDouble() * 1.5, random.nextDouble() * 1.5),
      ];
      expect(ScribbleDetector.isScribble(noisy), isTrue);
    });

    test('a rounded scratch (sine wave stacked tightly) is a scribble', () {
      final points = [
        for (var t = 0.0; t < 8 * pi; t += 0.1) Offset(t * 1.5, 15 * sin(t)),
      ];
      expect(ScribbleDetector.isScribble(points), isTrue);
    });
  });

  group('scribble detector: handwriting', () {
    // Letters 30 px tall, drawn as one stroke.
    test('"m" is not a scribble', () {
      final m = polyline([
        Offset.zero,
        const Offset(0, 30),
        const Offset(0, 5),
        const Offset(8, -2),
        const Offset(16, 5),
        const Offset(16, 30),
        const Offset(16, 5),
        const Offset(24, -2),
        const Offset(32, 5),
        const Offset(32, 30),
      ]);
      expect(ScribbleDetector.isScribble(m), isFalse);
    });

    test('"w" is not a scribble', () {
      final w = polyline([
        Offset.zero,
        const Offset(10, 30),
        const Offset(20, 5),
        const Offset(30, 30),
        const Offset(40, 0),
      ]);
      expect(ScribbleDetector.isScribble(w), isFalse);
    });

    test('"z" is not a scribble', () {
      final z = polyline([
        Offset.zero,
        const Offset(30, 0),
        const Offset(0, 30),
        const Offset(30, 30),
      ]);
      expect(ScribbleDetector.isScribble(z), isFalse);
    });

    test('a long underline, a circle and a short line are not scribbles', () {
      expect(
        ScribbleDetector.isScribble(
          polyline([Offset.zero, const Offset(400, 3)]),
        ),
        isFalse,
      );
      final circle = [
        for (var t = 0.0; t < 2 * pi; t += 0.05)
          Offset(20 * cos(t), 20 * sin(t)),
      ];
      expect(ScribbleDetector.isScribble(circle), isFalse);
      expect(
        ScribbleDetector.isScribble(
          polyline([Offset.zero, const Offset(10, 10)]),
        ),
        isFalse,
      );
    });

    test('a cursive row of loops moving along the line is not a scribble', () {
      final loops = [
        for (var t = 0.0; t < 6 * pi; t += 0.1)
          Offset(t * 8 + 10 * cos(t), 10 * sin(t)),
      ];
      expect(ScribbleDetector.isScribble(loops), isFalse);
    });

    test('too few points is never a scribble', () {
      expect(ScribbleDetector.isScribble(const []), isFalse);
      expect(ScribbleDetector.isScribble(const [Offset.zero]), isFalse);
    });
  });

  test('reversals are counted', () {
    expect(ScribbleDetector.countReversals(zigzag(passes: 8)), 7);
    expect(
      ScribbleDetector.countReversals(
        polyline([Offset.zero, const Offset(100, 0)]),
      ),
      0,
    );
  });
}
