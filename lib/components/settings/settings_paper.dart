import 'package:material_ui/material_ui.dart';
import 'package:quill/components/canvas/canvas_background_preview.dart';
import 'package:quill/data/custom_patterns.dart';
import 'package:quill/data/editor/page.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/i18n/extensions/canvas_background_pattern_localized.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// Settings, Paper: the pattern new notes start with, and saved custom papers.
class const SettingsPaper({super.key}) extends StatefulWidget {
  @override
  State<SettingsPaper> createState() => _SettingsPaperState();
}

class _SettingsPaperState extends State<SettingsPaper> {
  @override
  void initState() {
    stows.lastBackgroundPattern.addListener(_changed);
    stows.lastLineHeight.addListener(_changed);
    stows.lastLineThickness.addListener(_changed);
    stows.customBackgroundPatterns.addListener(_changed);
    super.initState();
  }

  @override
  void dispose() {
    stows.lastBackgroundPattern.removeListener(_changed);
    stows.lastLineHeight.removeListener(_changed);
    stows.lastLineThickness.removeListener(_changed);
    stows.customBackgroundPatterns.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Future<void> _addCustom() async {
    final created = await showDialog<CustomPattern>(
      context: context,
      builder: (_) => const _NewPatternDialog(),
    );
    if (created == null) return;
    CustomPattern.add(created);
    created.setAsDefault();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = TextTheme.of(context);
    const pageSize = EditorPage.defaultSize;
    final previewHeight =
        pageSize.height / pageSize.width * CanvasBackgroundPreview.fixedWidth;
    final defaultPattern = stows.lastBackgroundPattern.value;
    final defaultHeight = stows.lastLineHeight.value;
    final defaultThickness = stows.lastLineThickness.value;
    final customs = CustomPattern.all;

    Widget tile({
      required String name,
      required CanvasBackgroundPattern pattern,
      required int lineHeight,
      required int lineThickness,
      required VoidCallback onTap,
      VoidCallback? onDelete,
    }) {
      final selected =
          pattern == defaultPattern &&
          (!pattern.usesLineHeight || lineHeight == defaultHeight) &&
          (!pattern.usesLineHeight || lineThickness == defaultThickness);
      return InkWell(
        borderRadius: const .all(.circular(8)),
        onTap: onTap,
        child: Stack(
          children: [
            CanvasBackgroundPreview(
              selected: selected,
              invert: false,
              backgroundColor: null,
              backgroundPattern: pattern,
              backgroundImage: null,
              pageSize: pageSize,
              lineHeight: lineHeight,
              lineThickness: lineThickness,
            ),
            Positioned(
              bottom: previewHeight * 0.1,
              left: 0,
              right: 0,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ColorScheme.of(context).surface
                        .withValues(alpha: 0.85),
                    borderRadius: const .all(.circular(8)),
                  ),
                  child: Padding(
                    padding: const .symmetric(horizontal: 6, vertical: 2),
                    child: Text(name, style: textTheme.labelSmall),
                  ),
                ),
              ),
            ),
            if (onDelete != null)
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  tooltip: 'Delete',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                  onPressed: onDelete,
                ),
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const .symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: .start,
        children: [
          Text('Default pattern', style: textTheme.titleMedium),
          Text(
            'New notes start with this paper. Changing a note\'s pattern in '
            'the editor does not change it.',
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: previewHeight,
            child: ListView.separated(
              scrollDirection: .horizontal,
              itemCount: CanvasBackgroundPattern.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final pattern = CanvasBackgroundPattern.values[index];
                return tile(
                  name: pattern.localizedName,
                  pattern: pattern,
                  lineHeight: defaultHeight,
                  lineThickness: defaultThickness,
                  onTap: () => stows.lastBackgroundPattern.value = pattern,
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Text('Custom patterns', style: textTheme.titleMedium),
          Text(
            'Your own spacing and thickness. Tap one to make it the default; '
            'all of them are also in the editor\'s page menu.',
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: previewHeight,
            child: ListView.separated(
              scrollDirection: .horizontal,
              itemCount: customs.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                if (index == customs.length) {
                  return InkWell(
                    borderRadius: const .all(.circular(8)),
                    onTap: _addCustom,
                    child: Container(
                      width: CanvasBackgroundPreview.fixedWidth,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: ColorScheme.of(context).outlineVariant,
                          width: 2,
                        ),
                        borderRadius: const .all(.circular(8)),
                      ),
                      child: const Center(child: Icon(Icons.add, size: 32)),
                    ),
                  );
                }
                final custom = customs[index];
                return tile(
                  name: custom.name,
                  pattern: custom.pattern,
                  lineHeight: custom.lineHeight,
                  lineThickness: custom.lineThickness,
                  onTap: custom.setAsDefault,
                  onDelete: () => CustomPattern.remove(custom.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class const _NewPatternDialog() extends StatefulWidget {
  @override
  State<_NewPatternDialog> createState() => _NewPatternDialogState();
}

class _NewPatternDialogState extends State<_NewPatternDialog> {
  final nameController = TextEditingController();
  var pattern = CanvasBackgroundPattern.grid;
  var lineHeight = stows.lastLineHeight.value;
  var lineThickness = stows.lastLineThickness.value;

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  static const _basePatterns = [
    CanvasBackgroundPattern.lined,
    CanvasBackgroundPattern.collegeLtr,
    CanvasBackgroundPattern.collegeRtl,
    CanvasBackgroundPattern.grid,
    CanvasBackgroundPattern.dots,
    CanvasBackgroundPattern.staffs,
    CanvasBackgroundPattern.tablature,
    CanvasBackgroundPattern.cornell,
  ];

  @override
  Widget build(BuildContext context) {
    const pageSize = EditorPage.defaultSize;
    return AlertDialog(
      title: const Text('New custom pattern'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            DropdownButton<CanvasBackgroundPattern>(
              value: pattern,
              isExpanded: true,
              items: [
                for (final p in _basePatterns)
                  DropdownMenuItem(value: p, child: Text(p.localizedName)),
              ],
              onChanged: (p) => setState(() => pattern = p ?? pattern),
            ),
            const SizedBox(height: 8),
            Text('Spacing: $lineHeight'),
            Slider(
              value: lineHeight.toDouble(),
              min: CustomPattern.minLineHeight.toDouble(),
              max: CustomPattern.maxLineHeight.toDouble(),
              divisions: 16,
              onChanged: (v) => setState(() => lineHeight = v.round()),
            ),
            Text('Line thickness: $lineThickness'),
            Slider(
              value: lineThickness.toDouble(),
              min: CustomPattern.minLineThickness.toDouble(),
              max: CustomPattern.maxLineThickness.toDouble(),
              divisions: 4,
              onChanged: (v) => setState(() => lineThickness = v.round()),
            ),
            const SizedBox(height: 8),
            Center(
              child: CanvasBackgroundPreview(
                selected: true,
                invert: false,
                backgroundColor: null,
                backgroundPattern: pattern,
                backgroundImage: null,
                pageSize: pageSize,
                lineHeight: lineHeight,
                lineThickness: lineThickness,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: nameController.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  CustomPattern(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    name: nameController.text.trim(),
                    pattern: pattern,
                    lineHeight: lineHeight,
                    lineThickness: lineThickness,
                  ),
                ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
