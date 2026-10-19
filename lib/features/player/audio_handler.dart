import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../library/data/art_previews.dart';
import '../library/data/library_repository.dart';

/// Album art for lock-screen/notification, cached on disk. The native side
/// loads `artCacheFile` preferentially; content URIs resolve via its own
/// ContentResolver path. Failures degrade to no art, never a crash.
class NotifArt {
  static Future<String?> cacheCover(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return await cacheBytes(res.bodyBytes, '${url.hashCode}');
    } catch (e) {
      ArchLog.w('player', 'notif art failed: $e');
      return null;
    }
  }

  /// Raw bytes (embedded art via ArtCache) to a stable notification file.
  static Future<String?> cacheBytes(Uint8List bytes, String name) async {
    try {
      if (bytes.isEmpty) return null;
      final dir = await getApplicationCacheDirectory();
      final art = Directory('${dir.path}/notif_art');
      if (!await art.exists()) await art.create(recursive: true);
      final file = File('${art.path}/$name.jpg');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      ArchLog.w('player', 'notif art bytes failed: $e');
      return null;
    }
  }
}

/// Own heartbeat: background playback. UI may crash; this keeps playing.
class ArchAudioHandler extends BaseAudioHandler {
  final AudioPlayer _player = AudioPlayer();
  List<Song> _songs = [];
  bool _busy = false;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  int _playGen = 0;
  int _skipGen = 0;

  ArchAudioHandler() {
    _player.playbackEventStream.map(_toPlaybackState).pipe(playbackState);
    // Notification icons mirror engine state (shuffle/repeat), not
    // just playback events: re-publish on those flips.
    _player.shuffleModeEnabledStream.listen((_) => _republish());
    _player.loopModeStream.listen((_) => _republish());
    // The notification only rebuilds on control flips and metadata sets —
    // never on index change alone. So every index change re-sets the
    // media item explicitly: taps, auto-advance, next/prev, lock intents.
    // Routed through _setItem so the known art file rides along and
    // the extra never flaps off and back (that flap is the flicker).
    _player.currentIndexStream.listen((index) {
      if (index == null) return;
      final items = queue.value;
      if (index < 0 || index >= items.length) return;
      _setItem(items[index]);
      ArchLog.i('player', 'index -> ${items[index].title}');
      // Auto-advance lands artless (see above): attach behind, guarded.
      if (index < _songs.length) {
        final s = _songs[index];
        if (items[index].id == s.uri.toString()) {
          unawaited(_attachArtFile(s));
        }
      }
    });
    unawaited(_configureSession());
  }

  /// Re-publish the current state (notification icon refresh). Reads
  /// the live event so nothing else has to be threaded through.
  void _republish() {
    try {
      playbackState.add(_toPlaybackState(_player.playbackEvent));
    } catch (e) {
      ArchLog.w('player', 'republish failed: $e');
    }
  }

  /// Last-known art file per media id: every mediaItem assignment
  /// routes through [_setItem] so a known file rides along and the
  /// extra never flaps off and back (that flap is the art flicker).
  final Map<String, String> _artFiles = {};
  static const _artCap = 64;

  void _rememberArt(String id, String path) {
    if (id.isEmpty || path.isEmpty) return;
    _artFiles[id] = path;
    while (_artFiles.length > _artCap) {
      _artFiles.remove(_artFiles.keys.first);
    }
  }

  void _setItem(MediaItem item) {
    var extras = item.extras;
    final has = (extras?['artCacheFile'] as String?) ?? '';
    if (has.isNotEmpty) {
      _rememberArt(item.id, has);
    } else {
      final known = _artFiles[item.id];
      if (known != null && known.isNotEmpty) {
        item = item.copyWith(extras: {...?extras, 'artCacheFile': known});
      }
    }
    mediaItem.value = item;
  }

