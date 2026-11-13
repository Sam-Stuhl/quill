import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:keybinder/keybinder.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quill/components/canvas/hud/canvas_hud.dart';
import 'package:quill/components/canvas/interactive_canvas.dart';
import 'package:quill/data/editor/page.dart';
import 'package:quill/data/extensions/change_notifier_extensions.dart';
import 'package:quill/data/extensions/matrix4_extensions.dart';
import 'package:quill/data/input_trace.dart';
import 'package:quill/data/palm_rejection.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/touch_gestures.dart';
import 'package:quill/pages/editor/editor.dart';
import 'package:vector_math/vector_math_64.dart';

class CanvasGestureDetector extends StatefulWidget {
  new({
    super.key,
    required this.filePath,
    required this.isDrawGesture,
    this.onInteractionEnd,
    required this.onDrawStart,
    required this.onDrawUpdate,
    required this.onDrawEnd,
    required this.updatePointerData,
    required this.onHovering,
    required this.onHoveringEnd,
    required this.onStylusButtonChanged,
    required this.undo,
    required this.redo,
    required this.onTouchAction,
    this.onTouchCancelledByPen,
    this.onLongPress,
    this.onTap,
    required this.pages,
    required this.initialPageIndex,
    required this.pageBuilder,
    required this.placeholderPageBuilder,
    required this.isTextEditing,
    TransformationController? transformationController,
  }) : _transformationController =
           transformationController ?? TransformationController();

  final String filePath;

  final bool Function(ScaleStartDetails scaleDetails) isDrawGesture;
  final ValueChanged<ScaleEndDetails>? onInteractionEnd;
  final ValueChanged<ScaleStartDetails> onDrawStart;
  final ValueChanged<ScaleUpdateDetails> onDrawUpdate;
  final ValueChanged<ScaleEndDetails> onDrawEnd;

  /// Called when the pressure of the stylus changes.
  /// The [pressure] value is normalized into a range of 0 to 1.
  final void Function(PointerDeviceKind kind, double? pressure)
  updatePointerData;
  final VoidCallback onHovering;
  final VoidCallback onHoveringEnd;
  final ValueChanged<bool> onStylusButtonChanged;

  final VoidCallback undo;
  final VoidCallback redo;

  /// Called when a mapped tap gesture (Settings, Gestures) is performed.
  final ValueChanged<TouchAction> onTouchAction;

  /// The Pencil arrived while a finger or palm was already down: drop any
  /// stroke that touch was drawing.
  final VoidCallback? onTouchCancelledByPen;

  /// A single finger held still on the canvas (global position).
  final ValueChanged<Offset>? onLongPress;

  /// A single finger tapped the canvas quickly (global position).
  final ValueChanged<Offset>? onTap;

  final List<EditorPage> pages;
  final int? initialPageIndex;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final Widget Function(BuildContext context, int pageIndex)
  placeholderPageBuilder;

  final bool Function() isTextEditing;

  late final TransformationController _transformationController;

  @override
  State<CanvasGestureDetector> createState() => CanvasGestureDetectorState();

  static const kMinScale = 0.3;
  static const kMaxScale = 10.0;

  static double getTopOfPage({
    required int pageIndex,
    required List<EditorPage> pages,
    required double screenWidth,
  }) {
    if (pageIndex <= 0) return 0;

    double top = 0;

    for (int i = 0; i < pageIndex && i < pages.length; i++) {
      final pageSize = pages[i].size;

      /// Since we use a FittedBox, the actual width of the page
      /// is the minimum of the page width and the screen width.
      final pageWidthFitted = min(pageSize.width, screenWidth);

      top += 16;
      top += pageSize.height * (pageWidthFitted / pageSize.width);
    }

    return top;
  }

  static void scrollToPage({
    required int pageIndex,
    required List<EditorPage> pages,
    required double screenWidth,
    required TransformationController transformationController,
  }) {
    final topOfPage = -CanvasGestureDetector.getTopOfPage(
      pageIndex: pageIndex,
      pages: pages,
      screenWidth: screenWidth,
    );
    transformationController.value = Matrix4.translationValues(
      0,
      // Slight upwards offset so that the page is not flush with the top of the screen
      topOfPage + 50,
      0,
    );
  }

