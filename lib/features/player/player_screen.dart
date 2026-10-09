import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../library/song_row.dart';
import 'player_providers.dart';

/// Simple player on purpose — visual language gets rethought later.
/// Big art, red glow, transport, scrub bar. Everything moves.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(currentSongProvider).value;
    final playing = ref.watch(playingProvider).value ?? false;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final handler = ref.read(audioHandlerProvider);
    final total = song?.duration ?? Duration.zero;
    final totalMs = total.inMilliseconds;
    final posMs = position.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 1);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => ref.read(playerOpenProvider.notifier).state = false,
                  child: const Text('‹ Library', style: TextStyle(color: archRed)),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: archRed, width: 2),
                  boxShadow: const [
                    BoxShadow(color: Color(0x66FA1744), blurRadius: 32, spreadRadius: 2)
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: song == null
                      ? const Icon(Icons.music_note, color: inkTextDim, size: 96)
                      : Hero(
                          tag: 'art-${song.title}',
                          child: AlbumArt(albumId: song.albumId, fill: true, radius: 0),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              Text(song?.title ?? 'Nothing playing',
                  maxLines: 1, style: Theme.of(context).textTheme.headlineSmall),
              Text(song?.artist ?? 'Pick a song from the library',
                  maxLines: 1, style: const TextStyle(color: inkTextDim)),
              const SizedBox(height: 12),
              Slider(
                value: posMs.toDouble(),
                max: (totalMs > 0 ? totalMs : 1).toDouble(),
                activeColor: archRed,
                onChanged: (v) => handler.seek(Duration(milliseconds: v.toInt())),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(position), style: const TextStyle(color: inkTextDim)),
                  Text(_fmt(total), style: const TextStyle(color: inkTextDim)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    iconSize: 40,
                    onPressed: () => handler.skipToPrevious(),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton(
                    iconSize: 64,
                    color: archRed,
                    onPressed: () => playing ? handler.pause() : handler.play(),
                    icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                  ),
                  IconButton(
                    iconSize: 40,
                    onPressed: () => handler.skipToNext(),
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmt(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
