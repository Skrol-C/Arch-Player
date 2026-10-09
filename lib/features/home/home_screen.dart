import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../library/library_providers.dart';
import '../library/song_row.dart';
import '../player/player_providers.dart';

/// Minimal landing: continue listening + recently added. The pill is the star.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider).value ?? [];
    final current = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    final recent = List<Song>.from(songs)
      ..sort((a, b) => b.year.compareTo(a.year));

    return ListView(
      padding: const EdgeInsets.only(bottom: 140),
      children: [
        const SizedBox(height: 56),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Home', style: Theme.of(context).textTheme.headlineLarge),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Continue listening',
              style: TextStyle(color: archRed, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        Builder(builder: (context) {
          final song = current ?? (songs.isEmpty ? null : songs.first);
          if (song == null) {
            return const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('Nothing yet — pick from Library.',
                  style: TextStyle(color: inkTextDim)),
            );
          }
          return ListTile(
            onTap: () async {
              final handler = ref.read(audioHandlerProvider);
              final opener = ref.read(playerOpenProvider.notifier);
              if (current == null) {
                await handler.playSong(song, songs);
              } else if (!playing) {
                await handler.play();
              }
              opener.state = true;
            },
            leading: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: inkRaised, borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.music_note, color: inkTextDim, size: 32),
            ),
            title: Text(song.title, maxLines: 1),
            subtitle: Text(song.artist,
                maxLines: 1, style: const TextStyle(color: inkTextDim)),
            trailing: current != null ? const NowBars() : null,
          );
        }),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Recently added',
              style: TextStyle(color: archRed, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        for (final song in recent.take(10))
          SongRow(
            song: song,
            art: Container(
              width: 52,
              height: 52,
              decoration:
                  BoxDecoration(color: inkRaised, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.music_note, color: inkTextDim),
            ),
            isCurrent: song.id == current?.id,
            onTap: () async {
              final handler = ref.read(audioHandlerProvider);
              final opener = ref.read(playerOpenProvider.notifier);
              await handler.playSong(song, recent);
              opener.state = true;
            },
          ),
      ],
    );
  }
}
