import 'package:material_ui/material_ui.dart';
import 'package:quill/components/canvas/save_indicator.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/i18n/strings.g.dart';
import 'package:quill/pages/editor/editor.dart';

class const Whiteboard({super.key}) extends StatelessWidget {
  static const filePath = '/_whiteboard';

  static bool needsToAutoClearWhiteboard =
      stows.autoClearWhiteboardOnExit.value;

  static final _whiteboardKey = GlobalKey<EditorState>(
    debugLabel: 'whiteboard',
  );

  static SavingState? get savingState =>
      _whiteboardKey.currentState?.savingState.value;
  static void triggerSave() {
    final editorState = _whiteboardKey.currentState;
    if (editorState == null) return;
    assert(editorState.savingState.value == .waitingToSave);
    editorState.saveToFile();
    editorState.snackBarNeedsToSaveBeforeExiting();
  }

  @override
  Widget build(BuildContext context) {
    return Editor(
      key: _whiteboardKey,
      path: filePath,
      customTitle: t.home.titles.whiteboard,
    );
  }
}
