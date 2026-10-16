/// A local track. [uri] is a content:// URI playable by just_audio.
/// [folderKey]/[folderLabel] drive the unlimited folder toggles.
class Song {
  final int id;
  final Uri uri;
  final String title;
  final String artist;
  final String album;
  final int albumId;
  final Duration duration;
  final int year;
  final String folderKey;
  final String folderLabel;

  /// Full device path (MediaStore DATA). Folder picks match by prefix.
  final String path;

  /// MediaStore DATE_ADDED, seconds since epoch. Drives Recently Added.
  final int addedSecs;

  const Song({
    required this.id,
    required this.uri,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumId,
    required this.duration,
    required this.year,
    required this.folderKey,
    required this.folderLabel,
    this.path = '',
    this.addedSecs = 0,
  });
}

class MusicFolder {
  final String key;
  final String label;
  final int count;

  const MusicFolder({
    required this.key,
    required this.label,
    required this.count,
  });
}

class Album {
  final String key;
  final String title;
  final String artist;
  final List<Song> songs;

  const Album({
    required this.key,
    required this.title,
    required this.artist,
    required this.songs,
  });
}

class ArtistEntry {
  final String name;
  final List<Song> songs;

  const ArtistEntry({required this.name, required this.songs});
}

/// One track of a provider-resolved full album tracklist (Deezer /
/// MusicBrainz). Durations feed the owned-match window; zero means
/// the source gave none and matching falls back to title-only.
class AlbumTrack {
  final int position;
  final String title;
  final int durationSecs;

  const AlbumTrack({
    required this.position,
    required this.title,
    this.durationSecs = 0,
  });
}

/// Shared identity discipline: album checkmarks, Song Doctor, and
/// where-heard all match on normalized title (+ duration window
/// when both sides carry one). Defined once, reused everywhere.
String normTitle(String t) {
  var n = t.toLowerCase();
  // Feature credits live in titles too ("Song (feat. B)" vs "Song"):
  // parenthesized, bracketed, and suffixed forms all go before the
  // split below ever sees them. Different rips tag differently;
  // identity must not.
  n = n.replaceAll(
    RegExp(r'\s*[\(\[]\s*(feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]'),
    '',
  );
  n = n.split(RegExp(r'\s+feat\.?\s+')).first;
  n = n.split(RegExp(r'\s+ft\.?\s+')).first;
  n = n.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
  return n.split(RegExp(r'\s+')).join(' ').trim();
}

bool durClose(int aSecs, int bSecs, {int window = 5}) =>
    (aSecs - bSecs).abs() <= window;

/// Collaboration split: comma, semicolon, and feat/ft/featuring
/// (bare or parenthesized) divide; `&` stays intact so band names
/// never fracture. Primary artist = first segment. Display strings
/// are untouched - splitting happens at the grouping layer only
/// (providers, lookups), never in the song itself.
List<String> splitArtists(String raw) {
  final out = <String>[];
  // Parenthesized features become plain separators first, so one
  // split below handles bare and bracketed forms alike.
  final flat = raw.replaceAll(
    RegExp(
      r'\s*[\(\[]\s*(feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]',
      caseSensitive: false,
    ),
    ',',
  );
  final sep = RegExp(
    r'\s*(?:,|;|\bfeat\.?|\bft\.?|\bfeaturing\b)\s*',
    caseSensitive: false,
  );
  for (final s in flat.split(sep)) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) continue;
    if (out.any((e) => e.toLowerCase() == t.toLowerCase())) continue;
    out.add(t);
  }
  if (out.isEmpty) out.add(raw.trim());
  return out;
}

String primaryArtist(String raw) => splitArtists(raw).first;

/// Case-insensitive overlap: do these two artist tags share anyone?
bool artistsOverlap(String a, String b) {
  final sa = splitArtists(a).map((e) => e.toLowerCase()).toSet();
  final sb = splitArtists(b).map((e) => e.toLowerCase()).toSet();
  return sa.intersection(sb).isNotEmpty;
}

