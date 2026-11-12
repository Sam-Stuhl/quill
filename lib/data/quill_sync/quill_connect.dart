import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:quill/data/file_manager/file_manager.dart';

/// What Quill sync's server (quill-sync/connect.py) knows about Sam's courses,
/// and the two things a note can be sent to: ATLAS's shelf, and Canvas (as a
/// proposal Sam taps Submit on). See docs/quill-sync.md, "Connected".
class QuillDue {
  const new({required this.name, required this.dueAt});

  factory fromJson(Map<String, dynamic> json) => QuillDue(
    name: json['name'] as String,
    dueAt: DateTime.parse(json['dueAt'] as String),
  );

  final String name;
  final DateTime dueAt;
}

class QuillAssignment {
  const new({
    required this.id,
    required this.course,
    required this.name,
    required this.dueAt,
    required this.submitted,
  });

  factory fromJson(Map<String, dynamic> json) => QuillAssignment(
    id: json['id'] as int,
    course: json['course'] as int,
    name: json['name'] as String,
    dueAt: json['dueAt'] == null
        ? null
        : DateTime.parse(json['dueAt'] as String),
    submitted: json['submitted'] == true,
  );

  final int id;
  final int course;
  final String name;
  final DateTime? dueAt;
  final bool submitted;
}

class QuillCourse {
  const new({
    required this.folder,
    required this.code,
    required this.name,
    required this.next,
    required this.assignments,
  });

  factory fromJson(Map<String, dynamic> json) => QuillCourse(
    folder: json['folder'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    next: json['next'] == null
        ? null
        : QuillDue.fromJson(json['next'] as Map<String, dynamic>),
    assignments: [
      for (final a in json['assignments'] as List)
        QuillAssignment.fromJson(a as Map<String, dynamic>),
    ],
  );

  /// The course's notebook folder in Quill, e.g. `/Fall 26/CS 114`.
  final String folder;
  final String code;
  final String name;
  final QuillDue? next;
  final List<QuillAssignment> assignments;
}

class QuillConnect {
  new({
    required this.baseUrl,
    required this.token,
    required this.stateDir,
    http.Client? client,
    Future<void> Function(String)? createFolder,
    this.refreshEvery = const Duration(minutes: 15),
  }) : _client = client ?? http.Client(),
       _createFolder = createFolder ?? FileManager.createFolder;

  static final log = Logger('QuillConnect');

  /// The running instance, or null when Quill sync is off.
  static QuillConnect? instance;

  /// The current courses, newest known state (empty until the first answer or
  /// a saved copy loads). Listened to by the folder cards.
  static final courses = ValueNotifier<List<QuillCourse>>(const []);

  final Uri baseUrl;
  final String token;
  final String stateDir;
  final Duration refreshEvery;
  final http.Client _client;
  final Future<void> Function(String) _createFolder;

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  var _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  var _refreshing = false;

  File get _cacheFile => File('$stateDir/courses.json');

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Future<void> start() async {
    await _loadCache();
    try {
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    } catch (_) {
      // No Flutter binding (pure Dart tests).
    }
    _timer = Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _lifecycle?.dispose();
    _client.close();
  }

  Future<void> _loadCache() async {
    try {
      courses.value = _parse(await _cacheFile.readAsString());
    } catch (_) {
      // none yet, or unreadable: the first answer replaces it
    }
  }

  static List<QuillCourse> _parse(String body) => [
    for (final c
        in (jsonDecode(body) as Map<String, dynamic>)['courses'] as List)
      QuillCourse.fromJson(c as Map<String, dynamic>),
  ];

  /// Asks the server for the courses, saves them, and makes sure each has its
  /// folder. Quiet when the server is away: the saved copy stays.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final res = await _client
          .get(baseUrl.resolve('/v1/courses'), headers: _auth)
          .timeout(const Duration(seconds: 45));
      if (res.statusCode != 200) return;
      final parsed = _parse(res.body);
      courses.value = parsed;
      _lastRefresh = DateTime.now();
      await Directory(stateDir).create(recursive: true);
      await _cacheFile.writeAsString(res.body);
      for (final c in parsed) {
        await _createFolder(c.folder);
      }
    } catch (e) {
      log.fine('courses unavailable: $e');
    } finally {
      _refreshing = false;
    }
  }

  /// [refresh], unless it ran in the last minute (the folder page calls this).
  Future<void> refreshIfStale() async {
    if (DateTime.now().difference(_lastRefresh) < const Duration(minutes: 1)) {
      return;
    }
    await refresh();
  }

  /// The course whose folder holds [path] (a note or a folder), if any.
  static QuillCourse? courseOfPath(String path, [List<QuillCourse>? from]) {
    for (final c in from ?? courses.value) {
      if (path == c.folder || path.startsWith('${c.folder}/')) return c;
    }
    return null;
  }

  /// "Due tomorrow", "Due Fri": the line on a course folder's card.
  static String dueLabel(QuillDue due, [DateTime? now]) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    now ??= DateTime.now();
    final at = due.dueAt.toLocal();
    final days = DateTime(
      at.year,
      at.month,
      at.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (at.isBefore(now)) return 'Overdue';
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    final time = '$hour:$minute ${at.hour < 12 ? 'AM' : 'PM'}';
    if (days == 0) return 'Due today $time';
    if (days == 1) return 'Due tomorrow';
    if (days < 7) return 'Due ${weekdays[at.weekday - 1]}';
    return 'Due ${months[at.month - 1]} ${at.day}';
  }

  /// Puts a page (PNG) or the finished PDF of [note] on ATLAS's shelf.
  /// Returns what the server said. Throws on failure.
  Future<String> sendToAtlas({
    required String note,
    required bool page,
    required Uint8List bytes,
  }) async {
    final res = await _post('/v1/send', {
      'note': note,
      'kind': page ? 'page' : 'pdf',
    }, bytes);
    return (jsonDecode(res) as Map<String, dynamic>)['said'] as String? ??
        'Sent to ATLAS';
  }

  /// Asks ATLAS to put [bytes] (the note's PDF) to Sam as a Canvas submission
  /// for [assignment]; he taps Submit there. Nothing is submitted from here.
  Future<String> proposeToCanvas({
    required String note,
    required QuillAssignment assignment,
    required Uint8List bytes,
  }) async {
    final res = await _post('/v1/canvas', {
      'note': note,
      'course': '${assignment.course}',
      'assignment': '${assignment.id}',
    }, bytes);
    return (jsonDecode(res) as Map<String, dynamic>)['said'] as String? ??
        'Proposed to Canvas';
  }

  Future<String> _post(
    String path,
    Map<String, String> query,
    Uint8List bytes,
  ) async {
    final uri = baseUrl.resolve(path).replace(queryParameters: query);
    final res = await _client
        .post(uri, headers: _auth, body: bytes)
        .timeout(const Duration(minutes: 3));
    if (res.statusCode != 200) {
      String why;
      try {
        why = (jsonDecode(res.body) as Map<String, dynamic>)['error'] as String;
      } catch (_) {
        why = 'HTTP ${res.statusCode}';
      }
      throw HttpException(why);
    }
    return res.body;
  }
}
