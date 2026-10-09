import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/secrets.local.dart' as secrets;

/// Enriches a local artist name: MusicBrainz (identity + discography),
/// Deezer (portrait + top tracks), Last.fm (bio). Three independent lanes —
/// pic, bio, and discography fire in parallel and render as each lands.
/// Every fetch is isolated: one dead provider degrades its block, never
/// the page. Versioned atomic disk cache; offline renders last-known-good.
class MetadataService {
  static const _mbBase = 'https://musicbrainz.org/ws/2';
  static const _dzBase = 'https://api.deezer.com';
  static const _lfmBase = 'https://ws.audioscrobbler.com/2.0/';
  static const _userAgent = 'ArchPlayer/0.1.0 (personal use)';
  static const _schema = 2;

  // MusicBrainz allows ~1 req/s. Serialize through a chain.
  Future<void> _mbGate = Future.value();

  Future<T> _viaMbGate<T>(Future<T> Function() work) {
    final run = _mbGate.then((_) => work());
    _mbGate = run.then((_) {}, onError: (_) {}).then((_) => Future.delayed(const Duration(seconds: 1)));
    return run;
  }

  final Map<String, String?> _caaMemo = {};

  /// Full enrich, all three lanes in PARALLEL. Kept for prefetch.
  Future<ArtistMeta> enrich(String artistName) async {
    final results = await Future.wait([
      picFor(artistName),
      bioFor(artistName),
      releasesFor(artistName),
    ]);
    return ArtistMeta(
      imageUrl: results[0] as String?,
      bio: results[1] as String?,
      releases: (results[2] as List<ReleaseGroup>?) ?? const [],
    );
  }

  /// Portrait: cache first, else Deezer live. Never waits on others.
  Future<String?> picFor(String artistName) async {
    final stopwatch = Stopwatch()..start();
    final cached = (await _readCache(artistName))?.imageUrl;
    if (cached != null) {
      _refreshField(artistName, _dzPic(artistName), (m, v) => m.copyWith(imageUrl: v));
      ArchLog.i('meta', 'pic cache hit: $artistName');
      return cached;
    }
    try {
      final found = await _dzArtist(artistName).timeout(const Duration(seconds: 15));
      final live = found?.imageUrl;
      ArchLog.i('meta', 'pic live: $artistName (${stopwatch.elapsedMilliseconds}ms)');
      if (live != null) await _mergeCache(artistName, (m) => m.copyWith(imageUrl: live));
      if (found != null) await _mergeCache(artistName, (m) => m.copyWith(dzId: found.id));
      return live;
    } catch (e) {
      ArchLog.w('meta', 'Deezer pic failed for $artistName: $e');
      return null;
    }
  }

  /// Bio: cache first, else Last.fm live. Never waits on others.
  Future<String?> bioFor(String artistName) async {
    final stopwatch = Stopwatch()..start();
    final cached = (await _readCache(artistName))?.bio;
    if (cached != null) {
      _refreshField(artistName, _lfmBio(artistName), (m, v) => m.copyWith(bio: v));
      ArchLog.i('meta', 'bio cache hit: $artistName');
      return cached;
    }
    try {
      final live = await _lfmBio(artistName).timeout(const Duration(seconds: 15));
      ArchLog.i('meta', 'bio live: $artistName (${stopwatch.elapsedMilliseconds}ms)');
      if (live != null) await _mergeCache(artistName, (m) => m.copyWith(bio: live));
      return live;
    } catch (e) {
      ArchLog.w('meta', 'Last.fm bio failed for $artistName: $e');
      return null;
    }
  }

  /// Discography: cache first, else MusicBrainz live (gated 1 req/s).
  Future<List<ReleaseGroup>> releasesFor(String artistName) async {
    final stopwatch = Stopwatch()..start();
    final cached = (await _readCache(artistName))?.releases ?? [];
    if (cached.isNotEmpty) {
      _refreshField(artistName, _mbReleasesFor(artistName), (m, v) => m.copyWith(releases: v));
      ArchLog.i('meta', 'releases cache hit: $artistName (${cached.length})');
      return cached;
    }
    try {
      final live = await _mbReleasesFor(artistName).timeout(const Duration(seconds: 30));
      ArchLog.i('meta', 'releases live: $artistName (${live.length}, ${stopwatch.elapsedMilliseconds}ms)');
      if (live.isNotEmpty) await _mergeCache(artistName, (m) => m.copyWith(releases: live));
      return live;
    } catch (e) {
      ArchLog.w('meta', 'MB releases failed for $artistName: $e');
      return const [];
    }
  }

