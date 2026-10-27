import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/log.dart';
import '../../library/data/playlist_store.dart';
import '../../library/playlists_providers.dart';
import '../widgets/setting_bits.dart';

/// Backup: playlists out and back in as one JSON document. Export
/// shares a file; import reads one back through the system picker.
/// Song links are by id, pending tracks by title+artist — a restore
/// on a fresh scan re-links what it can and keeps the rest pending.
class BackupPage extends ConsumerWidget {
  const BackupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'backup open');
    final lists = ref.watch(playlistsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Playlists',
            children: [
              SettingRow(
                icon: Icons.backup_rounded,
                title: 'Export playlists',
                subtitle:
                    '${lists.length} playlists → one JSON file',
                onTap: () => _export(context, ref, lists),
              ),
              SettingRow(
                icon: Icons.restore_rounded,
                title: 'Import playlists',
                subtitle: 'Restore from an exported JSON file',
                onTap: () => _import(context, ref),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Exports carry names, order, and track links — never '
              'audio files. Keep the file somewhere safe; it is the '
              'whole of your curation.',
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

  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    List<Playlist> lists,
  ) async {
    HapticFeedback.selectionClick();
    try {
      final doc = {
        'app': 'arch_player',
        'version': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'playlists': [
          for (final p in lists)
            {
              'id': p.id,
              'name': p.name,
              'songIds': p.songIds,
              'updatedMs': p.updatedMs,
              'pending': [
                for (final t in p.pending)
                  {
                    'title': t.title,
                    'artist': t.artist,
                    'album': t.album,
                  },
              ],
            },
        ],
      };
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}/arch-playlists-${DateTime.now().toUtc().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(doc),
      );
      ArchLog.i('backup', 'exported ${lists.length} playlists');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: 'Arch Player playlists',
        ),
      );
    } catch (e) {
      ArchLog.w('backup', 'export failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Export failed')));
      }
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    HapticFeedback.selectionClick();
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final path = picked?.path;
      if (path == null) return;
      final doc = jsonDecode(await File(path).readAsString());
      if (doc is! Map || doc['playlists'] is! List) {
        throw const FormatException('not an Arch playlists file');
      }
      if (doc['app'] != 'arch_player') {
        throw const FormatException('not an Arch playlists file');
      }
      final store = ref.read(playlistStoreProvider);
      final existing = await store.load();
      final ids = {for (final p in existing) p.id};
      var added = 0;
      final merged = [...existing];
      for (final raw in (doc['playlists'] as List)) {
        if (raw is! Map) continue;
        final id = '${raw['id'] ?? ''}';
        if (id.isEmpty || ids.contains(id)) continue;
        ids.add(id);
        merged.add(
          Playlist(
            id: id,
            name: '${raw['name'] ?? 'Restored'}',
            songIds: [
              for (final s in (raw['songIds'] as List? ?? []))
                if (s is int) s,
            ],
            updatedMs:
                (raw['updatedMs'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
            pending: [
              for (final t in (raw['pending'] as List? ?? []))
                if (t is Map)
                  PendingTrack(
                    title: '${t['title'] ?? ''}',
                    artist: '${t['artist'] ?? ''}',
                    album: '${t['album'] ?? ''}',
                  ),
            ],
          ),
        );
        added++;
      }
      await store.save(merged);
      ref.invalidate(playlistsProvider);
      ArchLog.i('backup', 'imported $added playlists');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restored $added playlists')),
        );
      }
    } catch (e) {
      ArchLog.w('backup', 'import failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read that file')),
        );
      }
    }
  }
}
