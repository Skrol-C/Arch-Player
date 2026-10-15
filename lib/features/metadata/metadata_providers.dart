import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../library/library_providers.dart';
import '../lyrics/tag_lyrics.dart';
import 'metadata_service.dart';

final metadataServiceProvider = Provider<MetadataService>(
  (ref) => MetadataService(),
);

final artistMetaProvider = FutureProvider.family<ArtistMeta, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).enrich(artistName);
});

/// Independent progressive providers: pic, bio, and discography render
/// the moment each lands instead of waiting on the slowest.
final artistPicProvider = FutureProvider.family<String?, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).picFor(artistName);
});

final artistBioProvider = FutureProvider.family<String?, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).bioFor(artistName);
});

final artistReleasesProvider =
    FutureProvider.family<List<ReleaseGroup>, String>((ref, artistName) {
      return ref.watch(metadataServiceProvider).releasesFor(artistName);
    });

/// True artist wordmark (fanart.tv HD ClearLogo), when one exists.
/// Null = the hero falls back to our display-font voice.
final artistLogoProvider = FutureProvider.family<String?, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).logoFor(artistName);
});

/// Chart top tracks, fresh per page open (preview URLs expire).
final artistTopProvider = FutureProvider.family<List<TopTrack>, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).topTracks(artistName);
});

/// Release cover art, resolved lazily per visible item.
final releaseCoverProvider = FutureProvider.family<String?, String>((
  ref,
  rgMbid,
) {
  return ref.watch(metadataServiceProvider).coverFor(rgMbid);
});

/// Full album tracklist (Deezer, else MusicBrainz), keyed
/// "artist\x00album" lowercased. Empty = unresolvable - callers
/// render owned-only, never a hole.
final albumTracklistProvider = FutureProvider.family<List<AlbumTrack>, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .albumTracksFor(artist: artist, album: album);
});

/// Album genres, same key shape. Embedded file tags win (your
/// files beat fuzzy matching), then Last.fm / MusicBrainz / Deezer.
/// Empty = the world says nothing.
final albumGenresProvider = FutureProvider.family<List<String>, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  final songs = ref.watch(songsProvider).value ?? [];
  for (final s in songs) {
    if (s.path.isEmpty) continue;
    if (s.artist.toLowerCase() != artist ||
        s.album.toLowerCase() != album) {
      continue;
    }
    final embedded = readEmbeddedGenre(s.path);
    ArchLog.i(
      'meta',
      'genre embedded ${embedded == null ? 'miss' : 'hit'}: $artist - $album',
    );
    if (embedded != null && embedded.isNotEmpty) return [embedded];
    break;
  }
  return ref
      .watch(metadataServiceProvider)
      .genresFor(artist: artist, album: album);
});

/// Album credits for Relationships, same key shape. Cached
/// alongside the tracklist; empty = unknown.
final albumCreditsProvider = FutureProvider.family<List<AlbumCredit>, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .creditsFor(artist: artist, album: album);
});

/// Record label, same key shape. Null = the world says nothing.
final albumLabelProvider = FutureProvider.family<String?, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .labelFor(artist: artist, album: album);
});

/// Remote (unowned) lyrics: same LRCLib ladder, network-only.
/// Key: "title\x00artist\x00album\x00durationSecs".
final remoteLyricsProvider = FutureProvider.family<LyricDoc, String>((
  ref,
  key,
) async {
  final parts = key.split('\x00');
  final title = parts.isNotEmpty ? parts.first : '';
  final artist = parts.length > 1 ? parts[1] : '';
  final album = parts.length > 2 ? parts[2] : '';
  final dur = parts.length > 3 ? int.tryParse(parts[3]) ?? 0 : 0;
  if (title.isEmpty || artist.isEmpty) return const LyricDoc();
  try {
    return await ref
        .watch(metadataServiceProvider)
        .lyricsForRemote(
          artist: artist,
          title: title,
          album: album,
          durationSecs: dur,
        );
  } catch (_) {
    return const LyricDoc();
  }
});
