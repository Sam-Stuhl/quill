import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/palm_rejection.dart';

void main() {
  test('touches pass when the pen has not been used', () {
    final palm = PalmRejection(holdMs: () => 800);
    expect(palm.touchDown(1), isFalse);
  });

  test('touches are rejected while the pen is down or hovering', () {
    final palm = PalmRejection(holdMs: () => 800);
    palm.stylusEvent(10, down: true, up: false);
    expect(palm.touchDown(1), isTrue);
    expect(palm.isRejected(1), isTrue);
    palm.touchEnded(1);
    expect(palm.isRejected(1), isFalse);
  });

  test('touches stay rejected for the hold time after the pen lifts', () async {
    final palm = PalmRejection(holdMs: () => 100);
    palm.stylusEvent(10, down: true, up: false);
    palm.stylusEvent(10, down: false, up: true);
    expect(palm.penActive, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(palm.penActive, isFalse);
    expect(palm.touchDown(2), isFalse);
  });

  test('a hold of 0 turns it off', () {
    final palm = PalmRejection(holdMs: () => 0);
    palm.stylusEvent(10, down: true, up: false);
    expect(palm.touchDown(1), isFalse);
  });
}