  /// Chart top tracks. Preview URLs expire — call fresh per page open.
  Future<List<TopTrack>> topTracks(String artistName) async {
    final stopwatch = Stopwatch()..start();
    try {
      var dzId = (await _readCache(artistName))?.dzId;
      dzId ??= (await _dzArtist(artistName))?.id;
      if (dzId == null || dzId == 0) return const [];
      await _mergeCache(artistName, (m) => m.copyWith(dzId: dzId));
      final uri = Uri.parse('$_dzBase/artist/$dzId/top?limit=10');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const [];
      final list = (jsonDecode(res.body) as Map)['data'] as List? ?? [];
      var rank = 0;
      final out = <TopTrack>[];
      for (final t in list) {
        final m = t as Map;
        final album = m['album'] as Map?;
        rank++;
        out.add(TopTrack(
          rank: (m['rank'] as num?)?.toInt() ?? (1000000 - rank),
          title: (m['title'] as String?) ?? 'Unknown title',
          albumTitle: (album?['title'] as String?) ?? '',
          coverUrl: (album?['cover_medium'] as String?) ?? (album?['cover'] as String?),
          duration: Duration(seconds: (m['duration'] as num?)?.toInt() ?? 0),
          previewUrl: m['preview'] as String?,
        ));
      }
      out.sort((a, b) => b.rank.compareTo(a.rank));
      ArchLog.i('meta', 'top tracks: $artistName (${out.length}, ${stopwatch.elapsedMilliseconds}ms)');
      return out;
    } catch (e) {
      ArchLog.w('meta', 'Deezer top failed for $artistName: $e');
      return const [];
    }
  }

  /// Cover Art Archive front art for a release-group MBID.
  /// Session-memory cached; 404-tolerant. Bytes live in the image cache.
  Future<String?> coverFor(String? rgMbid) async {
    if (rgMbid == null || rgMbid.isEmpty) return null;
    if (_caaMemo.containsKey(rgMbid)) return _caaMemo[rgMbid];
    try {
      final uri = Uri.parse('https://coverartarchive.org/release-group/$rgMbid');
      final res = await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(
        const Duration(seconds: 10),
      );
      if (res.statusCode != 200) {
        _caaMemo[rgMbid] = null;
        return null;
      }
      final images = (jsonDecode(res.body) as Map)['images'] as List? ?? [];
      for (final img in images) {
        final m = img as Map;
        if (m['front'] == true) {
          final thumbs = m['thumbnails'] as Map?;
          final url = (thumbs?['small'] ?? thumbs?['large'] ?? m['image']) as String?;
          _caaMemo[rgMbid] = url;
          return url;
        }
      }
      _caaMemo[rgMbid] = null;
      return null;
    } catch (_) {
      _caaMemo[rgMbid] = null;
      return null;
    }
  }

  Future<List<ReleaseGroup>> _mbReleasesFor(String artistName) async {
    final mbid = await _viaMbGate(() => _mbSearchArtist(artistName));
    if (mbid == null) return const [];
    return _mbReleases(mbid);
  }

  /// Returns the MBID of the best match, or null when nothing is safe.
  /// No guessing: ambiguous = local-only page.
  Future<String?> _mbSearchArtist(String name) async {
    final clean = _cleanName(name);
    final uri = Uri.parse('$_mbBase/artist/?query=artist:${Uri.encodeQueryComponent(clean)}&fmt=json&limit=5');
    final res = await http.get(uri, headers: {'User-Agent': _userAgent});
    if (res.statusCode != 200) return null;
    final list = (jsonDecode(res.body) as Map)['artists'] as List? ?? [];
    if (list.isEmpty) return null;
    final first = list.first as Map;
    final score = (first['score'] as num?)?.toInt() ?? 0;
    if (score < 90) return null;
    return first['id'] as String?;
  }

  Future<List<ReleaseGroup>> _mbReleases(String mbid) async {
    final out = <ReleaseGroup>[];
    var offset = 0;
    for (var page = 0; page < 3; page++) {
      final uri = Uri.parse('$_mbBase/release-group/?artist=$mbid&fmt=json&limit=100&offset=$offset');
      final res = await _viaMbGate(() => http.get(uri, headers: {'User-Agent': _userAgent}));
      if (res.statusCode != 200) break;
      final body = jsonDecode(res.body) as Map;
      final groups = body['release-groups'] as List? ?? [];
      if (groups.isEmpty) break;
      for (final g in groups) {
        final m = g as Map;
        final primary = (m['primary-type'] as String? ?? '').toLowerCase();
        final secondary = ((m['secondary-types'] as List?) ?? []).map((e) => '$e'.toLowerCase()).toList();
        out.add(ReleaseGroup(
          type: _classify(primary, secondary),
          title: (m['title'] as String?) ?? 'Unknown release',
          year: _yearOf(m['first-release-date'] as String?),
          rgMbid: m['id'] as String?,
        ));
      }
      final total = (body['release-group-count'] as num?)?.toInt() ?? 0;
      offset += groups.length;
      if (offset >= total) break;
    }
    return out;
  }

  static String _classify(String primary, List<String> secondary) {
    if (primary == 'single') return 'single';
    if (primary == 'ep') return 'ep';
    if (primary == 'broadcast') return 'other';
    if (secondary.contains('live')) return 'live';
    if (secondary.contains('compilation')) return 'compilation';
    if (primary == 'album') return 'album';
    return 'other';
  }