  /// Explicit audio session (their wheel, our policy): media usage,
  /// full gain (calls and nav still interrupt — never music-over-calls),
  /// and OS ducking for transient pings (notification sounds dip the
  /// volume instead of stopping the music). Full pause only for real
  /// takeovers. Auto-resume is foreground-gated: never surprise-resume
  /// while the user is inside another app.
  /// Every event logs — focus issues are diagnosable forever after this.
  bool _pausedForInterruption = false;

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          // False = the OS dips our volume itself on duckable
          // transients (notification pings). True used to park the
          // whole track for every ping — that was the full pause.
          androidWillPauseWhenDucked: false,
        ),
      );
      session.interruptionEventStream.listen((e) async {
        ArchLog.i('player', 'interruption begin=${e.begin} type=${e.type}');
        try {
          if (!e.begin) {
            if (_pausedForInterruption) {
              _pausedForInterruption = false;
              // Resume only if we're the foreground app. An app like
              // TikTok abandons focus every time it pauses a video —
              // resuming unconditionally is what kept pulling music
              // back while the user was still inside it.
              final foregrounded =
                  WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed;
              if (foregrounded && !_player.playing) {
                await _player.play();
                ArchLog.i('player', 'resumed after interruption');
              } else if (!foregrounded) {
                ArchLog.i(
                  'player',
                  'interruption ended in background - staying paused',
                );
              }
            }
            return;
          }
          // Duckable transient (notification ping, nav prompt): the OS
          // handles the dip — keep playing, touch nothing.
          if (e.type == AudioInterruptionType.duck) {
            ArchLog.i('player', 'ducking under transient');
            return;
          }
          if (_player.playing) {
            _pausedForInterruption = true;
            await _player.pause();
          }
        } catch (err) {
          ArchLog.w('player', 'interruption handling failed: $err');
        }
      });
      session.becomingNoisyEventStream.listen((_) async {
        ArchLog.i('player', 'becoming noisy (output lost)');
        try {
          if (_player.playing) await _player.pause();
        } catch (err) {
          ArchLog.w('player', 'noisy-pause failed: $err');
        }
      });
      ArchLog.i('player', 'audio session configured (gain, pause-on-duck)');
    } catch (e) {
      ArchLog.w('player', 'audio session config failed: $e');
    }
  }

  /// Queue as a stream for the queue sheet. Every mutation flows through
  /// [_emitQueue] so the audio_service value and the UI stream stay one
  /// truth - never drift.
  StreamController<List<MediaItem>>? _queueController;

  Stream<List<MediaItem>> get queueStream {
    _queueController ??= StreamController<List<MediaItem>>.broadcast(
      onListen: () => _queueController?.add(List.of(queue.value)),
    );
    return _queueController!.stream;
  }

  /// Engine truth for notification-initiated flips: the providers
  /// converge off these same streams the notification icons read.
  Stream<bool> get shuffleModeEnabledStream => _player.shuffleModeEnabledStream;
  Stream<LoopMode> get loopModeStream => _player.loopModeStream;

  void _emitQueue(List<MediaItem> items) {
    queue.value = items;
    if (_queueController?.hasListener ?? false) {
      _queueController!.add(List.of(items));
    }
  }

  Future<void> setQueueSongs(List<Song> songs, {int startIndex = 0}) async {
    _songs = List<Song>.from(songs);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    // No preload: the tap answers now, media prepares behind the open
    // player screen. Preloading whole-library queues is what made taps
    // feel dead for seconds.
    await _player.setAudioSources(
      _songs.map((s) => AudioSource.uri(s.uri)).toList(),
      initialIndex: startIndex,
      preload: false,
    );
  }

  /// Atomic tap: newest wins, superseded calls bail silently, failure
  /// is verified before it surfaces. Every decision is logged: the
  /// next "it didn't switch" report diagnoses from one tap's lines
  /// instead of a week of guesses.
  Future<void> playSong(Song song, List<Song> context) async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) {
      ArchLog.i('player', 'tap debounced id=${song.id}');
      return;
    }
    _lastTap = now;
    // Newest tap wins: an in-flight older call bails at its next
    // checkpoint instead of landing late and reading as an auto-skip.
    final gen = ++_playGen;
    final watch = Stopwatch()..start();
    // If the engine is held by an older call, nudge it loose first
    // (stop aborts a pending load), then wait briefly for release.
    // Never pile a second setAudioSources onto a live one.
    if (_busy) {
      ArchLog.i('player', 'tap preempt id=${song.id}');
      unawaited(
        _player.stop().timeout(const Duration(seconds: 2)).catchError((_) {}),
      );
    }
    var waited = 0;
    while (_busy && waited < 30) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited++;
    }
    if (gen != _playGen) return;
    if (_busy) {
      ArchLog.w(
        'player',
        'tap engine still held id=${song.id} waited=${watch.elapsedMilliseconds}ms - taking over',
      );
    }
    _busy = true;
    // Rollback target: the UI commits optimistically below; on failure
    // it goes back to this instead of stranding on a silent song.
    final prevItem = mediaItem.value;
    final index = context.indexWhere((s) => s.id == song.id);
    try {
      ArchLog.i(
        'player',
        'play id=${song.id} title=${song.title} scheme=${song.uri.scheme}',
      );
      if (index < 0) {
        ArchLog.w('player', 'tap song missing from context id=${song.id}');
        return;
      }
      final sameQueue =
          _songs.length == context.length &&
          _songs.every((s) => context.any((c) => c.id == s.id));
      if (!sameQueue) {
        // Network previews can stall forever (expired URL, captive
        // portal). Bound it; failure surfaces, never wedges.
        await setQueueSongs(
          context,
          startIndex: index,
        ).timeout(const Duration(seconds: 20));
        if (gen != _playGen) return;
        ArchLog.i(
          'player',
          'queue rebuilt id=${song.id} n=${context.length} in=${watch.elapsedMilliseconds}ms',
        );
      } else {
        await _player
            .seek(Duration.zero, index: index)
            .timeout(const Duration(seconds: 10));
        if (gen != _playGen) return;
        ArchLog.i(
          'player',
          'same-queue seek id=${song.id} index=$index in=${watch.elapsedMilliseconds}ms',
        );
      }
      // currentIndexStream fires too, but set it now so the first
      // notification frame is already correct — never one stale behind.
      _setItem(song.toMediaItem());
      await _player.play().timeout(const Duration(seconds: 10));
      if (gen != _playGen) return;
      // Audibility gate: seek resolving is not playback — with lazy
      // sources the engine can sit silent for seconds, then fall
      // through to the neighbor. Confirm the index actually sounds;
      // on failure pause the fall-through, roll the UI back, surface.
      final landed = await _awaitAudible(index, gen);
      if (!landed) {
        if (gen != _playGen) return;
        ArchLog.w(
          'player',
          'tap inaudible id=${song.id} index=$index actual=${_player.currentIndex}',
        );
        try {
          await _player.pause();
        } catch (_) {}
        if (prevItem != null) _setItem(prevItem);
        throw StateError('tap inaudible id=${song.id}');
      }
      ArchLog.i(
        'player',
        'playing id=${song.id} in=${watch.elapsedMilliseconds}ms',
      );
      // Art follows behind the tap (zero tap cost): re-set the item
      // with a file-backed cover once resolved. Triple-guarded so a
      // slow fetch can never paint stale art over a newer track.
      unawaited(_attachArtFile(song));
    } catch (e) {
      // Superseded: silent by design, the newer tap owns the UI now.
      if (gen != _playGen) return;
      // Late success beats the error: if the engine actually sounds
      // the requested index, a toast would be a lie. Log and swallow.
      if (_player.playing && _player.currentIndex == index) {
        ArchLog.i('player', 'tap late success id=${song.id} after $e');
        unawaited(_attachArtFile(song));
        return;
      }
      rethrow;
    } finally {
      if (gen == _playGen) _busy = false;
    }
  }

  /// True once the engine audibly holds [index]. Fails fast the
  /// moment the index drifts elsewhere (fall-through), times out
  /// otherwise. Never throws: the caller decides.
  Future<bool> _awaitAudible(int index, int gen) async {
    for (var i = 0; i < 40; i++) {
      if (gen != _playGen) return false;
      final current = _player.currentIndex;
      // Index moved under us: the engine fell through to a neighbor.
      if (current != null && current != index) return false;
      if (_player.playing &&
          _player.processingState == ProcessingState.ready &&
          current == index) {
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return _player.playing && _player.currentIndex == index;
  }

  Future<void> _attachArtFile(Song song) async {
    try {
      // File-art previews first: instant when warm, exact for owned
      // files, and independent of MediaStore album art (missing for
      // fresh pulls — the old path silently attached nothing there).
      if (song.path.isNotEmpty) {
        final id = song.uri.toString();
        if (mediaItem.value?.id != id) return;
        final preview = await ArtPreviews.previewFor(song.path)
            .timeout(const Duration(seconds: 8));
        if (preview != null && preview.isNotEmpty) {
          if (mediaItem.value?.id != id) return;
          _setItem(
            mediaItem.value!.copyWith(
              extras: {...?mediaItem.value!.extras, 'artCacheFile': preview},
            ),
          );
          ArchLog.i('player', 'notif art preview id=${song.id}');
          return;
        }
      }
      if (song.albumId <= 0) return;
      final id = song.uri.toString();
      if (mediaItem.value?.id != id) return;
      final bytes = await ArtCache.of(song.albumId)
          .timeout(const Duration(seconds: 8));
      if (bytes == null || bytes.isEmpty) return;
      if (mediaItem.value?.id != id) return;
      final file = await NotifArt.cacheBytes(bytes, 'album_${song.albumId}');
      if (file == null || mediaItem.value?.id != id) return;
      final current = mediaItem.value;
      if (current == null) return;
      _setItem(
        current.copyWith(extras: {...?current.extras, 'artCacheFile': file}),
      );
      ArchLog.i('player', 'notif art attached id=${song.id}');
    } catch (_) {}
  }

  /// Preview with cover art: item + audio go first so the first
  /// tap answers instantly; the cover downloads behind and patches
  /// the extras when it lands (same recipe as _attachArtFile).
  Future<void> playPreview({
    required Uri uri,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int previewId,
  }) async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) {
      ArchLog.i('player', 'preview debounced title=$title');
      return;
    }
    _lastTap = now;
    final watch = Stopwatch()..start();
    var waited = 0;
    while (_busy && waited < 50) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited++;
    }
    if (_busy) {
      ArchLog.w('player', 'preview busy-wait capped title=$title - resetting');
      _busy = false;
    }
    _busy = true;
    try {
      ArchLog.i('player', 'preview title=$title');
      final item = MediaItem(
        id: uri.toString(),
        title: title,
        artist: artist,
        album: album,
        duration: const Duration(seconds: 30),
        artUri: null,
        // coverUrl rides from frame one so art has a network leg
        // while the file caches behind; the file patches in next.
        extras: {
          'songId': previewId,
          'albumId': 0,
          if (coverUrl != null && coverUrl.isNotEmpty) 'coverUrl': coverUrl,
        },
      );
      _songs = [];
      _emitQueue([item]);
      await _player
          .setAudioSource(AudioSource.uri(uri), preload: false)
          .timeout(const Duration(seconds: 20));
      _setItem(item);
      await _player.play().timeout(const Duration(seconds: 10));
      ArchLog.i(
        'player',
        'preview playing title=$title in=${watch.elapsedMilliseconds}ms',
      );
      if (coverUrl != null && coverUrl.isNotEmpty) {
        final artFile = await NotifArt.cacheCover(coverUrl);
        if (artFile != null && mediaItem.value?.id == item.id) {
          _setItem(
            item.copyWith(
              extras: {
                ...?item.extras,
                'artCacheFile': artFile,
                'coverUrl': coverUrl,
              },
            ),
          );
        }
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// Manual skip, optimistic: the target commits to the UI in-frame
  /// (deterministic order only — shuffle order lives inside the
  /// engine and is never guessed), then the engine follows. Supersede
  /// token shared with taps: a second skip retargets instead of
  /// racing. Fully logged: intent, expectation, landing.
  Future<void> _skip(int dir) async {
    final n = _songs.length;
    if (n == 0) return;
    final gen = ++_skipGen;
    final from = _player.currentIndex;
    int? expect;
    final deterministic =
        !_player.shuffleModeEnabled &&
        _player.loopMode != LoopMode.one &&
        from != null;
    if (deterministic) {
      var t = from + dir;
      if (_player.loopMode == LoopMode.all) {
        t = (t + n) % n;
      } else {
        t = t.clamp(0, n - 1);
      }
      expect = t;
      if (t >= 0 && t < queue.value.length) _setItem(queue.value[t]);
    }
    final watch = Stopwatch()..start();
    ArchLog.i(
      'player',
      'skip ${dir > 0 ? 'next' : 'prev'} from=$from expect=$expect',
    );
    if (dir > 0) {
      await _player.seekToNext();
    } else {
      await _player.seekToPrevious();
    }
    if (gen != _skipGen) {
      ArchLog.i('player', 'skip superseded');
      return;
    }
    ArchLog.i(
      'player',
      'skip landed index=${_player.currentIndex} in=${watch.elapsedMilliseconds}ms',
    );
  }

  @override
  Future<void> skipToNext() => _skip(1);

  @override
  Future<void> skipToPrevious() => _skip(-1);

  /// The song a manual skip in [dir] would land on (-1 = next, 1 =
  /// previous), or null past the end with loop off. Follows the
  /// engine's shuffle order when shuffling — the carousel peek must
  /// show the truth, never a guess. Null-safe by construction: empty
  /// queue, unknown index and order gaps all read as "no neighbor".
  Song? neighborSong(int dir) {
    if (_songs.isEmpty) return null;
    final cur = _player.currentIndex;
    if (cur == null || cur < 0 || cur >= _songs.length) return null;
    final List<int> order;
    if (_player.shuffleModeEnabled && _player.shuffleIndices.isNotEmpty) {
      order = _player.shuffleIndices;
    } else {
      order = List<int>.generate(_songs.length, (i) => i);
    }
    final pos = order.indexOf(cur);
    if (pos < 0) return null;
    final p = pos + dir;
    if (p < 0 || p >= order.length) {
      if (_player.loopMode != LoopMode.all) return null;
      return _songs[order[(p + order.length) % order.length]];
    }
    return _songs[order[p]];
  }

  /// Shuffle + repeat land here (providers own the state, prefs own the
  /// memory). Applied to the live player and logged like everything.
  Future<void> setShuffleEnabled(bool enabled) async {
    await _player.setShuffleModeEnabled(enabled);
    if (enabled) await _player.shuffle();
    ArchLog.i('player', 'shuffle=$enabled');
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _player.setLoopMode(mode);
    ArchLog.i('player', 'loop=$mode');
  }

  /// Sleep timer: wall-clock countdown, survives track changes, fires
  /// once (pause + clear). Ticks drive the remaining-time provider.
  final _sleepController = StreamController<Duration?>.broadcast();
  Timer? _sleepTick;
  DateTime? _sleepAt;

  Stream<Duration?> get sleepStream => _sleepController.stream;

  Future<void> startSleep(Duration after) async {
    cancelSleep();
    _sleepAt = DateTime.now().add(after);
    _sleepController.add(after);
    ArchLog.i('player', 'sleep in=${after.inMinutes}m');
    _sleepTick = Timer.periodic(const Duration(seconds: 1), (_) async {
      final at = _sleepAt;
      if (at == null) return;
      final remaining = at.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        await pause();
        cancelSleep();
        ArchLog.i('player', 'sleep fired');
      } else if (!_sleepController.isClosed) {
        _sleepController.add(remaining);
      }
    });
  }

  void cancelSleep() {
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepAt = null;
    if (!_sleepController.isClosed) _sleepController.add(null);
  }

  /// Queue surgery for the queue sheet. The just_audio playlist and the
  /// mirrored [_songs]/audio_service queue move together - one truth,
  /// never drift. Single-source (preview) queues ignore move/remove.
  /// Player-level ops (not the deprecated ConcatenatingAudioSource
  /// surface). Names avoid the BaseAudioHandler queue-item overrides.
  Future<void> moveQueueIndex(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _songs.length ||
        newIndex >= _songs.length) {
      return;
    }
    if (_songs.length < 2) return;
    await _player.moveAudioSource(oldIndex, newIndex);
    final s = _songs.removeAt(oldIndex);
    _songs.insert(newIndex, s);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    ArchLog.i('player', 'queue move $oldIndex -> $newIndex');
  }

  Future<void> removeQueueIndex(int index) async {
    if (index < 0 || index >= _songs.length) return;
    if (_songs.length == 1) {
      await clearQueue();
      return;
    }
    await _player.removeAudioSourceAt(index);
    final removed = _songs.removeAt(index);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    ArchLog.i('player', 'queue remove id=${removed.id} index=$index');
  }

  Future<void> clearQueue() async {
    await _player.stop();
    _songs = [];
    _emitQueue([]);
    mediaItem.value = null;
    cancelSleep();
    ArchLog.i('player', 'queue cleared');
  }

  @override
  Future<void> stop() => _player.stop();

  PlaybackState _toPlaybackState(PlaybackEvent event) {
    final shuffle = _player.shuffleModeEnabled;
    return PlaybackState(
      controls: [
        MediaControl.custom(
          androidIcon: shuffle
              ? 'drawable/ic_notif_shuffle_on'
              : 'drawable/ic_notif_shuffle_off',
          label: 'Shuffle',
          name: 'notif_shuffle',
        ),
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.custom(
          androidIcon: switch (_player.loopMode) {
            LoopMode.all => 'drawable/ic_notif_repeat_all',
            LoopMode.one => 'drawable/ic_notif_repeat_one',
            _ => 'drawable/ic_notif_repeat_off',
          },
          label: 'Repeat',
          name: 'notif_repeat',
        ),
      ],
      androidCompactActionIndices: const [1, 2, 3],
      // SEEK is what makes the notification seekbar scrubbable.
      // Without it Android shows progress display-only.
      systemActions: const {MediaAction.seek},
      processingState: switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    );
  }

  /// Notification shuffle/repeat land here. Engine flips first, then
  /// the loop/shuffle streams re-publish state (icons) and the
  /// providers sync prefs off those same streams — one truth.
  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    switch (name) {
      case 'notif_shuffle':
        final v = !_player.shuffleModeEnabled;
        await setShuffleEnabled(v);
        _republish();
        ArchLog.i('player', 'notif shuffle=$v');
      case 'notif_repeat':
        final v = LoopMode.values[(_player.loopMode.index + 1) % 3];
        await setLoopMode(v);
        _republish();
        ArchLog.i('player', 'notif loop=$v');
    }
  }
}

extension on Song {
  /// No content:// artUri: the notification loader can stall on the
  /// resolver and take the whole post (and foreground protection)
  /// down with it. Art arrives file-backed via [_attachArtFile]
  /// instead — same preferred path previews already use.
  MediaItem toMediaItem() => MediaItem(
    id: uri.toString(),
    title: title,
    artist: artist,
    album: album,
    duration: duration.inMilliseconds <= 0 ? null : duration,
    artUri: null,
    extras: {'songId': id, 'albumId': albumId},
  );
}
