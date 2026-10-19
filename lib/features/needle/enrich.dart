import '../../core/log.dart';
import '../../core/models.dart';
import '../metadata/metadata_service.dart';

/// Pull-time metadata gather: everything a fresh pull can know,
/// normalized into one record before bytes land. Sources, in
/// order: caller facts (search hit) -> provider lanes (Deezer
/// hi-res art, MusicBrainz credits, label) -> lyric ladder
/// (LRCLib first; PaxSenIX lanes display-only, never embedded).
class PullMeta {
  final String title;
  final String artist;
  final String album;
  final List<String> genres;
  final String label;
  final String isrc;
  final String composer;
  final String coverUrl;
  final List<AlbumCredit> credits;
  final LyricDoc lyrics;
  final int durationSecs;
  // Numbers and catalogue facts: a pull should land as rich as the
  // providers allow, not just title/artist/album.
  final String albumArtist;
  final String trackNumber;
  final String trackTotal;
  final String discNumber;
  final String discTotal;
  final String date;
  final String copyright;
  final String bpm;
  final String catalogNumber;
  final String barcode;
  /// Canonical release type from MusicBrainz (Album / Single / EP /
  /// Compilation / Live), not the provider's guess.
  final String releaseType;
  /// True when the identity lane supplied something beyond the
  /// query (adopted album, corrected spelling). False = the
  /// title/artist/album below echo the caller's query.
  final bool identityResolved;
  /// Apple and Deezer disagreed on the album — adopting either is
  /// a guess, so callers must not write identity fields.
  final bool identityConflict;

  const PullMeta({
    required this.title,
    required this.artist,
    required this.album,
    this.genres = const [],
    this.label = '',
    this.isrc = '',
    this.composer = '',
    this.coverUrl = '',
    this.credits = const [],
    this.lyrics = const LyricDoc(),
    this.durationSecs = 0,
    this.albumArtist = '',
    this.trackNumber = '',
    this.trackTotal = '',
    this.discNumber = '',
    this.discTotal = '',
    this.date = '',
    this.copyright = '',
    this.bpm = '',
    this.catalogNumber = '',
    this.barcode = '',
    this.releaseType = '',
    this.identityResolved = false,
    this.identityConflict = false,
  });
}

