import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import '../../library/library_providers.dart';
import '../../needle/needle_store.dart';
import '../widgets/setting_bits.dart';

/// Files: every storage location in one place. Music folders use the
/// system folder picker (SAF on Android — the only honest way to get
/// a readable tree), Needle and download dirs reuse the engine's own
/// persisted prefs. Add, remove, exclude — all wired, all live.
class FilesPage extends ConsumerWidget {
  const FilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'files settings open');
    final picked = ref.watch(pickedProvider).value ?? {};
    final excluded = ref.watch(excludedProvider).value ?? {};
    final songs = ref.watch(songsProvider).value ?? [];
    final needleRoot = ref.watch(needleRootProvider);
    final dlDir = ref.watch(downloadDirProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Files')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Music folders',
            children: [
              if (picked.isEmpty)
                SettingState.empty(
                  'No folders yet. Add one to start the library.',
                )
              else
                for (final path in picked)
                  _FolderRow(
                    path: path,
                    excluded: excluded.contains(path),
                    count: songs.where((s) {
                      return s.path.startsWith(path);
                    }).length,
                  ),
              SettingRow(
                icon: Icons.create_new_folder_rounded,
                title: 'Add folder',
                subtitle: 'System picker — you choose, we remember',
                onTap: () => _addFolder(context, ref),
              ),
            ],
          ),
          SettingGroup(
            title: 'Needle storage',
            children: [
              SettingRow(
                icon: Icons.folder_rounded,
                title: 'Needle folder',
                subtitle: 'Music/$needleRoot · Songs · Albums · Playlist',
                onTap: () =>
                    _rename(context, ref, 'Needle folder', needleRoot,
                        (v) => ref
                            .read(needleRootProvider.notifier)
                            .set(v)),
              ),
              SettingRow(
                icon: Icons.download_rounded,
                title: 'Download folder',
                subtitle: dlDir.isEmpty
                    ? 'Default app music folder'
                    : dlDir,
                onTap: () => _pickDlDir(context, ref),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Folders are picked through the system — Arch never '
              'guesses paths. Excluding a folder hides its tracks '
              'without forgetting the choice.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addFolder(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Where is your music?',
      );
      if (path == null) return;
      await ref.read(folderStoreProvider).addPicked(path);
      ArchLog.i('settings', 'folder picked: $path');
      ref.invalidate(songsProvider);
      ref.invalidate(pickedProvider);
    } catch (e) {
      ArchLog.w('settings', 'folder pick failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the folder picker'),
          ),
        );
      }
    }
  }

  Future<void> _pickDlDir(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Where should downloads land?',
      );
      if (path == null) return;
      await ref.read(downloadDirProvider.notifier).set(path);
      ArchLog.i('settings', 'download dir: $path');
    } catch (e) {
      ArchLog.w('settings', 'download dir pick failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the folder picker'),
          ),
        );
      }
    }
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    String title,
    String initial,
    Future<void> Function(String) save,
  ) async {
    HapticFeedback.selectionClick();
    final controller = TextEditingController(text: initial);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty || next == initial) return;
    await save(next);
    ArchLog.i('settings', '$title renamed: $next');
  }
}

class _FolderRow extends ConsumerWidget {
  final String path;
  final bool excluded;
  final int count;

  const _FolderRow({
    required this.path,
    required this.excluded,
    required this.count,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final short = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          excluded
              ? Icons.folder_off_rounded
              : Icons.folder_rounded,
          color: const Color(0xFFFC3C44),
        ),
      ),
      title: Text(
        short,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        excluded
            ? 'Excluded — hidden from the library'
            : '$count tracks',
        maxLines: 2,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: excluded ? 'Include' : 'Exclude',
            onPressed: () async {
              HapticFeedback.selectionClick();
              await ref
                  .read(folderStoreProvider)
                  .setExcluded(path, !excluded);
              ref.invalidate(songsProvider);
              ref.invalidate(excludedProvider);
            },
            icon: Icon(
              excluded
                  ? Icons.visibility_rounded
                  : Icons.visibility_off_rounded,
              color: scheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            onPressed: () async {
              HapticFeedback.selectionClick();
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Remove folder?'),
                  content: Text(
                    'Tracks from $short leave the library. '
                    'The files stay where they are.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Keep'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
              await ref.read(folderStoreProvider).removePicked(path);
              ref.invalidate(songsProvider);
              ref.invalidate(pickedProvider);
            },
            icon: Icon(
              Icons.delete_outline_rounded,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
