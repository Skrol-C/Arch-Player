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

  const MusicFolder({required this.key, required this.label, required this.count});
}

class Album {
  final String key;
  final String title;
  final String artist;
  final List<Song> songs;

  const Album({required this.key, required this.title, required this.artist, required this.songs});
}

class ArtistEntry {
  final String name;
  final List<Song> songs;

  const ArtistEntry({required this.name, required this.songs});
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

  const ArtistMeta(
      {this.mbid, this.dzId, this.imageUrl, this.bio, this.releases = const [], this.logoUrl});

  ArtistMeta copyWith(
      {String? mbid,
      int? dzId,
      String? imageUrl,
      String? bio,
      List<ReleaseGroup>? releases,
      String? logoUrl}) {
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

  const ReleaseGroup({required this.type, required this.title, this.artUrl, this.year, this.rgMbid});
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
enum LyricSource { embedded, lrclib, none }

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

  bool get hasSynced =>
      syncedLrc != null && syncedLrc!.trim().isNotEmpty;
  bool get hasPlain => plain != null && plain!.trim().isNotEmpty;
}