/// Enrich a pull in parallel lanes. One dead lane degrades its
/// block, never the pull. Never throws.
///
/// [includeLyrics]/[includeCover] exist for the Doctor: its sparse
/// apply writes neither (Finder owns lyrics, pencil owns covers),
/// so running those lanes would burn seconds and requests for
/// results it discards. Pull keeps both on.
Future<PullMeta> gatherPullMeta({
  required String title,
  required String artist,
  String album = '',
  String artUrl = '',
  String isrc = '',
  int durationSecs = 0,
  bool includeLyrics = true,
  bool includeCover = true,
  // Doctor-only: resolve canonical title/artist/album from the
  // catalogues before running lanes, so a thin file (empty album,
  // casing drift) queries with the real identity instead of its
  // own tags. Pulls leave this off: the search hit is already
  // canonical and resolving would cost requests for no gain.
  bool resolveIdentity = false,
}) async {
  final svc = MetadataService();
  var effTitle = title;
  var effArtist = artist;
  var effAlbum = album;
  var identityResolved = false;
  var identityConflict = false;
  if (resolveIdentity) {
    try {
      final res = await svc.resolveTrackIdentity(
        title: title,
        artist: artist,
        album: album,
        durationSecs: durationSecs,
        isrc: isrc,
      );
      identityConflict = res.conflict;
      final id = res.identity;
      if (id != null) {
        if (id.title.trim().isNotEmpty) effTitle = id.title;
        if (id.artist.trim().isNotEmpty) effArtist = id.artist;
        if (id.album.trim().isNotEmpty) effAlbum = id.album;
        identityResolved = true;
        ArchLog.i('meta',
            'identity adopted: "$title - $artist [$album]" -> "$effTitle - $effArtist [$effAlbum]"');
      } else if (res.conflict) {
        ArchLog.i('meta', 'identity conflict: keeping query, no adopt');
      }
    } catch (e) {
      ArchLog.w('meta', 'identity resolve failed: $e');
    }
  }
  List<AlbumCredit> credits = const [];
  List<String> genres = const [];
  var label = '';
  var releaseType = '';
  LyricDoc lyrics = const LyricDoc();
  TrackFacts trackFacts = const TrackFacts();
  var facts = const ReleaseFacts();
  String cover = artUrl;
  try {
    final results = await Future.wait([
      svc.creditsFor(artist: effArtist, album: effAlbum),
      svc.genresFor(artist: effArtist, album: effAlbum),
      // Label + catalogue number + barcode + release type, all off one
      // release search (the lane labelFor would otherwise repeat).
      svc.releaseFactsFor(artist: effArtist, album: effAlbum),
      svc.trackFactsFor(
          artist: effArtist, album: effAlbum, title: effTitle, durationSecs: durationSecs),
      includeLyrics
          ? _lyricsLadder(
              svc,
              artist: effArtist,
              title: effTitle,
              album: effAlbum,
              durationSecs: durationSecs,
            )
          : Future.value(const LyricDoc()),
      includeCover
          ? _hiResCover(svc,
              artist: effArtist, album: effAlbum, title: effTitle, fallback: artUrl)
          : Future.value(artUrl),
    ]);
    credits = results[0] as List<AlbumCredit>;
    genres = results[1] as List<String>;
    facts = results[2] as ReleaseFacts;
    label = facts.label;
    releaseType = facts.releaseType;
    trackFacts = results[3] as TrackFacts;
    lyrics = results[4] as LyricDoc;
    cover = (results[5] as String?) ?? artUrl;
  } catch (e) {
    ArchLog.w('meta', 'gather degraded: $e');
  }
  if (genres.isEmpty && trackFacts.genre.isNotEmpty) {
    genres = [trackFacts.genre];
  }
  return PullMeta(
    title: effTitle,
    artist: effArtist,
    album: effAlbum,
    genres: genres,
    label: label,
    // The search hit's ISRC usually beats a provider lookup; keep it
    // when present and fall back to whatever the track lanes found.
    isrc: isrc.isNotEmpty ? isrc : trackFacts.isrc,
    composer: trackFacts.composer,
    coverUrl: cover,
    credits: credits,
    lyrics: lyrics,
    durationSecs: durationSecs,
    albumArtist: trackFacts.albumArtist,
    trackNumber: trackFacts.track,
    trackTotal: trackFacts.trackTotal,
    discNumber: trackFacts.disc,
    discTotal: trackFacts.discTotal,
    date: trackFacts.date.isNotEmpty ? trackFacts.date : _yearOf(facts.date),
    copyright: trackFacts.copyright,
    bpm: trackFacts.bpm,
    catalogNumber: facts.catalogNumber,
    barcode: facts.barcode,
    releaseType: releaseType,
    identityResolved: identityResolved,
    identityConflict: identityConflict,
  );
}

/// "2001-05-15" -> "2001" when no fuller date survived.
String _yearOf(String date) {
  if (date.isEmpty) return '';
  final m = RegExp(r'^(\d{4})').firstMatch(date);
  return m?.group(1) ?? '';
}

/// Lyrics ladder for unlanded pulls: LRCLib first (embeddable),
/// PaxSenIX lanes after (display-only, never embedded). Empty =
/// unknown, never an error.
Future<LyricDoc> _lyricsLadder(
  MetadataService svc, {
  required String artist,
  required String title,
  required String album,
  required int durationSecs,
}) async {
  try {
    final doc = await svc.lyricsForRemote(
      artist: artist,
      title: title,
      album: album,
      durationSecs: durationSecs,
    );
    if (doc.hasSynced || doc.hasPlain || doc.instrumental) return doc;
  } catch (_) {}
  try {
    final pax = await svc.paxLyrics(
      artist: artist,
      title: title,
      durationSecs: durationSecs,
    );
    if (pax != null) return pax;
  } catch (e) {
    ArchLog.w('meta', 'paxsenix lane failed: $e');
  }
  return const LyricDoc();
}

Future<String?> _hiResCover(
  MetadataService svc, {
  required String artist,
  required String album,
  required String title,
  required String fallback,
}) async {
  try {
    // Title rides along: it is what tells four self-titled Weezer
    // albums apart. Without it the lane matches on an album name that
    // every one of them shares.
    final url =
        await svc.hiResCoverFor(artist: artist, album: album, title: title);
    if (url != null && url.isNotEmpty) return url;
  } catch (_) {}
  return fallback.isEmpty ? null : fallback;
}
