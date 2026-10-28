import 'dart:async';

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
import '../automix/harmonic_order.dart' show pickHarmonicBatch;
import '../library/data/library_repository.dart';
import '../library/library_providers.dart';
import '../metadata/metadata_providers.dart' show metadataServiceProvider;
import 'audio_handler.dart';

final audioHandlerProvider = Provider<ArchAudioHandler>((ref) {
  throw UnimplementedError(
    'audioHandlerProvider must be overridden at startup',
  );
});

final playerOpenProvider = StateProvider<bool>((ref) => false);

/// True while the player is out as a pushed fullscreen route above a
/// pushed page. The shell overlay and the pushed route must never both
/// mount PlayerScreen: two live players double the lyrics/button
/// controllers and trip element-lifecycle asserts on pop/push.
final playerRouteOpenProvider = StateProvider<bool>((ref) => false);

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

/// Melted dock: the full mini goo-merges into the pill through a shared
/// blender instead of falling past it. One extra backdrop pass while the
/// dock is up - the Appearance kill switch for weak GPUs. Persisted like
/// the theme choice: self-syncing notifier, no boot override needed.
final pillGooProvider = NotifierProvider<PillGooNotifier, bool>(
  PillGooNotifier.new,
);

class PillGooNotifier extends Notifier<bool> {
  static const _key = 'arch.pillGoo';

  @override
  bool build() {
    _sync();
    return true;
  }

  Future<void> _sync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getBool(_key) ?? true;
    } catch (_) {}
  }

  Future<void> set(bool v) async {
    state = v;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, v);
    } catch (_) {}
  }
}

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
    // Notification-initiated flips arrive engine-first: converge state
    // and prefs off the same stream the notification icons read, so
    // the three can never disagree. Echoes of our own toggles no-op.
    final sub = ref.read(audioHandlerProvider).shuffleModeEnabledStream.listen((
      v,
    ) async {
      if (v == state) return;
      state = v;
      (await SharedPreferences.getInstance()).setBool('arch.shuffle', v);
      ArchLog.i('player', 'shuffle external sync=$v');
    });
    ref.onDispose(sub.cancel);
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

/// Automix: continuous harmonic playback. Persisted, default off,
/// one tap off — the hub doc's rule. The transition engine and
/// ordering read this; the switch itself is just honest state.
final autoMixProvider = NotifierProvider<AutoMixNotifier, bool>(
  AutoMixNotifier.new,
);

class AutoMixNotifier extends Notifier<bool> {
  @override
  bool build() {
    _sync();
    // Engine couldn't take over: flip the toggle off so the UI never
    // disagrees with what is actually playing.
    final handler = ref.read(audioHandlerProvider);
    final sub = handler.automixFailures.listen((_) async {
      if (!state) return;
      state = false;
      (await SharedPreferences.getInstance()).setBool('arch.automix', false);
      ArchLog.w('player', 'automix unavailable - toggled off');
    });
    ref.onDispose(sub.cancel);
    return false;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool('arch.automix') ?? false;
    state = v;
    if (v) {
      try {
        await ref.read(audioHandlerProvider).setAutomixEnabled(true);
      } catch (_) {}
    }
  }

  Future<void> toggle() async {
    final v = !state;
    state = v;
    (await SharedPreferences.getInstance()).setBool('arch.automix', v);
    ArchLog.i('player', 'automix=$v');
    try {
      await ref.read(audioHandlerProvider).setAutomixEnabled(v);
    } catch (_) {}
  }
}

/// Autoplay: when the queue runs out, keep playing with harmonically
/// compatible tracks from the library instead of stopping. Off by
/// default (opt-in). The handler asks for more via [needMoreMusic];
/// this fills from the library tail-first and remembers recent fills
/// so repeats need a full library cycle first.
final autoPlayProvider = NotifierProvider<AutoPlayNotifier, bool>(
  AutoPlayNotifier.new,
);

class AutoPlayNotifier extends Notifier<bool> {
  final List<int> _recentFillIds = [];

  @override
  bool build() {
    _sync();
    final sub = ref
        .read(audioHandlerProvider)
        .needMoreMusic
        .listen((_) => unawaited(_fill()));
    ref.onDispose(sub.cancel);
    return false;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool('arch.autoplay') ?? false;
    if (v) await ref.read(audioHandlerProvider).setAutoplayEnabled(true);
    state = v;
  }

