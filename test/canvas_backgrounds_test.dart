import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/components/canvas/_canvas_background_painter.dart';
import 'package:sbn/canvas_background_pattern.dart';

void main() {
  group('Test canvas background patterns:', () {
    for (final pattern in CanvasBackgroundPattern.values) {
      _testPatternWithLineHeight(pattern, 10);
      _testPatternWithLineHeight(pattern, 50);

      _testRtlPattern(pattern);
    }
  });
}

void _testPatternWithLineHeight(
  CanvasBackgroundPattern pattern,
  int lineHeight,
) {
  test("'$pattern' with line height $lineHeight", () {
    const size = Size(1000, 1000);

    final elements = CanvasBackgroundPainter.getPatternElements(
      pattern: pattern,
      size: size,
      lineHeight: lineHeight,
    ).toList();

    if (pattern == .none) {
      expect(
        elements,
        isEmpty,
        reason: 'No elements should be returned for the none pattern',
      );
      return;
    } else {
      expect(
        elements,
        isNotEmpty,
        reason: 'Elements should be returned for patterns other than the none pattern',
      );
    }

    // Check that the elements are within the bounds of the canvas
    for (final element in elements) {
      expect(
        element.start.dx,
        inInclusiveRange(0, size.width),
        reason: 'element.start not within canvas bounds',
      );
      expect(
        element.start.dy,
        inInclusiveRange(0, size.height),
        reason: 'element.start not within canvas bounds',
      );
      expect(
        element.end.dx,
        inInclusiveRange(0, size.width),
        reason: 'element.end not within canvas bounds',
      );
      expect(
        element.end.dy,
        inInclusiveRange(0, size.height),
        reason: 'element.end not within canvas bounds',
      );
    }

    // The reMarkable patterns are full-bleed and ignore the line height:
    // see the reMarkable test below.
    if (pattern == .remarkableLined || pattern == .remarkableGraph) return;

    // Check we have 2 lineHeights of space at the top
    for (final element in elements) {
      if (element.secondaryColor) return; // ignore secondary elements
      expect(
        element.start.dy,
        greaterThanOrEqualTo(lineHeight * 2),
        reason:
            'Elements should leave 2 lineHeights of space at the top, but element.start.dy was ${element.start.dy}',
      );
      expect(
        element.end.dy,
        greaterThanOrEqualTo(lineHeight * 2),
        reason:
            'Elements should leave 2 lineHeights of space at the top, but element.end.dy was ${element.end.dy}',
      );
    }

    // Check all elements are lines or all elements are dots
    final allLines = elements.every((element) => element.isLine);
    final allDots = elements.every((element) => !element.isLine);
    expect(
      allLines || allDots,
      true,
      reason: 'All elements should be lines or all elements should be dots',
    );

    if (allLines) {
      // Check spacing
      double lastPosition = -1;
      bool? lastWasHorizontal;
      for (final element in elements) {
        final isHorizontal = element.start.dy == element.end.dy;
        final isVertical = element.start.dx == element.end.dx;
        expect(
          isHorizontal || isVertical,
          true,
          reason: 'Lines should be horizontal or vertical',
        );

        final position = isHorizontal ? element.start.dy : element.start.dx;

        // ignore spacing between a horizontal and a vertical line
        if (lastWasHorizontal != isHorizontal) {
          lastPosition = position;
          lastWasHorizontal = isHorizontal;
          continue;
        }

        if (pattern != .cornell) {
          // Cornell has two lines on the same row, so they shouldn't be spaced apart

          expect(
            position != lastPosition,
            true,
            reason: 'Lines should be spaced apart',
          );
        }

        final spacing = (position - lastPosition).abs();
        double diffFromALine = spacing % lineHeight;
        if (diffFromALine > lineHeight / 2) {
          diffFromALine = lineHeight - diffFromALine;
        }
        printOnFailure(
          'spacing: $spacing, lineHeight: $lineHeight, diffFromALine: $diffFromALine',
        );
        expect(
          diffFromALine,
          lessThan(lineHeight / 1000),
          reason: 'Lines should be spaced in intervals of lineHeight',
        );

        lastPosition = position;
      }
    }
  });
}

void _testRtlPattern(CanvasBackgroundPattern pattern) {
  test("'$pattern'", () {
    const size = Size(1000, 1000);

    final List<PatternElement> elements =
        CanvasBackgroundPainter.getPatternElements(
          pattern: pattern,
          size: size,
          lineHeight: 10,
        ).toList();

    var linesOnLeft = 0;
    var linesOnRight = 0;
    for (final element in elements) {
      if (!element.isLine) continue;

      // ignore horizontal lines
      if (element.start.dy == element.end.dy) continue;

      if (element.start.dx < size.width / 2) {
        linesOnLeft++;
      } else if (element.start.dx > size.width / 2) {
        linesOnRight++;
      }
    }

    final rtl = pattern.name.contains('rtl');
    final isCorrectlyRtl = rtl
        ? linesOnRight >= linesOnLeft * 0.9
        : linesOnLeft >= linesOnRight * 0.9;
    printOnFailure('linesOnLeft: $linesOnLeft, linesOnRight: $linesOnRight');
    expect(
      isCorrectlyRtl,
      true,
      reason: 'Lines should be on the left in ltr and on the right in rtl',
    );
  });

  test(
    'reMarkable patterns are 27 squares across, whatever the line height',
    () {
      const size = Size(1000, 1400);
      for (final lineHeight in [10, 40, 50]) {
        final lined = CanvasBackgroundPainter.getPatternElements(
          pattern: .remarkableLined,
          size: size,
          lineHeight: lineHeight,
        ).toList();
        final graph = CanvasBackgroundPainter.getPatternElements(
          pattern: .remarkableGraph,
          size: size,
          lineHeight: lineHeight,
        ).toList();

        final spacing = size.width / 27;
        final rows = lined.where((e) => e.start.dy == e.end.dy).toList();
        expect(rows.length, (size.height / spacing).ceil());
        expect(rows[1].start.dy - rows[0].start.dy, closeTo(spacing, 1e-9));
        expect(lined.every((e) => e.start.dy == e.end.dy), true);

        final columns = graph.where((e) => e.start.dx == e.end.dx).toList();
        expect(columns, hasLength(27));
        expect(graph.length, rows.length + 27);
      }
    },
  );
}
