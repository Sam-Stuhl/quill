import 'dart:io';

import 'package:collapsible/collapsible.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keybinder/keybinder.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/components/theming/adaptive_icon.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/components/theming/uni_icon.dart';
import 'package:saber/components/toolbar/color_bar.dart';
import 'package:saber/components/toolbar/export_bar.dart';
import 'package:saber/components/toolbar/pen_modal.dart';
import 'package:saber/components/toolbar/size_picker.dart';
import 'package:saber/components/toolbar/toolbar_button.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/i18n/strings.g.dart';

class Toolbar extends StatefulWidget {
  const new({
    super.key,
    required this.readOnly,
    required this.setTool,
    required this.currentTool,
    required this.setColor,
    required this.quillFocus,
    required this.textEditing,
    required this.toggleTextEditing,
    required this.undo,
    required this.isUndoPossible,
    required this.redo,
    required this.isRedoPossible,
    required this.toggleFingerDrawing,
    required this.pickPhoto,
    required this.paste,
    required this.exportAsSba,
    required this.exportAsPdf,
    required this.exportAsPng,
    this.exportToAtlas,
    this.exportToCanvas,
    this.header,
  });

  /// Back button, title and menus for the top layout. When the toolbar is
  /// aligned to the top and this is set, the toolbar draws the whole header
  /// (Notability's layout) and the editor shows no app bar of its own.
  final ToolbarHeader? header;

  final bool readOnly;

  final ValueChanged<Tool> setTool;
  final Tool currentTool;
  final ValueChanged<Color> setColor;

  final ValueNotifier<QuillStruct?> quillFocus;
  final bool textEditing;
  final VoidCallback toggleTextEditing;

  final VoidCallback undo;
  final bool isUndoPossible;
  final VoidCallback redo;
  final bool isRedoPossible;

  final VoidCallback toggleFingerDrawing;

  final VoidCallback pickPhoto;

  final VoidCallback paste;

  final Future Function(BuildContext)? exportAsSba;
  final Future Function(BuildContext)? exportAsPdf;
  final Future Function(BuildContext)? exportAsPng;
  final Future Function(BuildContext)? exportToAtlas;
  final Future Function(BuildContext)? exportToCanvas;

  @override
  State<Toolbar> createState() => _ToolbarState();

  static const _buttonPaddingHorizontal = EdgeInsets.symmetric(horizontal: 3);
  static const _buttonPaddingVertical = EdgeInsets.symmetric(vertical: 3);

  /// Height of the top layout's header row, below the status bar.
  static const topHeaderHeight = 68.0;

  /// Whether the toolbar draws the header: it is aligned to the top.
  static bool get usesTopLayout =>
      stows.editorToolbarAlignment.value == AxisDirection.up;
}

/// What the editor hands the toolbar for the top layout.
class ToolbarHeader {
  const new({
    required this.leading,
    required this.title,
    required this.onMore,
    required this.onPages,
  });

  final Widget leading;
  final Widget title;
  final VoidCallback onMore;
  final VoidCallback onPages;
}

class _ToolbarState extends State<Toolbar> {
  ValueNotifier<bool> showMoreTools = ValueNotifier(false);
  ValueNotifier<bool> showExportOptions = ValueNotifier(false);
  ValueNotifier<bool> showColorOptions = ValueNotifier(false);
  ValueNotifier<ToolOptions> toolOptionsType = ValueNotifier(ToolOptions.hide);

  @override
  void initState() {
    _assignKeybindings();

    DynamicMaterialApp.addFullscreenListener(_setState);

    super.initState();
  }

  void _setState() => setState(() {});