/// Album track fingerprint: normalized titles + 10s-bucketed
/// durations, sorted. Same tracks under varying artist tags
/// fingerprint equal (collaborations merge); genuinely different
/// same-title albums don't. The wide bucket absorbs rip variance
/// (gapless drift, encoder padding, pressing differences) without
/// confusing distinct same-title tracks. Shared with Song Doctor.
String albumPrint(List<Song> songs) {
  final keys = [
    for (final s in songs)
      '${normTitle(s.title)}:${s.duration.inSeconds ~/ 10}',
  ]..sort();
  return keys.join('|');
}

/// One credited hand on an album (producer, writer, performer...).
/// Roles come from MusicBrainz relationships or Deezer contributors;
/// mbid is null when the source gave a name only (pics resolve by
/// name through the existing artist-pic lane).
class AlbumCredit {
  final String name;
  final String role;
  final String? mbid;

  const AlbumCredit({required this.name, required this.role, this.mbid});
}

/// Enriched artist metadata (MusicBrainz + Deezer + Last.fm).
/// Every field nullable: a page without art/bio/discography is still valid.
class ArtistMeta {
  final String? mbid;
  final int? dzId;
  final String? imageUrl;
  final String? bio;
  final List<ReleaseGroup> releases;

  /// True artist wordmark (fanart.tv HD ClearLogo), when the world has
  /// one for this artist. Null = display-font fallback voice.
  final String? logoUrl;

  const ArtistMeta({
    this.mbid,
    this.dzId,
    this.imageUrl,
    this.bio,
    this.releases = const [],
    this.logoUrl,
  });

  ArtistMeta copyWith({
    String? mbid,
    int? dzId,
    String? imageUrl,
    String? bio,
    List<ReleaseGroup>? releases,
    String? logoUrl,
  }) {
    return ArtistMeta(
      mbid: mbid ?? this.mbid,
      dzId: dzId ?? this.dzId,
      imageUrl: imageUrl ?? this.imageUrl,
      bio: bio ?? this.bio,
      releases: releases ?? this.releases,
      logoUrl: logoUrl ?? this.logoUrl,
    );
  }
}

class ReleaseGroup {
  /// album | single | ep | live | compilation | other
  final String type;
  final String title;
  final String? artUrl;
  final int? year;
  final String? rgMbid;

  const ReleaseGroup({
    required this.type,
    required this.title,
    this.artUrl,
    this.year,
    this.rgMbid,
  });
}

/// A chart top-track from Deezer. [previewUrl] expires - fetched fresh per
/// page open, never cached long-term. Everything else caches normally.
class TopTrack {
  final int rank;
  final String title;
  final String albumTitle;
  final String? coverUrl;
  final Duration duration;
  final String? previewUrl;

  const TopTrack({
    required this.rank,
    required this.title,
    required this.albumTitle,
    this.coverUrl,
    required this.duration,
    this.previewUrl,
  });
}

/// Resolved lyrics for one track. [syncedLrc] is LRC text (from SYLT
/// or LRCLib synced); [plain] is untimed prose. Resolution order:
/// embedded -> LRCLib -> none. Never throws, never lies about source.
/// [paxsenix] marks PaxSenIX-sourced lines (incl. Musixmatch):
/// display + cache ONLY, never embedded into files (their terms).
enum LyricSource { embedded, lrclib, paxsenix, none }

class LyricDoc {
  final String? plain;
  final String? syncedLrc;
  final LyricSource source;
  final bool instrumental;

  const LyricDoc({
    this.plain,
    this.syncedLrc,
    this.source = LyricSource.none,
    this.instrumental = false,
  });

  bool get hasSynced => syncedLrc != null && syncedLrc!.trim().isNotEmpty;
  bool get hasPlain => plain != null && plain!.trim().isNotEmpty;
}
