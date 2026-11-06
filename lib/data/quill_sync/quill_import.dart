import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/pages/editor/editor.dart';

/// Turns a file sent from the mini into a note, without the editor open.
/// See docs/quill-sync.md.
abstract class QuillImport {
  static const imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.heic',
  };

  /// Imports [bytes] (a file called [name]) into [folder], which starts and
  /// ends with a slash. Returns the new note's path without its extension.
  static Future<String> importBytes(
    Uint8List bytes, {
    required String folder,
    required String name,
  }) async {
    assert(folder.startsWith('/') && folder.endsWith('/'));
    final ext = p.extension(name).toLowerCase();
    final base = safeName(p.basenameWithoutExtension(name));
    await FileManager.createFolder(folder);

    if (ext == '.sba' || ext == Editor.extension) {
      final tmpDir = await Directory((await getTemporaryDirectory()).path)
          .createTemp('quill-import');
      try {
        final tmp = File(p.join(tmpDir.path, '$base$ext'));
        await tmp.writeAsBytes(bytes);
        final path = await FileManager.importFile(tmp.path, folder);
        if (path == null) throw Exception('Could not import $name');
        return path;
      } finally {
        await tmpDir.delete(recursive: true);
      }
    }

    final notePath = await FileManager.suffixFilePathToMakeItUnique(
      '$folder$base',
      intendedExtension: Editor.extension,
    );
    // No file there yet, so this is a fresh note, as the editor makes one.
    final coreInfo = await EditorCoreInfo.loadFromFilePath(notePath);
    PdfDocument? pdfDocument;
    try {
      if (ext == '.pdf') {
        pdfDocument = await PdfDocument.openData(bytes, sourceName: name);
        for (final pdfPage in pdfDocument.pages) {
          // Same sizing as the editor's own PDF import.
          final pageSize = Size(
            EditorPage.defaultWidth,
            EditorPage.defaultWidth * pdfPage.height / pdfPage.width,
          );
          coreInfo.pages.add(
            EditorPage(
              size: pageSize,
              backgroundImage: PdfEditorImage(
                id: coreInfo.nextImageId++,
                pdfBytes: bytes,
                pdfFile: null,
                pdfPage: pdfPage.pageNumber - 1,
                pageIndex: coreInfo.pages.length,
                pageSize: pageSize,
                naturalSize: pdfPage.size,
                onMoveImage: null,
                onDeleteImage: null,
                onMiscChange: null,
                assetCache: coreInfo.assetCache,
              ),
            ),
          );
        }
      } else if (imageExtensions.contains(ext)) {
        final naturalSize = await imageSize(bytes);
        final pageSize = Size(
          EditorPage.defaultWidth,
          EditorPage.defaultWidth * naturalSize.height / naturalSize.width,
        );
        coreInfo.pages.add(
          EditorPage(
            size: pageSize,
            backgroundImage: PngEditorImage(
              id: coreInfo.nextImageId++,
              extension: ext,
              imageProvider: MemoryImage(bytes),
              pageIndex: 0,
              pageSize: pageSize,
              naturalSize: naturalSize,
              srcRect: Offset.zero & naturalSize,
              dstRect: Offset.zero & pageSize,
              onMoveImage: null,
              onDeleteImage: null,
              onMiscChange: null,
              assetCache: coreInfo.assetCache,
            ),
          ),
        );
      } else {
        throw UnsupportedError('Quill cannot import $ext files');
      }
      if (coreInfo.pages.isEmpty) throw Exception('$name has no pages');
      // The editor keeps an empty page at the end to write on.
      coreInfo.pages.add(EditorPage());

      final (bson, assets) = coreInfo.saveToBinary(currentPageIndex: 0);
      final filePath = notePath + Editor.extension;
      // Assets first, so the note never points at a missing asset.
      for (var i = 0; i < assets.length; ++i) {
        await FileManager.writeFile(
          '$filePath.$i',
          await assets.getBytes(i),
          awaitWrite: true,
        );
      }
      await FileManager.writeFile(filePath, bson, awaitWrite: true);
      return notePath;
    } finally {
      await pdfDocument?.dispose();
      coreInfo.dispose();
    }
  }

  static Future<Size> imageSize(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    buffer.dispose();
    if (size.isEmpty) throw Exception('Image has no size');
    return size;
  }

  /// A file name the app accepts as a note name.
  static String safeName(String name) {
    var out = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    if (out.isEmpty || FileManager.validateFilename(out) != null) {
      out = 'Imported ${DateTime.now().toIso8601String().substring(0, 10)}';
    }
    return out;
  }

  /// Renders the note at [notePath] (no extension) to PDF bytes, headless.
  /// Returns null for a note with nothing on it.
  static Future<Uint8List?> renderPdf(String notePath) async {
    final coreInfo = await EditorCoreInfo.loadFromFilePath(notePath);
    try {
      if (coreInfo.readOnlyReason == .corrupted) {
        throw Exception('Could not read $notePath');
      }
      final pages = coreInfo.pages.toList();
      while (pages.isNotEmpty && pages.last.isEmpty) {
        pages.removeLast();
      }
      if (pages.isEmpty) return null;
      // PDF pages only load when a PdfPageView asks for them, and there is
      // none here, so start loading every PDF the note shows. The first
      // loadIn() then starts loading an image without waiting for it, and the
      // exporter waits no longer than that; a second loadIn() waits for it.
      // Without this an imported PDF could be missing from the export.
      final pdfDocuments = {
        for (final page in pages)
          for (final image in [?page.backgroundImage, ...page.images])
            if (image is PdfEditorImage)
              await coreInfo.assetCache.pdfDocumentCache.load(
                image.pdfFile?.path ?? 'inline_pdf_${image.id}.pdf',
                pdfBytes: image.pdfBytes,
              ),
      };
      await Future.wait([
        for (final document in pdfDocuments) document.loadPagesProgressively(),
      ]);
      await Future.wait([
        for (final page in pages)
          for (final image in [?page.backgroundImage, ...page.images])
            image.loadIn().then((_) => image.loadIn()),
      ]);
      // Same resolution as the exporter's screenshot (pixel ratio 2).
      await Future.wait([
        for (final page in pages)
          for (final image in [?page.backgroundImage, ...page.images])
            image.prerender(width: (page.size.width * 2).round()),
      ]);
      final pdf = await EditorExporter.generatePdf(
        coreInfo.copyWith(pages: pages),
      );
      return await pdf.save();
    } finally {
      coreInfo.dispose();
    }
  }
}
