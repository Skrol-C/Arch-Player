import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/secrets.local.dart' as secrets;

/// Enriches a local artist name: MusicBrainz (identity + discography),
/// Deezer (portrait + top tracks), Last.fm (bio). Three independent lanes -
/// pic, bio, and discography fire in parallel and render as each lands.
/// Every fetch is isolated: one dead provider degrades its block, never
/// the page. Versioned atomic disk cache; offline renders last-known-good.
/// Release-level facts that ride on one MusicBrainz release search.
class ReleaseFacts {
  final String label;
  final String catalogNumber;
  final String barcode;
  final String releaseType;
  final String date;
  const ReleaseFacts({
    this.label = '',
    this.catalogNumber = '',
    this.barcode = '',
    this.releaseType = '',
    this.date = '',
  });
}

/// Track-level facts from iTunes + Deezer: the numbers (track, disc),
/// date, album artist, copyright, bpm, ISRC and the composer role.
class TrackFacts {
  final String track;
  final String trackTotal;
  final String disc;
  final String discTotal;
  final String date;
  final String albumArtist;
  final String copyright;
  final String genre;
  final String bpm;
  final String isrc;
  final String composer;
  const TrackFacts({
    this.track = '',
    this.trackTotal = '',
    this.disc = '',
    this.discTotal = '',
    this.date = '',
    this.albumArtist = '',
    this.copyright = '',
    this.genre = '',
    this.bpm = '',
    this.isrc = '',
    this.composer = '',
  });

  /// Every field a pull can carry. A lane cascade stops once this is
  /// true, so a provider that answers everything costs one request.
  bool get isComplete =>
      track.isNotEmpty &&
      disc.isNotEmpty &&
      date.isNotEmpty &&
      albumArtist.isNotEmpty &&
      genre.isNotEmpty &&
      bpm.isNotEmpty &&
      isrc.isNotEmpty &&
      composer.isNotEmpty &&
      copyright.isNotEmpty;

  /// Fill-only merge: what this record already knows wins, [other]
  /// supplies the rest. A miss never overwrites a hit — Apple lacks
  /// the copyright atom for some releases, Deezer lacks the album,
  /// and neither gets to erase what the other found.
  TrackFacts mergedWith(TrackFacts other) => TrackFacts(
        track: track.isNotEmpty ? track : other.track,
        trackTotal: trackTotal.isNotEmpty ? trackTotal : other.trackTotal,
        disc: disc.isNotEmpty ? disc : other.disc,
        discTotal: discTotal.isNotEmpty ? discTotal : other.discTotal,
        date: date.isNotEmpty ? date : other.date,
        albumArtist: albumArtist.isNotEmpty ? albumArtist : other.albumArtist,
        copyright: copyright.isNotEmpty ? copyright : other.copyright,
        genre: genre.isNotEmpty ? genre : other.genre,
        bpm: bpm.isNotEmpty ? bpm : other.bpm,
        isrc: isrc.isNotEmpty ? isrc : other.isrc,
        composer: composer.isNotEmpty ? composer : other.composer,
      );

  /// How many of the eleven fields landed — the log line that says
  /// whether a pull was thin because the providers were, or because
  /// the lanes never matched.
  int get filled => [
        track,
        trackTotal,
        disc,
        discTotal,
        date,
        albumArtist,
        copyright,
        genre,
        bpm,
        isrc,
        composer,
      ].where((v) => v.isNotEmpty).length;
}

class MetadataService {
  static const _mbBase = 'https://musicbrainz.org/ws/2';
  static const _dzBase = 'https://api.deezer.com';
  static const _lfmBase = 'https://ws.audioscrobbler.com/2.0/';
  static const _userAgent = 'ArchPlayer/0.1.0 (personal use)';
  static const _schema = 2;

  // MusicBrainz allows ~1 req/s. Serialize through a chain. The
  // per-unit timeout is the load-bearing part: one hung request
  // must never wedge every later lookup behind it forever.
  Future<void> _mbGate = Future.value();

  Future<T> _viaMbGate<T>(Future<T> Function() work) {
    final run = _mbGate.then(
      (_) => work().timeout(const Duration(seconds: 45)),
    );
    _mbGate = run
        .then((_) {}, onError: (_) {})
        .then((_) => Future.delayed(const Duration(seconds: 1)));
    return run;
  }

  final Map<String, String?> _caaMemo = {};