  Keybinding? _ctrlF;
  Keybinding? _ctrlE;
  Keybinding? _ctrlC;
  Keybinding? _ctrlShiftS;
  Keybinding? _f11;
  Keybinding? _ctrlV;
  void _assignKeybindings() {
    _ctrlF = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyF),
    ], inclusive: true);
    _ctrlE = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyE),
    ], inclusive: true);
    _ctrlC = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyC),
    ], inclusive: true);
    _ctrlShiftS = Keybinding([
      KeyCode.ctrl,
      KeyCode.shift,
      KeyCode.from(LogicalKeyboardKey.keyS),
    ], inclusive: true);
    _f11 = Keybinding([KeyCode.from(LogicalKeyboardKey.f11)], inclusive: true);
    _ctrlV = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyV),
    ], inclusive: true);

    Keybinder.bind(_ctrlF!, widget.toggleFingerDrawing);
    Keybinder.bind(_ctrlE!, toggleEraser);
    Keybinder.bind(_ctrlC!, toggleColorOptions);
    Keybinder.bind(_ctrlShiftS!, toggleExportBar);
    Keybinder.bind(_f11!, toggleFullscreen);
    Keybinder.bind(_ctrlV!, widget.paste);
  }

  void _removeKeybindings() {
    if (_ctrlF != null) Keybinder.remove(_ctrlF!);
    if (_ctrlE != null) Keybinder.remove(_ctrlE!);
    if (_ctrlC != null) Keybinder.remove(_ctrlC!);
    if (_ctrlShiftS != null) Keybinder.remove(_ctrlShiftS!);
    if (_f11 != null) Keybinder.remove(_f11!);
    if (_ctrlV != null) Keybinder.remove(_ctrlV!);
  }

  void toggleEraser() {
    toolOptionsType.value = .hide;
    widget.setTool(Eraser()); // this toggles eraser
  }

  void toggleColorOptions() {
    showColorOptions.value = !showColorOptions.value;
  }

  void toggleExportBar() {
    showExportOptions.value = !showExportOptions.value;
  }

  void toggleFullscreen() async {
    DynamicMaterialApp.setFullscreen(
      !DynamicMaterialApp.isFullscreen,
      updateSystem: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);

    final brightness = Theme.brightnessOf(context);
    final invert = stows.editorAutoInvert.value && brightness == .dark;

    final isToolbarVertical =
        stows.editorToolbarAlignment.value == AxisDirection.left ||
        stows.editorToolbarAlignment.value == AxisDirection.right;

    final buttonPadding = isToolbarVertical
        ? Toolbar._buttonPaddingVertical
        : Toolbar._buttonPaddingHorizontal;

    final currentColor = switch (widget.currentTool) {
      final Pen pen => pen.color,
      final Select select => select.getDominantStrokeColor(),
      _ => null,
    };

    final exportBar = ValueListenableBuilder(
      valueListenable: showExportOptions,
      builder: (context, showExportOptions, child) {
        return Collapsible(
          axis: isToolbarVertical
              ? CollapsibleAxis.horizontal
              : CollapsibleAxis.vertical,
          maintainState: true,
          collapsed: !showExportOptions,
          child: child!,
        );
      },
      child: ExportBar(
        axis: isToolbarVertical ? Axis.vertical : Axis.horizontal,
        toggleExportBar: toggleExportBar,
        exportAsSba: widget.exportAsSba,
        exportAsPdf: widget.exportAsPdf,
        exportAsPng: widget.exportAsPng,
        exportToAtlas: widget.exportToAtlas,
        exportToCanvas: widget.exportToCanvas,
      ),
    );
    final penOptions = ValueListenableBuilder(
      valueListenable: toolOptionsType,
      builder: (context, toolOptionsType, _) {
        return Collapsible(
          axis: isToolbarVertical
              ? CollapsibleAxis.horizontal
              : CollapsibleAxis.vertical,
          maintainState: true,
          collapsed: toolOptionsType == .hide,
          child: switch (toolOptionsType) {
            .hide => const SizedBox.square(dimension: SizePicker.smallLength),
            .pen => PenModal(
              getTool: () => Pen.currentPen,
              setTool: widget.setTool,
            ),
            .highlighter => PenModal(
              getTool: () => Highlighter.currentHighlighter,
              setTool: widget.setTool,
            ),
            .pencil => PenModal(
              getTool: () => Pencil.currentPencil,
              setTool: widget.setTool,
            ),
          },
        );
      },
    );
    final colorBar = ValueListenableBuilder(
      valueListenable: showColorOptions,
      builder: (context, showColorOptions, child) {
        return Collapsible(
          axis: isToolbarVertical
              ? CollapsibleAxis.horizontal
              : CollapsibleAxis.vertical,
          maintainState: true,
          collapsed: !showColorOptions,
          child: child!,
        );
      },
      child: ColorBar(
        axis: isToolbarVertical ? Axis.vertical : Axis.horizontal,
        setColor: widget.setColor,
        currentColor: currentColor,
        invert: invert,
      ),
    );
    final quillBar = ValueListenableBuilder(
      valueListenable: widget.quillFocus,
      builder: (context, quill, _) {
        final baseButtonStyle =
            IconButtonTheme.of(context).style ?? const ButtonStyle();

        final iconTheme = QuillIconTheme(
          iconButtonUnselectedData: IconButtonData(
            style: baseButtonStyle.copyWith(
              backgroundColor: WidgetStateProperty.all(Colors.transparent),
              foregroundColor: WidgetStateProperty.all(colorScheme.primary),
            ),
          ),
          iconButtonSelectedData: IconButtonData(
            style: baseButtonStyle.copyWith(
              backgroundColor: WidgetStateProperty.all(colorScheme.primary),
              foregroundColor: WidgetStateProperty.all(colorScheme.onPrimary),
            ),
          ),
        );
        return Collapsible(
          axis: isToolbarVertical
              ? CollapsibleAxis.horizontal
              : CollapsibleAxis.vertical,
          maintainState: false,
          collapsed: !widget.textEditing || quill == null,
          child: quill != null
              ? QuillSimpleToolbar(
                  controller: quill.controller,
                  config: QuillSimpleToolbarConfig(
                    axis: isToolbarVertical ? Axis.vertical : Axis.horizontal,
                    buttonOptions: QuillSimpleToolbarButtonOptions(
                      base: QuillToolbarBaseButtonOptions(iconTheme: iconTheme),
                    ),
                    // scrollable on Android and iOS
                    multiRowsDisplay: !Platform.isAndroid && !Platform.isIOS,
                    showUndo: false,
                    showRedo: false,
                    showFontSize: false,
                    showFontFamily: false,
                    showClearFormat: false,
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    );
    final buttonRow = Builder(
      builder: (context) {
        final tools = <Widget>[
          ToolbarIconButton(
            tooltip: Pen.currentPen.name,
            selected: widget.currentTool == Pen.currentPen,
            enabled: !widget.readOnly,
            onPressed: () {
              if (widget.currentTool == Pen.currentPen) {
                if (toolOptionsType.value == .pen) {
                  toolOptionsType.value = .hide;
                } else {
                  toolOptionsType.value = .pen;
                }
              } else {
                toolOptionsType.value = .hide;
                widget.setTool(Pen.currentPen);
              }
            },
            padding: buttonPadding,
            child: UniIcon(Pen.currentPen.icon, size: 16),
          ),
          ToolbarIconButton(
            tooltip: t.editor.pens.pencil,
            selected: widget.currentTool == Pencil.currentPencil,
            enabled: !widget.readOnly,
            onPressed: () {
              if (widget.currentTool == Pencil.currentPencil) {
                if (toolOptionsType.value == .pencil) {
                  toolOptionsType.value = .hide;
                } else {
                  toolOptionsType.value = .pencil;
                }
              } else {
                toolOptionsType.value = .hide;
                widget.setTool(Pencil.currentPencil);
              }
            },
            padding: buttonPadding,
            child: const FaIcon(Pencil.pencilIcon, size: 16),
          ),
          ToolbarIconButton(
            tooltip: t.editor.pens.highlighter,
            selected: widget.currentTool == Highlighter.currentHighlighter,
            enabled: !widget.readOnly,
            onPressed: () {
              if (widget.currentTool == Highlighter.currentHighlighter) {
                if (toolOptionsType.value == .highlighter) {
                  toolOptionsType.value = .hide;
                } else {
                  toolOptionsType.value = .highlighter;
                }
              } else {
                toolOptionsType.value = .hide;
                widget.setTool(Highlighter.currentHighlighter);
              }
            },
            padding: buttonPadding,
            child: const FaIcon(Highlighter.highlighterIcon, size: 16),
          ),
          ValueListenableBuilder(
            valueListenable: showColorOptions,
            builder: (context, showColorOptions, child) {
              return ToolbarIconButton(
                tooltip: t.editor.toolbar.toggleColors,
                selected: showColorOptions,
                enabled: !widget.readOnly,
                onPressed: toggleColorOptions,
                padding: buttonPadding,
                child: child!,
              );
            },
            child: currentColor == null
                ? const Icon(Icons.palette)
                : Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: currentColor
                          .withInversion(invert)
                          .withValues(alpha: 1),
                      shape: .circle,
                      border: Border.all(color: colorScheme.primary, width: 2),
                    ),
                  ),
          ),
          ToolbarIconButton(
            tooltip: t.editor.toolbar.select,
            selected: widget.currentTool is Select,
            enabled: !widget.readOnly,
            onPressed: () {
              toolOptionsType.value = .hide;
              widget.setTool(Select.currentSelect);
            },
            padding: buttonPadding,
            child: Icon(
              CupertinoIcons.lasso,
              shadows: !widget.readOnly
                  ? [
                      BoxShadow(
                        color: colorScheme.primary,
                        blurRadius: 0.1,
                        spreadRadius: 10,
                        blurStyle: BlurStyle.solid,
                      ),
                    ]
                  : null,
            ),
          ),
          ToolbarIconButton(
            tooltip: t.editor.pens.laserPointer,
            selected: widget.currentTool == LaserPointer.currentLaserPointer,
            enabled: true, // even in read-only mode
            onPressed: () {
              toolOptionsType.value = .hide;
              widget.setTool(LaserPointer.currentLaserPointer);
            },
            padding: buttonPadding,
            child: const Icon(Symbols.stylus_laser_pointer),
          ),
          ToolbarIconButton(
            tooltip: t.editor.toolbar.toggleEraser,
            selected: widget.currentTool is Eraser,
            enabled: !widget.readOnly,
            onPressed: toggleEraser,
            padding: buttonPadding,
            child: const FaIcon(FontAwesomeIcons.eraser, size: 16),
          ),
          ToolbarIconButton(
            tooltip: t.editor.toolbar.photo,
            enabled: !widget.readOnly,
            onPressed: widget.pickPhoto,
            padding: buttonPadding,
            child: const AdaptiveIcon(
              icon: Icons.photo,
              cupertinoIcon: CupertinoIcons.photo,
            ),
          ),
          ToolbarIconButton(
            tooltip: t.editor.toolbar.text,
            selected: widget.textEditing,
            enabled: !widget.readOnly,
            onPressed: widget.toggleTextEditing,
            padding: buttonPadding,
            child: const AdaptiveIcon(
              icon: Icons.text_fields,
              cupertinoIcon: CupertinoIcons.text_cursor,
            ),
          ),
          if (!stows.hideFingerDrawingToggle.value)
            ValueListenableBuilder(
              valueListenable: stows.editorFingerDrawing,
              builder: (context, value, child) {
                return ToolbarIconButton(
                  tooltip: t.editor.toolbar.toggleFingerDrawing,
                  selected: value,
                  enabled: !widget.readOnly,
                  onPressed: widget.toggleFingerDrawing,
                  padding: buttonPadding,
                  child: const Icon(CupertinoIcons.hand_draw),
                );
              },
            ),
          ToolbarIconButton(
            tooltip: t.editor.toolbar.fullscreen,
            selected: DynamicMaterialApp.isFullscreen,
            enabled: !widget.readOnly,
            onPressed: toggleFullscreen,
            padding: buttonPadding,
            child: AdaptiveIcon(
              icon: DynamicMaterialApp.isFullscreen
                  ? Icons.fullscreen_exit
                  : Icons.fullscreen,
              cupertinoIcon: DynamicMaterialApp.isFullscreen
                  ? CupertinoIcons.fullscreen_exit
                  : CupertinoIcons.fullscreen,
            ),
          ),
        ];
        final trailing = <Widget>[
          ToolbarIconButton(
            tooltip: t.editor.toolbar.undo,
            enabled: !widget.readOnly && widget.isUndoPossible,
            onPressed: widget.undo,
            padding: buttonPadding,
            child: const AdaptiveIcon(
              icon: Icons.undo,
              cupertinoIcon: CupertinoIcons.arrow_uturn_left,
            ),
          ),
          ToolbarIconButton(
            tooltip: t.editor.toolbar.redo,
            enabled: !widget.readOnly && widget.isRedoPossible,
            onPressed: widget.redo,
            padding: buttonPadding,
            child: const AdaptiveIcon(
              icon: Icons.redo,
              cupertinoIcon: CupertinoIcons.arrow_uturn_right,
            ),
          ),
          ValueListenableBuilder(
            valueListenable: showExportOptions,
            builder: (context, showExportOptions, child) {
              return ToolbarIconButton(
                tooltip: t.editor.toolbar.export,
                selected: showExportOptions,
                enabled: !widget.readOnly,
                onPressed: toggleExportBar,
                padding: buttonPadding,
                child: child!,
              );
            },
            child: const AdaptiveIcon(
              icon: Icons.share,
              cupertinoIcon: CupertinoIcons.share,
            ),
          ),
        ];

        if (isToolbarVertical) {
          return Center(
            child: Padding(
              padding: const .all(8),
              child: Wrap(
                direction: Axis.vertical,
                alignment: WrapAlignment.center,
                runSpacing: 8,
                children: [...tools, ...trailing],
              ),
            ),
          );
        }

        // Notability's layout: drawing tools centred in one row, undo,
        // redo and share pinned to the trailing edge, away from the pen.
        return Padding(
          padding: const .all(8),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: tools,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ...trailing,
            ],
          ),
        );
      },
    );

    if (Toolbar.usesTopLayout && widget.header != null) {
      return _topLayout(
        context,
        exportBar: exportBar,
        penOptions: penOptions,
        quillBar: quillBar,
        currentColor: currentColor,
        invert: invert,
      );
    }

    final bars = <Widget>[exportBar, penOptions, colorBar, quillBar, buttonRow];

    return Flex(
      direction: isToolbarVertical ? Axis.horizontal : Axis.vertical,
      textDirection: switch (stows.editorToolbarAlignment.value) {
        AxisDirection.left => .rtl,
        AxisDirection.right => .ltr,
        _ => null,
      },
      verticalDirection: switch (stows.editorToolbarAlignment.value) {
        AxisDirection.down => VerticalDirection.down,
        AxisDirection.up => VerticalDirection.up,
        _ => VerticalDirection.down,
      },
      children: bars,
    );
  }

  /// Notability's layout, measured from its screenshots on the iPad: a header
  /// band with a back button at the left, the note's title behind a floating
  /// pill of tools, and a pill of undo, redo and menus at the right. Colours
  /// sit in a second row under the tools, inside the same pill.
  Widget _topLayout(
    BuildContext context, {
    required Widget exportBar,
    required Widget penOptions,
    required Widget quillBar,
    required Color? currentColor,
    required bool invert,
  }) {
    final header = widget.header!;
    final colorScheme = ColorScheme.of(context);
    final headerColor =
        Theme.of(context).appBarTheme.backgroundColor ?? colorScheme.surface;
    final pillColor = Theme.brightnessOf(context) == .dark
        ? colorScheme.surfaceContainerLowest
        : colorScheme.surfaceContainerHigh;
    final pillDecoration = BoxDecoration(
      color: pillColor,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: colorScheme.outlineVariant),
    );

    Widget pill({required Widget child}) =>
        DecoratedBox(decoration: pillDecoration, child: child);

    void toggleOptions(ToolOptions options, Tool tool) {
      if (widget.currentTool == tool) {
        toolOptionsType.value = toolOptionsType.value == options
            ? .hide
            : options;
      } else {
        toolOptionsType.value = .hide;
        widget.setTool(tool);
      }
    }

    final drawing = currentColor != null;
    final fingerDrawing = stows.hideFingerDrawingToggle.value
        ? null
        : ValueListenableBuilder(
            valueListenable: stows.editorFingerDrawing,
            builder: (context, value, child) => _PillButton(
              tooltip: t.editor.toolbar.toggleFingerDrawing,
              selected: value,
              enabled: !widget.readOnly,
              onPressed: widget.toggleFingerDrawing,
              child: const Icon(CupertinoIcons.hand_draw),
            ),
          );

    final mainTools = <Widget>[
      _PillButton(
        tooltip: Pen.currentPen.name,
        selected: widget.currentTool == Pen.currentPen,
        enabled: !widget.readOnly,
        onPressed: () => toggleOptions(.pen, Pen.currentPen),
        child: UniIcon(Pen.currentPen.icon, size: 18),
      ),
      _PillButton(
        tooltip: t.editor.pens.pencil,
        selected: widget.currentTool == Pencil.currentPencil,
        enabled: !widget.readOnly,
        onPressed: () => toggleOptions(.pencil, Pencil.currentPencil),
        child: const FaIcon(Pencil.pencilIcon, size: 18),
      ),
      _PillButton(
        tooltip: t.editor.pens.highlighter,
        selected: widget.currentTool == Highlighter.currentHighlighter,
        enabled: !widget.readOnly,
        onPressed: () =>
            toggleOptions(.highlighter, Highlighter.currentHighlighter),
        child: const FaIcon(Highlighter.highlighterIcon, size: 18),
      ),
      _PillButton(
        tooltip: t.editor.toolbar.toggleEraser,
        selected: widget.currentTool is Eraser,
        enabled: !widget.readOnly,
        onPressed: toggleEraser,
        child: const FaIcon(FontAwesomeIcons.eraser, size: 18),
      ),
      _PillButton(
        tooltip: t.editor.toolbar.text,
        selected: widget.textEditing,
        enabled: !widget.readOnly,
        onPressed: widget.toggleTextEditing,
        child: const Icon(Icons.text_fields),
      ),
      _PillButton(
        tooltip: t.editor.toolbar.select,
        selected: widget.currentTool is Select,
        enabled: !widget.readOnly,
        onPressed: () {
          toolOptionsType.value = .hide;
          widget.setTool(Select.currentSelect);
        },
        child: const Icon(CupertinoIcons.lasso),
      ),
      _PillButton(
        tooltip: t.editor.toolbar.photo,
        enabled: !widget.readOnly,
        onPressed: widget.pickPhoto,
        child: const Icon(Icons.add_circle_outline),
      ),
      const _PillDivider(),
      ?fingerDrawing,
    ];
    final moreTools = <Widget>[
      ?fingerDrawing,
      _PillButton(
        tooltip: t.editor.pens.laserPointer,
        selected: widget.currentTool == LaserPointer.currentLaserPointer,
        onPressed: () {
          toolOptionsType.value = .hide;
          widget.setTool(LaserPointer.currentLaserPointer);
        },
        child: const Icon(Symbols.stylus_laser_pointer),
      ),
      _PillButton(
        tooltip: t.editor.toolbar.fullscreen,
        selected: DynamicMaterialApp.isFullscreen,
        enabled: !widget.readOnly,
        onPressed: toggleFullscreen,
        child: Icon(
          DynamicMaterialApp.isFullscreen
              ? Icons.fullscreen_exit
              : Icons.fullscreen,
        ),
      ),
    ];

    final toolsPill = ValueListenableBuilder(
      valueListenable: showMoreTools,
      builder: (context, more, _) => pill(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _PillButton.size + 8,
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const .symmetric(horizontal: 6),
                      child: Row(children: more ? moreTools : mainTools),
                    ),
                  ),
                  _PillButton(
                    tooltip: null,
                    onPressed: () => showMoreTools.value = !more,
                    child: Icon(
                      more ? Icons.chevron_left : Icons.chevron_right,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Collapsible(
              axis: CollapsibleAxis.vertical,
              maintainState: true,
              collapsed: !drawing || more,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: colorScheme.outlineVariant,
                  ),
                  SizedBox(
                    height: _PillButton.size + 8,
                    child: ColorBar(
                      axis: Axis.horizontal,
                      setColor: widget.setColor,
                      currentColor: currentColor,
                      invert: invert,
                    ),
                  ),
                ],
              ),
            ),
            penOptions,
          ],
        ),
      ),
    );

    final backPill = SizedBox(
      width: _PillButton.size + 6,
      height: _PillButton.size + 6,
      child: pill(child: Center(child: header.leading)),
    );

    final rightPill = pill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 6),
          _PillButton(
            tooltip: t.editor.toolbar.undo,
            enabled: !widget.readOnly && widget.isUndoPossible,
            onPressed: widget.undo,
            child: const Icon(CupertinoIcons.arrow_uturn_left),
          ),
          _PillButton(
            tooltip: t.editor.toolbar.redo,
            enabled: !widget.readOnly && widget.isRedoPossible,
            onPressed: widget.redo,
            child: const Icon(CupertinoIcons.arrow_uturn_right),
          ),
          _PillButton(
            tooltip: null,
            onPressed: header.onMore,
            child: const Icon(Icons.more_horiz),
          ),
          ValueListenableBuilder(
            valueListenable: showExportOptions,
            builder: (context, showExportOptions, child) => _PillButton(
              tooltip: t.editor.toolbar.export,
              selected: showExportOptions,
              enabled: !widget.readOnly,
              onPressed: toggleExportBar,
              child: child!,
            ),
            child: const Icon(CupertinoIcons.share),
          ),
          _PillButton(
            tooltip: t.editor.pages,
            onPressed: header.onPages,
            child: const Icon(CupertinoIcons.rectangle_on_rectangle),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColoredBox(
          color: headerColor,
          child: SizedBox(
            height: Toolbar.topHeaderHeight,
            child: Padding(
              padding: const .symmetric(horizontal: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const .only(top: 8), child: backPill),
                  Expanded(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // the title sits behind the tools, as in Notability
                        Positioned.fill(
                          child: Padding(
                            padding: const .only(left: 12, top: 8),
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: SizedBox(
                                height: _PillButton.size + 6,
                                child: header.title,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 58,
                          top: 8,
                          width: 440,
                          child: toolsPill,
                        ),
                      ],
                    ),
                  ),
                  Padding(padding: const .only(top: 8), child: rightPill),
                ],
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const .symmetric(horizontal: 12),
            child: pill(child: exportBar),
          ),
        ),
        quillBar,
      ],
    );
  }

  @override
  void dispose() {
    DynamicMaterialApp.removeFullscreenListener(_setState);
    DynamicMaterialApp.setFullscreen(false, updateSystem: true);

    _removeKeybindings();
    super.dispose();
  }
}

enum ToolOptions { hide, pen, highlighter, pencil }

/// A tool in the top layout's pills: Notability's flat icon, with a bar under
/// it while it is the active tool.
class _PillButton extends StatelessWidget {
  const new({
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.selected = false,
    this.enabled = true,
  });

  /// 44 pt, what a fingertip needs.
  static const size = 44.0;

  final String? tooltip;
  final VoidCallback onPressed;
  final Widget child;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IconButton(
            tooltip: tooltip,
            onPressed: enabled ? onPressed : null,
            iconSize: 20,
            color: selected
                ? colorScheme.onSurface
                : colorScheme.onSurface.withValues(alpha: 0.78),
            disabledColor: colorScheme.onSurface.withValues(alpha: 0.3),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(size),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            icon: child,
          ),
          if (selected)
            Positioned(
              bottom: 4,
              child: IgnorePointer(
                child: Container(
                  width: 18,
                  height: 2,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurface,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PillDivider extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 22,
    margin: const EdgeInsets.symmetric(horizontal: 6),
    color: ColorScheme.of(context).outlineVariant,
  );
}
