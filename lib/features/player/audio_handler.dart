import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/models.dart';

/// Own heartbeat: background playback. UI may crash; this keeps playing.
class ArchAudioHandler extends BaseAudioHandler {
  final AudioPlayer _player = AudioPlayer();
  List<Song> _songs = [];

  ArchAudioHandler() {
    _player.playbackEventStream.map(_toPlaybackState).pipe(playbackState);
  }

  Future<void> setQueueSongs(List<Song> songs, {int startIndex = 0}) async {
    _songs = List<Song>.from(songs);
    queue.value = _songs.map((s) => s.toMediaItem()).toList();
    await _player.setAudioSources(
      _songs.map((s) => AudioSource.uri(s.uri)).toList(),
      initialIndex: startIndex,
    );
  }

  bool _busy = false;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  /// Single-flight + 400ms debounce: rapid taps queue behind one another
  /// instead of racing setAudioSources calls (that race was the preview
  /// pile-up + lag). Throws on failure so callers can surface it.
  Future<void> playSong(Song song, List<Song> context) async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) return;
    _lastTap = now;
    while (_busy) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _busy = true;
    try {
      final index = context.indexWhere((s) => s.id == song.id);
      if (index < 0) return;
      final sameQueue = _songs.length == context.length &&
          _songs.every((s) => context.any((c) => c.id == s.id));
      if (!sameQueue) {
        await setQueueSongs(context, startIndex: index);
      } else {
        await _player.seek(Duration.zero, index: index);
      }
      mediaItem.value = song.toMediaItem();
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
        extras: {'songId': id, 'albumId': albumId},
      );
}
