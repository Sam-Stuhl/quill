import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/tools/pen.dart';
import 'package:quill/i18n/strings.g.dart';

class Highlighter extends Pen {
  new()
    : super(
        name: t.editor.pens.highlighter,
        sizeMin: 10,
        sizeMax: 100,
        sizeStep: 10,
        icon: highlighterIcon,
        options: stows.lastHighlighterOptions.value,
        pressureEnabled: false,
        color: Colors.yellow.withAlpha(Highlighter.alpha),
        toolId: .highlighter,
      );

  static const alpha = 100;

  static var currentHighlighter = Highlighter();

  static const highlighterIcon = FontAwesomeIcons.highlighter;
}
