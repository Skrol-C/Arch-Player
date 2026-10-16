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
  });
}

/// Enrich a pull in parallel lanes. One dead lane degrades its
/// block, never the pull. Never throws.
Future<PullMeta> gatherPullMeta({
  required String title,
  required String artist,
  String album = '',
  String artUrl = '',
  String isrc = '',
  int durationSecs = 0,
}) async {
  final svc = MetadataService();
  List<AlbumCredit> credits = const [];
  List<String> genres = const [];
  String label = '';
  LyricDoc lyrics = const LyricDoc();
  String cover = artUrl;
  try {
    final results = await Future.wait([
      svc.creditsFor(artist: artist, album: album),
      svc.genresFor(artist: artist, album: album),
      svc.labelFor(artist: artist, album: album),
      _lyricsLadder(
        svc,
        artist: artist,
        title: title,
        album: album,
        durationSecs: durationSecs,
      ),
      _hiResCover(svc, artist: artist, album: album, fallback: artUrl),
    ]);
    credits = results[0] as List<AlbumCredit>;
    genres = results[1] as List<String>;
    label = (results[2] as String?) ?? '';
    lyrics = results[3] as LyricDoc;
    cover = (results[4] as String?) ?? artUrl;
  } catch (e) {
    ArchLog.w('meta', 'gather degraded: $e');
  }
  return PullMeta(
    title: title,
    artist: artist,
    album: album,
    genres: genres,
    label: label,
    isrc: isrc,
    coverUrl: cover,
    credits: credits,
    lyrics: lyrics,
    durationSecs: durationSecs,
  );
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
  required String fallback,
}) async {
  try {
    final url = await svc.hiResCoverFor(artist: artist, album: album);
    if (url != null && url.isNotEmpty) return url;
  } catch (_) {}
  return fallback.isEmpty ? null : fallback;
}
