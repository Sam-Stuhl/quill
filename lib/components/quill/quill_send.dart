import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:quill/data/editor/editor_core_info.dart';
import 'package:quill/data/editor/editor_exporter.dart';
import 'package:quill/data/quill_sync/quill_connect.dart';

/// The editor's two ways to hand a note on (export bar, "ATLAS" and "Canvas"):
/// a page or the finished PDF to ATLAS's shelf, and the PDF to Canvas as a
/// proposal that Sam taps Submit on. Nothing here submits anything.
abstract class QuillSend {
  /// Shown only when this build has Quill sync configured.
  static bool get available => QuillConnect.instance != null;

  static Future<void> toAtlas(
    BuildContext context,
    EditorCoreInfo coreInfo,
    int pageIndex,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showDialog<_AtlasChoice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Send to ATLAS'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _AtlasChoice.page),
            child: Text('This page (page ${pageIndex + 1}, PNG)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _AtlasChoice.pdf),
            child: const Text('The whole note (PDF)'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    await _run(messenger, 'ATLAS', () async {
      final page = choice == _AtlasChoice.page;
      final bytes = page
          ? await _pagePng(coreInfo, pageIndex)
          : await _pdf(coreInfo, context);
      return QuillConnect.instance!.sendToAtlas(
        note: _note(coreInfo, page ? pageIndex : null),
        page: page,
        bytes: bytes,
      );
    });
  }

  static Future<void> toCanvas(
    BuildContext context,
    EditorCoreInfo coreInfo,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final connect = QuillConnect.instance!;
    final all = QuillConnect.courses.value;
    final here = QuillConnect.courseOfPath(coreInfo.filePath);
    final courses = here != null ? [here] : all;
    final options =
        [
          for (final c in courses)
            for (final a in c.assignments) (course: c, assignment: a),
        ]..sort(
          (a, b) => a.assignment.submitted == b.assignment.submitted
              ? 0
              : (a.assignment.submitted ? 1 : -1),
        );
    if (options.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No Canvas assignments to submit to')),
      );
      return;
    }
    final picked = await showDialog<QuillAssignment>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Submit to Canvas'),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o.assignment),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(o.assignment.name),
                subtitle: Text(
                  '${o.course.code}'
                  '${o.assignment.dueAt == null ? '' : ', ${QuillConnect.dueLabel(QuillDue(name: o.assignment.name, dueAt: o.assignment.dueAt!)).toLowerCase()}'}'
                  '${o.assignment.submitted ? ', already submitted' : ''}',
                ),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    await _run(messenger, 'Canvas', () async {
      final bytes = await _pdf(coreInfo, context);
      return connect.proposeToCanvas(
        note: _note(coreInfo, null),
        assignment: picked,
        bytes: bytes,
      );
    });
  }

  static Future<void> _run(
    ScaffoldMessengerState messenger,
    String where,
    Future<String> Function() work,
  ) async {
    try {
      final said = await work();
      messenger.showSnackBar(SnackBar(content: Text(said)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not send to $where: $e')),
      );
    }
  }

  /// The note's path in Quill (no extension), with the page for a page send.
  static String _note(EditorCoreInfo coreInfo, int? pageIndex) {
    final base = coreInfo.filePath;
    return pageIndex == null ? base : '$base page ${pageIndex + 1}';
  }

  static Future<Uint8List> _pdf(
    EditorCoreInfo coreInfo,
    BuildContext context,
  ) async {
    final pdf = await EditorExporter.generatePdf(coreInfo, context);
    return pdf.save();
  }

  static Future<Uint8List> _pagePng(
    EditorCoreInfo coreInfo,
    int pageIndex,
  ) async {
    final page = coreInfo.pages[pageIndex];
    const maxRasterizableSize = 3000.0;
    var ratio = maxRasterizableSize / page.size.longestSide;
    if (ratio > 1) ratio = 1;
    final image = await EditorExporter.screenshotPage(
      coreInfo: coreInfo,
      pageIndex: pageIndex,
      rasterizeAllStrokes: true,
      pixelRatio: ratio,
    );
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}

enum _AtlasChoice { page, pdf }
