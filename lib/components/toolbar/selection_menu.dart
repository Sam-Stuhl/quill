import 'dart:math';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/toolbar/color_bar.dart';
import 'package:saber/data/clipboard_shelf.dart';
import 'package:saber/i18n/strings.g.dart';

/// Smallest target Apple asks for under a finger.
const double kTouchTarget = 44;

/// Puts [child] next to [anchor] (both in the same coordinate space):
/// centred above it when there is room, below it otherwise, never off screen.
class AnchoredMenuLayout extends SingleChildLayoutDelegate {
  const new({required this.anchor, this.gap = 14});

  final Rect anchor;
  final double gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    var x = anchor.center.dx - childSize.width / 2;
    x = x.clamp(margin, max(margin, size.width - childSize.width - margin));

    var y = anchor.top - childSize.height - gap;
    if (y < margin) {
      y = anchor.bottom + gap;
    }
    y = y.clamp(margin, max(margin, size.height - childSize.height - margin));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(AnchoredMenuLayout old) =>
      old.anchor != anchor || old.gap != gap;
}

/// The menu that sits next to a selection: cut, copy, duplicate, color and
/// delete, as one row under a finger, like Notability's.
class SelectionMenu extends StatefulWidget {
  const new({
    super.key,
    required this.currentColor,
    required this.cut,
    required this.copy,
    required this.duplicate,
    required this.delete,
    required this.setColor,
    required this.paste,
    required this.canPaste,
  });

  final Color? currentColor;
  final VoidCallback cut;
  final VoidCallback copy;
  final VoidCallback duplicate;
  final VoidCallback delete;
  final ValueChanged<Color> setColor;
  final VoidCallback paste;
  final bool canPaste;

  @override
  State<SelectionMenu> createState() => _SelectionMenuState();
}

class _SelectionMenuState extends State<SelectionMenu> {
  var showColors = false;

  @override
  Widget build(BuildContext context) {
    final s = t.editor.selectionBar;
    final colorScheme = ColorScheme.of(context);

    final Widget content;
    if (showColors) {
      content = Row(
        mainAxisSize: .min,
        children: [
          MenuTextButton(
            label: '‹',
            onPressed: () => setState(() => showColors = false),
          ),
          for (final named in ColorBar.normalColorOptions)
            _Swatch(
              color: named.color,
              name: named.name,
              selected: widget.currentColor == named.color,
              onTap: () {
                widget.setColor(named.color);
                setState(() => showColors = false);
              },
            ),
        ],
      );
    } else {
      content = Row(
        mainAxisSize: .min,
        children: [
          MenuTextButton(label: s.cut, onPressed: widget.cut),
          MenuTextButton(label: s.copy, onPressed: widget.copy),
          if (widget.canPaste)
            MenuTextButton(label: s.paste, onPressed: widget.paste),
          MenuTextButton(label: s.duplicate, onPressed: widget.duplicate),
          MenuTextButton(
            label: s.color,
            onPressed: () => setState(() => showColors = true),
          ),
          MenuTextButton(
            label: s.delete,
            onPressed: widget.delete,
            destructive: true,
          ),
        ],
      );
    }

    return MenuSurface(
      color: colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        scrollDirection: .horizontal,
        child: content,
      ),
    );
  }
}

/// The rounded floating surface shared by the context menus.
class MenuSurface extends StatelessWidget {
  const new({super.key, required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Material(
      color: color ?? colorScheme.surfaceContainerHighest,
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: const .all(.circular(14)),
      clipBehavior: .antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 16,
        ),
        child: child,
      ),
    );
  }
}

