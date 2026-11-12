import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:quill/components/canvas/_stroke.dart';
import 'package:quill/components/canvas/image/editor_image.dart';
import 'package:quill/data/tools/_tool.dart';
import 'package:sbn/tool_id.dart';

class Select extends Tool {
  new _();

  static final _currentSelect = Select._();
  static Select get currentSelect => _currentSelect;

  /// The minimum ratio of points inside a stroke or image
  /// for it to be selected.
  static const minPercentInside = 0.7;

  var selectResult = SelectResult(
    pageIndex: -1,
    strokes: const [],
    images: const [],
    path: Path(),
    pageIndexStart: null,
  );
  var doneSelecting = false;

  @override
  ToolId get toolId => .select;

  void unselect() {
    doneSelecting = false;
    selectResult.pageIndex = -1;
  }

  Color? getDominantStrokeColor() {
    if (!doneSelecting) return null;
    if (selectResult.strokes.isEmpty) return null;

    final colorDistribution = <Color, int>{};
    for (final stroke in selectResult.strokes) {
      colorDistribution.update(
        stroke.color,
        (value) => value + stroke.length,
        ifAbsent: () => stroke.length,
      );
    }
    assert(colorDistribution.isNotEmpty);

    return colorDistribution.entries.reduce((a, b) {
      return a.value > b.value ? a : b;
    }).key;
  }

  void onDragStart(Offset position, int pageIndex) {
    doneSelecting = false;
    selectResult = SelectResult(
      pageIndex: pageIndex,
      strokes: [],
      images: [],
      path: Path(),
      pageIndexStart: pageIndex,
    );
    selectResult.path.moveTo(position.dx, position.dy);
    onDragUpdate(position);
  }

  void onDragUpdate(Offset position) {
    selectResult.path.lineTo(position.dx, position.dy);
  }

  /// Adds the indices of any [strokes] that are inside the selection area
  /// to [selectResult.indices].
  void onDragEnd(List<Stroke> strokes, List<EditorImage> images) {
    selectResult.path.close();
    doneSelecting = true;

    for (int i = 0; i < strokes.length; i++) {
      final stroke = strokes[i];
      final percentInside = polygonPercentInside(
        selectResult.path,
        stroke.lowQualityPolygon,
      );
      if (percentInside > minPercentInside) {
        selectResult.strokes.add(stroke);
      }
    }

    for (int i = 0; i < images.length; i++) {
      final image = images[i];
      final percentInside = rectPercentInside(selectResult.path, image.dstRect);
      if (percentInside >= minPercentInside) {
        selectResult.images.add(image);
      }
    }
  }

  /// How far (in page units, before zoom) a finger may be from a stroke
  /// and still count as touching it.
  static const touchSlop = 18.0;

  /// Selects what is under [position] for a press and hold: the stroke or
  /// image touched, plus the strokes written right next to it (a word or a
  /// phrase), or just the one stroke for a highlighter. Returns false and
  /// leaves the selection alone when nothing is there.
  bool selectAt(
    Offset position,
    int pageIndex,
    List<Stroke> strokes,
    List<EditorImage> images, {
    double zoom = 1,
  }) {
    final slop = touchSlop / max(zoom, 0.3);

    Stroke? hit;
    var hitDistance = double.infinity;
    for (final stroke in strokes) {
      final d = _distanceToPolyline(position, stroke.lowQualityPolygon);
      if (d <= slop && d <= hitDistance) {
        hit = stroke;
        hitDistance = d;
      }
    }

    final chosenStrokes = <Stroke>[];
    final chosenImages = <EditorImage>[];
    Rect bounds;

    if (hit != null) {
      if (hit.toolId == .highlighter) {
        chosenStrokes.add(hit);
        bounds = hit.lowQualityPath.getBounds();
      } else {
        // grow over neighbouring strokes: wide gaps along a line, narrow
        // ones between lines, so a word is taken and not the whole page
        bounds = hit.lowQualityPath.getBounds();
        chosenStrokes.add(hit);
        final pending = strokes
            .where((s) => s != hit && s.toolId != .highlighter)
            .toList();
        var grew = true;
        while (grew && chosenStrokes.length < 300) {
          grew = false;
          final reach = bounds;
          final searchArea = Rect.fromLTRB(
            reach.left - 14,
            reach.top - 3,
            reach.right + 14,
            reach.bottom + 3,
          );
          for (int i = pending.length - 1; i >= 0; i--) {
            final b = pending[i].lowQualityPath.getBounds();
            if (!searchArea.overlaps(b)) continue;
            chosenStrokes.add(pending.removeAt(i));
            bounds = bounds.expandToInclude(b);
            grew = true;
          }
        }
      }
    } else {
      EditorImage? image;
      for (final candidate in images.reversed) {
        if (candidate.dstRect.inflate(slop / 2).contains(position)) {
          image = candidate;
          break;
        }
      }
      if (image == null) return false;
      chosenImages.add(image);
      bounds = image.dstRect;
    }

    selectResult = SelectResult(
      pageIndex: pageIndex,
      strokes: chosenStrokes,
      images: chosenImages,
      path: Path()..addRect(bounds.inflate(6)),
      pageIndexStart: pageIndex,
    );
    doneSelecting = true;
    return true;
  }

  static double _distanceToPolyline(Offset p, List<Offset> points) {
    if (points.isEmpty) return double.infinity;
    if (points.length == 1) return (points.first - p).distance;
    var best = double.infinity;
    for (int i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      final ab = b - a;
      final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = lengthSquared == 0
          ? 0.0
          : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lengthSquared).clamp(
              0.0,
              1.0,
            );
      final d = (a + ab * t - p).distance;
      if (d < best) best = d;
    }
    return best;
  }

  /// The box around the selection, in page coordinates.
  Rect? get bounds => doneSelecting && selectResult.pageIndex >= 0
      ? selectResult.path.getBounds()
      : null;

  static double rectPercentInside(Path selection, Rect rect) {
    const int gridSize = 5;
    final gridCellWidth = rect.width / (gridSize - 1);
    final gridCellHeight = rect.height / (gridSize - 1);

    int pointsInside = 0;
    for (int x = 0; x < gridSize; x++) {
      for (int y = 0; y < gridSize; y++) {
        if (selection.contains(
          Offset(rect.left + gridCellWidth * x, rect.top + gridCellHeight * y),
        )) {
          pointsInside++;
        }
      }
    }

    // times 1.25 because the grid is not very accurate
    return pointsInside / (gridSize * gridSize) * 1.25;
  }

  static double polygonPercentInside(Path selection, List<Offset> polygon) {
    int pointsInside = 0;
    for (final point in polygon) {
      if (selection.contains(point)) {
        pointsInside++;
      }
    }
    return pointsInside / polygon.length;
  }
}

class SelectResult {
  int pageIndex;
  final List<Stroke> strokes;
  final List<EditorImage> images;
  Path path;
  int? pageIndexStart;

  new({
    required this.pageIndex,
    required this.strokes,
    required this.images,
    required this.path,
    required this.pageIndexStart,
  });

  bool get isEmpty {
    return strokes.isEmpty && images.isEmpty;
  }

  SelectResult copyWith({
    int? pageIndex,
    List<Stroke>? strokes,
    List<EditorImage>? images,
    Path? path,
    int? pageIndexStart,
  }) {
    return SelectResult(
      pageIndex: pageIndex ?? this.pageIndex,
      strokes: strokes ?? this.strokes,
      images: images ?? this.images,
      path: path ?? this.path,
      pageIndexStart: pageIndexStart ?? this.pageIndexStart,
    );
  }
}