  final Map<String, ReleaseFacts> _releaseFactsMemo = {};

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
      _refreshField(
        artistName,
        _dzPic(artistName),
        (m, v) => m.copyWith(imageUrl: v),
      );
      ArchLog.i('meta', 'pic cache hit: $artistName');
      return cached;
    }
    try {
      final found = await _dzArtist(artistName)
          .timeout(const Duration(seconds: 15));
      final live = found?.imageUrl;
      ArchLog.i(
        'meta',
        'pic live: $artistName (${stopwatch.elapsedMilliseconds}ms)',
      );
      if (live != null) {
        await _mergeCache(artistName, (m) => m.copyWith(imageUrl: live));
      }
      if (found != null) {
        await _mergeCache(artistName, (m) => m.copyWith(dzId: found.id));
      }
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
      _refreshField(
        artistName,
        _lfmBio(artistName),
        (m, v) => m.copyWith(bio: v),
      );
      ArchLog.i('meta', 'bio cache hit: $artistName');
      return cached;
    }
    try {
      final live = await _lfmBio(artistName)
          .timeout(const Duration(seconds: 15));
      ArchLog.i(
        'meta',
        'bio live: $artistName (${stopwatch.elapsedMilliseconds}ms)',
      );
      if (live != null) {
        await _mergeCache(artistName, (m) => m.copyWith(bio: live));
      }
      return live;
    } catch (e) {
      ArchLog.w('meta', 'Last.fm bio failed for $artistName: $e');
      return null;
    }
  }

  /// Discography: cache first, else MusicBrainz live (gated 1 req/s).
  /// Also persists the artist MBID when the live path resolves it -
  /// the wordmark lane keys off it.
  Future<List<ReleaseGroup>> releasesFor(String artistName) async {
    final stopwatch = Stopwatch()..start();
    final cached = (await _readCache(artistName))?.releases ?? [];
    if (cached.isNotEmpty) {
      _refreshField(
        artistName,
        _mbReleasesFor(artistName),
        (m, v) => m.copyWith(releases: v?.releases),
      );
      ArchLog.i('meta', 'releases cache hit: $artistName (${cached.length})');
      return cached;
    }
    try {
      final live = await _mbReleasesFor(artistName)
          .timeout(const Duration(seconds: 30));
      ArchLog.i(
        'meta',
        'releases live: $artistName (${live.releases.length}, ${stopwatch.elapsedMilliseconds}ms)',
      );
      if (live.releases.isNotEmpty || live.mbid != null) {
        await _mergeCache(
          artistName,
          (m) => m.copyWith(releases: live.releases, mbid: live.mbid),
        );
      }
      return live.releases;
    } catch (e) {
      ArchLog.w('meta', 'MB releases failed for $artistName: $e');
      return const [];
    }
  }

  /// True artist wordmark (fanart.tv HD ClearLogo): cache first, else
  /// MBID resolve + fanart live. Null when the world has no mark for
  /// this artist - the hero falls back to our display-font voice.
  /// Empty API key = local-only, no network attempted.
  Future<String?> logoFor(String artistName) async {
    final cached = (await _readCache(artistName))?.logoUrl;
    if (cached != null) {
      _refreshField(
        artistName,
        _liveLogo(artistName),
        (m, v) => m.copyWith(logoUrl: v),
      );
      ArchLog.i('meta', 'logo cache hit: $artistName');
      return cached;
    }
    try {
      final live = await _liveLogo(artistName)
          .timeout(const Duration(seconds: 20));
      if (live != null) {
        await _mergeCache(artistName, (m) => m.copyWith(logoUrl: live));
      }
      return live;
    } catch (e) {
      ArchLog.w('meta', 'logo failed for $artistName: $e');
      return null;
    }
  }

  Future<String?> _liveLogo(String artistName) async {
    var mbid = (await _readCache(artistName))?.mbid;
    if (mbid == null || mbid.isEmpty) {
      mbid = await _viaMbGate(() => _mbSearchArtist(artistName));
      if (mbid == null) return null;
      await _mergeCache(artistName, (m) => m.copyWith(mbid: mbid));
    }
    // Lane 1: fanart.tv HD ClearLogo.
    final fanartKey = secrets.fanartApiKey;
    if (fanartKey.isNotEmpty && fanartKey != 'PASTE_KEY_HERE') {
      final memoKey = 'logo:$mbid';
      if (_caaMemo.containsKey(memoKey)) return _caaMemo[memoKey];
      try {
        final uri = Uri.parse(
          'https://webservice.fanart.tv/v3/music/$mbid?api_key=$fanartKey',
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body) as Map;
          String? pick(List? items) {
            if (items == null || items.isEmpty) return null;
            return (items.first as Map)['url'] as String?;
          }

          final url =
              pick(body['hdmusiclogo'] as List?) ??
              pick(body['musiclogo'] as List?);
          _caaMemo[memoKey] = url;
          if (url != null) {
            ArchLog.i('meta', 'logo live: $artistName (fanart)');
            return url;
          }
        } else {
          _caaMemo[memoKey] = null;
        }
      } catch (_) {
        _caaMemo[memoKey] = null;
      }
    }
    // Lane 2: TheAudioDB strArtistLogo (different community coverage).
    final tadbKey = secrets.audioDbApiKey;
    if (tadbKey.isNotEmpty && tadbKey != 'PASTE_KEY_HERE') {
      final memoKey = 'tadb:$mbid';
      if (_caaMemo.containsKey(memoKey)) return _caaMemo[memoKey];
      try {
        final uri = Uri.parse(
          'https://www.theaudiodb.com/api/v1/json/$tadbKey/artist-mb.php?i=$mbid',
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final artists = (jsonDecode(res.body) as Map)['artists'];
          String? url;
          if (artists is List && artists.isNotEmpty) {
            final logo = (artists.first as Map)['strArtistLogo'] as String?;
            if (logo != null && logo.isNotEmpty) url = logo;
          }
          _caaMemo[memoKey] = url;
          ArchLog.i(
            'meta',
            'logo live: $artistName ${url == null ? '(none)' : '(tadb)'}',
          );
          return url;
        }
        _caaMemo[memoKey] = null;
      } catch (_) {
        _caaMemo[memoKey] = null;
      }
    }
    ArchLog.i('meta', 'logo live: $artistName (none)');
    return null;
  }

  /// Lyrics: embedded tags win (handled by the lyrics slice before
  /// calling here); LRCLib is the network fallback. Disk-cached per
  /// track, capped - lyrics don't change, so no refresh lane.
  /// A logged fallback ladder (full -> no album -> no duration ->
  /// feat-stripped title) instead of one exact query: matching is
  /// fuzzy in the wild, and every miss names its rung. 404/offline
  /// at every rung = LyricDoc.none(), never an error surface.
  Future<LyricDoc> lyricsFor({
    required int songId,
    required String artist,
    required String title,
    required String album,
    required int durationSecs,
  }) async {
    final cached = await _readLyricCache(songId);
    if (cached != null) return cached;
    final doc = await _lrclibFetch(
      artist: artist,
      title: title,
      album: album,
      durationSecs: durationSecs,
    );
    if (doc == null) return const LyricDoc();
    await _writeLyricCache(songId, doc);
    return doc;
  }

  /// Remote (unowned) lyrics: same ladder, network-only, never
  /// cached - there is no song id to key on.
  Future<LyricDoc> lyricsForRemote({
    required String artist,
    required String title,
    required String album,
    required int durationSecs,
  }) async {
    return await _lrclibFetch(
          artist: artist,
          title: title,
          album: album,
          durationSecs: durationSecs,
        ) ??
        const LyricDoc();
  }

  Future<LyricDoc?> _lrclibFetch({
    required String artist,
    required String title,
    required String album,
    required int durationSecs,
  }) async {
    final cleanAlbum =
        album.isNotEmpty && album.toLowerCase() != 'unknown album'
        ? album
        : null;
    final strippedTitle = _stripFeat(title);
    final rungs = <Map<String, String>>[
      {
        'artist_name': artist,
        'track_name': title,
        'album_name': ?cleanAlbum,
        if (durationSecs > 0) 'duration': '$durationSecs',
      },
      {
        'artist_name': artist,
        'track_name': title,
        if (durationSecs > 0) 'duration': '$durationSecs',
      },
      {'artist_name': artist, 'track_name': title},
      if (strippedTitle != title)
        {'artist_name': artist, 'track_name': strippedTitle},
    ];
    for (var r = 0; r < rungs.length; r++) {
      try {
        final uri = Uri.parse('https://lrclib.net/api/get')
            .replace(queryParameters: rungs[r]);
        final res = await http.get(uri).timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) continue;
        final m = jsonDecode(res.body) as Map;
        final synced = (m['syncedLyrics'] as String?)?.trim();
        final plain = (m['plainLyrics'] as String?)?.trim();
        if ((synced == null || synced.isEmpty) &&
            (plain == null || plain.isEmpty) &&
            m['instrumental'] != true) {
          continue;
        }
        final doc = LyricDoc(
          plain: (plain == null || plain.isEmpty) ? null : plain,
          syncedLrc: (synced == null || synced.isEmpty) ? null : synced,
          source: LyricSource.lrclib,
          instrumental: m['instrumental'] == true,
        );
        ArchLog.i(
          'meta',
          'lyrics live: $artist - $title (rung ${r + 1}/${rungs.length}, ${doc.hasSynced
              ? 'synced'
              : doc.hasPlain
              ? 'plain'
              : 'instrumental'})',
        );
        return doc;
      } catch (e) {
        ArchLog.w(
          'meta',
          'LRCLib rung ${r + 1} failed for $artist - $title: $e',
        );
      }
    }
    return null;
  }

  static String _stripFeat(String title) {
    var t = title;
    t = t.replaceAll(
      RegExp(
        r'\s*[\(\[]?\s*feat\.?\s+[^\)\]]*[\)\]]?\s*$',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(RegExp(r'\s+ft\.?\s+.*$', caseSensitive: false), '');
    return t.trim().isEmpty ? title : t.trim();
  }

  Future<Directory> _lyricDir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/lyrics_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<LyricDoc?> _readLyricCache(int songId) async {
    try {
      final file = File('${(await _lyricDir()).path}/$songId.json');
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map;
      if ((m['v'] as num?)?.toInt() != 1) {
        await file.delete();
        return null;
      }
      final synced = m['synced'] as String?;
      final plain = m['plain'] as String?;
      if ((synced == null || synced.isEmpty) &&
          (plain == null || plain.isEmpty) &&
          m['instrumental'] != true) {
        return null;
      }
      return LyricDoc(
        plain: plain,
        syncedLrc: synced,
        source: LyricSource.lrclib,
        instrumental: m['instrumental'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLyricCache(int songId, LyricDoc doc) async {
    try {
      // No doc worth keeping (and not instrumental) = don't cache air.
      if (!doc.hasSynced && !doc.hasPlain && !doc.instrumental) return;
      final dir = await _lyricDir();
      final file = File('${dir.path}/$songId.json');
      await file.writeAsString(
        jsonEncode({
          'v': 1,
          'plain': doc.plain,
          'synced': doc.syncedLrc,
          'instrumental': doc.instrumental,
        }),
      );
      // Bounded: lyrics are small but infinite tracks aren't. Oldest
      // files go once past the cap.
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      if (files.length > 300) {
        final stats = <File, DateTime>{};
        for (final f in files) {
          stats[f] = await f.lastModified();
        }
        final ordered = stats.keys.toList()
          ..sort((a, b) => stats[a]!.compareTo(stats[b]!));
        for (final f in ordered.take(files.length - 300)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Chart top tracks. Preview URLs expire - call fresh per page open.
  Future<List<TopTrack>> topTracks(String artistName) async {
    final stopwatch = Stopwatch()..start();
    try {
      var dzId = (await _readCache(artistName))?.dzId;
      dzId ??= (await _dzArtist(artistName))?.id;
      if (dzId == null || dzId == 0) return const [];
      await _mergeCache(artistName, (m) => m.copyWith(dzId: dzId));
      final uri = Uri.parse('$_dzBase/artist/$dzId/top?limit=20');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const [];
      final list = (jsonDecode(res.body) as Map)['data'] as List? ?? [];
      var rank = 0;
      final out = <TopTrack>[];
      for (final t in list) {
        final m = t as Map;
        final album = m['album'] as Map?;
        rank++;
        out.add(
          TopTrack(
            rank: (m['rank'] as num?)?.toInt() ?? (1000000 - rank),
            title: (m['title'] as String?) ?? 'Unknown title',
            albumTitle: (album?['title'] as String?) ?? '',
            coverUrl:
                (album?['cover_medium'] as String?) ??
                (album?['cover'] as String?),
            duration: Duration(seconds: (m['duration'] as num?)?.toInt() ?? 0),
            previewUrl: m['preview'] as String?,
          ),
        );
      }
      out.sort((a, b) => b.rank.compareTo(a.rank));
      ArchLog.i(
        'meta',
        'top tracks: $artistName (${out.length}, ${stopwatch.elapsedMilliseconds}ms)',
      );
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
      final uri = Uri.parse(
        'https://coverartarchive.org/release-group/$rgMbid',
      );
      final res = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        _caaMemo[rgMbid] = null;
        return null;
      }
      final images = (jsonDecode(res.body) as Map)['images'] as List? ?? [];
      for (final img in images) {
        final m = img as Map;
        if (m['front'] == true) {
          final thumbs = m['thumbnails'] as Map?;
          final url =
              (thumbs?['small'] ?? thumbs?['large'] ?? m['image']) as String?;
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

  Future<({String? mbid, List<ReleaseGroup> releases})> _mbReleasesFor(
    String artistName,
  ) async {
    final mbid = await _viaMbGate(() => _mbSearchArtist(artistName));
    if (mbid == null) return (mbid: null, releases: const <ReleaseGroup>[]);
    return (mbid: mbid, releases: await _mbReleases(mbid));
  }

  /// Returns the MBID of the best match, or null when nothing is safe.
  /// No guessing: ambiguous = local-only page.
  Future<String?> _mbSearchArtist(String name) async {
    final clean = _cleanName(name);
    final uri = Uri.parse(
      '$_mbBase/artist/?query=artist:${Uri.encodeQueryComponent(clean)}&fmt=json&limit=5',
    );
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
      final uri = Uri.parse(
        '$_mbBase/release-group/?artist=$mbid&fmt=json&limit=100&offset=$offset',
      );
      final res = await _viaMbGate(
        () => http.get(uri, headers: {'User-Agent': _userAgent}),
      );
      if (res.statusCode != 200) break;
      final body = jsonDecode(res.body) as Map;
      final groups = body['release-groups'] as List? ?? [];
      if (groups.isEmpty) break;
      for (final g in groups) {
        final m = g as Map;
        final primary = (m['primary-type'] as String? ?? '').toLowerCase();
        final secondary = ((m['secondary-types'] as List?) ?? [])
            .map((e) => '$e'.toLowerCase())
            .toList();
        out.add(
          ReleaseGroup(
            type: _classify(primary, secondary),
            title: (m['title'] as String?) ?? 'Unknown release',
            year: _yearOf(m['first-release-date'] as String?),
            rgMbid: m['id'] as String?,
          ),
        );
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
    final uri = Uri.parse(
      '$_dzBase/search/artist?q=${Uri.encodeQueryComponent(name)}&limit=5',
    );
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
    return (
      id: (best['id'] as num?)?.toInt() ?? 0,
      imageUrl: (pic == null || pic.isEmpty) ? null : pic,
    );
  }

  Future<String?> _dzPic(String name) async =>
      (await _dzArtist(name))?.imageUrl;

  static bool _closeEnough(String a, String b) {
    final na = _cleanName(a), nb = _cleanName(b);
    return na.isNotEmpty && (na == nb || na.contains(nb) || nb.contains(na));
  }

  /// Artist lists agree on any shared name: a pull credited to
  /// "Yeat, Joji" must match a release credited to "Yeat". Tokens
  /// are compared for equality, never substring, so "Ye" still
  /// cannot match "Yeat".
  static bool _sameArtist(String a, String b) {
    final ta = _artistTokens(a), tb = _artistTokens(b);
    if (ta.isEmpty || tb.isEmpty) return false;
    for (final t in ta) {
      if (tb.contains(t)) return true;
    }
    return false;
  }

  /// "Yeat, Joji" / "Yeat & Joji" / "Yeat feat. Joji" all split to
  /// the names. ` x ` (surrounded by spaces) is a collaboration
  /// separator; a bare letter is not, so "Charli XCX" survives.
  static Set<String> _artistTokens(String raw) {
    final n = raw.toLowerCase().replaceAll('&', ',');
    final parts = n.split(
      RegExp(r'[,/;·]|\s+x\s+|\s+(?:feat|ft|with|and)\.?\s+'),
    );
    return {
      for (final p in parts)
        if (p.trim().isNotEmpty) p.trim(),
    };
  }

  /// Album names may carry an edition suffix, so a prefix match is
  /// allowed — but only when what follows is actually an edition
  /// marker ("(Deluxe)", "[Remastered]", "- EP"). Plain containment
  /// would let "AM" match "DAMN.".
  static bool _sameAlbum(String a, String b) {
    final na = _cleanName(a), nb = _cleanName(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    final short = na.length <= nb.length ? na : nb;
    final long = na.length <= nb.length ? nb : na;
    if (!long.startsWith(short)) return false;
    final rest = long.substring(short.length).trimLeft();
    if (rest.startsWith('(') || rest.startsWith('[') || rest.startsWith('-')) {
      return true;
    }
    return RegExp(
      r'^(deluxe|remaster(ed)?|edition|version|explicit|special|bonus|ep)\b',
    ).hasMatch(rest);
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
    bio ??= await _lfmBioWith(
      name,
      key.length > 32 ? key.substring(0, 32) : key,
    );
    return bio;
  }

  Future<String?> _lfmBioWith(String name, String key) async {
    final uri = Uri.parse(
      '$_lfmBase?method=artist.getinfo&artist=${Uri.encodeQueryComponent(name)}&api_key=$key&format=json&autocorrect=1',
    );
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

  void _refreshField<T>(
    String artistName,
    Future<T?> fetch,
    ArtistMeta Function(ArtistMeta, T?) apply,
  ) {
    fetch.then((v) async {
      if (v == null) return;
      if (v is List && v.isEmpty) return;
      await _mergeCache(artistName, (m) => apply(m, v));
    }, onError: (_) {});
  }

  Future<void> _mergeCache(
    String artistName,
    ArtistMeta Function(ArtistMeta) merge,
  ) async {
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
      final file = File(
        '${(await _cacheDir()).path}/${_keyOf(artistName)}.json',
      );
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map;
      // Version gate: unknown or corrupt schema self-deletes. Poison can
      // never survive a restart - the app heals the way a data wipe does.
      if ((m['v'] as num?)?.toInt() != _schema) {
        await file.delete();
        return null;
      }
      return ArtistMeta(
        mbid: m['mbid'] as String?,
        dzId: (m['dzId'] as num?)?.toInt(),
        imageUrl: m['imageUrl'] as String?,
        bio: m['bio'] as String?,
        logoUrl: m['logoUrl'] as String?,
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
      await tmp.writeAsString(
        jsonEncode({
          'v': _schema,
          'mbid': meta.mbid,
          'dzId': meta.dzId,
          'imageUrl': meta.imageUrl,
          'bio': meta.bio,
          'logoUrl': meta.logoUrl,
          'releases': [
            for (final r in meta.releases)
              {
                'type': r.type,
                'title': r.title,
                'artUrl': r.artUrl,
                'year': r.year,
                'rgMbid': r.rgMbid,
              },
          ],
        }),
      );
      await tmp.rename(file.path);
    } catch (_) {}
  }

  /// Full album tracklist: cache first, else Deezer live, else
  /// MusicBrainz live (gated). Empty = unresolvable offline or
  /// unknown - callers render owned-only, never a hole. Credits
  /// ride along in the same file for the Relationships page.
  Future<List<AlbumTrack>> albumTracksFor({
    required String artist,
    required String album,
  }) async {
    final stopwatch = Stopwatch()..start();
    final cached = await _readAlbumTracks(artist, album);
    if (cached != null && cached.isNotEmpty) {
      ArchLog.i('meta', 'tracklist cache hit: $album (${cached.length})');
      return cached;
    }
    try {
      final dz = await _dzAlbumTracks(
        artist,
        album,
      ).timeout(const Duration(seconds: 15));
      if (dz.isNotEmpty) {
        ArchLog.i(
          'meta',
          'tracklist live: $album (${dz.length}, deezer, ${stopwatch.elapsedMilliseconds}ms)',
        );
        List<AlbumCredit> credits = const [];
        try {
          credits = await _dzAlbumCredits(
            artist,
            album,
          ).timeout(const Duration(seconds: 10));
        } catch (_) {}
        await _writeAlbumTracks(artist, album, dz, credits);
        return dz;
      }
    } catch (e) {
      ArchLog.w('meta', 'Deezer tracklist failed for $album: $e');
    }
    try {
      final mb = await _mbAlbumTracks(
        artist,
        album,
      ).timeout(const Duration(seconds: 30));
      if (mb.tracks.isNotEmpty) {
        ArchLog.i(
          'meta',
          'tracklist live: $album (${mb.tracks.length}, mb, ${stopwatch.elapsedMilliseconds}ms)',
        );
        await _writeAlbumTracks(artist, album, mb.tracks, mb.credits);
      }
      return mb.tracks;
    } catch (e) {
      ArchLog.w('meta', 'MB tracklist failed for $album: $e');
      return const [];
    }
  }

  /// Album credits for Relationships: cache-read (populated by the
  /// tracklist fetch above). Empty = unknown, never an error.
  Future<List<AlbumCredit>> creditsFor({
    required String artist,
    required String album,
  }) async {
    var credits = await _readAlbumCredits(artist, album);
    if (credits != null) return credits;
    await albumTracksFor(artist: artist, album: album);
    return await _readAlbumCredits(artist, album) ?? const [];
  }

  /// PaxSenIX lyrics (lyrics.paxsenix.org, keyless): Musixmatch
  /// lane first, then eastern lanes (QQ, NetEase, Kugou) for
  /// misses. Returns null when nothing resolves. Results are
  /// DISPLAY-ONLY (LyricSource.paxsenix): Musixmatch terms forbid
  /// embedding; the embed step must check the source. Timeouts
  /// per lane; third party, no SLA, never load-bearing.
  Future<LyricDoc?> paxLyrics({
    required String artist,
    required String title,
    int durationSecs = 0,
  }) async {
    const base = 'https://lyrics.paxsenix.org';
    LyricDoc? fromLrc(String? lrc) {
      if (lrc == null || lrc.trim().isEmpty) return null;
      final text = lrc.trim();
      if (_looksSynced(text)) {
        return LyricDoc(
            syncedLrc: text, source: LyricSource.paxsenix);
      }
      return LyricDoc(plain: text, source: LyricSource.paxsenix);
    }

    Future<LyricDoc?> musixmatch() async {
      final uri = Uri.parse('$base/musixmatch/lyrics').replace(
        queryParameters: {
          't': title,
          'a': artist,
          if (durationSecs > 0) 'd': '$durationSecs',
          'format': 'lrc',
          'v': '2',
        },
      );
      final res =
          await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      try {
        final m = jsonDecode(res.body) as Map;
        final data = m['data'] ?? m;
        if (data is! Map) return null;
        for (final k in ['synced_lyrics', 'syncedLyrics', 'lrc', 'lyrics', 'plain_lyrics', 'plainLyrics', 'text']) {
          final v = data[k];
          if (v is String && v.trim().isNotEmpty) {
            return fromLrc(v);
          }
          if (v is List && v.isNotEmpty) {
            final joined = [
              for (final e in v)
                if (e is Map && (e['text'] ?? e['line']) is String)
                  (e['text'] ?? e['line']) as String
                else if (e is String)
                  e,
            ].join('\n').trim();
            if (joined.isNotEmpty) return fromLrc(joined);
          }
        }
        return null;
      } catch (_) {
        return fromLrc(res.body);
      }
    }

    Future<LyricDoc?> qqNetEase() async {
      for (final lane in ['qq', 'netease', 'kugou']) {
        try {
          final search = Uri.parse('$base/$lane/search').replace(
            queryParameters: {
              'q': '$artist $title',
            },
          );
          final sres = await http
              .get(search)
              .timeout(const Duration(seconds: 10));
          if (sres.statusCode != 200) continue;
          String? id;
          try {
            final m = jsonDecode(sres.body) as Map;
            final data = m['data'] ?? m['result'] ?? m['results'];
            final list = data is List
                ? data
                : (data is Map ? (data['list'] ?? data['songs']) : null);
            if (list is List && list.isNotEmpty) {
              final first = list.first;
              if (first is Map) {
                id = (first['id'] ?? first['songid'] ?? first['songId'])
                    ?.toString();
              }
            } else if (data is Map) {
              id = (data['id'] ?? data['songid'])?.toString();
            }
          } catch (_) {
            continue;
          }
          if (id == null || id.isEmpty) continue;
          final lres = await http
              .get(Uri.parse('$base/$lane/lyrics')
                  .replace(queryParameters: {'id': id, 'v': '2'}))
              .timeout(const Duration(seconds: 10));
          if (lres.statusCode != 200) continue;
          try {
            final m = jsonDecode(lres.body) as Map;
            final data = m['data'] ?? m;
            if (data is Map) {
              for (final k in ['lrc', 'lyric', 'lyrics', 'synced_lyrics', 'text']) {
                final v = data[k];
                if (v is String && v.trim().isNotEmpty) {
                  final doc = fromLrc(v);
                  if (doc != null) return doc;
                }
              }
            }
          } catch (_) {}
        } catch (_) {}
      }
      return null;
    }

    try {
      final mm = await musixmatch();
      if (mm != null) {
        ArchLog.i('meta', 'lyrics paxsenix (musixmatch): $artist - $title');
        return mm;
      }
    } catch (_) {}
    try {
      final east = await qqNetEase();
      if (east != null) {
        ArchLog.i('meta', 'lyrics paxsenix (eastern): $artist - $title');
        return east;
      }
    } catch (_) {}
    return null;
  }

  static bool _looksSynced(String text) {
    var hits = 0;
    for (final line in text.split('\n')) {
      if (RegExp(r'^\s*\[\d{1,3}:\d{2}([.:]\d{1,3})?\]').hasMatch(line)) {
        hits++;
        if (hits >= 2) return true;
      }
    }
    return false;
  }

  /// Hi-res cover, best first: Apple master (3000px, keyless), Cover
  /// Art Archive original (often 1500-3000px), Deezer cover_xl
  /// (1000px). Null = unknown.
  ///
  /// [title] is not decoration. Album NAMES collide - Weezer has four
  /// self-titled albums and every "Greatest Hits" matches every
  /// other - so an album-name-only lookup returns the wrong cover
  /// with total confidence (Blue where Green was meant). The TRACK is
  /// the key that disambiguates; the album name is kept as
  /// confirmation, never as the only evidence.
  Future<String?> hiResCoverFor({
    required String artist,
    required String album,
    String title = '',
  }) async {
    try {
      final apple = await _appleCover(artist, album, title);
      if (apple != null && apple.isNotEmpty) {
        ArchLog.i('meta', 'cover lane apple: $artist - $title - $album');
        return apple;
      }
    } catch (_) {}
    try {
      final caa = await _caaAlbumCover(artist, album, title);
      if (caa != null && caa.isNotEmpty) {
        ArchLog.i('meta', 'cover lane caa: $artist - $title - $album');
        return caa;
      }
    } catch (_) {}
    try {
      final dzt = await _dzCoverForTrack(artist, album, title);
      if (dzt != null && dzt.isNotEmpty) {
        ArchLog.i('meta', 'cover lane deezer track: $artist - $title');
        return dzt;
      }
      final id = await _dzAlbumId(artist, album);
      if (id == 0) return null;
      final res = await http
          .get(Uri.parse('$_dzBase/album/$id'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map;
      for (final k in ['cover_xl', 'cover_big', 'cover_medium']) {
        final v = body[k] as String?;
        if (v != null && v.isNotEmpty) {
          ArchLog.i('meta', 'cover lane deezer ($k): $artist - $album');
          return v;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Apple Music artwork. The track lane runs first — it is the one
  /// that fixes self-titled and greatest-hits collisions. The album
  /// lane stays as the fallback for when no track name is known.
  Future<String?> _appleCover(
      String artist, String album, String title) async {
    if (title.trim().isNotEmpty) {
      final hit = await _appleSearch(
        term: '$title $artist',
        entity: 'song',
        attribute: 'songTerm',
        artist: artist,
        album: album,
        title: title,
      );
      if (hit != null) return hit;
    }
    if (album.trim().isEmpty) return null;
    return _appleSearch(
      term: album,
      entity: 'album',
      attribute: 'albumTerm',
      artist: artist,
      album: album,
      title: '',
    );
  }

  /// One iTunes search pass, every hit verified before it is trusted:
  /// artist always, track name when a song search supplied one, album
  /// whenever we know it. That album check is what stops a
  /// compilation containing the track ("Blue / Green / Red") from
  /// winning over the album the track actually came from.
  Future<String?> _appleSearch({
    required String term,
    required String entity,
    required String attribute,
    required String artist,
    required String album,
    required String title,
  }) async {
    final uri = Uri.parse(
      'https://itunes.apple.com/search'
      '?term=${Uri.encodeQueryComponent(term)}'
      '&entity=$entity&attribute=$attribute&limit=15',
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final list = (jsonDecode(res.body) as Map)['results'] as List? ?? [];
    for (final a in list) {
      final m = a as Map;
      if (!_sameArtist(artist, (m['artistName'] as String?) ?? '')) continue;
      if (title.isNotEmpty) {
        final name = (m['trackName'] as String?) ?? '';
        if (name.isEmpty || normTitle(name) != normTitle(title)) continue;
      }
      if (album.trim().isNotEmpty &&
          !_sameAlbum(album, (m['collectionName'] as String?) ?? '')) {
        continue;
      }
      final art = (m['artworkUrl100'] as String?) ?? '';
      if (art.isEmpty) continue;
      final big = art.replaceAll(RegExp(r'/\d+x\d+bb\.'), '/3000x3000bb.');
      if (big != art) return big;
    }
    return null;
  }

  /// Deezer cover by track: resolves to the track's own album, so a
  /// self-titled record lands on the right one. Track search carries
  /// the whole album object, so no second call is needed.
  Future<String?> _dzCoverForTrack(
      String artist, String album, String title) async {
    if (title.trim().isEmpty) return null;
    final q = 'track:"${title.replaceAll('"', '')}"'
        ' artist:"${artist.replaceAll('"', '')}"';
    final res = await http
        .get(Uri.parse(
            '$_dzBase/search/track?q=${Uri.encodeQueryComponent(q)}&limit=10'))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final list = (jsonDecode(res.body) as Map)['data'] as List? ?? [];
    for (final t in list) {
      final m = t as Map;
      final am = m['artist'] as Map?;
      if (!_sameArtist(artist, (am?['name'] as String?) ?? '')) continue;
      if (normTitle((m['title'] as String?) ?? '') != normTitle(title)) {
        continue;
      }
      final alb = m['album'] as Map?;
      if (album.trim().isNotEmpty &&
          !_sameAlbum(album, (alb?['title'] as String?) ?? '')) {
        continue;
      }
      for (final k in ['cover_xl', 'cover_big', 'cover_medium']) {
        final v = alb?[k] as String?;
        if (v != null && v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// Cover Art Archive original front art for an album. Track lane
  /// first (recording -> its release-group), album-name lane second.
  Future<String?> _caaAlbumCover(
      String artist, String album, String title) async {
    final memoKey = 'alb:${artist.toLowerCase()}\u0000'
        '${album.toLowerCase()}\u0000${title.toLowerCase()}';
    if (_caaMemo.containsKey(memoKey)) return _caaMemo[memoKey];
    try {
      var rgid = '';
      if (title.trim().isNotEmpty) {
        rgid = await _mbReleaseGroupForTrack(title, artist, album);
      }
      if (rgid.isEmpty) rgid = await _mbReleaseGroupForAlbum(album, artist);
      if (rgid.isEmpty) {
        _caaMemo[memoKey] = null;
        return null;
      }
      final url = await _caaFront('release-group', rgid);
      _caaMemo[memoKey] = url;
      return url;
    } catch (_) {
      _caaMemo[memoKey] = null;
      return null;
    }
  }

  /// MusicBrainz release-group for a TRACK. This is the lookup that
  /// survives colliding album names: find the recording, keep only the
  /// releases whose title matches the album, then prefer Official and
  /// the earliest date - the original album, never a later compilation.
  ///
  /// Note `releases` comes back on the recording search itself (25 of
  /// them for "Smile"), each carrying `date` and `release-group`.
  Future<String> _mbReleaseGroupForTrack(
      String title, String artist, String album) async {
    final q = 'recording:"${title.replaceAll('"', '')}"'
        ' AND artist:"${artist.replaceAll('"', '')}"';
    final search = Uri.parse(
      '$_mbBase/recording/?query=${Uri.encodeQueryComponent(q)}&fmt=json&limit=5',
    );
    final res = await _viaMbGate(
      () => http.get(search, headers: {'User-Agent': _userAgent}),
    );
    if (res.statusCode != 200) return '';
    final recs = (jsonDecode(res.body) as Map)['recordings'] as List? ?? [];
    for (final rec in recs) {
      final m = rec as Map;
      if (((m['score'] as num?)?.toInt() ?? 0) < 85) continue;
      // MusicBrainz keys this `artist-credit` (hyphenated) - read the
      // right key or every candidate is rejected and the lane dies.
      final credits = (m['artist-credit'] as List?) ?? [];
      final names = credits
          .map((c) => ((c as Map)['name'] as String?) ?? '')
          .join(', ');
      if (!_sameArtist(artist, names)) continue;
      if (normTitle((m['title'] as String?) ?? '') != normTitle(title)) {
        continue;
      }
      final picks = <Map>[];
      for (final r in (m['releases'] as List?) ?? []) {
        final rm = r as Map;
        if (album.trim().isNotEmpty &&
            !_sameAlbum(album, (rm['title'] as String?) ?? '')) {
          continue;
        }
        picks.add(rm);
      }
      if (picks.isEmpty) continue;
      picks.sort((a, b) {
        final ao = (a['status'] as String?) == 'Official' ? 0 : 1;
        final bo = (b['status'] as String?) == 'Official' ? 0 : 1;
        if (ao != bo) return ao - bo;
        return ((a['date'] as String?) ?? '9999')
            .compareTo((b['date'] as String?) ?? '9999');
      });
      final rg = picks.first['release-group'] as Map?;
      final id = (rg?['id'] as String?) ?? '';
      if (id.isNotEmpty) return id;
    }
    return '';
  }

  /// MusicBrainz release-group by album name alone - no track to go
  /// on. Cannot separate same-titled albums; that is exactly why the
  /// track lane above exists.
  Future<String> _mbReleaseGroupForAlbum(String album, String artist) async {
    if (album.trim().isEmpty) return '';
    final q = 'release:"${album.replaceAll('"', '')}"'
        ' AND artist:"${artist.replaceAll('"', '')}"';
    final search = Uri.parse(
      '$_mbBase/release/?query=${Uri.encodeQueryComponent(q)}&fmt=json&limit=5',
    );
    final res = await _viaMbGate(
      () => http.get(search, headers: {'User-Agent': _userAgent}),
    );
    if (res.statusCode != 200) return '';
    final releases = (jsonDecode(res.body) as Map)['releases'] as List? ?? [];
    for (final r in releases) {
      final m = r as Map;
      if (((m['score'] as num?)?.toInt() ?? 0) < 85) continue;
      final credits = (m['artist-credit'] as List?) ?? [];
      final names = credits
          .map((c) => ((c as Map)['name'] as String?) ?? '')
          .join(', ');
      if (!_sameArtist(artist, names)) continue;
      if (!_sameAlbum(album, (m['title'] as String?) ?? '')) continue;
      final rg = m['release-group'] as Map?;
      final id = (rg?['id'] as String?) ?? '';
      if (id.isNotEmpty) return id;
    }
    return '';
  }

  /// CAA front image from a `release-group/<id>` endpoint. The `image`
  /// field is the original file, never a thumbnail.
  Future<String?> _caaFront(String kind, String id) async {
    final res = await http.get(
      Uri.parse('https://coverartarchive.org/$kind/$id'),
      headers: {'User-Agent': _userAgent},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final images = (jsonDecode(res.body) as Map)['images'] as List? ?? [];
    for (final img in images) {
      final m = img as Map;
      if (m['front'] != true) continue;
      final thumbs = m['thumbnails'] as Map?;
      return (m['image'] ?? thumbs?['large'] ?? thumbs?['small']) as String?;
    }
    return null;
  }

  /// Label, catalogue number, barcode and release type — all of them
  /// ride on the release SEARCH the label lane already makes, so this
  /// costs no extra request. (Verified: the search response carries
  /// `barcode`, `label-info[].catalog-number` and
  /// `release-group.primary-type`.)
  Future<ReleaseFacts> releaseFactsFor({
    required String artist,
    required String album,
  }) async {
    if (album.trim().isEmpty) return const ReleaseFacts();
    final memoKey = 'facts:${artist.toLowerCase()}\u0000${album.toLowerCase()}';
    final memoed = _releaseFactsMemo[memoKey];
    if (memoed != null) return memoed;
    try {
      final q = 'release:"${album.replaceAll('"', '')}"'
          ' AND artist:"${artist.replaceAll('"', '')}"';
      final search = Uri.parse(
        '$_mbBase/release/?query=${Uri.encodeQueryComponent(q)}&fmt=json&limit=5',
      );
      final res = await _viaMbGate(
        () => http.get(search, headers: {'User-Agent': _userAgent}),
      );
      if (res.statusCode != 200) return const ReleaseFacts();
      final releases = (jsonDecode(res.body) as Map)['releases'] as List? ?? [];
      for (final r in releases) {
        final m = r as Map;
        if (((m['score'] as num?)?.toInt() ?? 0) < 85) continue;
        final credits = (m['artist-credit'] as List?) ?? [];
        final names = credits
            .map((c) => ((c as Map)['name'] as String?) ?? '')
            .join(', ');
        if (!_sameArtist(artist, names)) continue;
        if (!_sameAlbum(album, (m['title'] as String?) ?? '')) continue;
        String label = '';
        String catalog = '';
        final info = (m['label-info'] as List?) ?? [];
        for (final li in info) {
          final lm = li as Map;
          final name = ((lm['label'] as Map?)?['name'] as String?) ?? '';
          if (name.isNotEmpty) {
            label = name;
            catalog = (lm['catalog-number'] as String?) ?? '';
            break;
          }
        }
        final rg = m['release-group'] as Map?;
        final facts = ReleaseFacts(
          label: label,
          catalogNumber: catalog,
          barcode: (m['barcode'] as String?) ?? '',
          releaseType: (rg?['primary-type'] as String?) ?? '',
          date: (m['date'] as String?) ?? '',
        );
        _releaseFactsMemo[memoKey] = facts;
        return facts;
      }
    } catch (_) {}
    return const ReleaseFacts();
  }

  /// Track facts from every provider that has them. Apple and Deezer
  /// are independent and fast, so both are asked at once; MusicBrainz
  /// is asked only when something is still missing. A field one lane
  /// answers is never overwritten by a later one, and a field no lane
  /// answers stays empty — the embed then writes what exists and
  /// leaves the rest untouched. The cascade stops the moment every
  /// field is filled.
  Future<TrackFacts> trackFactsFor({
    required String artist,
    required String album,
    required String title,
  }) async {
    // The query identity has to be clean. A raw title carries
    // "(feat. X)" and the artist may be a list ("Kanye West, Ye,
    // Travis Scott"); Apple ranks that query badly enough that the
    // real hit never appears, and one miss costs five fields at once
    // (verified: BULLY/3.FATHER returned 15 unrelated songs raw, and
    // the album's own track once cleaned).
    final qTitle = _searchTitle(title);
    final qArtist = _primaryArtist(artist);
    if (qTitle.isEmpty) return const TrackFacts();
    var facts = const TrackFacts();
    final parallel = await Future.wait([
      _safeFacts(() => _appleTrackLane(qTitle, qArtist, album)),
      _safeFacts(() => _dzTrackLane(qTitle, qArtist, album)),
    ]);
    for (final lane in parallel) {
      facts = facts.mergedWith(lane);
    }
    if (!facts.isComplete) {
      facts = facts
          .mergedWith(await _safeFacts(() => _mbTrackLane(qTitle, qArtist, album)));
    }
    // Album artist is the one field with a free fallback, and it
    // drives album grouping: the primary credit beats an empty atom.
    if (facts.albumArtist.isEmpty && qArtist.isNotEmpty) {
      facts = facts.mergedWith(TrackFacts(albumArtist: qArtist));
    }
    ArchLog.i('meta', 'track facts: ${facts.filled}/11 fields'
        '${facts.isComplete ? '' : ' (incomplete)'}');
    return facts;
  }

  /// One dead lane degrades its fields, never the pull.
  Future<TrackFacts> _safeFacts(Future<TrackFacts> Function() lane) async {
    try {
      return await lane();
    } catch (_) {
      return const TrackFacts();
    }
  }

  /// iTunes lane: the numbers, the date, the album artist, the
  /// copyright, the genre.
  Future<TrackFacts> _appleTrackLane(
      String title, String artist, String album) async {
    final hit = await _appleTrackHit(title, artist, album);
    if (hit == null) return const TrackFacts();
    return TrackFacts(
      track: _num(hit['trackNumber']),
      trackTotal: _num(hit['trackCount']),
      disc: _num(hit['discNumber']),
      discTotal: _num(hit['discCount']),
      date: _isoDay((hit['releaseDate'] as String?) ?? ''),
      albumArtist: (hit['collectionArtistName'] as String?) ?? '',
      copyright: (hit['copyright'] as String?) ?? '',
      genre: (hit['primaryGenreName'] as String?) ?? '',
    );
  }

  /// Deezer lane: exactly the fields iTunes does not carry — BPM,
  /// ISRC, and the composer credit.
  Future<TrackFacts> _dzTrackLane(
      String title, String artist, String album) async {
    final dz = await _dzTrackHit(title, artist, album);
    if (dz == null) return const TrackFacts();
    var composer = '';
    for (final c in (dz['contributors'] as List?) ?? []) {
      final cm = c as Map;
      final role = ((cm['role'] as String?) ?? '').toLowerCase();
      if (role == 'composer' || role == 'author' || role == 'writer') {
        composer = ((cm['name'] as String?) ?? '').trim();
        if (composer.isNotEmpty) break;
      }
    }
    return TrackFacts(
      track: _num(dz['track_position']),
      disc: _num(dz['disk_number']),
      date: (dz['release_date'] as String?) ?? '',
      bpm: _num(dz['bpm']),
      isrc: (dz['isrc'] as String?) ?? '',
      composer: composer,
    );
  }

  /// MusicBrainz lane: dates and track numbers for catalogue releases
  /// the streaming providers never got. Both requests ride the 1req/s
  /// gate, so this lane can be slow — which is why it only runs when
  /// the fast lanes left a hole.
  Future<TrackFacts> _mbTrackLane(
      String title, String artist, String album) async {
    final q = 'recording:"${title.replaceAll('"', '')}"'
        ' AND artist:"${artist.replaceAll('"', '')}"';
    final search = await _viaMbGate(() => http.get(
          Uri.parse('$_mbBase/recording/?query='
              '${Uri.encodeQueryComponent(q)}&fmt=json&limit=5'),
          headers: {'User-Agent': _userAgent},
        ));
    if (search.statusCode != 200) return const TrackFacts();
    final list = (jsonDecode(search.body) as Map)['recordings'] as List? ?? [];
    String? id;
    for (final r in list) {
      final m = r as Map;
      if (normTitle((m['title'] as String?) ?? '') != normTitle(title)) {
        continue;
      }
      final names = ((m['artist-credit'] as List?) ?? [])
          .map((c) => ((c as Map)['name'] as String?) ?? '')
          .join(', ');
      if (!_sameArtist(artist, names)) continue;
      id = m['id'] as String?;
      break;
    }
    if (id == null) return const TrackFacts();
    final look = await _viaMbGate(() => http.get(
          Uri.parse('$_mbBase/recording/$id?inc=releases+tags&fmt=json'),
          headers: {'User-Agent': _userAgent},
        ));
    if (look.statusCode != 200) return const TrackFacts();
    final m = jsonDecode(look.body) as Map;
    // Track numbers live under releases[].media[].track[].number, as
    // strings, alongside the medium's position (the disc) and its
    // track-count (the total).
    var track = '';
    var trackTotal = '';
    var disc = '';
    for (final rel in (m['releases'] as List?) ?? []) {
      for (final md in ((rel as Map)['media'] as List?) ?? []) {
        final mm = md as Map;
        for (final t in (mm['track'] as List?) ?? []) {
          final tm = t as Map;
          if (normTitle((tm['title'] as String?) ?? '') != normTitle(title)) {
            continue;
          }
          track = _numAny(tm['number']);
          trackTotal = _numAny(mm['track-count']);
          disc = _numAny(mm['position']);
          break;
        }
        if (track.isNotEmpty) break;
      }
      if (track.isNotEmpty) break;
    }
    // Genres arrive as folksonomy tags with weights: heaviest first.
    final tags = ((m['tags'] as List?) ?? []).toList()
      ..sort((a, b) => _tagWeight(b).compareTo(_tagWeight(a)));
    final genre =
        tags.isEmpty ? '' : ((tags.first as Map)['name'] as String?) ?? '';
    return TrackFacts(
      track: track,
      trackTotal: trackTotal,
      disc: disc,
      date: (m['first-release-date'] as String?) ?? '',
      genre: genre,
    );
  }

  static int _tagWeight(Object? tag) {
    final v = (tag as Map)['count'];
    return v is num ? v.toInt() : 0;
  }

  /// "2016-02-14T07:00:00Z" -> "2016-02-14": the day, no clock.
  static String _isoDay(String raw) {
    final m = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(raw);
    return m?.group(1) ?? '';
  }

  /// Search-shaped title: feature credits dropped, spacing collapsed.
  /// Casing survives (both catalogues are case-insensitive, and the
  /// query stays readable in the log).
  static String _searchTitle(String t) {
    var s = t.replaceAll(
      RegExp(
        r'\s*[\(\[]\s*(feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]',
        caseSensitive: false,
      ),
      '',
    );
    s = s.split(RegExp(r'\s+feat\.?\s+', caseSensitive: false)).first;
    s = s.split(RegExp(r'\s+ft\.?\s+', caseSensitive: false)).first;
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// The credit the catalogues index under: "Kanye West, Ye, Travis
  /// Scott" -> "Kanye West".
  static String _primaryArtist(String raw) {
    final parts = splitArtists(raw);
    return parts.isEmpty ? raw.trim() : parts.first;
  }

  /// MusicBrainz hands numbers back as strings ("3"); Apple and Deezer
  /// hand back ints. One reader for both.
  static String _numAny(Object? v) {
    if (v is num) return _num(v);
    if (v is String) return _num(int.tryParse(v.trim()) ?? 0);
    return '';
  }

  static String _num(Object? v) {
    if (v is num) {
      final n = v.toInt();
      return n > 0 ? '$n' : '';
    }
    return '';
  }

  /// The iTunes hit for a track, verified on artist + title + album.
  /// Apple ranks a term by how many tokens it carries, and a correct
  /// query can still bury the entry past the first page (verified:
  /// "FATHER Kanye West" pushes BULLY/3 to rank 26, while
  /// "FATHER Kanye West BULLY" puts it at rank 0 and "FATHER Kanye"
  /// at rank 1). So the term is tried in three shapes, most precise
  /// first — and every hit still has to pass title + artist + album,
  /// so a broader term can never win a wrong track.
  Future<Map?> _appleTrackHit(
      String title, String artist, String album) async {
    for (final term in _appleTerms(title, artist, album)) {
      final uri = Uri.parse(
        'https://itunes.apple.com/search'
        '?term=${Uri.encodeQueryComponent(term)}'
        '&entity=song&attribute=songTerm&limit=30',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) continue;
      final list = (jsonDecode(res.body) as Map)['results'] as List? ?? [];
      for (final a in list) {
        final m = a as Map;
        if (!_sameArtist(artist, (m['artistName'] as String?) ?? '')) continue;
        if (normTitle((m['trackName'] as String?) ?? '') != normTitle(title)) {
          continue;
        }
        if (album.trim().isNotEmpty &&
            !_sameAlbum(album, (m['collectionName'] as String?) ?? '')) {
          continue;
        }
        return m;
      }
    }
    // Direct song search is a ranking lottery: Apple's index does not
    // always surface a track its own album page carries (verified:
    // BULLY/3.FATHER is absent from every song-term page at limit 30,
    // while the album's lookup returns it at track 3 of 18). Resolve
    // the album id, then read the tracklist off it.
    return _appleAlbumHit(title, artist, album);
  }

  /// The same track, found through its album: match the collection by
  /// name + artist, then read that album's tracklist. Slower than a
  /// song search (two requests) and far more reliable — the lookup
  /// endpoint carries track totals and disc numbers the search
  /// endpoint drops.
  Future<Map?> _appleAlbumHit(
      String title, String artist, String album) async {
    if (album.trim().isEmpty) return null;
    try {
      final search = await http.get(Uri.parse(
        'https://itunes.apple.com/search'
        '?term=${Uri.encodeQueryComponent('$album $artist')}'
        '&entity=song&attribute=songTerm&limit=30',
      )).timeout(const Duration(seconds: 15));
      if (search.statusCode != 200) return null;
      final ids = <Object>[];
      for (final a in (jsonDecode(search.body) as Map)['results'] as List? ??
          const []) {
        final m = a as Map;
        if (!_sameAlbum(album, (m['collectionName'] as String?) ?? '')) {
          continue;
        }
        if (!_sameArtist(artist, (m['artistName'] as String?) ?? '')) continue;
        final id = m['collectionId'];
        if (id != null && !ids.contains(id)) ids.add(id);
        if (ids.length >= 3) break;
      }
      for (final id in ids) {
        final look = await http
            .get(Uri.parse(
                'https://itunes.apple.com/lookup?id=$id&entity=song&limit=60'))
            .timeout(const Duration(seconds: 15));
        if (look.statusCode != 200) continue;
        for (final a in (jsonDecode(look.body) as Map)['results'] as List? ??
            const []) {
          final m = a as Map;
          if (m['wrapperType'] != 'track') continue;
          if (normTitle((m['trackName'] as String?) ?? '') != normTitle(title)) {
            continue;
          }
          return m;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Search shapes for one track, most precise first: title + artist
  /// + album, then title + artist, then title + the artist's first
  /// name (Apple ranks short terms higher — the "Kanye West" form
  /// buries the hit that "Kanye" surfaces).
  static List<String> _appleTerms(
      String title, String artist, String album) {
    final terms = <String>[];
    if (album.trim().isNotEmpty) terms.add('$title $artist $album');
    terms.add('$title $artist');
    final first = artist.split(RegExp(r'\s+')).first;
    if (first.isNotEmpty && first != artist) terms.add('$title $first');
    return terms;
  }

  /// The Deezer hit for a track, verified the same way.
  Future<Map?> _dzTrackHit(String title, String artist, String album) async {
    final q = 'track:"${title.replaceAll('"', '')}"'
        ' artist:"${artist.replaceAll('"', '')}"';
    final res = await http
        .get(Uri.parse(
            '$_dzBase/search/track?q=${Uri.encodeQueryComponent(q)}&limit=10'))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final list = (jsonDecode(res.body) as Map)['data'] as List? ?? [];
    for (final t in list) {
      final m = t as Map;
      final am = m['artist'] as Map?;
      if (!_sameArtist(artist, (am?['name'] as String?) ?? '')) continue;
      if (normTitle((m['title'] as String?) ?? '') != normTitle(title)) {
        continue;
      }
      final alb = m['album'] as Map?;
      if (album.trim().isNotEmpty &&
          !_sameAlbum(album, (alb?['title'] as String?) ?? '')) {
        continue;
      }
      return m;
    }
    return null;
  }

  Future<String?> labelFor({
    required String artist,
    required String album,
  }) async {
    try {
      final cached = await _readAlbumLabel(artist, album);
      if (cached != null) return cached == '' ? null : cached;
      final q = 'release:"${album.replaceAll('"', '')}" AND artist:"${artist.replaceAll('"', '')}"';
      final search = Uri.parse(
        '$_mbBase/release/?query=${Uri.encodeQueryComponent(q)}&fmt=json&limit=5',
      );
      final res = await _viaMbGate(
        () => http.get(search, headers: {'User-Agent': _userAgent}),
      );
      String label = '';
      if (res.statusCode == 200) {
        final list =
            (jsonDecode(res.body) as Map)['releases'] as List? ?? [];
        for (final r in list) {
          final m = r as Map;
          if (((m['score'] as num?)?.toInt() ?? 0) < 85) continue;
          final info = (m['label-info'] as List?) ?? [];
          if (info.isNotEmpty) {
            final name =
                ((info.first as Map)['label'] as Map?)?['name']
                    as String?;
            if (name != null && name.trim().isNotEmpty) {
              label = name.trim();
              break;
            }
          }
        }
      }
      await _writeAlbumLabel(artist, album, label);
      return label.isEmpty ? null : label;
    } catch (_) {
      return null;
    }
  }

  /// Album genres: Last.fm folksonomy (keyed, junk-filtered), else
  /// MusicBrainz curated genres, else Deezer's broad genre. Max two,
  /// cached. Empty = the world says nothing usable.
  Future<List<String>> genresFor({
    required String artist,
    required String album,
  }) async {
    final cached = await _readAlbumGenres(artist, album);
    if (cached != null) return cached;
    var genres = await _lfmGenres(artist, album);
    var lane = 'lastfm';
    if (genres.isEmpty) {
      genres = await _mbGenres(artist, album);
      lane = 'musicbrainz';
    }
    if (genres.isEmpty) {
      genres = await _dzGenre(artist, album);
      lane = 'deezer';
    }
    ArchLog.i(
      'meta',
      genres.isEmpty
          ? 'genre miss all lanes: $artist - $album'
          : 'genre hit ($lane): $artist - $album = ${genres.join(', ')}',
    );
    await _writeAlbumGenres(artist, album, genres);
    return genres;
  }

  static const _genreJunk = {
    'albums i own',
    'my albums',
    'awesome',
    'favourite',
    'favorite',
    'favorites',
    'favourites',
    'love',
    'loved',
    'seen live',
    'own',
    'owned',
    'collection',
    'cd',
    'vinyl',
    'mp3',
    'flac',
    'all',
    'music',
    'songs',
    'song',
    'album',
    'albums',
    'artist',
    'artists',
    'band',
    'bands',
    'good',
    'great',
    'best',
    'love it',
    'my favorite',
    'own it',
  };

  Future<List<String>> _lfmGenres(String artist, String album) async {
    final key = secrets.lastFmApiKey;
    if (key.isEmpty || key == 'PASTE_KEY_HERE') return const [];
    try {
      final uri = Uri.parse(
        '$_lfmBase?method=album.getTopTags&artist=${Uri.encodeQueryComponent(artist)}&album=${Uri.encodeQueryComponent(album)}&api_key=$key&format=json',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const [];
      final tags = ((jsonDecode(res.body) as Map)['toptags'] as Map?)?['tag'];
      final list = tags is List ? tags : (tags is Map ? [tags] : []);
      final out = <String>[];
      for (final t in list) {
        final name = ((t as Map)['name'] as String?)?.trim() ?? '';
        final n = name.toLowerCase();
        if (n.length < 2 ||
            _genreJunk.contains(n) ||
            RegExp(r'^\d+$').hasMatch(n)) {
          continue;
        }
        if (!out.any((e) => e.toLowerCase() == n)) out.add(name);
        if (out.length >= 2) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _mbGenres(String artist, String album) async {
    try {
      final rg = await _mbReleaseGroupId(artist, album);
      if (rg == null) return const [];
      final res = await _viaMbGate(
        () => http.get(
          Uri.parse('$_mbBase/release-group/$rg?inc=genres&fmt=json'),
          headers: {'User-Agent': _userAgent},
        ),
      );
      if (res.statusCode != 200) return const [];
      final genres = (jsonDecode(res.body) as Map)['genres'] as List? ?? [];
      final out = <String>[];
      for (final g in genres) {
        final name = ((g as Map)['name'] as String?)?.trim() ?? '';
        if (name.isNotEmpty &&
            !out.any((e) => e.toLowerCase() == name.toLowerCase())) {
          out.add(name);
        }
        if (out.length >= 2) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _mbReleaseGroupId(String artist, String album) async {
    final q =
        'release:"${album.replaceAll('"', '')}" AND artist:"${artist.replaceAll('"', '')}"';
    final search = Uri.parse(
      '$_mbBase/release/?query=${Uri.encodeQueryComponent(q)}&fmt=json&limit=5',
    );
    final res = await _viaMbGate(
      () => http.get(search, headers: {'User-Agent': _userAgent}),
    );
    if (res.statusCode != 200) return null;
    final list = (jsonDecode(res.body) as Map)['releases'] as List? ?? [];
    for (final r in list) {
      final m = r as Map;
      if (((m['score'] as num?)?.toInt() ?? 0) >= 85) {
        final rg = m['release-group'] as Map?;
        final id = rg?['id'] as String?;
        if (id != null) return id;
      }
    }
    return null;
  }

  Future<List<String>> _dzGenre(String artist, String album) async {
    try {
      final id = await _dzAlbumId(artist, album);
      if (id == 0) return const [];
      final res = await http
          .get(Uri.parse('$_dzBase/album/$id'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body) as Map;
      final genres = body['genres'] as Map?;
      final data = genres?['data'] as List?;
      if (data == null || data.isEmpty) return const [];
      final name = ((data.first as Map)['name'] as String?)?.trim() ?? '';
      return name.isEmpty ? const [] : [name];
    } catch (_) {
      return const [];
    }
  }

  Future<int> _dzAlbumId(String artist, String album) async {
    final q =
        'artist:"${artist.replaceAll('"', '')}" album:"${album.replaceAll('"', '')}"';
    final search = Uri.parse(
      '$_dzBase/search/album?q=${Uri.encodeQueryComponent(q)}&limit=5',
    );
    final res = await http
        .get(search)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return 0;
    final list = (jsonDecode(res.body) as Map)['data'] as List? ?? [];
    for (final a in list) {
      final m = a as Map;
      final am = m['artist'] as Map?;
      if (_closeEnough(album, (m['title'] as String?) ?? '') &&
          _closeEnough(artist, (am?['name'] as String?) ?? '')) {
        return (m['id'] as num?)?.toInt() ?? 0;
      }
    }
    return 0;
  }

  Future<List<AlbumCredit>> _dzAlbumCredits(String artist, String album) async {
    try {
      final id = await _dzAlbumId(artist, album);
      if (id == 0) return const [];
      final res = await http.get(Uri.parse('$_dzBase/album/$id'));
      if (res.statusCode != 200) return const [];
      final contributors =
          (jsonDecode(res.body) as Map)['contributors'] as List? ?? [];
      final out = <AlbumCredit>[];
      for (final c in contributors) {
        final m = c as Map;
        final name = (m['name'] as String?)?.trim() ?? '';
        if (name.isEmpty ||
            out.any((e) => e.name.toLowerCase() == name.toLowerCase())) {
          continue;
        }
        out.add(
          AlbumCredit(
            name: name,
            role: ((m['role'] as String?) ?? 'performer').toLowerCase(),
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<AlbumTrack>> _dzAlbumTracks(String artist, String album) async {
    final id = await _dzAlbumId(artist, album);
    if (id == 0) return const [];
    final tracks = await http.get(
      Uri.parse('$_dzBase/album/$id/tracks?limit=100'),
    );
    if (tracks.statusCode != 200) return const [];
    final data = (jsonDecode(tracks.body) as Map)['data'] as List? ?? [];
    var pos = 0;
    return [
      for (final t in data)
        AlbumTrack(
          position: ((t as Map)['track_position'] as num?)?.toInt() ?? ++pos,
          title: ((t)['title'] as String?) ?? 'Unknown track',
          durationSecs: ((t)['duration'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// MB tracklist + credit rels in one release lookup
  /// (inc=recordings+artist-rels): the credits ride free on a call
  /// we already make. Roles filtered to real credits, deduped.
  static const _creditRoles = {
    'producer',
    'engineer',
    'mixer',
    'mix',
    'mastering',
    'writer',
    'composer',
    'lyricist',
    'arranger',
    'orchestrator',
    'conductor',
    'performer',
    'instrument',
    'vocal',
    'vocals',
    'dj',
    'remixer',
    'remix',
    'programming',
  };

  Future<({List<AlbumTrack> tracks, List<AlbumCredit> credits})> _mbAlbumTracks(
    String artist,
    String album,
  ) async {
    const empty = (tracks: <AlbumTrack>[], credits: <AlbumCredit>[]);
    final q =
        'release:"${album.replaceAll('"', '')}" AND artist:"${artist.replaceAll('"', '')}"';
    final search = Uri.parse(
      '$_mbBase/release/?query=${Uri.encodeQueryComponent(q)}&fmt=json&limit=5',
    );
    final res = await _viaMbGate(
      () => http.get(search, headers: {'User-Agent': _userAgent}),
    );
    if (res.statusCode != 200) return empty;
    final list = (jsonDecode(res.body) as Map)['releases'] as List? ?? [];
    Map? best;
    for (final r in list) {
      final m = r as Map;
      if (((m['score'] as num?)?.toInt() ?? 0) >= 85) {
        best = m;
        break;
      }
    }
    if (best == null) return empty;
    final id = best['id'] as String?;
    if (id == null) return empty;
    final rel = await _viaMbGate(
      () => http.get(
        Uri.parse('$_mbBase/release/$id?inc=recordings+artist-rels&fmt=json'),
        headers: {'User-Agent': _userAgent},
      ),
    );
    if (rel.statusCode != 200) return empty;
    final out = <AlbumTrack>[];
    final credits = <AlbumCredit>[];
    void addCredit(String name, String role, String? mbid) {
      name = name.trim();
      role = role.trim().toLowerCase();
      if (name.isEmpty || !_creditRoles.contains(role)) return;
      if (credits.any(
        (e) => e.name.toLowerCase() == name.toLowerCase() && e.role == role,
      )) {
        return;
      }
      credits.add(AlbumCredit(name: name, role: role, mbid: mbid));
    }

    final media = (jsonDecode(rel.body) as Map)['media'] as List? ?? [];
    for (final med in media) {
      final tracks = ((med as Map)['tracks'] as List?) ?? [];
      for (final tr in tracks) {
        final m = tr as Map;
        final lenMs = (m['length'] as num?)?.toInt() ?? 0;
        out.add(
          AlbumTrack(
            position: (m['position'] as num?)?.toInt() ?? out.length + 1,
            title: (m['title'] as String?) ?? 'Unknown track',
            durationSecs: lenMs > 0 ? lenMs ~/ 1000 : 0,
          ),
        );
        final relations = (m['relations'] as List?) ?? [];
        for (final relEntry in relations) {
          final rm = relEntry as Map;
          final type = (rm['type'] as String?) ?? '';
          final target = rm['artist'] as Map?;
          if (target == null) continue;
          addCredit(
            (target['name'] as String?) ?? '',
            type,
            target['id'] as String?,
          );
        }
      }
    }
    return (tracks: out, credits: credits);
  }

  Future<Directory> _albumTrackDir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/album_tracks');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _trackKeyOf(String artist, String album) =>
      '${_keyOf(artist)}__${_keyOf(album)}';

  Future<List<AlbumTrack>?> _readAlbumTracks(
    String artist,
    String album,
  ) async {
    try {
      final file = File(
        '${(await _albumTrackDir()).path}/${_trackKeyOf(artist, album)}.json',
      );
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map;
      if ((m['v'] as num?)?.toInt() != _schema) {
        await file.delete();
        return null;
      }
      // Pre-credits cache files refetch once: the live write
      // populates the complete schema. Offline stays owned-only.
      if (!m.containsKey('credits')) return null;
      return [
        for (final e in (m['tracks'] as List? ?? []))
          AlbumTrack(
            position: ((e as Map)['p'] as num?)?.toInt() ?? 0,
            title: (e['t'] as String?) ?? 'Unknown track',
            durationSecs: (e['d'] as num?)?.toInt() ?? 0,
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAlbumTracks(
    String artist,
    String album,
    List<AlbumTrack> tracks,
    List<AlbumCredit> credits,
  ) async {
    try {
      final dir = await _albumTrackDir();
      final file = File('${dir.path}/${_trackKeyOf(artist, album)}.json');
      final tmp = File('${dir.path}/${_trackKeyOf(artist, album)}.tmp');
      // Preserve already-cached genres + label: tracks, genres, and
      // label resolve on independent ladders and must never wipe
      // each other.
      List<String> genres = const [];
      String label = '';
      bool hasLabel = false;
      try {
        if (await file.exists()) {
          final prev = jsonDecode(await file.readAsString()) as Map;
          genres = [
            for (final g in (prev['genres'] as List? ?? []))
              if ((g as String).isNotEmpty) g,
          ];
          if (prev.containsKey('label')) {
            hasLabel = true;
            label = (prev['label'] as String?) ?? '';
          }
        }
      } catch (_) {}
      await tmp.writeAsString(
        jsonEncode({
          'v': _schema,
          'tracks': [
            for (final t in tracks)
              {'p': t.position, 't': t.title, 'd': t.durationSecs},
          ],
          'credits': [
            for (final c in credits) {'n': c.name, 'r': c.role, 'm': c.mbid},
          ],
          'genres': genres,
          if (hasLabel) 'label': label,
        }),
      );
      await tmp.rename(file.path);
    } catch (_) {}
  }

  Future<List<AlbumCredit>?> _readAlbumCredits(
    String artist,
    String album,
  ) async {
    try {
      final file = File(
        '${(await _albumTrackDir()).path}/${_trackKeyOf(artist, album)}.json',
      );
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map;
      if ((m['v'] as num?)?.toInt() != _schema) return null;
      // Absent key = fetched before credits existed: trigger a
      // refetch via the caller, don't lie with an empty list.
      if (!(m).containsKey('credits')) return null;
      return [
        for (final e in (m['credits'] as List? ?? []))
          AlbumCredit(
            name: ((e as Map)['n'] as String?) ?? '',
            role: (e['r'] as String?) ?? 'performer',
            mbid: e['m'] as String?,
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Label slot in the shared album file. '' = looked up, world
  /// said nothing. Absent key = never looked up.
  Future<String?> _readAlbumLabel(String artist, String album) async {
    try {
      final file = File(
        '${(await _albumTrackDir()).path}/${_trackKeyOf(artist, album)}.json',
      );
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map;
      if ((m['v'] as num?)?.toInt() != _schema) return null;
      if (!m.containsKey('label')) return null;
      return (m['label'] as String?) ?? '';
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAlbumLabel(
      String artist, String album, String label) async {
    try {
      final dir = await _albumTrackDir();
      final file = File('${dir.path}/${_trackKeyOf(artist, album)}.json');
      final tmp = File('${dir.path}/${_trackKeyOf(artist, album)}.tmp');
      // Preserve everything resolved on other ladders.
      var tracks = [];
      var credits = [];
      var genres = [];
      try {
        if (await file.exists()) {
          final prev = jsonDecode(await file.readAsString()) as Map;
          tracks = (prev['tracks'] as List?) ?? [];
          credits = (prev['credits'] as List?) ?? [];
          genres = (prev['genres'] as List?) ?? [];
        }
      } catch (_) {}
      await tmp.writeAsString(
        jsonEncode({
          'v': _schema,
          'tracks': tracks,
          'credits': credits,
          'genres': genres,
          'label': label,
        }),
      );
      await tmp.rename(file.path);
    } catch (_) {}
  }

  Future<List<String>?> _readAlbumGenres(String artist, String album) async {    try {
      final file = File(
        '${(await _albumTrackDir()).path}/${_trackKeyOf(artist, album)}.json',
      );
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map;
      if ((m['v'] as num?)?.toInt() != _schema) return null;
      if (!m.containsKey('genres')) return null;
      return [
        for (final g in (m['genres'] as List? ?? []))
          if ((g as String).isNotEmpty) g,
      ];
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAlbumGenres(
    String artist,
    String album,
    List<String> genres,
  ) async {
    try {
      final dir = await _albumTrackDir();
      final file = File('${dir.path}/${_trackKeyOf(artist, album)}.json');
      final tmp = File('${dir.path}/${_trackKeyOf(artist, album)}.tmp');
      // Preserve tracks + credits + label resolved on their own ladder.
      var tracks = [];
      var credits = [];
      var label = '';
      var hasLabel = false;
      try {
        if (await file.exists()) {
          final prev = jsonDecode(await file.readAsString()) as Map;
          tracks = (prev['tracks'] as List?) ?? [];
          credits = (prev['credits'] as List?) ?? [];
          if (prev.containsKey('label')) {
            hasLabel = true;
            label = (prev['label'] as String?) ?? '';
          }
        }
      } catch (_) {}
      await tmp.writeAsString(
        jsonEncode({
          'v': _schema,
          'tracks': tracks,
          'credits': credits,
          'genres': genres,
          if (hasLabel) 'label': label,
        }),
      );
      await tmp.rename(file.path);
    } catch (_) {}
  }
}
