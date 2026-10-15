import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import '../../core/models.dart';
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

  ArchAudioHandler() {
    _player.playbackEventStream.map(_toPlaybackState).pipe(playbackState);
    // The notification only rebuilds on control flips and metadata sets —
    // never on index change alone. So every index change re-sets the
    // media item explicitly: taps, auto-advance, next/prev, lock intents.
    _player.currentIndexStream.listen((index) {
      if (index == null) return;
      final items = queue.value;
      if (index < 0 || index >= items.length) return;
      mediaItem.value = items[index];
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

  /// Explicit audio session (their wheel, our policy): media usage,
  /// full gain (calls and nav still interrupt — never music-over-calls),
  /// and pause-with-state on every interruption start instead of silent
  /// ducking. A paused player with visible controls beats mystery-quiet.
  /// Every event logs — focus issues are diagnosable forever after this.
  bool _duckPaused = false;

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
          androidWillPauseWhenDucked: true,
        ),
      );
      session.interruptionEventStream.listen((e) async {
        ArchLog.i('player', 'interruption begin=${e.begin} type=${e.type}');
        try {
          if (!e.begin) {
            if (_duckPaused) {
              _duckPaused = false;
              await _player.play();
              ArchLog.i('player', 'resumed after interruption');
            }
            return;
          }
          if (_player.playing) {
            _duckPaused = true;
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

  /// Atomic tap: stop current, load new, play. Debounced, single-flight,
  /// bounded. Throws on failure so callers surface it - never silent.
  /// Every decision is logged: the next "it didn't switch" report
  /// diagnoses from one tap's lines instead of a week of guesses.
  Future<void> playSong(Song song, List<Song> context) async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) {
      ArchLog.i('player', 'tap debounced id=${song.id}');
      return;
    }
    _lastTap = now;
    final watch = Stopwatch()..start();
    // Single-flight, but never a life sentence: a wedged predecessor
    // used to park every later tap forever with zero evidence.
    var waited = 0;
    while (_busy && waited < 50) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited++;
    }
    if (_busy) {
      ArchLog.w(
        'player',
        'busy-wait capped id=${song.id} waited=${watch.elapsedMilliseconds}ms - resetting',
      );
      _busy = false;
    } else if (waited > 0) {
      ArchLog.i(
        'player',
        'busy-waited id=${song.id} waited=${watch.elapsedMilliseconds}ms',
      );
    }
    _busy = true;
    try {
      ArchLog.i(
        'player',
        'play id=${song.id} title=${song.title} scheme=${song.uri.scheme}',
      );
      final index = context.indexWhere((s) => s.id == song.id);
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
        ArchLog.i(
          'player',
          'queue rebuilt id=${song.id} n=${context.length} in=${watch.elapsedMilliseconds}ms',
        );
      } else {
        await _player
            .seek(Duration.zero, index: index)
            .timeout(const Duration(seconds: 10));
        ArchLog.i(
          'player',
          'same-queue seek id=${song.id} index=$index in=${watch.elapsedMilliseconds}ms',
        );
      }
      // currentIndexStream fires too, but set it now so the first
      // notification frame is already correct — never one stale behind.
      mediaItem.value = song.toMediaItem();
      await _player.play().timeout(const Duration(seconds: 10));
      ArchLog.i(
        'player',
        'playing id=${song.id} in=${watch.elapsedMilliseconds}ms',
      );
      // Art follows behind the tap (zero tap cost): re-set the item
      // with a file-backed cover once resolved. Triple-guarded so a
      // slow fetch can never paint stale art over a newer track.
      unawaited(_attachArtFile(song));
    } finally {
      _busy = false;
    }
  }

  Future<void> _attachArtFile(Song song) async {
    try {
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
      mediaItem.value = current.copyWith(
        extras: {...?current.extras, 'artCacheFile': file},
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
        extras: {'songId': previewId, 'albumId': 0},
      );
      _songs = [];
      _emitQueue([item]);
      await _player
          .setAudioSource(AudioSource.uri(uri), preload: false)
          .timeout(const Duration(seconds: 20));
      mediaItem.value = item;
      await _player.play().timeout(const Duration(seconds: 10));
      ArchLog.i(
        'player',
        'preview playing title=$title in=${watch.elapsedMilliseconds}ms',
      );
      if (coverUrl != null && coverUrl.isNotEmpty) {
        final artFile = await NotifArt.cacheCover(coverUrl);
        if (artFile != null && mediaItem.value?.id == item.id) {
          mediaItem.value = item.copyWith(
            extras: {
              ...?item.extras,
              'artCacheFile': artFile,
              'coverUrl': coverUrl,
            },
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

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

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
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      androidCompactActionIndices: const [0, 1, 2],
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
