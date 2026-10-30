import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import '../player/player_providers.dart';
import 'archtube_client.dart';
import 'extractor_backend.dart';
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

  static String _rejectedKey(int songId) => 'arch.video.rejected.$songId';

  /// Ids the user already rejected for this song (relink replaced
  /// them, unlink denounced them). Capped so prefs stay small.
  Future<Set<String>> loadRejected(int songId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_rejectedKey(songId)) ?? []).toSet();
    } catch (e) {
      ArchLog.w('archtube', 'rejected load failed: $e');
      return {};
    }
  }

  Future<void> addRejected(int songId, String videoId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_rejectedKey(songId)) ?? [];
      list.remove(videoId);
      list.add(videoId);
      while (list.length > 20) {
        list.removeAt(0);
      }
      await prefs.setStringList(_rejectedKey(songId), list);
    } catch (e) {
      ArchLog.w('archtube', 'rejected save failed: $e');
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
  final rejected = await store.loadRejected(q.songId);
  final hits = await client.search('${q.artist} ${q.title}');
  final match = pickMatch(
    hits: hits,
    artist: q.artist,
    title: q.title,
    songSecs: q.songSecs,
    excluded: rejected,
  );
  if (match == null) return null;
  final resolved = VideoLink(videoId: match.videoId);
  await store.save(q.songId, resolved);
  ref.read(videoOffsetProvider(q.songId).notifier).state = 0;
  return resolved;
});

/// Manual override entry point: paste an ID or URL, it becomes the
/// cached link for the song. A replaced auto-match is remembered as
/// rejected, so the next search picks the runner-up instead.
Future<void> setVideoLink(
  WidgetRef ref, {
  required int songId,
  required String input,
}) async {
  final id = extractVideoId(input);
  if (id == null) throw FormatException('Not a video ID or URL: $input');
  final store = ref.read(videoLinkStoreProvider);
  final current = await store.load(songId);
  if (current != null && current.videoId != id) {
    await store.addRejected(songId, current.videoId);
  }
  final resolved = VideoLink(videoId: id);
  await store.save(songId, resolved);
  ref.read(videoOffsetProvider(songId).notifier).state = 0;
  ref.invalidate(videoLinkProvider);
}

