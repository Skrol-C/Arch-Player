import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../library/library_providers.dart';

/// Minimal settings: folders entry, version. Needle teasers live here later.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider).value ?? [];
    return ListView(
      padding: const EdgeInsets.only(bottom: 140),
      children: [
        const SizedBox(height: 56),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Settings', style: Theme.of(context).textTheme.headlineLarge),
        ),
        ListTile(
          title: const Text('Music folders'),
          subtitle: Text('${songs.length} songs in library'),
          trailing: const Text('Manage them from Library › Folders'),
        ),
        FutureBuilder(
          future: PackageInfo.fromPlatform(),
          builder: (context, snap) => ListTile(
            title: const Text('Version'),
            subtitle: Text(snap.data == null
                ? '…'
                : '${snap.data!.version} — Needle coming soon'),
          ),
        ),
      ],
    );
  }
}
