import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import '../../library/library_providers.dart';
import '../widgets/setting_bits.dart';

/// Library: scan state at a glance. Counts come from the live scan,
/// rescan re-runs it. The button invalidates the same provider the
/// library screens read, so there is exactly one source of truth.
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'library settings open');
    final songs = ref.watch(songsProvider);
    final excluded = ref.watch(excludedProvider).value ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          songs.when(
            loading: () => SettingState.loading('Reading the library…'),
            error: (e, _) => SettingState.error(
              'Could not read the library: $e',
              retry: () => ref.invalidate(songsProvider),
            ),
            data: (list) {
              final artists = {
                for (final s in list) s.artist.toLowerCase(),
              }.length;
              final albums = {
                for (final s in list)
                  '${s.artist.toLowerCase()}\x00${s.album.toLowerCase()}',
              }.length;
              return SettingGroup(
                title: 'Scan',
                children: [
                  _CountRow(
                    icon: Icons.music_note_rounded,
                    title: 'Tracks',
                    value: '${list.length}',
                  ),
                  _CountRow(
                    icon: Icons.album_rounded,
                    title: 'Albums',
                    value: '$albums',
                  ),
                  _CountRow(
                    icon: Icons.person_rounded,
                    title: 'Artists',
                    value: '$artists',
                  ),
                  _CountRow(
                    icon: Icons.folder_off_rounded,
                    title: 'Excluded folders',
                    value: '${excluded.length}',
                  ),
                ],
              );
            },
          ),
          SettingGroup(
            title: 'Maintenance',
            children: [
              SettingRow(
                icon: Icons.refresh_rounded,
                title: 'Rescan library',
                subtitle: 'Pick up new and removed files',
                onTap: () {
                  HapticFeedback.selectionClick();
                  ArchLog.i('settings', 'manual rescan');
                  ref.invalidate(songsProvider);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Rescanning the library…'),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _CountRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.music_note_rounded,
          color: Color(0xFFFC3C44),
        ),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      trailing: Text(
        value,
        style: TextStyle(
          color: scheme.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
