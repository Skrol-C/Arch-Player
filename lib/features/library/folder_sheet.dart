import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_providers.dart';

/// Unlimited folder toggles, tucked in a sheet so the library stays premium.
class FolderSheet extends ConsumerWidget {
  const FolderSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    final excluded = ref.watch(excludedProvider).value ?? {};
    final songs = ref.watch(songsProvider).value ?? [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Music folders', style: Theme.of(context).textTheme.titleLarge),
            Text('${songs.length} songs in library',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: folders.length,
                itemBuilder: (context, i) {
                  final folder = folders[i];
                  final off = excluded.contains(folder.key);
                  return SwitchListTile(
                    title: Text(folder.label),
                    subtitle: Text('${folder.count} songs'),
                    value: !off,
                    onChanged: (on) => toggleFolder(ref, folder.key, !on),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  // SAF folder add lands with the next iteration; toggles
                  // cover every MediaStore folder today.
                  Navigator.of(context).pop();
                },
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