/// Forget the cached link (auto or manual). The denounced id is
/// remembered as rejected, so the next entry re-searches past it.
Future<void> clearVideoLink(WidgetRef ref, int songId) async {
  final store = ref.read(videoLinkStoreProvider);
  final current = await store.load(songId);
  if (current != null) {
    await store.addRejected(songId, current.videoId);
  }
  await store.clear(songId);
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

/// One picture option for the quality UI: progressive (sound muxed
/// in the same URL) or DASH video-only (sound rides the playback's
/// [VideoPlayback.dashAudioUrl]). Length/type feed the range proxy;
/// progressive options carry zeroes it never reads.
class VideoOption {
  final int itag;
  final String label;
  final String url;
  final bool dash;
  final int length;
  final String type;

  const VideoOption({
    required this.itag,
    required this.label,
    required this.url,
    required this.dash,
    this.length = 0,
    this.type = '',
  });
}

/// What the box plays: the picture ladder plus, in DASH mode, the
/// best direct audio URL with its length/type for the range proxy.
/// Progressive mode carries no audio URL. [cpn] is the playback
/// nonce for this resolve, shared by the player request, the picture
/// leg, and the sound leg; a fresh resolve mints a fresh one.
class VideoPlayback {
  final List<VideoOption> options;
  final String? dashAudioUrl;
  final int dashAudioLength;
  final String dashAudioType;
  final String cpn;

  const VideoPlayback({
    required this.options,
    this.dashAudioUrl,
    this.dashAudioLength = 0,
    this.dashAudioType = '',
    this.cpn = '',
  });

  bool get isDash => dashAudioUrl != null;
}

/// DASH ban per video: when set, playback resolves progressive
/// even if DASH URLs served. Session-only; set when freshly
/// resolved DASH URLs still fail to load (wall, not expiry).
final dashFailedProvider =
    StateProvider.family<bool, String>((ref, videoId) => false);

/// Hybrid DASH flag per video: picture DASH walled, but the sound
/// leg serves, so the box plays progressive picture (muted) under
/// DASH sound. Session-only.
final hybridDashProvider =
    StateProvider.family<bool, String>((ref, videoId) => false);

/// Global DASH wall switch, session-only. Set after DASH loads fail
/// on two distinct videos: the egress walls adaptive URLs outright
/// (direct 403s), so later videos skip the double-fail dance and go
/// straight progressive. Cleared by the menu Reload row and by any
/// successful DASH start.
final dashWalledProvider = StateProvider<bool>((ref) => false);

/// Consecutive DASH failures backing the wall switch.
final dashFailStreakProvider = StateProvider<int>((ref) => 0);

/// Video id of the last DASH failure: the streak counts distinct
/// videos only, so one flaky video never walls the session.
final dashLastFailedProvider = StateProvider<String?>((ref) => null);

/// Record a DASH load failure for [videoId]. Returns true when the
/// wall switch flipped on this call.
bool noteDashFailure(WidgetRef ref, String videoId) {
  if (ref.read(dashLastFailedProvider) != videoId) {
    ref.read(dashLastFailedProvider.notifier).state = videoId;
    final streak = ref.read(dashFailStreakProvider) + 1;
    ref.read(dashFailStreakProvider.notifier).state = streak;
    if (streak >= 2) {
      ref.read(dashWalledProvider.notifier).state = true;
      ArchLog.w('archtube', 'dash walled egress, going progressive');
      return true;
    }
  }
  return false;
}

/// Clear every DASH failure memory: bans, streak, wall. The menu
/// Reload row calls this to force a fresh probe.
void clearDashFailures(WidgetRef ref, String? videoId) {
  if (videoId != null) {
    ref.read(dashFailedProvider(videoId).notifier).state = false;
    ref.invalidate(videoPlaybackProvider(videoId));
  }
  ref.read(dashFailStreakProvider.notifier).state = 0;
  ref.read(dashLastFailedProvider.notifier).state = null;
  ref.read(dashWalledProvider.notifier).state = false;
}

/// Playback for a resolved video id: DASH pair when direct URLs
/// serve, progressive ladder otherwise (never empty options when
/// either lane lands).
final videoPlaybackProvider = FutureProvider.family<VideoPlayback, String>((
  ref,
  videoId,
) async {
  final client = ref.watch(archtubeClientProvider);
  final backend = ref.watch(streamBackendProvider);
  final walled = ref.watch(dashWalledProvider);
  final banned = ref.watch(dashFailedProvider(videoId));
  // One nonce per resolve: the player request and every proxy leg
  // for this play share it; a re-resolve mints a fresh one.
  final cpn = generateContentPlaybackNonce();
  if (!walled && !banned) {
    final dash = await backendPlayerDash(backend, client, videoId, cpn: cpn);
    if (dash.playable) {
      // Picture-only itags pair with the response's own hottest
      // audio lane; the song stays parked while the pair plays.
      final audio = dash.bestAudio!;
      return VideoPlayback(
        options: [
          for (final v in dash.videos)
            VideoOption(
              itag: v.itag,
              label: v.qualityLabel.isEmpty ? 'itag ${v.itag}' : v.qualityLabel,
              url: v.url,
              dash: true,
              length: v.contentLength,
              type: v.contentType,
            ),
        ],
        dashAudioUrl: audio.url,
        dashAudioLength: audio.contentLength,
        dashAudioType: audio.contentType,
        cpn: cpn,
      );
    }
  }
  final progressive =
      await backendPlayerStreams(backend, client, videoId, cpn: cpn);
  return VideoPlayback(
    options: [
      for (final s in progressive)
        VideoOption(
          itag: s.itag,
          label: s.qualityLabel.isEmpty ? 'itag ${s.itag}' : s.qualityLabel,
          url: s.url,
          dash: false,
        ),
    ],
    cpn: cpn,
  );
});

/// Frame fit inside the stage box: fit shows the whole picture,
/// fill crops to cover. Persisted per device, not per song.
enum VideoAspect { fit, fill }

final videoAspectProvider =
    NotifierProvider<VideoAspectNotifier, VideoAspect>(
        VideoAspectNotifier.new);

class VideoAspectNotifier extends Notifier<VideoAspect> {
  static const _key = 'arch.video.aspect';

  @override
  VideoAspect build() {
    _sync();
    return VideoAspect.fit;
  }

  Future<void> _sync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = VideoAspect.values.asNameMap()[prefs.getString(_key)];
      if (v != null) state = v;
    } catch (e) {
      ArchLog.w('archtube', 'aspect load failed: $e');
    }
  }

  Future<void> set(VideoAspect v) async {
    state = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, v.name);
    } catch (e) {
      ArchLog.w('archtube', 'aspect save failed: $e');
    }
  }
}

/// Fullscreen request event: the menu increments, the player box
/// pushes the route. A counter, not a bool, so repeats retrigger.
final videoFullscreenRequestProvider = StateProvider<int>((ref) => 0);

