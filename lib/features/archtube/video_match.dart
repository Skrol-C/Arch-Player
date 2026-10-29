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

/// Asymmetric duration window, in seconds. A video much shorter
/// than the song cannot hold it; a longer one is usually the
/// official cut with intro and outro, so the long side stays wide.
const matchShortToleranceSecs = 10;
const matchLongToleranceSecs = 90;

/// Upper bound for the longer-video bias: beyond this the candidate
/// is a different cut (extended mix, live set), not the song.
const longerBiasCapSecs = 45;

/// Words that carry no identity when echoing the song title.
const _titleStopwords = {
  'the',
  'and',
  'feat',
  'ft',
  'official',
  'music',
  'video',
  'lyric',
  'lyrics',
  'audio',
  'visualizer',
  'hd',
  '4k',
};

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Set<String> _sigWords(String norm) => norm
    .split(' ')
    .where((w) => w.length > 2 && !_titleStopwords.contains(w))
    .toSet();

bool _hasAny(String norm, List<String> words) {
  for (final w in words) {
    if (norm.contains(w)) return true;
  }
  return false;
}

/// Rank search hits for [artist]/[title] against [songSecs].
/// Duration filter first (asymmetric: shorts rejected fast, longs
/// tolerated), then title echo, artist echo, and the official lane
/// (VEVO and official artist channels), with wrong-cut penalties
/// (live, cover, remix, slowed, karaoke and kin) that stand down
/// when the song itself names them. [excluded] holds ids the user
/// already rejected through relink or unlink: they never re-win.
/// Returns the winner or null when nothing qualifies.
ArchtubeHit? pickMatch({
  required List<ArchtubeHit> hits,
  required String artist,
  required String title,
  required int songSecs,
  Set<String> excluded = const {},
}) {
  final songNorm = _norm(title);
  final songWords = _sigWords(songNorm);
  final artistNorm = _norm(artist);
  bool songHas(String w) => songNorm.contains(w);
  ArchtubeHit? best;
  var bestScore = -1 << 30;
  // Tier preference: when the artist's own channel, VEVO, or an
  // official music video qualifies on duration, fan cuts cannot win
  // on duration closeness alone. Falls back to the open field when
  // no authoritative cut names the song.
  ArchtubeHit? bestOfficial;
  var bestOfficialScore = -1 << 30;
  for (final h in hits) {
    if (excluded.contains(h.videoId)) continue;
    final d = h.durationSecs;
    if (d == null) continue;
    final diff = d - songSecs;
    if (diff < -matchShortToleranceSecs || diff > matchLongToleranceSecs) {
      continue;
    }
    var score = 100 - diff.abs() * 2;
    if (diff >= 0 && diff <= longerBiasCapSecs) score += 15;
    final tNorm = _norm(h.title);
    final cNorm = _norm(h.channel);
    var echo = 0;
    for (final w in songWords) {
      if (tNorm.contains(w)) echo++;
    }
    score += (echo * 6).clamp(0, 18);
    // Single-letter artists echo-match everything, so the artist
    // lane needs a real name to stand on.
    final artistKnown = artistNorm.length > 1;
    if (artistKnown &&
        (tNorm.contains(artistNorm) || cNorm.contains(artistNorm))) {
      score += 12;
    }
    // Artist-channel authority: the artist's own channel (exact
    // name, VEVO, official, or music channel) outranks fan uploads
    // even when a fan cut sits closer in length. Topic channels
    // never count: they hold the name but not the authority.
    final ownChannel = artistKnown &&
        (cNorm == artistNorm ||
            (cNorm.contains(artistNorm) &&
                _hasAny(cNorm, const ['vevo', 'official', 'music'])));
    if (ownChannel) {
      score += 20;
    } else if (cNorm.contains('vevo')) {
      score += 10;
    }
    if (tNorm.contains('official music video')) {
      score += 8;
    } else if (tNorm.contains('official')) {
      score += 5;
    }
    if (!songHas('live') &&
        _hasAny(tNorm, const ['live', 'concert', 'tour'])) {
      score -= 25;
    }
    if (!songHas('cover') && tNorm.contains('cover')) score -= 25;
    if (!songHas('remix') &&
        _hasAny(tNorm, const ['remix', 'mashup', 'flip'])) {
      score -= 25;
    }
    if (!songHas('acoustic') && tNorm.contains('acoustic')) score -= 20;
    if (_hasAny(tNorm, const [
      'slowed',
      'sped up',
      'speed up',
      '8d',
      'nightcore',
      'reverb',
      'karaoke',
      'reaction',
      'tutorial',
      'lesson',
    ])) {
      score -= 20;
    }
    // Lyric uploads of any phrasing lose to staged video when the
    // song itself is not a lyric cut.
    if (!songHas('lyric') && tNorm.contains('lyric')) score -= 20;
    // Audio uploads are a last resort, never a winner when staged
    // video qualifies: some carry motion visuals, so they stay
    // eligible, parked far behind.
    if (_hasAny(tNorm, const [
      'official audio',
      '(audio)',
      '[audio]',
      'audio only',
    ])) {
      score -= 25;
    }
    if (cNorm.contains('topic')) score -= 6;
    final authoritative = ownChannel ||
        cNorm.contains('vevo') ||
        tNorm.contains('official music video');
    if (authoritative && (songWords.isEmpty || echo > 0)) {
      if (score > bestOfficialScore) {
        bestOfficialScore = score;
        bestOfficial = h;
      }
    }
    if (score > bestScore) {
      bestScore = score;
      best = h;
    }
  }
  final winner = bestOfficial ?? best;
  if (winner != null) {
    final winningScore =
        bestOfficial != null ? bestOfficialScore : bestScore;
    ArchLog.i('video-match',
        'picked ${winner.videoId} "${winner.title}" (${winner.durationSecs}s '
        'vs song ${songSecs}s, score $winningScore'
        '${bestOfficial != null ? ', official lane' : ''})');
  }
  return winner;
}
