import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/pen_activity.dart';
import 'package:saber/data/quill_sync/quill_connect.dart';
import 'package:saber/data/quill_sync/quill_import.dart';
import 'package:saber/pages/editor/editor.dart';

/// Quill sync: keeps a folder on the mini current with every note, and imports
/// whatever lands in its inbox. See docs/quill-sync.md.
///
/// The iPad is the only writer of notes, so there are no conflicts: every
/// upload is the whole current file, queued by path (latest operation wins)
/// and persisted, so nothing is lost to a crash, a kill or being offline.
class QuillSync {
  new({
    required this.baseUrl,
    required this.token,
    required this.stateDir,
    http.Client? client,
    this.renderPdf = QuillImport.renderPdf,
    this.importBytes = QuillImport.importBytes,
    this.pdfDebounce = const Duration(seconds: 2),
    this.pollWait = const Duration(seconds: 25),
  }) : _client = client ?? http.Client();

  static final log = Logger('QuillSync');

  /// Compiled in at install time (scripts/install-on-ipad.sh). Empty in
  /// tests and other builds, which turns Quill sync off.
  static const configuredUrl = String.fromEnvironment('QUILL_SYNC_URL');
  static const configuredToken = String.fromEnvironment('QUILL_SYNC_TOKEN');

  /// The running instance, or null when Quill sync is off.
  static QuillSync? instance;

  /// Starts Quill sync if this build has a server configured.
  static Future<void> startIfConfigured() async {
    if (configuredUrl.isEmpty || configuredToken.isEmpty) return;
    final dir = await getApplicationSupportDirectory();
    instance = QuillSync(
      baseUrl: Uri.parse(configuredUrl),
      token: configuredToken,
      stateDir: '${dir.path}/quill_sync',
    );
    await instance!.start();
    QuillConnect.instance = QuillConnect(
      baseUrl: Uri.parse(configuredUrl),
      token: configuredToken,
      stateDir: '${dir.path}/quill_sync',
    );
    unawaited(QuillConnect.instance!.start());
  }

  final Uri baseUrl;
  final String token;
  final String stateDir;
  final http.Client _client;
  final Future<Uint8List?> Function(String notePath) renderPdf;
  final Future<String> Function(
    Uint8List bytes, {
    required String folder,
    required String name,
  })
  importBytes;
  final Duration pdfDebounce;
  final Duration pollWait;

  static final noteFileRegex = RegExp(r'\.sbn2(\.(\d+|p))?$');

  /// path -> operation, in the order they were first queued.
  @visibleForTesting
  final ops = <String, QueuedOp>{};

  /// Note paths (no extension) whose PDF needs rendering.
  @visibleForTesting
  final pdfs = <String>{};

  /// Inbox item ids already imported, newest last.
  @visibleForTesting
  final delivered = <String>[];

  /// Inbox imports under way: id -> the note path the import will create, and
  /// whether a note was already there. Saved before importing, so an import
  /// cut short by iOS (it kills the app for memory) is recognised on the next
  /// try instead of creating a "(2)" copy.
  @visibleForTesting
  final importing = <String, Map<String, dynamic>>{};

  final _pdfTimers = <String, Timer>{};
  var _running = false;
  var _draining = false;
  var _drainAgain = false;
  Timer? _retryTimer;
  var _failures = 0;
  var _pollGeneration = 0;
  AppLifecycleListener? _lifecycle;

  /// Completes each time the queue empties; for tests and measurements.
  final _idle = StreamController<void>.broadcast();
  Stream<void> get onIdle => _idle.stream;

  bool get isIdle => ops.isEmpty && pdfs.isEmpty && !_draining;

  File get _stateFile => File('$stateDir/state.json');

  Future<void> start() async {
    _running = true;
    await _load();
    try {
      _lifecycle = AppLifecycleListener(onResume: onResume);
    } catch (_) {
      // No Flutter binding (pure Dart tests): resume handling is not needed.
    }
    unawaited(reconcile());
    _kick();
    unawaited(_pollInbox(_pollGeneration));
  }

  Future<void> stop() async {
    _running = false;
    _pollGeneration++;
    _retryTimer?.cancel();
    for (final t in _pdfTimers.values) {
      t.cancel();
    }
    _lifecycle?.dispose();
    _client.close();
  }

  /// The app came back to the foreground: iOS will have dropped the long
  /// poll and paused retries, so start both again and catch up.
  void onResume() {
    if (!_running) return;
    _failures = 0;
    _retryTimer?.cancel();
    _kick();
    unawaited(reconcile());
    unawaited(_pollInbox(++_pollGeneration));
  }

  // -- hooks from FileManager ----------------------------------------------

