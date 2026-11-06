import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/quill_sync/quill_import.dart';
import 'package:saber/data/quill_sync/quill_sync.dart';

import 'utils/test_mock_channel_handlers.dart';

/// An in-memory quill-sync server (quill-sync/server.py's API).
class FakeServer {
  final files = <String, Uint8List>{};
  final pdfs = <String, Uint8List>{};
  final deleted = <String>[];
  final inbox = <Map<String, dynamic>>[];
  final inboxBytes = <String, Uint8List>{};
  final acks = <String, String?>{};
  var version = 0;
  var failing = false;
  var requests = 0;
  Completer<void> _inboxChanged = Completer();

  void drop(String id, String folder, String name, Uint8List bytes) {
    inbox.add({
      'id': id,
      'file': '${folder.substring(1)}$name',
      'folder': folder,
      'name': name,
    });
    inboxBytes[id] = bytes;
    version++;
    _inboxChanged.complete();
    _inboxChanged = Completer();
  }

  MockClient get client => MockClient((req) async {
    requests++;
    if (failing) return http.Response('down', 503);
    final path = req.url.queryParameters['path'];
    switch ((req.method, req.url.path)) {
      case ('PUT', '/v1/file'):
        files[path!] = req.bodyBytes;
      case ('PUT', '/v1/pdf'):
        pdfs[path!] = req.bodyBytes;
      case ('DELETE', '/v1/file'):
        files.remove(path);
        deleted.add(path!);
        if (path.endsWith('.sbn2')) {
          pdfs.remove(path.substring(0, path.length - 5));
        }
      case ('GET', '/v1/manifest'):
        return http.Response(jsonEncode({'files': {}, 'pdfs': {}}), 200);
      case ('GET', '/v1/inbox'):
        final since = int.tryParse(req.url.queryParameters['since'] ?? '');
        if (since == version) {
          await _inboxChanged.future.timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
        }
        return http.Response(
          jsonEncode({'version': version, 'items': inbox}),
          200,
        );
      case ('POST', final p) when p.endsWith('/ack'):
        final id = p.split('/')[3];
        final note = (jsonDecode(req.body) as Map)['note'] as String?;
        acks[id] = note;
        if (inbox.any((i) => i['id'] == id)) {
          inbox.removeWhere((i) => i['id'] == id);
          version++;
        }
      case ('GET', final p) when p.startsWith('/v1/inbox/'):
        return http.Response.bytes(inboxBytes[p.split('/')[3]]!, 200);
      default:
        return http.Response('not found', 404);
    }
    return http.Response('{"ok":true}', 200);
  });
}

Uint8List pngBytes(int w, int h) =>
    Uint8List.fromList(im.encodePng(im.Image(width: w, height: h)));

