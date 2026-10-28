import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../player/morph_icon.dart';
import '../settings/widgets/arch_switch.dart';
import 'library_providers.dart';

/// Unlimited folder control: picked homes, per-folder toggles, add more.
/// Toggles live here (in context); Settings holds the summary + entry.
class FolderSheet extends ConsumerWidget {
  const FolderSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    final excluded = ref.watch(excludedProvider).value ?? {};
    final picked = ref.watch(pickedProvider).value ?? {};
    final songs = ref.watch(songsProvider).value ?? [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Music folders',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              '${songs.length} songs in library',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            if (picked.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Picked homes: ${picked.length}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: folders.length,
                itemBuilder: (context, i) {
                  final folder = folders[i];
                  final off = excluded.contains(folder.key);
                  return CascadeIn(
                    // Cap the stagger: long folder lists shouldn't
                    // ripple forever, and states persist so only
                    // newly added rows ever replay.
                    delayMs: i.clamp(0, 8) * 30,
                    child: ListTile(
                      title: Text(folder.label),
                      subtitle: Text('${folder.count} songs'),
                      trailing: ArchSwitch(
                        value: !off,
                        onChanged: (on) =>
                            toggleFolder(ref, folder.key, !on),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _addFolder(context, ref),
                    child: const Text('Add folder'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addFolder(BuildContext context, WidgetRef ref) async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Where is your music?',
      );
      if (path == null) return;
      await ref.read(folderStoreProvider).addPicked(path);
      ArchLog.i('folders', 'picked: $path');
      ref.invalidate(songsProvider);
      ref.invalidate(pickedProvider);
    } catch (e) {
      ArchLog.w('folders', 'add failed: $e');
    }
  }
}