  /// [filePath] (relative to the documents directory) was written.
  void onWrite(String filePath) => _queue(filePath, .put);

  /// [filePath] (relative to the documents directory) was deleted.
  void onDelete(String filePath) => _queue(filePath, .delete);

  void _queue(String filePath, OpType type) {
    if (!_running || !noteFileRegex.hasMatch(filePath)) return;
    final existing = ops.remove(filePath);
    ops[filePath] = QueuedOp(
      type,
      writtenAt: DateTime.now().millisecondsSinceEpoch,
      generation: (existing?.generation ?? 0) + 1,
    );
    if (filePath.endsWith(Editor.extension)) {
      final note = filePath.substring(
        0,
        filePath.length - Editor.extension.length,
      );
      if (type == .put) {
        _schedulePdf(note);
      } else {
        // The server trashes the PDF along with the note.
        _pdfTimers.remove(note)?.cancel();
        pdfs.remove(note);
      }
    }
    _save();
    _kick();
  }

  /// How long the pen must have been idle before a PDF is rendered.
  static const penQuiet = Duration(seconds: 3);

  void _schedulePdf(String note, {Duration? after}) {
    _pdfTimers[note]?.cancel();
    _pdfTimers[note] = Timer(after ?? pdfDebounce, () {
      // Rendering a note takes seconds of main-thread work: not while the
      // pen is being used.
      final idle = PenActivity.sinceLast;
      if (idle < penQuiet) {
        _pdfTimers.remove(note);
        _schedulePdf(note, after: penQuiet - idle);
        return;
      }
      _pdfTimers.remove(note);
      pdfs.add(note);
      _save();
      _kick();
    });
  }

  // -- uploading -----------------------------------------------------------

