import 'package:flutter_test/flutter_test.dart';
import 'package:quill/data/palm_rejection.dart';

void main() {
  test('a finger passes when the pen is not in use', () {
    final palm = PalmRejection(enabled: true);
    expect(palm.touchDown(1, radius: 15.7), isFalse);
  });

  test('touches are ignored while the pen is down', () {
    final palm = PalmRejection(enabled: true);
    palm.stylusEvent(10, down: true, up: false);
    expect(palm.touchDown(1, radius: 15.7), isTrue);
    expect(palm.isRejected(1), isTrue);
    palm.touchEnded(1);
    expect(palm.isRejected(1), isFalse);
  });

  test('a finger works again as soon as the pen lifts', () {
    final palm = PalmRejection(enabled: true);
    palm.stylusEvent(10, down: true, up: false);
    palm.stylusEvent(10, down: false, up: true);
    expect(palm.penActive, isFalse);
    expect(palm.touchDown(2, radius: 15.7), isFalse);
  });

  test('a palm-sized contact is always ignored', () {
    final palm = PalmRejection(enabled: true);
    expect(palm.touchDown(1, radius: 36.5), isTrue);
  });

  test('hovering counts as the pen in use, briefly', () async {
    final palm = PalmRejection(enabled: true);
    palm.stylusEvent(10, down: false, up: false);
    expect(palm.penActive, isTrue);
    await Future<void>.delayed(
      const Duration(milliseconds: PalmRejection.hoverMs + 50),
    );
    expect(palm.penActive, isFalse);
  });

  test('off ignores nothing', () {
    final palm = PalmRejection(enabled: false);
    palm.stylusEvent(10, down: true, up: false);
    expect(palm.touchDown(1, radius: 36.5), isFalse);
  });
}
