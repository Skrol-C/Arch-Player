import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/song_row.dart';
import 'play_guarded.dart';
import 'player_providers.dart';

/// Glassy and clean: big art with pink glow, artist context line,
/// full transport. No generic plates.
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
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => ref.read(playerOpenProvider.notifier).state = false,
                child: const Text('‹ Library', style: TextStyle(color: archPink)),
              ),
            ),
            const SizedBox(height: 8),
            FocalEntrance(
              child: Container(
                height: 320,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: archPink.withValues(alpha: 0.5), width: 2),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33FC3C44), blurRadius: 40, spreadRadius: 2),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: song == null
                      ? const Icon(Icons.music_note, color: inkDim, size: 96)
                      : AlbumArt(albumId: song.albumId, fill: true, radius: 0),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(song?.title ?? 'Nothing playing',
                maxLines: 1,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall),
            Text(
                song == null
                    ? 'Pick a song from the library'
                    : '${song.artist} · ${song.album}',
                maxLines: 1,
                textAlign: TextAlign.center,
                style: const TextStyle(color: inkDim)),
            const SizedBox(height: 12),
            Slider(
              value: posMs.toDouble(),
              max: (totalMs > 0 ? totalMs : 1).toDouble(),
              activeColor: archPink,
              onChanged: (v) => handler.seek(Duration(milliseconds: v.toInt())),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(fmtDuration(position), style: const TextStyle(color: inkDim)),
                Text(fmtDuration(total), style: const TextStyle(color: inkDim)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  iconSize: 44,
                  color: ink,
                  onPressed: () => playGuarded(context, () => handler.skipToPrevious()),
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                Container(
                  width: 76,
                  height: 76,
                  decoration: const BoxDecoration(color: archPink, shape: BoxShape.circle),
                  child: IconButton(
                    iconSize: 40,
                    color: Colors.white,
                    onPressed: () =>
                        playGuarded(context, () => playing ? handler.pause() : handler.play()),
                    icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  ),
                ),
                IconButton(
                  iconSize: 44,
                  color: ink,
                  onPressed: () => playGuarded(context, () => handler.skipToNext()),
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text('Lyrics, queue and sleep live here soon',
                  style: TextStyle(color: inkDim, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