  void _kick() {
    if (!_running) return;
    if (_draining) {
      _drainAgain = true;
      return;
    }
    if (_retryTimer?.isActive ?? false) return;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      do {
        _drainAgain = false;
        while (_running && ops.isNotEmpty) {
          final path = ops.keys.first;
          final op = ops[path]!;
          await _send(path, op);
          // Only drop it if nothing newer was queued while it was sending.
          if (ops[path]?.generation == op.generation) ops.remove(path);
          await _save();
        }
        while (_running && ops.isEmpty && pdfs.isNotEmpty) {
          final note = pdfs.first;
          pdfs.remove(note);
          try {
            await _sendPdf(note);
          } catch (_) {
            pdfs.add(note);
            rethrow;
          }
          await _save();
        }
      } while (_running && _drainAgain);
      _failures = 0;
      if (isIdleExceptDraining) _idle.add(null);
    } catch (e) {
      _failures++;
      final delay = Duration(seconds: min(30, 1 << min(_failures - 1, 5)));
      log.warning('Upload failed ($_failures), retrying in $delay: $e');
      _retryTimer = Timer(delay, () {
        _retryTimer = null;
        _kick();
      });
    } finally {
      _draining = false;
    }
  }

  bool get isIdleExceptDraining => ops.isEmpty && pdfs.isEmpty;

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Uri _url(String path, [Map<String, String>? query]) =>
      baseUrl.replace(path: path, queryParameters: query);

  void _check(http.BaseResponse r, String what) {
    if (r.statusCode == 400) {
      // The server will never take this one; logging and dropping it is
      // better than blocking the queue behind it forever.
      log.severe('Server refused $what (400)');
      return;
    }
    if (r.statusCode != 200) {
      throw HttpException('$what: HTTP ${r.statusCode}');
    }
  }

  Future<void> _send(String path, QueuedOp op) async {
    if (op.type == .delete) {
      final r = await _client
          .delete(_url('/v1/file', {'path': path}), headers: _auth)
          .timeout(const Duration(seconds: 30));
      return _check(r, 'delete $path');
    }
    final file = FileManager.getFile(path);
    if (!file.existsSync()) return; // a delete for it is queued or coming
    final bytes = await file.readAsBytes();
    final r = await _client
        .put(
          _url('/v1/file', {'path': path}),
          headers: {
            ..._auth,
            'X-Mtime': '${file.lastModifiedSync().millisecondsSinceEpoch}',
            'X-Quill-Written-At': '${op.writtenAt}',
          },
          body: bytes,
        )
        .timeout(Duration(seconds: 30 + bytes.length ~/ 100000));
    _check(r, 'upload $path');
  }

  Future<void> _sendPdf(String note) async {
    final file = FileManager.getFile(note + Editor.extension);
    if (!file.existsSync()) return;
    final mtime = file.lastModifiedSync().millisecondsSinceEpoch;
    final Uint8List? pdf;
    try {
      pdf = await renderPdf(note);
    } catch (e, st) {
      // A note that cannot be rendered should not hold up the others.
      log.severe('Could not render $note to PDF: $e', e, st);
      return;
    }
    if (pdf == null) return;
    final r = await _client
        .put(
          _url('/v1/pdf', {'path': note}),
          headers: {
            ..._auth,
            'X-Mtime': '$mtime',
            'X-Quill-Written-At': '$mtime',
          },
          body: pdf,
        )
        .timeout(Duration(seconds: 30 + pdf.length ~/ 100000));
    _check(r, 'upload $note.pdf');
  }

  /// Uploads [bytes] as [note]'s PDF instead of rendering it. Falls back to
  /// rendering later if the upload fails.
  Future<void> _sendSourcePdf(String note, Uint8List bytes) async {
    _pdfTimers.remove(note)?.cancel();
    pdfs.remove(note);
    final file = FileManager.getFile(note + Editor.extension);
    try {
      final mtime = file.lastModifiedSync().millisecondsSinceEpoch;
      final r = await _client
          .put(
            _url('/v1/pdf', {'path': note}),
            headers: {
              ..._auth,
              'X-Mtime': '$mtime',
              'X-Quill-Written-At': '$mtime',
            },
            body: bytes,
          )
          .timeout(Duration(seconds: 30 + bytes.length ~/ 100000));
      _check(r, 'upload $note.pdf');
    } catch (e) {
      log.warning('Could not send the imported PDF of $note, will render: $e');
      pdfs.add(note);
      _kick();
    }
  }

  // -- reconcile -----------------------------------------------------------

  /// Uploads every note file the server lacks or has an older copy of, and
  /// renders every PDF that is missing or older than its note. Never deletes.
  Future<void> reconcile() async {
    try {
      final r = await _client
          .get(_url('/v1/manifest'), headers: _auth)
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
      final manifest = jsonDecode(r.body) as Map<String, dynamic>;
      final files = (manifest['files'] as Map).cast<String, dynamic>();
      final pdfMtimes = (manifest['pdfs'] as Map).cast<String, dynamic>();

      final root = FileManager.documentsDirectory;
      var queued = 0;
      await for (final entity in Directory(root).list(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path
            .substring(root.length)
            .replaceAll(Platform.pathSeparator, '/');
        if (!noteFileRegex.hasMatch(path)) continue;
        final mtime = entity.lastModifiedSync().millisecondsSinceEpoch;
        final remote = files[path] as Map?;
        if (remote == null || remote['mtime'] != mtime) {
          if (!ops.containsKey(path)) {
            ops[path] = QueuedOp(.put, writtenAt: mtime, generation: 1);
            queued++;
          }
        }
        if (path.endsWith(Editor.extension)) {
          final note = path.substring(0, path.length - Editor.extension.length);
          final pdfMtime = pdfMtimes[note] as int?;
          if (pdfMtime == null || pdfMtime < mtime) {
            pdfs.add(note);
            queued++;
          }
        }
      }
      if (queued > 0) {
        log.info('Reconcile queued $queued uploads');
        await _save();
        _kick();
      }
    } catch (e) {
      log.warning('Reconcile failed (will retry on resume): $e');
    }
  }

  // -- inbox ---------------------------------------------------------------

  Future<void> _pollInbox(int generation) async {
    int? version;
    var failures = 0;
    while (_running && generation == _pollGeneration) {
      try {
        final r = await _client
            .get(
              _url('/v1/inbox', {
                'wait': '${pollWait.inSeconds}',
                'since': ?version?.toString(),
              }),
              headers: _auth,
            )
            .timeout(pollWait + const Duration(seconds: 15));
        if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
        final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
        if (generation != _pollGeneration) return;
        version = body['version'] as int?;
        failures = 0;
        for (final item in (body['items'] as List).cast<Map>()) {
          await _deliver(item.cast<String, dynamic>());
        }
        for (final d in ((body['deletes'] as List?) ?? const []).cast<Map>()) {
          await _deleteRequested(d['id'] as String, d['note'] as String);
        }
      } catch (e) {
        if (generation != _pollGeneration) return;
        failures++;
        version = null;
        final delay = Duration(seconds: min(30, 1 << min(failures - 1, 5)));
        log.warning('Inbox poll failed, retrying in $delay: $e');
        await Future.delayed(delay);
      }
    }
  }

  /// A note was deleted on the mini's side (`server.py delete`): delete it
  /// here, which sends it to the server's trash like any delete, then ack.
  Future<void> _deleteRequested(String id, String note) async {
    if (FileManager.doesFileExist(note + Editor.extension)) {
      await FileManager.deleteFile(note + Editor.extension);
      log.info('Deleted $note, as asked from the mini');
    }
    final r = await _client
        .post(_url('/v1/deletes/$id/ack'), headers: _auth, body: '{}')
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw HttpException('delete ack: ${r.statusCode}');
  }

  Future<void> _deliver(Map<String, dynamic> item) async {
    final id = item['id'] as String;
    final name = item['name'] as String;
    final folder = item['folder'] as String;
    String? note;
    if (!delivered.contains(id)) {
      final pending = importing[id];
      final expected = pending?['note'] as String?;
      if (pending != null &&
          pending['existed'] == false &&
          expected != null &&
          FileManager.doesFileExist(expected + Editor.extension)) {
        // Imported before the app was killed, just not recorded: done.
        note = expected;
        log.info('Import of ${item['file']} had finished before a restart');
      } else {
        final r = await _client
            .get(_url('/v1/inbox/$id'), headers: _auth)
            .timeout(const Duration(minutes: 2));
        if (r.statusCode != 200) {
          throw HttpException('download $id: HTTP ${r.statusCode}');
        }
        final target =
            folder + QuillImport.safeName(p.basenameWithoutExtension(name));
        importing[id] = {
          'note': target,
          'existed': FileManager.doesFileExist(target + Editor.extension),
        };
        await _save();
        try {
          note = await importBytes(r.bodyBytes, folder: folder, name: name);
        } catch (e, st) {
          // Not acked, so it stays in the inbox and is tried again later.
          log.severe('Could not import ${item['file']}: $e', e, st);
          return;
        }
        if (p.extension(name).toLowerCase() == '.pdf') {
          // The note is the PDF with nothing on it yet, so the PDF itself is
          // the note's PDF: no render, which for a long PDF can take more
          // memory than iOS allows.
          await _sendSourcePdf(note, r.bodyBytes);
        }
      }
      delivered.add(id);
      if (delivered.length > 500) delivered.removeAt(0);
      importing.remove(id);
      await _save();
    }
    final ack = await _client
        .post(
          _url('/v1/inbox/$id/ack'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({'note': ?note}),
        )
        .timeout(const Duration(seconds: 30));
    if (ack.statusCode != 200) throw HttpException('ack: ${ack.statusCode}');
  }

  // -- state ---------------------------------------------------------------

  Future<void> _load() async {
    try {
      if (!_stateFile.existsSync()) return;
      final json = jsonDecode(await _stateFile.readAsString()) as Map;
      for (final MapEntry(:key, :value) in (json['ops'] as Map).entries) {
        ops[key as String] = QueuedOp.fromJson((value as Map).cast());
      }
      pdfs.addAll((json['pdfs'] as List).cast<String>());
      delivered.addAll((json['delivered'] as List).cast<String>());
      for (final MapEntry(:key, :value)
          in ((json['importing'] as Map?) ?? const {}).entries) {
        importing[key as String] = (value as Map).cast<String, dynamic>();
      }
    } catch (e, st) {
      // A bad state file only costs a reconcile, which rebuilds the queue.
      log.severe('Could not read Quill sync state: $e', e, st);
    }
  }

  Future<void>? _saving;
  var _saveAgain = false;

  /// Writes the queue to disk (atomically), coalescing bursts of changes.
  Future<void> _save() {
    if (_saving != null) {
      _saveAgain = true;
      return _saving!;
    }
    return _saving = () async {
      try {
        do {
          _saveAgain = false;
          final json = jsonEncode({
            'ops': {for (final e in ops.entries) e.key: e.value.toJson()},
            'pdfs': pdfs.toList(),
            'delivered': delivered,
            'importing': importing,
          });
          await Directory(stateDir).create(recursive: true);
          final tmp = File('${_stateFile.path}.tmp');
          await tmp.writeAsString(json, flush: true);
          await tmp.rename(_stateFile.path);
        } while (_saveAgain);
      } finally {
        _saving = null;
      }
    }();
  }
}

enum OpType { put, delete }

class QueuedOp {
  new(this.type, {required this.writtenAt, required this.generation});

  factory fromJson(Map<String, dynamic> json) => QueuedOp(
    json['t'] == 'd' ? .delete : .put,
    writtenAt: json['w'] as int,
    generation: 0,
  );

  final OpType type;

  /// When the file was written, ms since epoch: for latency measurement.
  final int writtenAt;

  /// Bumped on every new write to the same path while it is queued.
  final int generation;

  Map<String, dynamic> toJson() => {
    't': type == .delete ? 'd' : 'p',
    'w': writtenAt,
  };

  @override
  String toString() => 'QueuedOp($type, gen $generation)';
}
