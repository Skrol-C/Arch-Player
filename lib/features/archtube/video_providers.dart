import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import 'archtube_client.dart';
import 'video_match.dart';

final archtubeClientProvider = Provider<ArchtubeClient>((ref) {
  final client = ArchtubeClient();
  ref.onDispose(client.dispose);
  return client;
});

/// Video mode: now-playing only, never mixed into queues (v1 rule).
/// Entering pauses just_audio, exiting resumes. Never both.
final videoModeProvider = StateProvider<bool>((ref) => false);

/// Quality pick per video. Null means the ladder best.
final selectedItagProvider =
    StateProvider.family<int?, String>((ref, videoId) => null);

/// Manual nudge per song, persisted to the cached link.
final videoOffsetProvider =
    StateProvider.family<double, int>((ref, songId) => 0);

/// Cached link per library song id. SharedPreferences-backed:
/// `arch.video.<songId>` = "videoId|offsetSec".
class VideoLinkStore {
  static String _key(int songId) => 'arch.video.$songId';

  Future<VideoLink?> load(int songId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(songId));
      if (raw == null) return null;
      return VideoLink.decode(raw);
    } catch (e) {
      ArchLog.w('archtube', 'link load failed: $e');
      return null;
    }
  }

  Future<void> save(int songId, VideoLink link) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(songId), link.encode());
    } catch (e) {
      ArchLog.w('archtube', 'link save failed: $e');
    }
  }

  Future<void> clear(int songId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(songId));
    } catch (e) {
      ArchLog.w('archtube', 'link clear failed: $e');
    }
  }
}

final videoLinkStoreProvider =
    Provider<VideoLinkStore>((ref) => VideoLinkStore());

/// Link resolution for a song: the cached link when present, else one
/// artist+title search (duration-filtered, longer-video bias), cached
/// for every later tap. Manual override lands through [setVideoLink].
final videoLinkProvider =
    FutureProvider.family<VideoLink?, SongQuery>((ref, q) async {
  final store = ref.watch(videoLinkStoreProvider);
  final cached = await store.load(q.songId);
  if (cached != null) {
    ref.read(videoOffsetProvider(q.songId).notifier).state =
        cached.videoOffsetSec;
    return cached;
  }
  final client = ref.watch(archtubeClientProvider);
  final hits = await client.search('${q.artist} ${q.title}');
  final match = pickMatch(hits: hits, songSecs: q.songSecs);
  if (match == null) return null;
  final resolved = VideoLink(videoId: match.videoId);
  await store.save(q.songId, resolved);
  ref.read(videoOffsetProvider(q.songId).notifier).state = 0;
  return resolved;
});

/// Manual override entry point: paste an ID or URL, it becomes the
/// cached link for the song. Clears the auto-match, if any.
Future<void> setVideoLink(
  WidgetRef ref, {
  required int songId,
  required String input,
}) async {
  final id = extractVideoId(input);
  if (id == null) throw FormatException('Not a video ID or URL: $input');
  final resolved = VideoLink(videoId: id);
  await ref.read(videoLinkStoreProvider).save(songId, resolved);
  ref.read(videoOffsetProvider(songId).notifier).state = 0;
  ref.invalidate(videoLinkProvider);
}

/// Forget the cached link (auto or manual). Next entry re-searches.
Future<void> clearVideoLink(WidgetRef ref, int songId) async {
  await ref.read(videoLinkStoreProvider).clear(songId);
  ref.read(videoOffsetProvider(songId).notifier).state = 0;
  ref.invalidate(videoLinkProvider);
}

class SongQuery {
  final int songId;
  final String artist;
  final String title;
  final int songSecs;

  const SongQuery({
    required this.songId,
    required this.artist,
    required this.title,
    required this.songSecs,
  });

  @override
  bool operator ==(Object other) =>
      other is SongQuery &&
      other.songId == songId &&
      other.artist == artist &&
      other.title == title &&
      other.songSecs == songSecs;

  @override
  int get hashCode => Object.hash(songId, artist, title, songSecs);
}

/// Link resolution inputs, one per song.
SongQuery songQuery({
  required int songId,
  required String artist,
  required String title,
  required int songSecs,
}) =>
    SongQuery(
      songId: songId,
      artist: artist,
      title: title,
      songSecs: songSecs,
    );

/// Progressive streams for a resolved video id.
final videoStreamsProvider =
    FutureProvider.family<List<ArchtubeStream>, String>((ref, videoId) async {
  final client = ref.watch(archtubeClientProvider);
  return client.playerStreams(videoId);
});