  static int? _yearOf(String? date) {
    if (date == null || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }

  Future<({int id, String? imageUrl})?> _dzArtist(String name) async {
    final uri = Uri.parse('$_dzBase/search/artist?q=${Uri.encodeQueryComponent(name)}&limit=5');
    final res = await http.get(uri);
    if (res.statusCode != 200) return null;
    final list = (jsonDecode(res.body) as Map)['data'] as List? ?? [];
    if (list.isEmpty) return null;
    Map? best;
    for (final a in list) {
      final m = a as Map;
      if (_closeEnough(name, (m['name'] as String?) ?? '')) {
        best = m;
        break;
      }
    }
    best ??= list.first as Map;
    if (!_closeEnough(name, (best['name'] as String?) ?? '')) return null;
    final pic = best['picture_xl'] as String?;
    return (id: (best['id'] as num?)?.toInt() ?? 0, imageUrl: (pic == null || pic.isEmpty) ? null : pic);
  }

  Future<String?> _dzPic(String name) async => (await _dzArtist(name))?.imageUrl;

  static bool _closeEnough(String a, String b) {
    final na = _cleanName(a), nb = _cleanName(b);
    return na.isNotEmpty && (na == nb || na.contains(nb) || nb.contains(na));
  }

  static String _cleanName(String name) {
    var n = name.toLowerCase();
    n = n.split(RegExp(r'\s+feat\.?\s+')).first;
    n = n.split(RegExp(r'\s+ft\.?\s+')).first;
    return n.trim();
  }

  Future<String?> _lfmBio(String name) async {
    final key = secrets.lastFmApiKey;
    if (key.isEmpty || key == 'PASTE_KEY_HERE') return null;
    String? bio = await _lfmBioWith(name, key);
    bio ??= await _lfmBioWith(name, key.length > 32 ? key.substring(0, 32) : key);
    return bio;
  }

  Future<String?> _lfmBioWith(String name, String key) async {
    final uri = Uri.parse(
        '$_lfmBase?method=artist.getinfo&artist=${Uri.encodeQueryComponent(name)}&api_key=$key&format=json&autocorrect=1');
    final res = await http.get(uri);
    if (res.statusCode != 200) return null;
    final artist = (jsonDecode(res.body) as Map)['artist'] as Map?;
    if (artist?['error'] != null) {
      ArchLog.w('meta', 'Last.fm key rejected, degrading to no-bio');
      return null;
    }
    final summary = (artist?['bio'] as Map?)?['summary'] as String?;
    if (summary == null || summary.isEmpty) return null;
    return summary.split('<a href').first.trim();
  }

  void _refreshField<T>(String artistName, Future<T?> fetch, ArtistMeta Function(ArtistMeta, T?) apply) {
    fetch.then((v) async {
      if (v == null) return;
      if (v is List && v.isEmpty) return;
      await _mergeCache(artistName, (m) => apply(m, v));
    }, onError: (_) {});
  }

  Future<void> _mergeCache(String artistName, ArtistMeta Function(ArtistMeta) merge) async {
    final current = await _readCache(artistName) ?? const ArtistMeta();
    await _writeCache(artistName, merge(current));
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/artist_meta');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _keyOf(String artistName) =>
      artistName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  Future<ArtistMeta?> _readCache(String artistName) async {
    try {
      final file = File('${(await _cacheDir()).path}/${_keyOf(artistName)}.json');
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map;
      // Version gate: unknown or corrupt schema self-deletes. Poison can
      // never survive a restart — the app heals the way a data wipe does.
      if ((m['v'] as num?)?.toInt() != _schema) {
        await file.delete();
        return null;
      }
      return ArtistMeta(
        mbid: m['mbid'] as String?,
        dzId: (m['dzId'] as num?)?.toInt(),
        imageUrl: m['imageUrl'] as String?,
        bio: m['bio'] as String?,
        releases: ((m['releases'] as List?) ?? []).map((e) {
          final r = e as Map;
          return ReleaseGroup(
            type: (r['type'] as String?) ?? 'other',
            title: (r['title'] as String?) ?? 'Unknown release',
            artUrl: r['artUrl'] as String?,
            rgMbid: r['rgMbid'] as String?,
            year: (r['year'] as num?)?.toInt(),
          );
        }).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String artistName, ArtistMeta meta) async {
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}/${_keyOf(artistName)}.json');
      final tmp = File('${dir.path}/${_keyOf(artistName)}.tmp');
      await tmp.writeAsString(jsonEncode({
        'v': _schema,
        'mbid': meta.mbid,
        'dzId': meta.dzId,
        'imageUrl': meta.imageUrl,
        'bio': meta.bio,
        'releases': [
          for (final r in meta.releases)
            {'type': r.type, 'title': r.title, 'artUrl': r.artUrl, 'year': r.year, 'rgMbid': r.rgMbid},
        ],
      }));
      await tmp.rename(file.path);
    } catch (_) {}
  }
}
