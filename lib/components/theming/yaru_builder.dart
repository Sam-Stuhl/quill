import 'package:dynamic_yaru/dynamic_yaru.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quill/components/theming/quill_theme.dart';
import 'package:quill/data/prefs.dart';
import 'package:sbn/font_fallbacks.dart';
import 'package:yaru/yaru.dart';

class YaruBuilder extends StatefulHookWidget {
  const new({
    super.key,
    required this.primary,
    this.platform = .linux,
    required this.builder,
  });

  final Color? primary;
  final TargetPlatform platform;
  final Widget Function(BuildContext context, ThemeData theme) builder;

  @override
  State<YaruBuilder> createState() => _YaruBuilderState();
}

class _YaruBuilderState extends State<YaruBuilder> {
  @override
  Widget build(BuildContext context) {
    // Use colors from KDE theme where possible.
    final themeMode = useValueListenable(stows.appTheme);
    final accentColor = useValueListenable(stows.accentColor);
    final hyperlegibleFont = useValueListenable(stows.hyperlegibleFont);
    final highContrast = MediaQuery.highContrastOf(context);
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final Brightness brightness = switch (themeMode) {
      .system => platformBrightness,
      .light => .light,
      .dark => .dark,
    };
    final dynamicYaru = useMemoized(
      () {
        if (accentColor != null) return null; // custom theme, not system
        if (brightness != platformBrightness) return null;

        DynamicYaru.refresh();
        final theme = DynamicYaru.getTheme(
          fontFamily: hyperlegibleFont
              ? 'AtkinsonHyperlegibleNext'
              : 'Adwaita Sans',
          fontFamilyFallback: quillSansSerifFontFallbacks,
        );
        if (theme == null) return null;

        return QuillTheme.getThemeFromYaruFixed(theme, widget.platform);
      },
      [
        accentColor,
        platformBrightness,
        brightness,
        widget.platform,
        hyperlegibleFont,
      ],
    );

    if (dynamicYaru != null) {
      return widget.builder(context, dynamicYaru);
    }

    return YaruTheme(
      builder: (context, yaru, _) {
        final theme = QuillTheme.getThemeFromYaru(
          widget.primary ?? yaru.variant?.color ?? Colors.yellow,
          brightness,
          widget.platform,
          highContrast,
        );

        return widget.builder(context, theme);
      },
    );
  }
}
