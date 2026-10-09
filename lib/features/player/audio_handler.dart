import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import '../../core/models.dart';

/// Album art for lock-screen/notification, cached on disk. The native side
/// loads `artCacheFile` preferentially; content URIs resolve via its own
/// ContentResolver path. Failures degrade to no art, never a crash.
class NotifArt {
  static Future<String?> cacheCover(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final dir = await getApplicationCacheDirectory();
      final art = Directory('${dir.path}/notif_art');
      if (!await art.exists()) await art.create(recursive: true);
      final file = File('${art.path}/${url.hashCode}.jpg');
      await file.writeAsBytes(res.bodyBytes, flush: true);
      return file.path;
    } catch (e) {
      ArchLog.w('player', 'notif art failed: $e');
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
    });
  }

  Future<void> setQueueSongs(List<Song> songs, {int startIndex = 0}) async {
    _songs = List<Song>.from(songs);
    queue.value = _songs.map((s) => s.toMediaItem()).toList();
    await _player.setAudioSources(
      _songs.map((s) => AudioSource.uri(s.uri)).toList(),
      initialIndex: startIndex,
    );
  }

  /// Atomic tap: stop current, load new, play. Debounced, single-flight,
  /// bounded. Throws on failure so callers surface it — never silent.
  Future<void> playSong(Song song, List<Song> context) async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) return;
    _lastTap = now;
    while (_busy) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _busy = true;
    try {
      ArchLog.i('player', 'play id=${song.id} title=${song.title} scheme=${song.uri.scheme}');
      final index = context.indexWhere((s) => s.id == song.id);
      if (index < 0) return;
      final sameQueue = _songs.length == context.length &&
          _songs.every((s) => context.any((c) => c.id == s.id));
      if (!sameQueue) {
        // Network previews can stall forever (expired URL, captive
        // portal). Bound it; failure surfaces, never wedges.
        await setQueueSongs(context, startIndex: index)
            .timeout(const Duration(seconds: 20));
      } else {
        await _player.seek(Duration.zero, index: index);
      }
      // currentIndexStream fires too, but set it now so the first
      // notification frame is already correct — never one stale behind.
      mediaItem.value = song.toMediaItem();
      await _player.play();
    } finally {
      _busy = false;
    }
  }

  /// Preview with cover art: downloads the Deezer cover to cache, then
  /// plays with the file-backed art the native loader prefers.
  Future<void> playPreview({
    required Uri uri,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int previewId,
  }) async {
    String? artFile;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      artFile = await NotifArt.cacheCover(coverUrl);
    }
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) return;
    _lastTap = now;
    while (_busy) {
      await Future.delayed(const Duration(milliseconds: 100));
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
        extras: {'songId': previewId, 'albumId': 0, if (artFile != null) 'artCacheFile': artFile},
      );
      _songs = [];
      queue.value = [item];
      await _player
          .setAudioSource(AudioSource.uri(uri))
          .timeout(const Duration(seconds: 20));
      mediaItem.value = item;
      await _player.play();
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
  MediaItem toMediaItem() => MediaItem(
        id: uri.toString(),
        title: title,
        artist: artist,
        album: album,
        duration: duration.inMilliseconds <= 0 ? null : duration,
        artUri: albumId > 0
            ? Uri.parse('content://media/external/audio/albumart/$albumId')
            : null,
        extras: {'songId': id, 'albumId': albumId},
      );
}
