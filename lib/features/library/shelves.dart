import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Library shelves, trimmed to one: Recently Added as a cover grid.
/// Shown only when no search query is active.
class Shelves extends ConsumerWidget {
  const Shelves({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(libraryQueryProvider);
    if (query.trim().isNotEmpty) return const SizedBox.shrink();
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [SizedBox(height: 8), _RecentlyAddedGrid()],
    );
  }
}

/// Up to 25 recent arrivals, cover-first. Tapping plays through them.
class _RecentlyAddedGrid extends ConsumerWidget {
  const _RecentlyAddedGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentlyAddedProvider);
    if (recent.isEmpty) return const SizedBox.shrink();
    final current = ref.watch(currentSongProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Recently Added',
            style: TextStyle(
              fontFamily: 'ArchSerif',
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 10),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 20,
            childAspectRatio: 0.78,
          ),
          itemCount: recent.length,
          itemBuilder: (context, i) {
            final song = recent[i];
            final selected = song.id == current?.id;
            return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                final handler = ref.read(audioHandlerProvider);
                playAndOpen(ref, context, () => handler.playSong(song, recent));
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: selected
                            ? Border.all(color: archPink, width: 2)
                            : null,
                      ),
                      child: FileArtImage(
                        path: song.path,
                        albumId: song.albumId,
                        fill: true,
                        radius: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    song.title,
                    maxLines: 1,
                    style: TextStyle(
                      color: selected ? archPink : ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    style: const TextStyle(color: inkDim, fontSize: 13),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