/// Live video clock while video owns the stage. Published per
/// wall-clock second, not per frame, so the seekbar follows without
/// a rebuild storm. Readers map it to song time (minus offset).
final videoPositionProvider = StateProvider<Duration>((ref) => Duration.zero);

/// Video play state for the transport center button. Published on
/// transitions only, never per frame.
final videoPlayingProvider = StateProvider<bool>((ref) => false);

/// Video play/pause request event: generation counter plus the
/// target state. The player box applies new generations.
final videoPlayRequestProvider = StateProvider<({int gen, bool play})>(
  (ref) => (gen: 0, play: true),
);

/// Video seek request event: generation counter plus the target
/// video-clock position. The player box seeks on new generations.
/// Send through [requestVideoSeek] so the bar jumps in-frame too.
final videoSeekRequestProvider = StateProvider<({int gen, Duration pos})>(
  (ref) => (gen: 0, pos: Duration.zero),
);

/// Song-time ms for a raw video clock: the clock minus the offset,
/// clamped to the song. The play window is [offset, offset + song]
/// on the video clock, which reads as [0, song] here. Song owns the
/// timeline: every bar readout and step target flows through this.
int mapVideoClockToSongMs({
  required int videoClockMs,
  required double offsetSec,
  required int songLenMs,
}) {
  final songMs = (videoClockMs - offsetSec * 1000).round();
  return songMs.clamp(0, songLenMs);
}

/// Video-clock ms for a song-time seek: plus the offset, clamped to
/// the play window. Seeks map back through the same window the bar
/// reads, so a scrub landing always matches its preview.
int mapSongToVideoClockMs({
  required int songMs,
  required double offsetSec,
  required int songLenMs,
}) {
  final offsetMs = (offsetSec * 1000).round();
  return (songMs + offsetMs).clamp(offsetMs, offsetMs + songLenMs);
}

/// One send path for video seeks: ring the player box and publish
/// the target clock at once, so the seekbar jumps in-frame even if
/// the video stalls behind the seek. The next clock tick corrects
/// any dust.
void requestVideoSeek(WidgetRef ref, Duration videoClock) {
  final req = ref.read(videoSeekRequestProvider);
  ref.read(videoSeekRequestProvider.notifier).state =
      (gen: req.gen + 1, pos: videoClock);
  ref.read(videoPositionProvider.notifier).state = videoClock;
}

/// Step seek in video mode: moves the video clock by [bySecs]
/// inside the play window, and walks the paused audio with it so
/// resume and lyrics stay aligned. One path for the transport row.
Future<void> nudgeVideoSeconds(
  WidgetRef ref, {
  required int songId,
  required Duration songDuration,
  required int bySecs,
}) async {
  final clock = ref.read(videoPositionProvider);
  final offset = ref.read(videoOffsetProvider(songId));
  final songLenMs = songDuration.inMilliseconds;
  // Step in song time, map back through the window: the stepped
  // clock and the walked audio land on the same mapped point.
  final steppedSongMs = (mapVideoClockToSongMs(
            videoClockMs: clock.inMilliseconds,
            offsetSec: offset,
            songLenMs: songLenMs,
          ) +
          bySecs * 1000)
      .clamp(0, songLenMs);
  final vTarget = Duration(
    milliseconds: mapSongToVideoClockMs(
      songMs: steppedSongMs,
      offsetSec: offset,
      songLenMs: songLenMs,
    ),
  );
  requestVideoSeek(ref, vTarget);
  final songMs = mapVideoClockToSongMs(
    videoClockMs: vTarget.inMilliseconds,
    offsetSec: offset,
    songLenMs: songLenMs,
  );
  try {
    await ref.read(audioHandlerProvider).seek(Duration(milliseconds: songMs));
  } catch (e) {
    ArchLog.w('archtube', 'step audio seek failed: $e');
  }
}

/// Shared offset nudge: moves the per-song video start offset,
/// persisted to the cached link. One path for the stage row and
/// the video menu.
Future<void> nudgeVideoOffset(
  WidgetRef ref, {
  required int songId,
  required double by,
}) async {
  final notifier = ref.read(videoOffsetProvider(songId).notifier);
  final next = (notifier.state + by).clamp(0.0, 30.0);
  notifier.state = next;
  try {
    final store = ref.read(videoLinkStoreProvider);
    final link = await store.load(songId);
    if (link != null) {
      await store.save(songId, link.withOffset(next));
    }
  } catch (e) {
    ArchLog.w('archtube', 'offset persist failed: $e');
  }
}
