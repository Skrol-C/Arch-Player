import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import 'needle_store.dart';

/// Download preferences: quality tier + storage folder. Real
/// persisted state the engine will consume; files land tagged with
/// art and lyrics.
class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(needleRootProvider);
    final dir = ref.watch(downloadDirProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Text(
            'Quality is picked on every download; pulls file under the Needle folder below.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.folder_rounded, color: archPink),
            ),
            title: const Text(
              'Needle folder',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Music/$root · Songs · Albums · Playlist',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13),
            ),
            trailing: Icon(Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onTap: () async {
              HapticFeedback.selectionClick();
              final controller = TextEditingController(text: root);
              final next = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Needle folder'),
                  content: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Needle',
                      prefixText: 'Music / ',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () =>
                          Navigator.of(ctx).pop(controller.text),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              );
              if (next != null && context.mounted) {
                await ref
                    .read(needleRootProvider.notifier)
                    .set(next);
                ArchLog.i('needle', 'root set');
              }
            },
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.folder_rounded, color: archPink),
            ),
            title: const Text(
              'Storage folder',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              dir.isEmpty ? 'Default app music folder' : dir,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13),
            ),
            trailing: Icon(Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            onTap: () async {
              HapticFeedback.selectionClick();
              try {
                final path = await FilePicker.getDirectoryPath(
                  dialogTitle: 'Where should downloads land?',
                );
                if (path == null) return;
                await ref.read(downloadDirProvider.notifier).set(path);
                ArchLog.i('needle', 'download dir picked');
              } catch (e) {
                ArchLog.w('needle', 'download dir failed: $e');
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not open folder picker')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