  static int getPageIndex({
    required double scrollY,
    required List<EditorPage> pages,
    required double screenWidth,
  }) {
    if (scrollY <= 0) return 0;

    double top = 0;

    for (int i = 0; i < pages.length; i++) {
      final pageSize = pages[i].size;

      /// Since we use a FittedBox, the actual width of the page
      /// is the minimum of the page width and the screen width.
      final pageWidthFitted = min(pageSize.width, screenWidth);

      top += 16;
      top += pageSize.height * (pageWidthFitted / pageSize.width);

      if (top > scrollY) return i;
    }

    return pages.length - 1;
  }
}

class CanvasGestureDetectorState extends State<CanvasGestureDetector> {
  late var containerBounds = const BoxConstraints();

  @visibleForTesting
  Matrix4 get transform => widget._transformationController.value;

  /// If zooming is locked, this is the zoom level.
  /// Otherwise, this is null.
  late double? zoomLockedValue = stows.lastZoomLock.value
      ? widget._transformationController.value.approxScale
      : null;

  /// Whether single-finger panning is locked.
  /// Two-finger panning is always enabled.
  late bool singleFingerPanLock = stows.lastSingleFingerPanLock.value;

  /// Whether panning is locked to being horizontal or vertical.
  /// Otherwise, panning can be done in any (i.e. diagonal) direction.
  late bool axisAlignedPanLock = stows.lastAxisAlignedPanLock.value;

  void zoomIn() => widget._transformationController.value =
      setZoom(
        scaleDelta: 0.1,
        transformation: widget._transformationController.value,
        containerBounds: containerBounds,
      ) ??
      widget._transformationController.value;
  void zoomOut() => widget._transformationController.value =
      setZoom(
        scaleDelta: -0.1,
        transformation: widget._transformationController.value,
        containerBounds: containerBounds,
      ) ??
      widget._transformationController.value;
  @visibleForTesting
  static Matrix4? setZoom({
    required double scaleDelta,
    required Matrix4 transformation,
    required BoxConstraints containerBounds,
  }) {
    final oldScale = transformation.approxScale;
    final newScale = oldScale + scaleDelta;

    if (newScale < CanvasGestureDetector.kMinScale) return null;
    if (newScale > CanvasGestureDetector.kMaxScale) return null;

    final center = Vector3(
      containerBounds.maxWidth / 2,
      containerBounds.maxHeight / 2,
      0,
    );
    final translation =
        (transformation.getTranslation() - center) * (newScale / oldScale) +
        center;

    return Matrix4.translation(translation)
      ..scaleByDouble(newScale, newScale, newScale, 1);
  }

  final Map<AxisDirection, Timer> _arrowKeyPanTimers = {};
  void arrowKeyPan(AxisDirection direction, bool pressed) {
    _arrowKeyPanTimers.remove(direction)?.cancel();
    if (!pressed) return;

    // arrow keys are used to navigate around text
    if (widget.isTextEditing()) return;

    _arrowKeyPanNow(direction);

    // Wait for 200ms, then pan every 100ms
    const ms100 = Duration(milliseconds: 100);
    const ms200 = Duration(milliseconds: 200);
    _arrowKeyPanTimers[direction] = Timer(ms200, () {
      _arrowKeyPanTimers[direction] = Timer.periodic(ms100, (_) {
        _arrowKeyPanNow(direction);
      });
    });
  }

  void _arrowKeyPanNow(AxisDirection direction) {
    final transformation = widget._transformationController.value;
    const panAmount = 50.0;

    transformation.leftTranslateByDouble(
      switch (direction) {
        AxisDirection.left => panAmount,
        AxisDirection.right => -panAmount,
        AxisDirection.up => 0.0,
        AxisDirection.down => 0.0,
      },
      switch (direction) {
        AxisDirection.left => 0.0,
        AxisDirection.right => 0.0,
        AxisDirection.up => panAmount,
        AxisDirection.down => -panAmount,
      },
      0,
      1,
    );
    widget._transformationController.notifyListenersPlease();
  }

