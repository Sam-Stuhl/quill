import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:quill/data/file_manager/file_manager.dart';
import 'package:quill/data/flavor_config.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/quill_defaults.dart';
import 'package:quill/data/quill_sync/quill_connect.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';

import 'utils/test_mock_channel_handlers.dart';

const coursesBody = {
  'generatedAt': 1,
  'courses': [
    {
      'folder': '/Fall 26/CS 114',
      'code': 'CS 114',
      'name': 'Introduction to Computer Science II',
      'next': {
        'name': 'Midterm 1 - Corrections',
        'dueAt': '2030-11-10T04:59:59Z',
      },
      'assignments': [
        {
          'id': 11,
          'course': 1,
          'name': 'Homework 10',
          'dueAt': '2030-11-12T04:59:59Z',
          'submitted': false,
        },
      ],
    },
    {
      'folder': '/Fall 26/FYS',
      'code': 'FYS SEM',
      'name': 'Seminar',
      'next': null,
      'assignments': <Object>[],
    },
  ],
};

void main() {
  late String stateDir;
  late List<String> folders;
  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    FlavorConfig.setup();
    await FileManager.init(shouldWatchRootDirectory: false);
  });

  setUp(() async {
    stateDir = (await Directory.systemTemp.createTemp('quill-connect-')).path;
    folders = [];
    requests = [];
    QuillConnect.courses.value = const [];
  });

  QuillConnect make(http.Client client) => QuillConnect(
    baseUrl: Uri.parse('https://mini.example:8796'),
    token: 'tok',
    stateDir: stateDir,
    client: client,
    createFolder: (f) async => folders.add(f),
  );

  http.Client serving({int status = 200, Object? body = coursesBody}) =>
      MockClient((req) async {
        requests.add(req);
        if (req.url.path == '/v1/courses') {
          return http.Response(jsonEncode(body), status);
        }
        return http.Response(
          jsonEncode({'ok': true, 'said': 'on the shelf'}),
          200,
        );
      });

  group('courses', () {
    test(
      'refresh loads courses, makes their folders, and saves a copy',
      () async {
        final connect = make(serving());
        await connect.refresh();
        expect(QuillConnect.courses.value.map((c) => c.code), [
          'CS 114',
          'FYS SEM',
        ]);
        expect(folders, ['/Fall 26/CS 114', '/Fall 26/FYS']);
        expect(requests.single.headers['Authorization'], 'Bearer tok');
        expect(
          QuillConnect.courses.value.first.next!.name,
          'Midterm 1 - Corrections',
        );

        // A later start with the server away still has the courses.
        QuillConnect.courses.value = const [];
        final offline = make(
          MockClient((_) async => throw const SocketException('away')),
        );
        await offline.start();
        expect(QuillConnect.courses.value, hasLength(2));
        await offline.stop();
      },
    );

    test('a server error keeps what was there', () async {
      final connect = make(serving());
      await connect.refresh();
      final bad = make(serving(status: 502, body: {'error': 'down'}));
      await bad.refresh();
      expect(QuillConnect.courses.value, hasLength(2));
    });

    test('a note belongs to the course whose folder holds it', () async {
      await make(serving()).refresh();
      expect(
        QuillConnect.courseOfPath('/Fall 26/CS 114/HW 10')!.code,
        'CS 114',
      );
      expect(QuillConnect.courseOfPath('/Fall 26/CS 114')!.code, 'CS 114');
      expect(QuillConnect.courseOfPath('/Fall 26/CS 1140/x'), isNull);
      expect(QuillConnect.courseOfPath('/Fall 26'), isNull);
      expect(QuillConnect.courseOfPath('/Other/x'), isNull);
    });

    test('the due line is plain', () {
      final now = DateTime(2030, 11, 6, 12);
      String label(DateTime d) =>
          QuillConnect.dueLabel(QuillDue(name: 'x', dueAt: d.toUtc()), now);
      expect(label(DateTime(2030, 11, 6, 23, 59)), 'Due today 11:59 PM');
      expect(label(DateTime(2030, 11, 7, 9)), 'Due tomorrow');
      expect(label(DateTime(2030, 11, 10, 9)), 'Due Sun');
      expect(label(DateTime(2030, 11, 20, 9)), 'Due Nov 20');
      expect(label(DateTime(2030, 11, 6, 8)), 'Overdue');
    });
  });

  group('sending', () {
    test('a page or PDF goes to ATLAS with its kind and note', () async {
      final connect = make(serving());
      final said = await connect.sendToAtlas(
        note: '/Fall 26/CS 114/Lec 3',
        page: true,
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(said, 'on the shelf');
      final r = requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/v1/send');
      expect(r.url.queryParameters, {
        'note': '/Fall 26/CS 114/Lec 3',
        'kind': 'page',
      });
      expect(r.bodyBytes, [1, 2, 3]);
    });

    test('a Canvas proposal carries the course and assignment', () async {
      final connect = make(serving());
      await make(serving()).refresh();
      await connect.proposeToCanvas(
        note: '/Fall 26/CS 114/HW 10',
        assignment: QuillConnect.courses.value.first.assignments.first,
        bytes: Uint8List.fromList([9]),
      );
      final r = requests.last;
      expect(r.url.path, '/v1/canvas');
      expect(r.url.queryParameters['course'], '1');
      expect(r.url.queryParameters['assignment'], '11');
    });

    test('a refused send says why', () async {
      final connect = make(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'not an assignment of a current course'}),
            400,
          ),
        ),
      );
      expect(
        connect.proposeToCanvas(
          note: '/x',
          assignment: const QuillAssignment(
            id: 5,
            course: 1,
            name: 'n',
            dueAt: null,
            submitted: false,
          ),
          bytes: Uint8List(1),
        ),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('not an assignment'),
          ),
        ),
      );
    });
  });

  group('defaults', () {
    test('apply once, and again only when the version goes up', () async {
      await stows.quillDefaultsVersion.waitUntilRead();
      stows.quillDefaultsVersion.value = 0;
      stows.lastBackgroundPattern.value = CanvasBackgroundPattern.none;
      await QuillDefaults.applyOnce();
      expect(
        stows.lastBackgroundPattern.value,
        CanvasBackgroundPattern.collegeLtr,
      );
      expect(stows.lastTool.value, ToolId.fountainPen);
      expect(
        stows.lastBallpointPenColor.value,
        QuillDefaults.inkBlue.toARGB32(),
      );
      expect(stows.accentColor.value, QuillDefaults.accent);
      expect(stows.quillDefaultsVersion.value, QuillDefaults.version);

      // Sam changes the paper in the app: the next launch leaves it alone.
      stows.lastBackgroundPattern.value = CanvasBackgroundPattern.none;
      await QuillDefaults.applyOnce();
      expect(stows.lastBackgroundPattern.value, CanvasBackgroundPattern.none);
    });
  });
}