class MenuTextButton extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return InkWell(
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: kTouchTarget,
          minWidth: kTouchTarget + 8,
        ),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Padding(
            padding: const .symmetric(horizontal: 14),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: destructive ? colorScheme.error : colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const new({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Semantics(
      label: name,
      button: true,
      child: InkResponse(
        onTap: onTap,
        radius: kTouchTarget / 2,
        child: SizedBox.square(
          dimension: kTouchTarget,
          child: Center(
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color,
                shape: .circle,
                border: Border.all(
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.outlineVariant,
                  width: selected ? 3 : 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown after a press and hold on empty paper: paste, or open the shelf.
class PasteMenu extends StatelessWidget {
  const new({super.key, required this.paste, required this.openShelf});

  final VoidCallback paste;
  final VoidCallback openShelf;

  @override
  Widget build(BuildContext context) {
    final s = t.editor.selectionBar;
    return MenuSurface(
      child: Row(
        mainAxisSize: .min,
        children: [
          MenuTextButton(label: s.pasteHere, onPressed: paste),
          MenuTextButton(label: s.clipboard, onPressed: openShelf),
        ],
      ),
    );
  }
}

/// The recent copies, newest first. Tap one to paste it; it stays on the shelf.
class ClipboardShelfSheet extends StatelessWidget {
  const new({super.key, required this.onPaste});

  final ValueChanged<ClipboardEntry> onPaste;

  @override
  Widget build(BuildContext context) {
    final s = t.editor.selectionBar;
    final shelf = ClipboardShelf.instance;
    return SafeArea(
      child: ListenableBuilder(
        listenable: shelf,
        builder: (context, _) {
          final entries = shelf.entries;
          return Column(
            mainAxisSize: .min,
            children: [
              Padding(
                padding: const .fromLTRB(20, 14, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.clipboard,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (entries.isNotEmpty)
                      TextButton(
                        onPressed: shelf.clear,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(kTouchTarget, kTouchTarget),
                        ),
                        child: Text(s.clipboardClear),
                      ),
                  ],
                ),
              ),
              if (entries.isEmpty)
                Padding(
                  padding: const .all(28),
                  child: Text(s.clipboardEmpty, textAlign: .center),
                )
              else
                SizedBox(
                  height: 150,
                  child: ListView.separated(
                    scrollDirection: .horizontal,
                    padding: const .symmetric(horizontal: 16, vertical: 8),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => _ShelfCard(
                      entry: entries[i],
                      onTap: () => onPaste(entries[i]),
                      onRemove: () => shelf.remove(entries[i]),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _ShelfCard extends StatelessWidget {
  const new({required this.entry, required this.onTap, required this.onRemove});

  final ClipboardEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SizedBox(
      width: 150,
      child: Stack(
        children: [
          Positioned.fill(
            child: Material(
              color: Colors.white,
              borderRadius: const .all(.circular(12)),
              clipBehavior: .antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const .all(8),
                  child: Column(
                    children: [
                      Expanded(
                        child: CustomPaint(
                          painter: _EntryPainter(entry),
                          size: .infinite,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t.editor.selectionBar.clipboardItems(
                          n: entry.itemCount,
                        ),
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              onPressed: onRemove,
              iconSize: 18,
              constraints: const BoxConstraints(
                minWidth: kTouchTarget,
                minHeight: kTouchTarget,
              ),
              color: colorScheme.outline,
              icon: const Icon(CupertinoIcons.xmark_circle_fill),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryPainter extends CustomPainter {
  new(this.entry);

  final ClipboardEntry entry;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = entry.bounds;
    if (bounds.isEmpty) return;
    final scale = min(size.width / bounds.width, size.height / bounds.height);
    final scaled = Size(bounds.width * scale, bounds.height * scale);
    canvas.translate(
      (size.width - scaled.width) / 2,
      (size.height - scaled.height) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);

    final imagePaint = Paint()..color = Colors.black12;
    for (final image in entry.images) {
      canvas.drawRect(image.dstRect, imagePaint);
    }
    for (final Stroke stroke in entry.strokes) {
      canvas.drawPath(
        stroke.lowQualityPath,
        Paint()
          ..color = stroke.color.withValues(alpha: 1)
          ..style = .fill,
      );
    }
  }

  @override
  bool shouldRepaint(_EntryPainter old) => old.entry != entry;
}