  var _setupKeybindings = false;
  late Keybinding _ctrlPlus, _ctrlEquals, _ctrlMinus;
  late Keybinding _leftKey, _rightKey, _upKey, _downKey;
  void _assignKeybindings() {
    _ctrlPlus = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.add),
    ], inclusive: true);
    _ctrlEquals = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.equal),
    ], inclusive: true);
    _ctrlMinus = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.minus),
    ], inclusive: true);
    Keybinder.bind(_ctrlPlus, zoomIn);
    Keybinder.bind(_ctrlEquals, zoomIn);
    Keybinder.bind(_ctrlMinus, zoomOut);

    _leftKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowLeft),
    ], inclusive: true);
    _rightKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowRight),
    ], inclusive: true);
    _upKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowUp),
    ], inclusive: true);
    _downKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowDown),
    ], inclusive: true);
    Keybinder.bind(
      _leftKey,
      (bool pressed) => arrowKeyPan(AxisDirection.left, pressed),
    );
    Keybinder.bind(
      _rightKey,
      (bool pressed) => arrowKeyPan(AxisDirection.right, pressed),
    );
    Keybinder.bind(
      _upKey,
      (bool pressed) => arrowKeyPan(AxisDirection.up, pressed),
    );
    Keybinder.bind(
      _downKey,
      (bool pressed) => arrowKeyPan(AxisDirection.down, pressed),
    );

    _setupKeybindings = true;
  }

  void _removeKeybindings() {
    if (!_setupKeybindings) return;
    _setupKeybindings = false;

    Keybinder.remove(_ctrlPlus);
    Keybinder.remove(_ctrlEquals);
    Keybinder.remove(_ctrlMinus);

    Keybinder.remove(_leftKey);
    Keybinder.remove(_rightKey);
    Keybinder.remove(_upKey);
    Keybinder.remove(_downKey);
    _arrowKeyPanTimers.forEach((_, timer) => timer.cancel());
  }

  @override
  void initState() {
    setInitialTransform();
    widget._transformationController.addListener(onTransformChanged);
    _assignKeybindings();
    stows.palmRejection.addListener(_onPalmSettingChanged);
    super.initState();
  }

  /// When the widget is created, we still have an empty coreInfo.
  /// Wait for note to be loaded before setting the initial transform.
  @override
  void didUpdateWidget(CanvasGestureDetector oldWidget) {
    if (oldWidget.initialPageIndex != widget.initialPageIndex ||
        oldWidget.filePath != widget.filePath) {
      setInitialTransform();
    }
    super.didUpdateWidget(oldWidget);
  }

  /// Sets the initial transform so that we're scrolled to the correct page.
  /// Has no effect if note hasn't yet loaded or if the user has already scrolled.
  void setInitialTransform() {
    // wait for note to be loaded
    if (widget.filePath.isEmpty) return;

    // don't override user's scroll
    if (!widget._transformationController.value.isIdentity()) return;

    final transformCacheItem = CanvasTransformCache.get(widget.filePath);

    if (transformCacheItem != null) {
      // if we're opening the same note, restore the last transform
      widget._transformationController.value = transformCacheItem.transform;
      if (zoomLockedValue != null) {
        zoomLockedValue = transformCacheItem.transform.approxScale;
      }
    } else if (widget.initialPageIndex != null) {
      // if we're opening a different note, scroll to the last recorded page
      CanvasGestureDetector.scrollToPage(
        pageIndex: widget.initialPageIndex!,
        pages: widget.pages,
        screenWidth: MediaQuery.sizeOf(context).width,
        transformationController: widget._transformationController,
      );
    }
  }

  Timer? _snapZoomTimer;

  /// Corrects the transform if it's out of bounds.
  /// If the scale is less than 1, centers the pages horizontally.
  /// Otherwise, prevents the user from scrolling past the edges.
  void onTransformChanged() {
    final scale = widget._transformationController.value.approxScale;
    final translation = widget._transformationController.value.getTranslation();

    double adjustmentX = 0;
    double adjustmentY = 0;

    // snap to 1.0x zoom
    _snapZoomTimer?.cancel();
    final diffFrom1 = (scale - 1).abs();
    // allow 0.001 leeway for floating point error
    if (diffFrom1 < 0.05 && diffFrom1 > 0.001)
      _snapZoomTimer = Timer(const Duration(milliseconds: 200), resetZoom);

    if (scale < 1) {
      // horizontally center pages if zoomed out
      final center = containerBounds.maxWidth * (1 - scale) / 2;
      adjustmentX = center - translation.x;
    } else {
      // if zoomed in, don't allow scrolling past the edges
      late final minX = containerBounds.maxWidth * (1 - scale);
      if (translation.x > 0) {
        adjustmentX = -translation.x;
      } else if (translation.x < minX) {
        adjustmentX = minX - translation.x;
      }

      if (translation.y > 0) {
        adjustmentY = -translation.y;
      }
    }

    if (adjustmentX.abs() > 0.1 || adjustmentY.abs() > 0.1) {
      widget._transformationController.value.leftTranslateByDouble(
        adjustmentX,
        adjustmentY,
        0,
        1,
      );
    }
  }

  /// Resets the zoom level to 1.0x
  void resetZoom() {
    final transformation = widget._transformationController.value;
    final scale = transformation.approxScale;
    if (scale == 1) return;

    widget._transformationController.value =
        setZoom(
          scaleDelta: 1 - scale,
          transformation: transformation,
          containerBounds: containerBounds,
        ) ??
        transformation;
  }

  late final _tapClassifier = TouchTapClassifier();
  late final _tapResolver = TouchGestureResolver(
    actionFor: (gesture) => stows.touchGestureActions[gesture]!.value,
    onAction: widget.onTouchAction,
  );

  /// Press and hold: one finger kept still for this long.
  static const longPressDuration = Duration(milliseconds: 450);
  static const longPressSlop = 12.0;
  Timer? _longPressTimer;
  Offset? _longPressStart;

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressStart = null;
  }

  late final _palm = PalmRejection(enabled: stows.palmRejection.value);

  void _onPalmSettingChanged() => _palm.enabled = stows.palmRejection.value;

  /// The gesture recognizer sees a touch before palm rejection does, and
  /// resolves a gesture when the ignored touch is cancelled. Such a gesture has
  /// only ignored touches in it: it must neither draw nor pan (the input trace
  /// showed it leaving a dot, 2026-11-13).
  bool get _onlyRejectedTouchesDown =>
      _touchesDown.isNotEmpty &&
      _touchesDown.every(_palm.isRejected) &&
      !_palm.penActive;

  /// Touch pointers currently down, so a palm that landed before the pen can be
  /// cancelled when the pen arrives.
  final Set<int> _touchesDown = {};

  /// Page position when the first touch of the current set landed, so a pan a
  /// palm caused before the pen arrived can be taken back.
  Matrix4? _transformBeforeTouch;

  void _undoPalmEffects() {
    if (_touchesDown.isEmpty) return;
    InputTrace.log('pen arrived: undo palm ${_touchesDown.toList()}');
    final before = _transformBeforeTouch;
    if (before != null) widget._transformationController.value = before;
    _transformBeforeTouch = null;
    widget.onTouchCancelledByPen?.call();
  }

  void _cancelPointer(int pointer) {
    // Out of the current event dispatch: cancelling inside it can re-enter.
    // Out of the current event dispatch: cancelling inside it can re-enter.
    scheduleMicrotask(() {
      if (mounted) GestureBinding.instance.cancelPointer(pointer);
    });
  }

  /// Runs on every pointer event, before anything else looks at it.
  /// Returns true if the event is a touch that palm rejection swallowed.
  bool _palmRejects(PointerEvent event) {
    final rejected = _palmRejectsInner(event);
    if ((InputTrace.enabled || InputTrace.sink != null) &&
        event is! PointerHoverEvent) {
      InputTrace.pointer(rejected ? 'REJECT' : 'pass', event);
    }
    return rejected;
  }

  bool _palmRejectsInner(PointerEvent event) {
    final isStylus =
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    if (isStylus) {
      final wasActive = _palm.penActive;
      _palm.stylusEvent(
        event.pointer,
        down: event is PointerDownEvent,
        up: event is PointerUpEvent || event is PointerCancelEvent,
      );
      if (!wasActive && _palm.penActive) {
        // The pen just arrived: whatever is already touching is a palm.
        _undoPalmEffects();
        for (final pointer in _touchesDown.toList()) {
          _palm.rejected.add(pointer);
          _cancelPointer(pointer);
        }
      }
      return false;
    }
    if (event.kind != PointerDeviceKind.touch) return false;

    if (event is PointerDownEvent) {
      if (_touchesDown.isEmpty) {
        _transformBeforeTouch = widget._transformationController.value.clone();
      }
      _touchesDown.add(event.pointer);
      if (_palm.touchDown(event.pointer, radius: event.radiusMajor)) {
        // So the editor never takes this touch for the pen it saw last.
        widget.updatePointerData(PointerDeviceKind.touch, null);
        _cancelPointer(event.pointer);
        return true;
      }
      return false;
    }
    final rejected = _palm.isRejected(event.pointer);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touchesDown.remove(event.pointer);
      if (_touchesDown.isEmpty) _transformBeforeTouch = null;
      _palm.touchEnded(event.pointer);
    }
    return rejected;
  }

  void _classifyTouch(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (event is PointerDownEvent) {
      _tapClassifier.pointerDown(
        event.pointer,
        event.position,
        event.timeStamp,
      );
      _cancelLongPress();
      if (_tapClassifier.pointerCount == 1 && widget.onLongPress != null) {
        _longPressStart = event.position;
        _longPressTimer = Timer(longPressDuration, () {
          final position = _longPressStart;
          _cancelLongPress();
          if (position != null) widget.onLongPress?.call(position);
        });
      }
    } else if (event is PointerMoveEvent) {
      _tapClassifier.pointerMove(
        event.pointer,
        event.position,
        event.timeStamp,
      );
      final start = _longPressStart;
      if (start != null && (event.position - start).distance > longPressSlop) {
        _cancelLongPress();
      }
    } else if (event is PointerUpEvent) {
      _cancelLongPress();
      final fingers = _tapClassifier.pointerUp(event.pointer, event.timeStamp);
      if (fingers == null) return;
      if (fingers == 1) widget.onTap?.call(event.position);
      // With finger drawing on, a lone finger draws: leave it alone.
      if (fingers == 1 && stows.editorFingerDrawing.value) {
        _tapResolver.flush();
        return;
      }
      _tapResolver.onTap(fingers);
    } else if (event is PointerCancelEvent) {
      _cancelLongPress();
      _tapClassifier.pointerCancel(event.pointer);
    }
  }

  void _listenerPointerEvent(PointerEvent event) {
    if (event.kind == PointerDeviceKind.touch &&
        _palm.isRejected(event.pointer)) {
      return;
    }
    final isStylus =
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    if (isStylus && event is PointerDownEvent) {
      _detectStylusButton(event);
    }

    final double? pressure;
    if (isStylus) {
      if (event.pressureMin != event.pressureMax) {
        pressure = _inverseLerp(
          event.pressure,
          min: event.pressureMin,
          max: event.pressureMax,
        );
      } else {
        // Detected as stylus, but no pressure values
        pressure = null;
      }
    } else {
      pressure = null;
    }
    widget.updatePointerData(event.kind, pressure);

    if (isStylus &&
        stows.autoDisableFingerDrawingWhenStylusDetected.value &&
        // Don't change if the user has a fixed value for finger drawing
        !stows.hideFingerDrawingToggle.value) {
      stows.editorFingerDrawing.value = false;
    }
  }

  var stylusButtonWasPressed = false;

  void _listenerPointerHoverEvent(PointerEvent event) {
    if (event.kind != .stylus && event.kind != .invertedStylus) return;

    // Apparently flutter synthesizes a hover event on pointer down,
    // so these are used to detect when hovering ends
    if (event.synthesized) {
      widget.onHoveringEnd();
    } else {
      widget.onHovering();
    }

    _detectStylusButton(event);
  }

  void _detectStylusButton(PointerEvent event) {
    final pressed =
        event.buttons == kSecondaryButton || event.kind == .invertedStylus;
    if (stylusButtonWasPressed != pressed) {
      stylusButtonWasPressed = pressed;
      widget.onStylusButtonChanged(pressed);
    }
  }

  void _listenerPointerUpEvent(PointerEvent event) {
    _classifyTouch(event);
    widget.updatePointerData(event.kind, null);
    if (stylusButtonWasPressed) {
      stylusButtonWasPressed = false;
      widget.onStylusButtonChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.sizeOf(context);

    return Stack(
      children: [
        Listener(
          onPointerDown: (event) {
            if (_palmRejects(event)) return;
            _classifyTouch(event);
            _listenerPointerEvent(event);
          },
          onPointerMove: (event) {
            if (_palmRejects(event)) return;
            _classifyTouch(event);
            _listenerPointerEvent(event);
          },
          onPointerUp: (event) {
            if (_palmRejects(event)) return;
            _listenerPointerUpEvent(event);
          },
          onPointerCancel: (event) {
            if (_palmRejects(event)) return;
            _classifyTouch(event);
          },
          onPointerHover: (event) {
            _palmRejects(event);
            _listenerPointerHoverEvent(event);
          },
          child: GestureDetector(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints containerBounds) {
                this.containerBounds = containerBounds;

                return InteractiveCanvasViewer.builder(
                  minScale: zoomLockedValue ?? CanvasGestureDetector.kMinScale,
                  maxScale: zoomLockedValue ?? CanvasGestureDetector.kMaxScale,
                  panEnabled: !singleFingerPanLock,
                  panAxis: axisAlignedPanLock ? PanAxis.aligned : PanAxis.free,

                  // Smoother scrolling fling gesture than the default
                  interactionEndFrictionCoefficient: 0.1,

                  // we need a non-zero boundary margin so we can zoom out
                  // past the size of the page (for minScale < 1)
                  boundaryMargin: .symmetric(
                    vertical: 0,
                    horizontal: screenSize.width * 2,
                  ),

                  transformationController: widget._transformationController,

                  isDrawGesture: widget.isDrawGesture,
                  ignoreGesture: () => _onlyRejectedTouchesDown,
                  onInteractionEnd: widget.onInteractionEnd,
                  onDrawStart: widget.onDrawStart,
                  onDrawUpdate: widget.onDrawUpdate,
                  onDrawEnd: widget.onDrawEnd,

                  builder: (BuildContext context, Quad viewport) {
                    return _PagesBuilder(
                      pages: widget.pages,
                      pageBuilder: widget.pageBuilder,
                      placeholderPageBuilder: widget.placeholderPageBuilder,
                      boundingBox: _axisAlignedBoundingBox(viewport),
                      containerWidth: containerBounds.maxWidth,
                    );
                  },
                );
              },
            ),
          ),
        ),
        Positioned.fill(
          child: CanvasHud(
            transformationController: widget._transformationController,
            zoomLock: zoomLockedValue != null,
            setZoomLock: (bool zoomLock) => setState(() {
              zoomLockedValue = zoomLock
                  ? widget._transformationController.value.approxScale
                  : null;
              stows.lastZoomLock.value = zoomLock;
            }),
            resetZoom: zoomLockedValue != null ? null : resetZoom,
            singleFingerPanLock: singleFingerPanLock,
            setSingleFingerPanLock: (bool singleFingerPanLock) => setState(() {
              this.singleFingerPanLock = singleFingerPanLock;
              stows.lastSingleFingerPanLock.value = singleFingerPanLock;
            }),
            axisAlignedPanLock: axisAlignedPanLock,
            setAxisAlignedPanLock: (bool axisAlignedPanLock) => setState(() {
              this.axisAlignedPanLock = axisAlignedPanLock;
              stows.lastAxisAlignedPanLock.value = axisAlignedPanLock;
            }),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    CanvasTransformCache.add(
      widget.filePath,
      widget._transformationController.value,
    );
    widget._transformationController.removeListener(onTransformChanged);
    widget._transformationController.dispose();
    stows.palmRejection.removeListener(_onPalmSettingChanged);
    _removeKeybindings();
    _cancelLongPress();
    _tapResolver.dispose();
    super.dispose();
  }

  /// Returns the axis aligned bounding box for the given Quad,
  /// which might not be axis aligned.
  /// From https://api.flutter.dev/flutter/widgets/InteractiveViewer/builder.html
  static Rect _axisAlignedBoundingBox(Quad quad) {
    final List<Vector3> points = [
      quad.point0,
      quad.point1,
      quad.point2,
      quad.point3,
    ];

    final left = points.map((point) => point.x).reduce(min);
    final right = points.map((point) => point.x).reduce(max);
    final top = points.map((point) => point.y).reduce(min);
    final bottom = points.map((point) => point.y).reduce(max);

    return .fromLTRB(left, top, right, bottom);
  }
}

class _PagesBuilder extends StatelessWidget {
  const new({
    required this.pages,
    required this.pageBuilder,
    required this.placeholderPageBuilder,
    required this.boundingBox,
    required this.containerWidth,
  });

  final List<EditorPage> pages;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final Widget Function(BuildContext context, int pageIndex)
  placeholderPageBuilder;
  final Rect boundingBox;
  final double containerWidth;

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = [
      const SizedBox.square(dimension: Editor.gapBetweenPages),
      const SizedBox.square(dimension: Editor.gapBetweenPages),
    ];

    double topOfPage = Editor.gapBetweenPages * 2;
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final page = pages[pageIndex];
      final pageWidth = min(
        page.size.width,
        containerWidth,
      ); // because of FittedBox
      final pageHeight = pageWidth / page.size.width * page.size.height;
      final bottomOfPage = topOfPage + pageHeight;

      final isFocused = page.quill.focusNode.hasFocus;
      final isInViewport =
          boundingBox.bottom >= topOfPage && boundingBox.top <= bottomOfPage;
      final shouldRender = isFocused || isInViewport;

      page.isRendered = shouldRender;
      children.add(
        shouldRender
            ? pageBuilder(context, pageIndex)
            : placeholderPageBuilder(context, pageIndex),
      );

      children.add(const SizedBox.square(dimension: Editor.gapBetweenPages));

      topOfPage = bottomOfPage + Editor.gapBetweenPages;
    }

    children.add(const SizedBox.square(dimension: Editor.gapBetweenPages));
    return Column(children: children);
  }
}

@visibleForTesting
class CanvasTransformCache {
  static const _maxCacheSize = 5;
  static final _cache = LinkedList<CanvasTransformCacheItem>();

  new _();

  static void add(String filePath, Matrix4 transform) {
    for (final entry in _cache) {
      if (entry.filePath != filePath) continue;
      entry.unlink();
      break;
    }
    _cache.add(CanvasTransformCacheItem(filePath, transform));

    if (_cache.length > _maxCacheSize) {
      _cache.first.unlink();
    }
  }

  static CanvasTransformCacheItem? get(String filePath) {
    try {
      return _cache.firstWhere((item) => item.filePath == filePath);
    } on StateError {
      return null;
    }
  }

  @visibleForTesting
  static void clear() {
    _cache.clear();
  }
}

@visibleForTesting
base class CanvasTransformCacheItem
    extends LinkedListEntry<CanvasTransformCacheItem> {
  final String filePath;
  final Matrix4 transform;

  new(this.filePath, this.transform);
}

double _inverseLerp(num value, {required num min, required num max}) {
  assert(max >= min, 'Max ($max) must be >= min ($min)');
  assert(
    value >= min && value <= max,
    'Value ($value) must be between $min and $max',
  );
  return (value - min) / (max - min);
}
