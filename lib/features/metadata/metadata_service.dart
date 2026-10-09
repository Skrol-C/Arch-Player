import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/models.dart';
import '../../core/secrets.local.dart' as secrets;

/// Enriches a local artist name: MusicBrainz (identity + discography),
/// Deezer (portrait + top tracks), Last.fm (bio). Every fetch is isolated —
/// one dead provider degrades its block, never the page. Results cached on
/// disk keyed by artist; offline renders last-known-good.
class MetadataService {
  static const _mbBase = 'https://musicbrainz.org/ws/2';
  static const _dzBase = 'https://api.deezer.com';
  static const _lfmBase = 'https://ws.audioscrobbler.com/2.0/';
  static const _userAgent = 'ArchPlayer/0.1.0 (personal use)';

  // MusicBrainz allows ~1 req/s. Serialize through a chain.
  Future<void> _mbGate = Future.value();

  Future<T> _viaMbGate<T>(Future<T> Function() work) {
    final run = _mbGate.then((_) => work());
    _mbGate = run.then((_) {}, onError: (_) {}).then((_) => Future.delayed(const Duration(seconds: 1)));
    return run;
  }

  Future<ArtistMeta> enrich(String artistName) async {
    final cached = await _readCache(artistName);
    if (cached != null) {
      // Refresh in background; render cache now.
      _fetchAndCache(artistName).then((fresh) {
        if (fresh != null) _writeCache(artistName, fresh);
      }, onError: (_) {});
      return cached;
    }
    final fresh = await _fetchAndCache(artistName);
    if (fresh != null) {
      await _writeCache(artistName, fresh);
      return fresh;
    }
    return const ArtistMeta();
  }

  Future<ArtistMeta?> _fetchAndCache(String artistName) async {
    String? mbid;
    List<ReleaseGroup> releases = [];
    try {
      final found = await _viaMbGate(() => _mbSearchArtist(artistName));
      mbid = found;
      if (mbid != null) {
        releases = await _viaMbGate(() => _mbReleases(mbid!)).timeout(
          const Duration(seconds: 20),
          onTimeout: () => <ReleaseGroup>[],
        );
      }
    } catch (e) {
      debugPrint('MB enrich failed for $artistName: $e');
    }

    String? imageUrl;
    try {
      imageUrl = await _dzArtistImage(artistName, mbid)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('Deezer enrich failed for $artistName: $e');
    }

    String? bio;
    try {
      bio = await _lfmBio(artistName).timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('Last.fm enrich failed for $artistName: $e');
    }

    if (mbid == null && imageUrl == null && bio == null && releases.isEmpty) {
      return null;
    }
    return ArtistMeta(mbid: mbid, imageUrl: imageUrl, bio: bio, releases: releases);
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
    // Require a confident match; person/group both fine.
    if (score < 90) return null;
    return first['id'] as String?;
  }

  Future<List<ReleaseGroup>> _mbReleases(String mbid) async {
    final out = <ReleaseGroup>[];
    // Primary types via release-groups; secondary types refine singles/EPs.
    var offset = 0;
    for (var page = 0; page < 3; page++) {
      final uri = Uri.parse(
          '$_mbBase/release-group/?artist=$mbid&fmt=json&limit=100&offset=$offset');
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

  Future<String?> _dzArtistImage(String name, String? mbid) async {
    // Deezer search, guarded: require a close name match.
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
    return (pic == null || pic.isEmpty) ? null : pic;
  }

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
    final summary = (artist?['bio'] as Map?)?['summary'] as String?;
    if (summary == null || summary.isEmpty) return null;
    // Strip the "Read more on Last.fm" link tail.
    return summary.split('<a href').first.trim();
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
      return ArtistMeta(
        mbid: m['mbid'] as String?,
        imageUrl: m['imageUrl'] as String?,
        bio: m['bio'] as String?,
        releases: ((m['releases'] as List?) ?? []).map((e) {
          final r = e as Map;
          return ReleaseGroup(
            type: (r['type'] as String?) ?? 'other',
            title: (r['title'] as String?) ?? 'Unknown release',
            artUrl: r['artUrl'] as String?,
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
      final file = File('${(await _cacheDir()).path}/${_keyOf(artistName)}.json');
      await file.writeAsString(jsonEncode({
        'mbid': meta.mbid,
        'imageUrl': meta.imageUrl,
        'bio': meta.bio,
        'releases': [
          for (final r in meta.releases)
            {'type': r.type, 'title': r.title, 'artUrl': r.artUrl, 'year': r.year},
        ],
      }));
    } catch (_) {}
  }
}
