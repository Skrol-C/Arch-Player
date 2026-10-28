import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import 'needle_store.dart';

/// Downloads: where Needle files land. The default library lives at
/// shared Music/Needle with Songs, Albums and Playlist folders.
/// Picking a folder overrides that wholesale (same convention as the
/// publish step: SD cards welcome, scoped storage may refuse and the
/// pull then falls back to the library). Reset returns to default.
class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key});

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Where should Needle files land?',
      );
      if (path == null) return;
      await ref.read(downloadDirProvider.notifier).set(path);
      ArchLog.i('needle', 'download dir picked');
    } catch (e) {
      ArchLog.w('needle', 'download dir failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open folder picker')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(needleRootProvider);
    final dir = ref.watch(downloadDirProvider);
    final custom = dir.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Text(
            custom
                ? 'Pulls land straight in your folder.'
                : 'Pulls file into Songs, Albums and Playlist folders under Music/$root.',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.folder_rounded, color: archPink),
            ),
            title: const Text(
              'Needle location',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              custom ? dir : 'Music/$root',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            trailing: custom
                ? TextButton(
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      ref.read(downloadDirProvider.notifier).set('');
                      ArchLog.i('needle', 'download dir reset');
                    },
                    child: const Text('Reset'),
                  )
                : Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
            onTap: () => _pick(context, ref),
          ),
        ],
      ),
    );
  }
}
