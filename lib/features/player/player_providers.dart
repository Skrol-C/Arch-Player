import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/art_tone.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../library/data/library_repository.dart';
import '../library/library_providers.dart';
import 'audio_handler.dart';

final audioHandlerProvider = Provider<ArchAudioHandler>((ref) {
  throw UnimplementedError(
    'audioHandlerProvider must be overridden at startup',
  );
});

final playerOpenProvider = StateProvider<bool>((ref) => false);

/// Player panel: cover art, full lyrics, or queue. Lyrics and queue
/// buttons toggle their panel (tap again returns to cover). The art
/// header morphs between full and compact with the panel - one stage,
/// like the reference, not three screens.
enum PlayerPanel { none, lyrics, queue }

final playerPanelProvider = StateProvider<PlayerPanel>(
  (ref) => PlayerPanel.none,
);

/// Lyrics immersion: chrome fades after 3s idle on the lyrics
/// panel, restored by any tap. The banner + words stay; everything
/// else melts.
final immersionProvider = StateProvider<bool>((ref) => false);

/// Keep-awake while the player is open (lyrics reading, shelf
/// listening): on when the player opens, off when it closes. The OS
/// clears the flag with the window, so no leak path exists.
final _wakeChannel = MethodChannel('arch.player/library');

Future<void> setKeepAwake(bool keep) async {
  try {
    await _wakeChannel.invokeMethod('setKeepAwake', {'keep': keep});
  } catch (e) {
    ArchLog.w('player', 'wake failed: $e');
  }
}

/// Mini player visibility: content exists and the full player isn't
/// open. One driver for the mini bar, the adaptive pill margin, and
/// the library bottom clearance - they never disagree.
final miniVisibleProvider = Provider<bool>((ref) {
  final open = ref.watch(playerOpenProvider);
  final song = ref.watch(currentSongProvider).value;
  return !open && song != null;
});

/// One resolution rule for media items: library match by songId, else
/// render from the item itself (streaming previews) so no surface ever
/// shows "nothing playing" while audio flows.
Song songFromItem(MediaItem item, List<Song> songs) {
  final id = item.extras?['songId'] as int?;
  if (id != null) {
    for (final s in songs) {
      if (s.id == id) return s;
    }
  }
  return Song(
    id: id ?? -1,
    uri: Uri.tryParse(item.id) ?? Uri(),
    title: item.title,
    artist: item.artist ?? '',
    album: item.album ?? '',
    albumId: 0,
    duration: item.duration ?? const Duration(seconds: 30),
    year: 0,
    folderKey: 'preview',
    folderLabel: 'Preview',
  );
}

final currentSongProvider = StreamProvider<Song?>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return handler.mediaItem.asyncMap((item) {
    if (item == null) return null;
    final id = item.extras?['songId'] as int?;
    ArchLog.i('player', 'currentSong id=$id title=${item.title}');
    final songs = ref.read(songsProvider).value ?? [];
    return songFromItem(item, songs);
  });
});

final playingProvider = StreamProvider<bool>((ref) {
  return ref
      .watch(audioHandlerProvider)
      .playbackState
      .map((s) => s.playing)
      .distinct();
});

final positionProvider = StreamProvider<Duration>((ref) {
  return AudioService.position;
});

/// Buffered position for the scrub bar's secondary fill.
final bufferedProvider = StreamProvider<Duration>((ref) {
  return ref
      .watch(audioHandlerProvider)
      .playbackState
      .map((s) => s.bufferedPosition)
      .distinct();
});

/// True while the engine is preparing or stalled: the player screen
/// shows its loading state and parks the transport until audio flows.
final bufferingProvider = StreamProvider<bool>((ref) {
  return ref
      .watch(audioHandlerProvider)
      .playbackState
      .map(
        (s) =>
            s.processingState == AudioProcessingState.loading ||
            s.processingState == AudioProcessingState.buffering,
      )
      .distinct();
});

/// Shuffle + repeat: state here, engine application + disk memory
/// inside. Persisted across restarts, applied to the live player on
/// load so state and engine never disagree.
final shuffleProvider = NotifierProvider<ShuffleNotifier, bool>(
  ShuffleNotifier.new,
);

class ShuffleNotifier extends Notifier<bool> {
  @override
  bool build() {
    _sync();
    return false;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool('arch.shuffle') ?? false;
    if (v) await ref.read(audioHandlerProvider).setShuffleEnabled(true);
    state = v;
  }

  Future<void> toggle() async {
    final v = !state;
    state = v;
    await ref.read(audioHandlerProvider).setShuffleEnabled(v);
    (await SharedPreferences.getInstance()).setBool('arch.shuffle', v);
  }
}

final loopProvider = NotifierProvider<LoopNotifier, LoopMode>(LoopNotifier.new);

class LoopNotifier extends Notifier<LoopMode> {
  @override
  LoopMode build() {
    _sync();
    return LoopMode.off;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = LoopMode.values[(prefs.getInt('arch.loop') ?? 0).clamp(0, 2)];
    if (v != LoopMode.off) await ref.read(audioHandlerProvider).setLoopMode(v);
    state = v;
  }

  /// off -> all -> one -> off.
  Future<void> cycle() async {
    final v = LoopMode.values[(state.index + 1) % LoopMode.values.length];
    state = v;
    await ref.read(audioHandlerProvider).setLoopMode(v);
    (await SharedPreferences.getInstance()).setInt('arch.loop', v.index);
  }
}

/// Sleep countdown: null = off. Ticks every second while armed.
final sleepProvider = StreamProvider<Duration?>((ref) {
  return ref.watch(audioHandlerProvider).sleepStream;
});

/// The live queue, resolved to songs by the one rule. Re-maps when
/// the library reloads so queue rows always have art and titles.
final queueProvider = StreamProvider<List<Song>>((ref) {
  final songs = ref.watch(songsProvider).value ?? [];
  final handler = ref.watch(audioHandlerProvider);
  return handler.queueStream.map(
    (items) => [for (final item in items) songFromItem(item, songs)],
  );
});

/// Artwork palette for the current track, from bytes already held by
/// ArtCache - zero extra I/O. Null until art (or a song) exists.
final playerPaletteProvider = FutureProvider<ArtPalette?>((ref) {
  final song = ref.watch(currentSongProvider).value;
  if (song == null || song.albumId <= 0) return null;
  return ArtTone.paletteFromBytes(
    'art:${song.albumId}',
    () => ArtCache.of(song.albumId, ArtBucket.large),
  );
});

/// Adaptive light wash for the player canvas: the artwork's muted
/// tone pulled toward paper, contrast-clamped so ink always reads.
/// Brightness is a parameter, not an assumption - dark mode later
/// flips this mapping, nothing else.
Color playerWashOf(ArtPalette? palette) {
  final base = palette?.wash ?? paperRaised;
  var pull = 0.6;
  var wash = Color.lerp(base, paper, pull)!;
  while (pull < 1.0 && _inkContrast(wash) < 4.5) {
    pull += 0.05;
    wash = Color.lerp(base, paper, pull)!;
  }
  return wash;
}

double _inkContrast(Color wash) {
  final l1 = ink.computeLuminance() + 0.05;
  final l2 = wash.computeLuminance() + 0.05;
  return l1 > l2 ? l1 / l2 : l2 / l1;
}
