import 'dart:async';

import 'package:collapsible/collapsible.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:quill/components/home/delete_note_button.dart';
import 'package:quill/components/home/export_note_button.dart';
import 'package:quill/components/home/grid_folders.dart';
import 'package:quill/components/home/home_layout_button.dart';
import 'package:quill/components/home/masonry_files.dart';
import 'package:quill/components/home/move_note_button.dart';
import 'package:quill/components/home/new_note_button.dart';
import 'package:quill/components/home/no_files.dart';
import 'package:quill/components/home/path_components.dart';
import 'package:quill/components/home/rename_note_button.dart';
import 'package:quill/components/home/sort_button.dart';
import 'package:quill/components/home/syncing_button.dart';
import 'package:quill/components/theming/quill_theme.dart';
import 'package:quill/data/file_manager/file_manager.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/quill_sync/quill_connect.dart';
import 'package:quill/data/routes.dart';
import 'package:quill/i18n/strings.g.dart';

class BrowsePage extends StatefulHookWidget {
  const new({super.key, String? path}) : initialPath = path;

  final String? initialPath;

  @visibleForTesting
  static DirectoryChildren? overrideChildren;

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  DirectoryChildren? children;

  String? path;

  final ValueNotifier<List<String>> selectedFiles = ValueNotifier([]);

  @override
  void initState() {
    path = widget.initialPath;

    unawaited(QuillConnect.instance?.refreshIfStale());
    findChildrenOfPath();
    fileWriteSubscription = FileManager.fileWriteStream.stream.listen(
      fileWriteListener,
    );
    selectedFiles.addListener(_setState);

    super.initState();
  }

  @override
  void dispose() {
    selectedFiles.removeListener(_setState);
    fileWriteSubscription?.cancel();
    super.dispose();
  }

  StreamSubscription? fileWriteSubscription;
  void fileWriteListener(FileOperation event) {
    if (!event.filePath.startsWith(path ?? '/')) return;
    findChildrenOfPath(fromFileListener: true);
  }

  void _setState() => setState(() {});

  Future findChildrenOfPath({bool fromFileListener = false}) async {
    if (!mounted) return;

    if (fromFileListener) {
      // don't refresh if we're not on the home page
      final location = GoRouterState.of(context).uri.toString();
      if (!location.startsWith(RoutePaths.prefixOfHome)) return;
    }

    children =
        BrowsePage.overrideChildren ??
        await FileManager.getChildrenOfDirectory(
          path ?? '/',
          sortMetric: stows.browseSortMetric.value,
        );

    if (mounted) setState(() {});
  }

  void onDirectoryTap(String folder) {
    selectedFiles.value = [];
    if (folder == '..') {
      path = p.dirname(path ?? '/');
      if (path == '/') path = null;
    } else {
      path = p.join(path ?? '/', folder);
    }
    context.go(HomeRoutes.browseFilePath(path ?? '/'));
    findChildrenOfPath();
  }

  void onPathComponentTap(String? newPath) {
    selectedFiles.value = [];
    if (newPath == null || newPath.isEmpty || newPath == '/') {
      newPath = null;
    }
    path = newPath;
    context.go(HomeRoutes.browseFilePath(path ?? '/'));
    findChildrenOfPath();
  }

  Future<void> createFolder(String folderName) async {
    final folderPath = '${path ?? ''}/$folderName';
    await FileManager.createFolder(folderPath);
    findChildrenOfPath();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final platform = Theme.of(context).platform;
    final crossAxisCount = MediaQuery.sizeOf(context).width ~/ 300 + 1;
    useListenable(stows.homeLayout);
    useListenable(QuillConnect.courses);
    useOnListenableChange(stows.browseSortMetric, findChildrenOfPath);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            collapsedHeight: kToolbarHeight,
            expandedHeight: platform.isMaterialNative ? 200 - 8 : null,
            pinned: true,
            scrolledUnderElevation: 1,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                t.home.titles.browse,
                style: TextStyle(color: colorScheme.onSurface),
              ),
              centerTitle: false,
              titlePadding: const EdgeInsetsDirectional.only(
                start: 16,
                bottom: 8, // less than other pages for path components
              ),
            ),
            actions: const [
              BrowseSortButton(),
              HomeLayoutButton(),
              SyncingButton(),
            ],
          ),
          SliverToBoxAdapter(
            child: PathComponents(path, onPathComponentTap: onPathComponentTap),
          ),
          const SliverPadding(padding: .only(bottom: 16)),
          GridFolders(
            isAtRoot: path?.isEmpty ?? true,
            subtitleOf: (folderName) {
              final course = QuillConnect.courseOfPath(
                p.join(path ?? '/', folderName),
              );
              final next = course?.next;
              if (course == null || next == null) return null;
              // Only on the course's own card, not on folders inside it.
              if (p.join(path ?? '/', folderName) != course.folder) return null;
              return '${next.name}\n${QuillConnect.dueLabel(next)}';
            },
            crossAxisCount: crossAxisCount,
            onTap: onDirectoryTap,
            createFolder: createFolder,
            doesFolderExist: (String folderName) {
              return children?.directories.contains(folderName) ?? false;
            },
            renameFolder: (String oldName, String newName) async {
              final oldPath = '${path ?? ''}/$oldName';
              await FileManager.renameDirectory(oldPath, newName);
              findChildrenOfPath();
            },
            isFolderEmpty: (String folderName) async {
              final folderPath = '${path ?? ''}/$folderName';
              final children = await FileManager.getChildrenOfDirectory(
                folderPath,
              );
              return children?.isEmpty ?? true;
            },
            deleteFolder: (String folderName) async {
              final folderPath = '${path ?? ''}/$folderName';
              await FileManager.deleteDirectory(folderPath);
              findChildrenOfPath();
            },
            folders: [
              for (final directoryPath in children?.directories ?? const [])
                directoryPath,
            ],
          ),
          if (children == null) ...[
            // loading
          ] else if (children!.isEmpty) ...[
            const SliverSafeArea(sliver: SliverToBoxAdapter(child: NoFiles())),
          ] else ...[
            SliverSafeArea(
              top: false,
              minimum: const .only(
                top: 8,
                // Allow space for the FloatingActionButton
                bottom: 70,
              ),
              sliver: MasonryFiles(
                crossAxisCount: crossAxisCount,
                files: [
                  for (final filePath in children?.files ?? const [])
                    "${path ?? ""}/$filePath",
                ],
                selectedFiles: selectedFiles,
              ),
            ),
          ],
        ],
      ),
      floatingActionButton: NewNoteButton(
        cupertino: platform.isCupertino,
        path: path,
      ),
      persistentFooterButtons: selectedFiles.value.isEmpty
          ? null
          : [
              Collapsible(
                axis: CollapsibleAxis.vertical,
                collapsed: selectedFiles.value.length != 1,
                child: RenameNoteButton(
                  existingPath: selectedFiles.value.isEmpty
                      ? ''
                      : selectedFiles.value.first,
                  unselectNotes: () => selectedFiles.value = [],
                ),
              ),
              MoveNoteButton(
                filesToMove: selectedFiles.value,
                unselectNotes: () => selectedFiles.value = [],
              ),
              DeleteNoteButton(
                filesToDelete: selectedFiles.value,
                unselectNotes: () => selectedFiles.value = [],
              ),
              ExportNoteButton(selectedFiles: selectedFiles.value),
            ],
    );
  }
}
