import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/touch_gestures.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('TouchTapClassifier', () {
    late TouchTapClassifier c;
    setUp(() => c = TouchTapClassifier());

    test('two-finger tap', () {
      c.pointerDown(1, const Offset(100, 100), ms(0));
      c.pointerDown(2, const Offset(200, 100), ms(10));
      expect(c.pointerUp(1, ms(80)), isNull); // one finger still down
      expect(c.pointerUp(2, ms(90)), 2);
    });

    test('three and four-finger taps report their count', () {
      for (final n in [3, 4]) {
        for (var i = 0; i < n; i++) {
          c.pointerDown(i, Offset(i * 50.0, 0), ms(i));
        }
        int? result;
        for (var i = 0; i < n; i++) {
          result = c.pointerUp(i, ms(100 + i));
        }
        expect(result, n);
      }
    });

    test('one finger, briefly, is reported as a one-finger tap', () {
      c.pointerDown(1, Offset.zero, ms(0));
      expect(c.pointerUp(1, ms(50)), 1);
    });

    test('one finger drawing a stroke is not a tap', () {
      c.pointerDown(1, Offset.zero, ms(0));
      c.pointerMove(1, const Offset(40, 0), ms(40));
      expect(c.pointerUp(1, ms(80)), isNull);
    });

    test('small jitter is still a tap', () {
      c.pointerDown(1, Offset.zero, ms(0));
      c.pointerDown(2, const Offset(100, 0), ms(0));
      c.pointerMove(1, const Offset(4, 4), ms(30));
      c.pointerMove(2, const Offset(103, 5), ms(30));
      c.pointerUp(1, ms(60));
      expect(c.pointerUp(2, ms(60)), 2);
    });

    test('moving more than 10 px is a pan, not a tap', () {
      c.pointerDown(1, Offset.zero, ms(0));
      c.pointerDown(2, const Offset(100, 0), ms(0));
      c.pointerMove(1, const Offset(0, 11), ms(30));
      c.pointerUp(1, ms(60));
      expect(c.pointerUp(2, ms(60)), isNull);
    });

    test('moving out and back is still not a tap', () {
      c.pointerDown(1, Offset.zero, ms(0));
      c.pointerDown(2, const Offset(100, 0), ms(0));
      c.pointerMove(1, const Offset(0, 50), ms(30));
      c.pointerMove(1, Offset.zero, ms(60));
      c.pointerUp(1, ms(70));
      expect(c.pointerUp(2, ms(70)), isNull);
    });

    test('a long press is not a tap', () {
      c.pointerDown(1, Offset.zero, ms(0));
      c.pointerDown(2, const Offset(100, 0), ms(0));
      c.pointerUp(1, ms(300));
      expect(c.pointerUp(2, ms(310)), isNull);
    });

    test('a cancelled pointer spoils the tap', () {
      c.pointerDown(1, Offset.zero, ms(0));
      c.pointerDown(2, const Offset(100, 0), ms(0));
      c.pointerCancel(1);
      expect(c.pointerUp(2, ms(50)), isNull);
    });

    test('state resets between contacts', () {
      c.pointerDown(1, Offset.zero, ms(0));
      c.pointerDown(2, const Offset(100, 0), ms(0));
      c.pointerMove(1, const Offset(0, 80), ms(20));
      c.pointerUp(1, ms(40));
      c.pointerUp(2, ms(40));

      c.pointerDown(3, Offset.zero, ms(1000));
      c.pointerDown(4, const Offset(100, 0), ms(1010));
      c.pointerUp(3, ms(1060));
      expect(c.pointerUp(4, ms(1070)), 2);
    });

    test(
      'a finger added after a stroke started and lifted late is not a tap',
      () {
        c.pointerDown(1, Offset.zero, ms(0));
        c.pointerDown(2, const Offset(100, 0), ms(240));
        c.pointerUp(1, ms(260));
        expect(c.pointerUp(2, ms(270)), isNull);
      },
    );
  });

  group('TouchGestureResolver', () {
    late Map<TouchGesture, TouchAction> mapping;
    late List<TouchAction> fired;
    late TouchGestureResolver r;
    TouchGesture g(int fingers, int taps) => TouchGesture(fingers, taps);

    setUp(() {
      mapping = {for (final g in TouchGesture.values) g: g.defaultAction};
      fired = [];
      r = TouchGestureResolver(
        actionFor: (g) => mapping[g] ?? TouchAction.none,
        onAction: fired.add,
        multiTapWindow: ms(300),
      );
    });
    tearDown(() => r.dispose());

    test('there are 11 gestures, and a lone one-finger tap is not one', () {
      expect(TouchGesture.values, hasLength(11));
      expect(TouchGesture.values, isNot(contains(g(1, 1))));
    });

    test(
      'defaults: 2 fingers undo, 3 fingers redo, 1-finger double eraser',
      () {
        expect(g(2, 1).defaultAction, TouchAction.undo);
        expect(g(3, 1).defaultAction, TouchAction.redo);
        expect(g(1, 2).defaultAction, TouchAction.eraser);
        expect(g(4, 1).defaultAction, TouchAction.none);
      },
    );

    test(
      'two- and three-finger taps fire at once when no double is mapped',
      () {
        r.onTap(2);
        r.onTap(3);
        r.onTap(4);
        expect(fired, [TouchAction.undo, TouchAction.redo]);
      },
    );

    test('mapping is respected', () {
      mapping[g(4, 1)] = TouchAction.nextPage;
      mapping[g(2, 1)] = TouchAction.none;
      r.onTap(4);
      r.onTap(2);
      expect(fired, [TouchAction.nextPage]);
    });

    test('five fingers and zero map to nothing', () {
      r.onTap(0);
      r.onTap(5);
      expect(fired, isEmpty);
    });

    test(
      'a one-finger single tap does nothing, a double toggles the eraser',
      () {
        fakeAsync((async) {
          r.onTap(1);
          async.elapse(ms(1000));
          expect(fired, isEmpty);

          r.onTap(1);
          async.elapse(ms(100));
          r.onTap(1);
          expect(fired, [TouchAction.eraser]);
        });
      },
    );

    test('two one-finger taps too far apart are not a double tap', () {
      fakeAsync((async) {
        r.onTap(1);
        async.elapse(ms(400));
        r.onTap(1);
        async.elapse(ms(400));
        expect(fired, isEmpty);
      });
    });

    test('a double tap on 2 fingers delays a single tap, then fires it', () {
      mapping[g(2, 2)] = TouchAction.pen;
      fakeAsync((async) {
        r.onTap(2);
        expect(fired, isEmpty);
        async.elapse(ms(299));
        expect(fired, isEmpty);
        async.elapse(ms(2));
        expect(fired, [TouchAction.undo]);
      });
    });

    test('two quick two-finger taps fire only the double', () {
      mapping[g(2, 2)] = TouchAction.pen;
      fakeAsync((async) {
        r.onTap(2);
        async.elapse(ms(150));
        r.onTap(2);
        async.elapse(ms(1000));
        expect(fired, [TouchAction.pen]);
      });
    });

    test('triple taps count to three and fire at once', () {
      mapping[g(2, 3)] = TouchAction.highlighter;
      mapping[g(2, 2)] = TouchAction.none;
      fakeAsync((async) {
        r.onTap(2);
        async.elapse(ms(100));
        r.onTap(2);
        async.elapse(ms(100));
        r.onTap(2);
        expect(fired, [TouchAction.highlighter]);
        async.elapse(ms(1000));
        expect(fired, [TouchAction.highlighter]);
      });
    });

    test('a double tap with the triple unmapped fires after the double', () {
      mapping[g(2, 2)] = TouchAction.select;
      fakeAsync((async) {
        r.onTap(2);
        r.onTap(2);
        expect(fired, [TouchAction.select]);
      });
    });

    test('a tap with a different finger count flushes the waiting one', () {
      mapping[g(2, 2)] = TouchAction.pen;
      fakeAsync((async) {
        r.onTap(2);
        r.onTap(3);
        async.elapse(ms(1000));
        expect(fired, [TouchAction.undo, TouchAction.redo]);
      });
    });
  });

  test('every action has a label', () {
    for (final a in TouchAction.values) {
      expect(a.label, isNotEmpty);
    }
  });
}
