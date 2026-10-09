import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/models.dart';
import '../library/library_providers.dart';
import 'audio_handler.dart';

final audioHandlerProvider = Provider<ArchAudioHandler>((ref) {
  throw UnimplementedError('audioHandlerProvider must be overridden at startup');
});

final playerOpenProvider = StateProvider<bool>((ref) => false);

final currentSongProvider = StreamProvider<Song?>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return handler.mediaItem.asyncMap((item) {
    if (item == null) return null;
    final id = item.extras?['songId'] as int?;
    if (id == null) return null;
    final songs = ref.read(songsProvider).value ?? [];
    for (final s in songs) {
      if (s.id == id) return s;
    }
    return null;
  });
});

final playingProvider = StreamProvider<bool>((ref) {
  return ref.watch(audioHandlerProvider).playbackState.map((s) => s.playing).distinct();
});

final positionProvider = StreamProvider<Duration>((ref) {
  return AudioService.position;
});
