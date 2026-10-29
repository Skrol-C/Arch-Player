import '../../core/log.dart';
import 'archtube_client.dart';

/// The cached link between a library song and its video. Searched
/// once (artist + title, duration-filtered), cached on the track,
/// never re-searched per tap. [videoOffsetSec] skips the excess head
/// so the video starts where the song starts; manual nudge fallback,
/// default 0. Same trick as Namida's video offset.
class VideoLink {
  final String videoId;
  final double videoOffsetSec;

  const VideoLink({required this.videoId, this.videoOffsetSec = 0});

  String encode() => '$videoId|$videoOffsetSec';

  static VideoLink? decode(String raw) {
    final parts = raw.split('|');
    if (parts.isEmpty || parts.first.isEmpty) return null;
    return VideoLink(
      videoId: parts.first,
      videoOffsetSec: parts.length > 1
          ? double.tryParse(parts[1]) ?? 0
          : 0,
    );
  }

  VideoLink withOffset(double offset) =>
      VideoLink(videoId: videoId, videoOffsetSec: offset);
}

/// Accepts a bare 11-char ID or any common YouTube URL form
/// (watch, youtu.be, shorts, embed, live). Null when unrecognized.
String? extractVideoId(String input) {
  final t = input.trim();
  if (t.isEmpty) return null;
  if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(t)) return t;
  final m = RegExp(
    r'(?:youtube\.com/(?:watch\?[^ ]*v=|shorts/|embed/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})',
  ).firstMatch(t);
  return m?.group(1);
}

/// Duration window for matching: a candidate passes when it lands
/// within this of the song length. Music videos run long (intros,
/// outros); exact-length only would starve the matcher.
const matchWindowSecs = 30;

/// Upper bound for the longer-video bias: beyond this the candidate
/// is a different cut (extended mix, live set), not the song.
const longerBiasCapSecs = 120;

/// Rank search hits for [artist]/[title] against [songSecs].
/// Duration filter first, then bias to the same song in a longer
/// video (official videos outrun the audio by seconds). Returns the
/// winner or null when nothing lands in the window.
ArchtubeHit? pickMatch({
  required List<ArchtubeHit> hits,
  required int songSecs,
}) {
  ArchtubeHit? best;
  var bestScore = -1 << 30;
  for (final h in hits) {
    final d = h.durationSecs;
    if (d == null) continue;
    final diff = d - songSecs;
    if (diff.abs() > matchWindowSecs) continue;
    var score = 100 - diff.abs() * 2;
    if (diff >= 0 && diff <= longerBiasCapSecs) score += 15;
    // Title echo: exact title words in the video title win ties.
    final norm = h.title.toLowerCase();
    if (norm.contains('official')) score += 5;
    if (norm.contains('music video')) score += 5;
    if (score > bestScore) {
      bestScore = score;
      best = h;
    }
  }
  if (best != null) {
    ArchLog.i('video-match',
        'picked ${best.videoId} "${best.title}" (${best.durationSecs}s '
        'vs song ${songSecs}s)');
  }
  return best;
}