  Future<void> toggle() async {
    final v = !state;
    state = v;
    await ref.read(audioHandlerProvider).setAutoplayEnabled(v);
    (await SharedPreferences.getInstance()).setBool('arch.autoplay', v);
    ArchLog.i('player', 'autoplay=$v');
  }

  /// Append the next tracks after the queue tail. Automix OFF:
  /// random picks - no analysis, no I/O, instant. Automix ON:
  /// harmonic batch over a capped, cache-only pool (never file
  /// tag reads: those are sync I/O and wedged the UI for minutes
  /// on large libraries). Unknowns fall back to random rather
  /// than stopping the music.
  bool _filling = false;

  Future<void> _fill() async {
    if (!ref.mounted || !state) return;
    if (_filling) return;
    _filling = true;
    try {
      await _fillInner().timeout(const Duration(seconds: 15));
    } catch (e) {
      ArchLog.w('player', 'autoplay fill failed: $e');
    } finally {
      _filling = false;
    }
  }

  Future<void> _fillInner() async {
    final handler = ref.read(audioHandlerProvider);
    final all = ref.read(songsProvider).value ?? const <Song>[];
    if (all.isEmpty) return;
    final tail = handler.queueTail;
    if (tail == null) return;
    final queued = handler.queueSongIds.toSet();
    final eligible = [
      for (final s in all)
        if (s.id != tail.id &&
            !queued.contains(s.id) &&
            !_recentFillIds.contains(s.id))
          s,
    ];
    if (eligible.isEmpty) return;
    List<Song> picks;
    if (!handler.automixOn) {
      eligible.shuffle();
      picks = eligible.take(5).toList();
    } else {
      final meta = ref.read(metadataServiceProvider);
      // Disk cache only (no path): file tag reads are sync I/O.
      // Memoized: scoring touches every pair without this.
      final memo = <int, TrackMusicalInfo?>{};
      TrackMusicalInfo? infoOf(Song s) => memo.putIfAbsent(
            s.id,
            () => meta.musicalInfoCached(
              title: s.title,
              artist: s.artist,
            ),
          );
      // Capped: scoring is O(k*n) and must stay millisecond-scale.
      // The recent/queued exclusions rotate variety across fills.
      final pool = [tail, ...eligible.take(300)];
      final ids = pickHarmonicBatch(
        songs: pool,
        infoOf: infoOf,
        fromId: tail.id,
        recentIds: {...queued, ..._recentFillIds},
        k: 5,
      );
      if (ids.isEmpty) {
        eligible.shuffle();
        picks = eligible.take(5).toList();
        ArchLog.i(
          'automix',
          'autoplay harmonic found nothing - random fallback',
        );
      } else {
        picks = [for (final id in ids) pool.firstWhere((s) => s.id == id)];
      }
    }
    if (picks.isEmpty) return;
    if (ref.read(shuffleProvider)) picks.shuffle();
    _recentFillIds.addAll([for (final p in picks) p.id]);
    while (_recentFillIds.length > 60) {
      _recentFillIds.removeAt(0);
    }
    ArchLog.i(
      'automix',
      'autoplay append ${picks.length} after ${tail.id}',
    );
    await handler.appendToQueue(picks);
  }
}

final loopProvider = NotifierProvider<LoopNotifier, LoopMode>(LoopNotifier.new);

class LoopNotifier extends Notifier<LoopMode> {
  @override
  LoopMode build() {
    _sync();
    // Same engine-first convergence as shuffle above.
    final sub = ref.read(audioHandlerProvider).loopModeStream.listen((v) async {
      if (v == state) return;
      state = v;
      (await SharedPreferences.getInstance()).setInt('arch.loop', v.index);
      ArchLog.i('player', 'loop external sync=$v');
    });
    ref.onDispose(sub.cancel);
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
/// Follows the engine's shuffle permutation while shuffling, true
/// order otherwise — Up Next shows what will actually play.
final queueProvider = StreamProvider<List<Song>>((ref) {
  final songs = ref.watch(songsProvider).value ?? [];
  final handler = ref.watch(audioHandlerProvider);
  return handler.effectiveQueueStream.map(
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

/// Adaptive wash for the player canvas: the artwork's muted tone pulled
/// toward the page, contrast-clamped so page text always reads.
/// Light pulls toward paper for ink text; dark/amoled pulls toward the
/// scaffold for light text. Brightness is a parameter, not an
/// assumption - dark mode flips this mapping, nothing else.
Color playerWashOf(ArtPalette? palette, {bool dark = false, bool amoled = false}) {
  return archWashOf(palette?.wash, dark: dark, amoled: amoled);
}
