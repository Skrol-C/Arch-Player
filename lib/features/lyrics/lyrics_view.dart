import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../metadata/lyrics_providers.dart';
import '../player/player_providers.dart';
import 'lyric_stage.dart';

/// Inline lyrics filling the player below the transport. Synced
/// lines render on our own stage (sweep fill, handoff motion,
/// haptic flips); untimed tags render as prose; nothing found
/// renders an honest empty - never a hole.
class LyricsSlot extends ConsumerStatefulWidget {
  const LyricsSlot({super.key});

  /// Snap back to the live line (e.g. the toolbar lyrics button).
  /// Bumps the jump nonce; the stage re-centers on change.
  static void jumpToActive(WidgetRef ref) {
    ref.read(lyricJumpProvider.notifier).state++;
  }

  @override
  ConsumerState<LyricsSlot> createState() => _LyricsSlotState();
}

class _LyricsSlotState extends ConsumerState<LyricsSlot> {
  @override
  Widget build(BuildContext context) {
    final song = ref.watch(currentSongProvider).value;
    if (song == null) return const SizedBox.shrink();
    final docAsync = ref.watch(lyricsDocProvider(song.id));
    return docAsync.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(color: archPink)),
      error: (_, _) => _note(context, 'Lyrics unavailable right now.'),
      data: (doc) {
        if (doc.instrumental && !doc.hasSynced && !doc.hasPlain) {
          return _note(context, 'Instrumental - no words to show.');
        }
        if (doc.hasSynced) {
          return Column(
            children: [
              Expanded(
                child: LyricStage(
                  key: ValueKey('stage-${song.id}'),
                  syncedLrc: doc.syncedLrc!,
                  offset: Duration.zero,
                ),
              ),
              _sourceLine(doc),
            ],
          );
        }
        if (doc.hasPlain) {
          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(32, 12, 32, 24),
                  child: Text(
                    doc.plain!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 16,
                      height: 1.8,
                    ),
                  ),
                ),
              ),
              _sourceLine(doc),
            ],
          );
        }
        return _note(context, 'No lyrics for this track yet.');
      },
    );
  }

  Widget _sourceLine(LyricDoc doc) {
    final label = switch (doc.source) {
      LyricSource.embedded => 'Embedded lyrics',
      LyricSource.lrclib => 'Lyrics - LRCLib',
      LyricSource.none => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label, style: const TextStyle(color: inkDim, fontSize: 11)),
    );
  }

  Widget _note(BuildContext context, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: inkDim, fontSize: 14),
        ),
      ),
    );
  }
}
