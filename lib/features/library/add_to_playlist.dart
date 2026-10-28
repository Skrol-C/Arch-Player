import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../player/morph_icon.dart';
import 'data/playlist_store.dart';
import 'library_providers.dart';
import 'playlist_art.dart';
import 'playlists_providers.dart';

/// New / rename dialog. Returns the created playlist (for callers
/// that want to open it), or null on cancel / rename.
Future<Playlist?> newPlaylistDialog(
  BuildContext context,
  WidgetRef ref, {
  Playlist? existing,
}) async {
  final c = TextEditingController(text: existing?.name ?? '');
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      title: Text(existing == null ? 'New playlist' : 'Rename playlist'),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: 60,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => Navigator.of(context).pop(c.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: archPink),
          onPressed: () => Navigator.of(context).pop(c.text),
          child: Text(existing == null ? 'Create' : 'Save'),
        ),
      ],
    ),
  );
  if (name == null || !context.mounted) return null;
  final clean = name.trim();
  if (clean.isEmpty) return null;
  HapticFeedback.selectionClick();
  final notifier = ref.read(playlistsProvider.notifier);
  if (existing == null) return notifier.create(clean);
  await notifier.rename(existing.id, clean);
  return null;
}

/// Add-to-playlist sheet: existing lists + Favourites + New.
/// Works for one song, select-mode bulks, and unowned refs (which
/// land as greyed pending entries). Check = already holds
/// everything picked; New adds the missing ids only.
Future<void> showAddToPlaylistSheet(
  WidgetRef ref,
  BuildContext context,
  List<Song> picked, {
  List<PendingTrack> pending = const [],
}) async {
  HapticFeedback.selectionClick();
  final lists = ref.read(playlistsProvider);
  final songs = ref.read(songsProvider).value ?? [];
  final ids = {for (final s in picked) s.id};
  final hasPending = pending.isNotEmpty;
  final pickedId = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.88,
    ),
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LiquidGlassLens(
        style: ArchGlass.sheet(
            radius: 28, amoled: isAmoledScheme(sheetContext)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(sheetContext)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
                  child: Text(
                    'Add to playlist',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: lists.length + 1,
              itemBuilder: (_, i) {
                if (i == lists.length) {
                  return CascadeIn(
                    delayMs: lists.length * 30,
                    child: ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(sheetContext)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.add_rounded, color: archPink),
                      ),
                      title: const Text(
                        'New playlist',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      onTap: () => Navigator.of(sheetContext).pop('_new'),
                    ),
                  );
                }
                final p = lists[i];
                final members = playlistSongs(p, songs);
                final has = ids.isNotEmpty &&
                    ids.every((id) => p.songIds.contains(id)) &&
                    !hasPending;
                return CascadeIn(
                  delayMs: i * 30,
                  child: ListTile(
                    leading: p.isSystem
                        ? Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.star_rounded,
                              color: archPink,
                            ),
                          )
                        : _SheetThumb(playlist: p, songs: members),
                    title: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${members.length} songs',
                      style: TextStyle(
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    trailing: has
                        ? const Icon(
                            CupertinoIcons.checkmark,
                            color: archPink,
                          )
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(p.id),
                  ),
                );
              },
            ),
          ),
                ],
              ),
            ),
          ),
        ),
      ),
  );
  if (pickedId == null || !context.mounted) return;
  final notifier = ref.read(playlistsProvider.notifier);
  if (pickedId == '_new') {
    final name = picked.length == 1 && pending.isEmpty
        ? picked.first.title
        : 'New Playlist';
    final created = await notifier.create(name);
    await notifier.addSongs(created.id, ids.toList());
    await notifier.addPending(created.id, pending);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Created "${created.name}"'
            '${ids.isEmpty ? '' : ' with ${ids.length} song${ids.length == 1 ? '' : 's'}'}'
            '${pending.isEmpty ? '' : ' + ${pending.length} to find'}',
          ),
        ),
      );
    }
    return;
  }
  final before =
      ref.read(playlistsProvider).where((p) => p.id == pickedId).firstOrNull;
  final fresh = [
    for (final id in ids)
      if (!(before?.songIds.contains(id) ?? false)) id,
  ];
  await notifier.addSongs(pickedId, fresh);
  await notifier.addPending(pickedId, pending);
  if (context.mounted) {
    final total = fresh.length + pending.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          total == 0
              ? 'Already in there'
              : 'Added $total song${total == 1 ? '' : 's'}'
                  '${pending.isEmpty ? '' : ' (${pending.length} to find)'}',
        ),
      ),
    );
  }
}

class _SheetThumb extends StatelessWidget {
  final Playlist playlist;
  final List<Song> songs;
  const _SheetThumb({required this.playlist, required this.songs});

  @override
  Widget build(BuildContext context) {
    if (playlist.hasCustomArt) {
      return FutureBuilder<Uint8List?>(
        future: PlaylistArt.coverBytes(playlist.customArt),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes != null && bytes.isNotEmpty) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                bytes,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
              ),
            );
          }
          return _gradientThumb(context);
        },
      );
    }
    return _gradientThumb(context);
  }

  Widget _gradientThumb(BuildContext context) {
    return FutureBuilder<List<Color>>(
      future: PlaylistArt.gradientFor(songs),
      builder: (context, snap) {
        final raised = Theme.of(context).colorScheme.surfaceContainerHighest;
        final stops = snap.data ?? [raised, raised];
        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: stops,
            ),
          ),
        );
      },
    );
  }
}
