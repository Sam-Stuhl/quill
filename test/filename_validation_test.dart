import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/file_manager/file_manager.dart';

void main() {
  group('validateFilename', () {
    test('allows ordinary names that start with a reserved word', () {
      for (final name in [
        'Concept Diagram',
        'Content',
        'Auxiliary notes',
        'Nullspace',
        'Com1 review',
        'printing',
        'CON 2',
      ]) {
        expect(FileManager.validateFilename(name), isNull, reason: name);
      }
    });
    test('still refuses reserved device names and dots', () {
      for (final name in [
        'con',
        'CON',
        'con.txt',
        'aux',
        'nul.x',
        'COM1',
        'lpt9',
        '.',
        '..',
        'a:b',
        'a/b',
      ]) {
        expect(FileManager.validateFilename(name), isNotNull, reason: name);
      }
    });
  });
}
