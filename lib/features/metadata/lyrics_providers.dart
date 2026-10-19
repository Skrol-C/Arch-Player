import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models.dart';
import '../library/library_providers.dart';
import '../lyrics/tag_lyrics.dart';
import 'metadata_providers.dart';

/// Lyric resolution, one order: explicit Finder pick -> embedded
/// tags -> LRCLib network. A pick wins over the file (otherwise a
/// cache-only PaxSenIX choice would hide behind stale embedded
/// lines forever); the file wins over the network.
/// Keyed by song id; the doc carries its own source for honest UI.
final lyricsDocProvider = FutureProvider.family<LyricDoc, int>((
  ref,
  songId,
) async {
  final songs = ref.watch(songsProvider).value ?? [];
  Song? song;
  for (final s in songs) {
    if (s.id == songId) {
      song = s;
      break;
    }
  }
  if (song == null) return const LyricDoc();
  try {
    final pick =
        await ref.watch(metadataServiceProvider).pickedLyrics(song.id);
    if (pick != null &&
        (pick.hasSynced || pick.hasPlain || pick.instrumental)) {
      return pick;
    }
  } catch (_) {}
  if (song.path.isNotEmpty) {
    final embedded = readEmbeddedLyrics(song.path);
    if (embedded.hasSynced || embedded.hasPlain) return embedded;
  }
  try {
    return await ref
        .watch(metadataServiceProvider)
        .lyricsFor(
          songId: song.id,
          artist: song.artist,
          title: song.title,
          album: song.album,
          durationSecs: song.duration.inSeconds,
        );
  } catch (_) {
    return const LyricDoc();
  }
});

/// Re-center request for the lyric stage (toolbar lyrics button).
/// Bumped, never set - the stage scrolls on change.
final lyricJumpProvider = StateProvider<int>((ref) => 0);

/// Haptic tick as lyric lines turn over. Default on; Settings V2
/// wires the visible toggle. Persisted like shuffle/repeat.
final lyricHapticsProvider = NotifierProvider<LyricHapticsNotifier, bool>(
  LyricHapticsNotifier.new,
);

class LyricHapticsNotifier extends Notifier<bool> {
  @override
  bool build() {
    _sync();
    return true;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('arch.lyricHaptics') ?? true;
  }

  Future<void> set(bool v) async {
    state = v;
    (await SharedPreferences.getInstance()).setBool('arch.lyricHaptics', v);
  }
}