Future<void> until(bool Function() cond, {int seconds = 10}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late FakeServer server;
  late QuillSync sync;
  late String stateDir;
  final rendered = <String>[];

  QuillSync makeSync({
    Future<String> Function(
      Uint8List, {
      required String folder,
      required String name,
    })?
    importer,
  }) => QuillSync(
    baseUrl: Uri.parse('http://quill.test'),
    token: 't',
    stateDir: stateDir,
    client: server.client,
    renderPdf: (note) async {
      rendered.add(note);
      return Uint8List.fromList(utf8.encode('%PDF $note'));
    },
    importBytes: importer ?? QuillImport.importBytes,
    pdfDebounce: const Duration(milliseconds: 10),
    pollWait: const Duration(seconds: 1),
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    FlavorConfig.setup();
    await FileManager.init(shouldWatchRootDirectory: false);
  });

  setUp(() async {
    final root = Directory(FileManager.documentsDirectory);
    if (root.existsSync()) await root.delete(recursive: true);
    await root.create(recursive: true);
    stateDir = (await Directory.systemTemp.createTemp('quill-sync-')).path;
    server = FakeServer();
    rendered.clear();
  });

  tearDown(() async {
    await QuillSync.instance?.stop();
    QuillSync.instance = null;
  });

  test(
    'writes, moves and deletes reach the server, PDFs follow notes',
    () async {
      sync = QuillSync.instance = makeSync();
      await sync.start();

      await FileManager.writeFile('/School/a.sbn2', [
        1,
        2,
        3,
      ], awaitWrite: true);
      await FileManager.writeFile('/School/a.sbn2.0', [4], awaitWrite: true);
      await FileManager.writeFile('/School/a.sbn2', [
        1,
        2,
        3,
        4,
      ], awaitWrite: true);
      await until(() => sync.isIdle && server.pdfs.containsKey('/School/a'));
      expect(server.files['/School/a.sbn2'], [1, 2, 3, 4]);
      expect(server.files['/School/a.sbn2.0'], [4]);
      expect(utf8.decode(server.pdfs['/School/a']!), '%PDF /School/a');

      await FileManager.moveFile('/School/a.sbn2', '/School/b.sbn2');
      await until(() => sync.isIdle && server.pdfs.containsKey('/School/b'));
      expect(
        server.files.keys,
        containsAll(['/School/b.sbn2', '/School/b.sbn2.0']),
      );
      expect(server.files.containsKey('/School/a.sbn2'), isFalse);
      expect(server.pdfs.containsKey('/School/a'), isFalse);

      await FileManager.deleteFile('/School/b.sbn2');
      await until(() => sync.isIdle);
      expect(server.files, isEmpty);
      expect(server.pdfs, isEmpty);
      expect(
        server.deleted,
        containsAll(['/School/b.sbn2', '/School/b.sbn2.0']),
      );
    },
  );

  test('a burst of saves is coalesced per path', () async {
    sync = QuillSync.instance = makeSync();
    await sync.start();
    server.failing = true;
    for (var i = 0; i < 20; i++) {
      await FileManager.writeFile('/n.sbn2', [i], awaitWrite: true);
    }
    expect(sync.ops.keys, ['/n.sbn2']);
    server.failing = false;
    sync.onResume();
    await until(() => sync.isIdle && server.pdfs.isNotEmpty);
    expect(server.files['/n.sbn2'], [19]);
  });

  test(
    'the queue survives a restart and drains when the server is back',
    () async {
      sync = QuillSync.instance = makeSync();
      await sync.start();
      server.failing = true;
      await FileManager.writeFile('/offline.sbn2', [7], awaitWrite: true);
      await FileManager.writeFile('/gone.sbn2', [8], awaitWrite: true);
      await FileManager.deleteFile('/gone.sbn2');
      await Future.delayed(const Duration(milliseconds: 100));
      await sync.stop();
      expect(File('$stateDir/state.json').existsSync(), isTrue);

      server.failing = false;
      sync = QuillSync.instance = makeSync();
      await sync.start();
      await until(() => sync.isIdle && server.pdfs.containsKey('/offline'));
      expect(server.files['/offline.sbn2'], [7]);
      expect(server.files.containsKey('/gone.sbn2'), isFalse);
      expect(server.deleted, contains('/gone.sbn2'));
    },
  );

  test(
    'an inbox image becomes a note, once, with a page sized to it',
    () async {
      final imported = <String>[];
      sync = QuillSync.instance = makeSync(
        importer: (bytes, {required folder, required name}) async {
          final path = await QuillImport.importBytes(
            bytes,
            folder: folder,
            name: name,
          );
          imported.add(path);
          return path;
        },
      );
      await sync.start();

      server.drop('aaaa', '/Inbox test/', 'photo.png', pngBytes(300, 600));
      await until(() => server.acks.containsKey('aaaa'));
      expect(server.acks['aaaa'], '/Inbox test/photo');
      expect(imported, ['/Inbox test/photo']);

      final coreInfo = await EditorCoreInfo.loadFromFilePath(
        '/Inbox test/photo',
      );
      expect(coreInfo.pages, hasLength(2)); // the image, then an empty page
      expect(coreInfo.pages.first.backgroundImage, isNotNull);
      expect(
        coreInfo.pages.first.size.height,
        closeTo(EditorPage.defaultWidth * 2, 0.01),
      );
      expect(coreInfo.pages.last.isEmpty, isTrue);
      coreInfo.dispose();
      // ...and the new note goes back up to the mini like any other.
      await until(() => server.files.containsKey('/Inbox test/photo.sbn2'));

      // Redelivered (ack lost): acked again, not imported again.
      server.drop('aaaa', '/Inbox test/', 'photo.png', pngBytes(300, 600));
      await until(() => server.inbox.isEmpty);
      expect(imported, hasLength(1));

      // Same name again: a new note with Quill's suffix, never an overwrite.
      server.drop('bbbb', '/Inbox test/', 'photo.png', pngBytes(10, 10));
      await until(() => server.acks.containsKey('bbbb'));
      expect(server.acks['bbbb'], '/Inbox test/photo (2)');
    },
  );

  test('a failed import is not acked', () async {
    sync = QuillSync.instance = makeSync();
    await sync.start();
    server.drop('cccc', '/', 'broken.png', Uint8List.fromList([1, 2, 3]));
    await Future.delayed(const Duration(milliseconds: 500));
    expect(server.acks, isEmpty);
    expect(server.inbox, hasLength(1));
  });

  // Needs a PDFium library outside the app, e.g. after a macOS build:
  // PDFIUM_PATH=build/native_assets/macos/libpdfium.dylib flutter test ...
  final pdfium = Platform.environment['PDFIUM_PATH'];
  test(
    'a PDF becomes a note with a page per PDF page, and renders back',
    skip: pdfium == null ? 'set PDFIUM_PATH to run' : false,
    () async {
      await pdfrxInitialize();
      final doc = pw.Document()
        ..addPage(
          pw.Page(
            pageFormat: PdfPageFormat.letter,
            build: (_) => pw.Text('one'),
          ),
        )
        ..addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4.landscape,
            build: (_) => pw.Text('two'),
          ),
        );
      final bytes = await doc.save();

      final note = await QuillImport.importBytes(
        bytes,
        folder: '/Pdfs/',
        name: 'hw 3.pdf',
      );
      expect(note, '/Pdfs/hw 3');
      expect(FileManager.getFile('/Pdfs/hw 3.sbn2.0').readAsBytesSync(), bytes);

      final coreInfo = await EditorCoreInfo.loadFromFilePath(note);
      expect(coreInfo.pages, hasLength(3));
      final letter = coreInfo.pages[0].size;
      expect(letter.height / letter.width, closeTo(11 / 8.5, 0.01));
      final landscape = coreInfo.pages[1].size;
      expect(landscape.width, greaterThan(landscape.height));
      coreInfo.dispose();

      final pdf = await QuillImport.renderPdf(note);
      expect(utf8.decode(pdf!.sublist(0, 4)), '%PDF');
      final reread = await PdfDocument.openData(pdf);
      expect(reread.pages, hasLength(2)); // the empty last page is left out
      // The imported page's text made it into the export.
      final image = await reread.pages[0].render();
      final pixels = image!.pixels;
      var dark = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] < 128 && pixels[i + 1] < 128 && pixels[i + 2] < 128)
          dark++;
      }
      image.dispose();
      expect(dark, greaterThan(20), reason: 'the PDF background was not drawn');
      await reread.dispose();
    },
  );

  test(
    'an image note renders back with the image in it',
    skip: pdfium == null ? 'set PDFIUM_PATH to run' : false,
    () async {
      await pdfrxInitialize();
      final black = im.Image(width: 200, height: 100);
      im.fill(black, color: im.ColorRgb8(0, 0, 0));
      final note = await QuillImport.importBytes(
        Uint8List.fromList(im.encodePng(black)),
        folder: '/',
        name: 'black.png',
      );
      final pdf = await QuillImport.renderPdf(note);
      final reread = await PdfDocument.openData(pdf!);
      final image = await reread.pages[0].render();
      final pixels = image!.pixels;
      var dark = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] < 128) dark++;
      }
      expect(
        dark / (pixels.length / 4),
        greaterThan(0.5),
        reason: 'image missing',
      );
      image.dispose();
      await reread.dispose();
    },
  );

  test('safeName keeps names the app accepts', () {
    expect(QuillImport.safeName('hw: 3/4'), 'hw_ 3_4');
    expect(QuillImport.safeName('  '), startsWith('Imported '));
  });

  group('autosave race', () {
    test('a change made during a save stays unsaved', () {
      final history = EditorHistory();
      history.recordChange(HistoricStub());
      final savedChange = history.lastChange;
      history.recordChange(HistoricStub()); // drawn while saving
      history.markChangeAsSaved(savedChange);
      expect(history.isCurrentStateSaved, isFalse);
      history.markChangeAsSaved(history.lastChange);
      expect(history.isCurrentStateSaved, isTrue);
    });
  });
}

class HistoricStub extends HistoricPageInsert {
  new() : super(pageIndex: 0, page: EditorPage());
}
