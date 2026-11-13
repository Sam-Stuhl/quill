import 'package:flutter_test/flutter_test.dart';
import 'package:quill/data/palm_rejection.dart';

void main() {
  test('touches pass when the pen has not been used', () {
    final palm = PalmRejection(holdMs: 800);
    expect(palm.touchDown(1), isFalse);
  });

  test('touches are rejected while the pen is down or hovering', () {
    final palm = PalmRejection(holdMs: 800);
    palm.stylusEvent(10, down: true, up: false);
    expect(palm.touchDown(1), isTrue);
    expect(palm.isRejected(1), isTrue);
    palm.touchEnded(1);
    expect(palm.isRejected(1), isFalse);
  });

  test('touches stay rejected for the hold time after the pen lifts', () async {
    final palm = PalmRejection(holdMs: 100);
    palm.stylusEvent(10, down: true, up: false);
    palm.stylusEvent(10, down: false, up: true);
    expect(palm.penActive, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(palm.penActive, isFalse);
    expect(palm.touchDown(2), isFalse);
  });

  test('a hold of 0 turns it off', () {
    final palm = PalmRejection(holdMs: 0);
    palm.stylusEvent(10, down: true, up: false);
    expect(palm.touchDown(1), isFalse);
  });

  test('a large contact radius is a palm and is rejected outright', () {
    final palm = PalmRejection(holdMs: 800);
    expect(palm.touchDown(1, radius: 10), isFalse);
    expect(palm.touchDown(2, radius: 40), isTrue);
    expect(palm.isRejected(2), isTrue);
  });

  test('a large radius is allowed when the setting is off', () {
    final palm = PalmRejection(holdMs: 0);
    expect(palm.touchDown(1, radius: 40), isFalse);
  });

  test('a new touch is unconfirmed until it has been down a moment', () async {
    final palm = PalmRejection(holdMs: 800);
    expect(palm.touchesConfirmed, isTrue);
    palm.touchDown(1, radius: 10);
    expect(palm.touchesConfirmed, isFalse);
    await Future<void>.delayed(
      const Duration(milliseconds: PalmRejection.confirmMs + 30),
    );
    expect(palm.touchesConfirmed, isTrue);
    palm.touchDown(2, radius: 10);
    expect(palm.touchesConfirmed, isFalse);
    palm.touchEnded(2);
    expect(palm.touchesConfirmed, isTrue);
  });

  test('clearing pending touches confirms nothing was waiting', () {
    final palm = PalmRejection(holdMs: 800);
    palm.touchDown(1, radius: 10);
    palm.clearPending();
    expect(palm.touchesConfirmed, isTrue);
  });
}
