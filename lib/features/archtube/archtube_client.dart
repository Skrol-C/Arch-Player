import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/log.dart';
import 'client_identities.dart';
import 'player_js.dart';
import 'po_token.dart';
import 'upstream_engine.dart';

/// Content playback nonce: 16-char random alphanumeric, unique per
/// playback session, NewPipe grammar. YouTube stamps `cpn` on every
/// videoplayback URL and stats ping; requests without one read as
/// off-script and eat the probation wall. One per video play, never
/// per chunk: the picture leg, the sound leg, and the player request
/// for one playback all share it.
String generateContentPlaybackNonce() {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final r = math.Random.secure();
  return String.fromCharCodes(
    List.generate(16, (_) => chars.codeUnitAt(r.nextInt(chars.length))),
  );
}

/// One progressive (single-file) stream: instant start, no DASH
/// stitching, no muxing. v1 only speaks progressive MP4.
class ArchtubeStream {
  final int itag;
  final String url;
  final String mime;
  final String qualityLabel;
  final int bitrate;

  const ArchtubeStream({
    required this.itag,
    required this.url,
    required this.mime,
    required this.qualityLabel,
    required this.bitrate,
  });
}

/// One video-only (DASH) stream: picture without sound. ANDROID
/// serves these with direct URLs today, no decipher. The player box
/// pairs one with an [ArchtubeDashAudio] in the dual player.
class ArchtubeDashVideo {
  final int itag;
  final String url;
  final String qualityLabel;
  final int width;
  final int height;
  final int bitrate;
  final String mime;
  final int contentLength;
  final String contentType;

  const ArchtubeDashVideo({
    required this.itag,
    required this.url,
    required this.qualityLabel,
    required this.width,
    required this.height,
    required this.bitrate,
    required this.mime,
    required this.contentLength,
    required this.contentType,
  });

  bool get isMp4Avc =>
      mime.contains('video/mp4') && mime.contains('avc1');
}

/// One audio-only (DASH) stream: the video's own sound for the dual
/// player. Higher bitrate than the progressive mux (251 opus, then
/// 140 m4a), which is the whole audible point of DASH.
class ArchtubeDashAudio {
  final int itag;
  final String url;
  final int bitrate;
  final String mime;
  final int contentLength;
  final String contentType;

  const ArchtubeDashAudio({
    required this.itag,
    required this.url,
    required this.bitrate,
    required this.mime,
    required this.contentLength,
    required this.contentType,
  });
}

/// A playable DASH pair: picture ladder plus sound ladder. Empty
/// when nothing direct served (caller falls back to progressive).
class ArchtubeDash {
  final List<ArchtubeDashVideo> videos;
  final List<ArchtubeDashAudio> audios;

  const ArchtubeDash({required this.videos, required this.audios});

  bool get playable => videos.isNotEmpty && audios.isNotEmpty;

  /// The video's own sound: hottest lane first (251 opus, then 140
  /// m4a), from the SAME streamingData response as the picture. The
  /// dual player pairs the picture with this, never with the library
  /// song, so music-video sound FX play instead of clashing.
  ArchtubeDashAudio? get bestAudio => audios.isEmpty ? null : audios.first;
}

/// One search hit for video matching.
class ArchtubeHit {
  final String videoId;
  final String title;
  final String channel;
  final int? durationSecs;

  const ArchtubeHit({
    required this.videoId,
    required this.title,
    required this.channel,
    this.durationSecs,
  });
}

/// Our own minimal InnerTube client: `player` endpoint first, a small
/// `search` helper for video matching. Verified 2026-10-29: ANDROID
/// returns playability OK with progressive itag 18 direct URLs
/// (no cipher) and search returns compactVideoRenderer hits.
///
/// Disguise rotation: tries each ladder identity in order, keeps the
/// first that comes back OK with at least one usable stream. A dry
/// or non-OK identity is skipped, never retried for that call.
/// Ciphered URLs fall back to the player-JS decipher
/// ([PlayerCipher], cached per player version) before an identity
/// is declared dry.
class ArchtubeClient {
  final http.BaseClient _http;

  ArchtubeClient([http.BaseClient? httpClient])
      : _http = httpClient ?? _EngineClient();

  void dispose() => _http.close();

  static const _host = 'https://www.youtube.com';

  /// Progressive itag ladder, best first. 22 = 720p MP4, 18 = 360p MP4.
  static const preferredItags = [22, 18];

  Future<Map<String, dynamic>?> _post(
    String endpoint,
    ArchtubeIdentity id,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_host/youtubei/v1/$endpoint'
        '?key=${id.apiKey}&prettyPrint=false');
    final headers = {
      'Content-Type': 'application/json',
      'User-Agent': id.userAgent,
    };
    final payload = {
      ...body,
      'context': id.contextPayload(),
    };
    // Session identity accrues in the background, never blocking:
    // the first calls go out bare, later ones carry visitorData and
    // the PO token slot when one exists. State logs once.
    final vid = body['videoId'];
    if (vid is String && vid.isNotEmpty) {
      PoTokenSlot.ensureVisitorData(_http, vid);
    }
    PoTokenSlot.apply(payload, headers);
    try {
      final res = await _http
          .post(
            uri,
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        ArchLog.w('archtube', '${id.clientName} $endpoint HTTP '
            '${res.statusCode}');
        return null;
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      ArchLog.w('archtube', '${id.clientName} $endpoint failed: $e');
      return null;
    }
  }

  /// Player streams for [videoId], rotating disguises until one
  /// yields a usable progressive stream. Empty when all are dry.
  Future<List<ArchtubeStream>> playerStreams(
    String videoId, {
    String? cpn,
  }) async {
    for (final id in archtubeLadder) {
      final json = await _post('player', id, {
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
        if (cpn != null && cpn.isNotEmpty)
          'playbackContext': {
            'contentPlaybackContext': {'cpn': cpn},
          },
      });
      if (json == null) continue;
      final status = json['playabilityStatus'] as Map<String, dynamic>? ?? {};
      if (status['status'] != 'OK') {
        ArchLog.i(
          'archtube',
          '${id.clientName} player status '
              '${status['status'] ?? 'unknown'} for $videoId',
        );
        continue;
      }
      final streams = parseProgressiveStreams(json);
      if (streams.isEmpty) {
        // Direct URLs dry: one decipher attempt before rotating.
        final rescued = await _rescueCiphered(json, videoId);
        if (rescued != null) {
          final retry = parseProgressiveStreams({'streamingData': rescued});
          if (retry.isNotEmpty) {
            ArchLog.i(
              'archtube',
              '${id.clientName} deciphered ${retry.length} for $videoId',
            );
            return retry;
          }
        }
        ArchLog.i('archtube', '${id.clientName} dry for $videoId, rotating');
        continue;
      }
      if (!identical(id, archtubeLadder.first)) {
        ArchLog.i(
          'archtube',
          '${id.clientName} served $videoId (${streams.length} streams)',
        );
      }
      return streams;
    }
    ArchLog.w('archtube', 'all disguises dry for $videoId');
    return [];
  }

  /// DASH pair for [videoId], rotating disguises until one yields a
  /// playable video+audio set with direct URLs. Empty when all are
  /// dry or ciphered: the caller falls back to progressive.
  Future<ArchtubeDash> playerDash(String videoId, {String? cpn}) async {
    for (final id in archtubeLadder) {
      final json = await _post('player', id, {
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
        if (cpn != null && cpn.isNotEmpty)
          'playbackContext': {
            'contentPlaybackContext': {'cpn': cpn},
          },
      });
      if (json == null) continue;
      final status = json['playabilityStatus'] as Map<String, dynamic>? ?? {};
      if (status['status'] != 'OK') continue;
      var dash = parseAdaptiveStreams(json);
      if (!dash.playable) {
        // Direct URLs dry: one decipher attempt before rotating.
        final rescued = await _rescueCiphered(json, videoId);
        if (rescued != null) {
          dash = parseAdaptiveStreams({'streamingData': rescued});
          if (dash.playable) {
            ArchLog.i(
              'archtube',
              '${id.clientName} deciphered DASH for $videoId '
              '(${dash.videos.length}v+${dash.audios.length}a)',
            );
          }
        }
      }
      if (!dash.playable) {
        ArchLog.i(
          'archtube',
          '${id.clientName} DASH dry for $videoId, rotating',
        );
        continue;
      }
      ArchLog.i(
        'archtube',
        '${id.clientName} DASH for $videoId '
            '(${dash.videos.length}v+${dash.audios.length}a)',
      );
      // IP-binding check: the URL is cut for the IP that asked. Log the
      // bound ip so the phone's public IP can be held next to it.
      final firstUrl = dash.videos.isNotEmpty ? dash.videos.first.url : '';
      final boundIp = Uri.tryParse(firstUrl)?.queryParameters['ip'];
      ArchLog.i('archtube', 'DASH url bound ip=$boundIp for $videoId');
      return dash;
    }
    return const ArchtubeDash(videos: [], audios: []);
  }

  /// Artist + title search for video matching. Returns raw hits;
  /// ranking lives in [scoreHits] (video_match.dart).
  Future<List<ArchtubeHit>> search(String query) async {
    for (final id in archtubeLadder) {
      final json = await _post('search', id, {'query': query});
      if (json == null) continue;
      final hits = parseSearchHits(json);
      if (hits.isNotEmpty) return hits;
      ArchLog.i('archtube',
          '${id.clientName} search dry for "$query", rotating');
    }
    return [];
  }

  /// Progressive streams out of a player response. Ciphered URLs are
  /// skipped (v1 has no decipher); the count is logged so the later
  /// decipher slot knows what it left behind.
  static List<ArchtubeStream> parseProgressiveStreams(
    Map<String, dynamic> json,
  ) {
    final sd = json['streamingData'] as Map<String, dynamic>?;
    final formats = sd?['formats'] as List?;
    if (formats == null) return [];
    final out = <ArchtubeStream>[];
    var ciphered = 0;
    for (final f in formats) {
      if (f is! Map<String, dynamic>) continue;
      final url = f['url'] as String?;
      if (url == null || url.isEmpty) {
        if (f['signatureCipher'] != null) ciphered++;
        continue;
      }
      out.add(ArchtubeStream(
        itag: (f['itag'] as num?)?.toInt() ?? 0,
        url: url,
        mime: (f['mime'] as String?) ?? '',
        qualityLabel: (f['qualityLabel'] as String?) ?? '',
        bitrate: (f['bitrate'] as num?)?.toInt() ?? 0,
      ));
    }
    if (ciphered > 0) {
      ArchLog.i('archtube', 'skipped $ciphered ciphered formats '
          '(decipher slot not yet implemented)');
    }
    out.sort((a, b) {
      final ai = preferredItags.indexOf(a.itag);
      final bi = preferredItags.indexOf(b.itag);
      if (ai != bi) {
        if (ai < 0) return 1;
        if (bi < 0) return -1;
        return ai.compareTo(bi);
      }
      return b.bitrate.compareTo(a.bitrate);
    });
    return out;
  }

  /// DASH sets out of a player response: video-only ladder plus
  /// audio-only ladder, direct URLs only. Ciphered entries are
  /// skipped and counted; surround codecs (ac-3, ec-3) are skipped,
  /// stereo only. Duplicate itags keep the first.
  static ArchtubeDash parseAdaptiveStreams(Map<String, dynamic> json) {
    final sd = json['streamingData'] as Map<String, dynamic>?;
    final adaptive = sd?['adaptiveFormats'] as List?;
    if (adaptive == null) return const ArchtubeDash(videos: [], audios: []);
    final videos = <ArchtubeDashVideo>[];
    final audios = <ArchtubeDashAudio>[];
    final seenVideo = <int>{};
    final seenAudio = <int>{};
    var ciphered = 0;
    for (final f in adaptive) {
      if (f is! Map<String, dynamic>) continue;
      final url = f['url'] as String?;
      if (url == null || url.isEmpty) {
        if (f['signatureCipher'] != null) ciphered++;
        continue;
      }
      final itag = (f['itag'] as num?)?.toInt() ?? 0;
      final mime = (f['mimeType'] as String?) ?? '';
      final bitrate = (f['bitrate'] as num?)?.toInt() ?? 0;
      final contentLength =
          int.tryParse('${f['contentLength'] ?? ''}') ?? 0;
      final contentType = mime.split(';').first.trim();
      if (mime.startsWith('video/')) {
        if (!seenVideo.add(itag)) continue;
        videos.add(ArchtubeDashVideo(
          itag: itag,
          url: url,
          qualityLabel: (f['qualityLabel'] as String?) ?? '',
          width: (f['width'] as num?)?.toInt() ?? 0,
          height: (f['height'] as num?)?.toInt() ?? 0,
          bitrate: bitrate,
          mime: mime,
          contentLength: contentLength,
          contentType: contentType.isEmpty ? 'video/mp4' : contentType,
        ));
      } else if (mime.startsWith('audio/')) {
        if (mime.contains('ac-3') || mime.contains('ec-3')) continue;
        if (!seenAudio.add(itag)) continue;
        audios.add(ArchtubeDashAudio(
          itag: itag,
          url: url,
          bitrate: bitrate,
          mime: mime,
          contentLength: contentLength,
          contentType: contentType.isEmpty ? 'audio/mp4' : contentType,
        ));
      }
    }
    if (ciphered > 0) {
      ArchLog.i('archtube', 'skipped $ciphered ciphered adaptive formats');
    }
    // Picture ladder: MP4/AVC first (safest decode), then tallest,
    // then hottest bitrate. Unlabeled entries sink.
    videos.sort((a, b) {
      if (a.isMp4Avc != b.isMp4Avc) return a.isMp4Avc ? -1 : 1;
      if (a.height != b.height) return b.height.compareTo(a.height);
      return b.bitrate.compareTo(a.bitrate);
    });
    // Sound ladder: hottest bitrate first (251 opus, then 140 m4a).
    audios.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return ArchtubeDash(videos: videos, audios: audios);
  }

  /// Search hits out of a search response. Tolerates both the
  /// compact (mobile clients) and full (web clients) renderers;
  /// anything unrecognized is skipped, never fatal.
  static List<ArchtubeHit> parseSearchHits(Map<String, dynamic> json) {
    final hits = <ArchtubeHit>[];
    void visit(dynamic node) {
      if (node is List) {
        for (final e in node) {
          visit(e);
        }
        return;
      }
      if (node is! Map<String, dynamic>) return;
      final vr = node['compactVideoRenderer'] ?? node['videoRenderer'];
      if (vr is Map<String, dynamic>) {
        final hit = _hitFromRenderer(vr);
        if (hit != null) hits.add(hit);
        return;
      }
      for (final v in node.values) {
        visit(v);
      }
    }
    visit(json['contents']);
    return hits;
  }

  static ArchtubeHit? _hitFromRenderer(Map<String, dynamic> r) {
    final videoId = r['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) return null;
    String runsText(dynamic field) {
      if (field is! Map<String, dynamic>) return '';
      final runs = field['runs'] as List?;
      if (runs == null) return field['simpleText'] as String? ?? '';
      return runs
          .whereType<Map<String, dynamic>>()
          .map((e) => e['text'] as String? ?? '')
          .join();
    }

    return ArchtubeHit(
      videoId: videoId,
      title: runsText(r['title']),
      channel: runsText(r['shortBylineText'] ?? r['ownerText']),
      durationSecs: parseDurationLabel(
        runsText(r['lengthText']),
      ),
    );
  }

  /// "M:SS" / "H:MM:SS" / "LIVE" / "" into seconds. Null when the
  /// label carries no real duration (live, upcoming, missing).
  static int? parseDurationLabel(String label) {
    final t = label.trim();
    if (t.isEmpty) return null;
    final parts = t.split(':');
    if (parts.length > 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return null;
      nums.add(n);
    }
    var secs = 0;
    for (final n in nums) {
      secs = secs * 60 + n;
    }
    return secs;
  }

  /// Ciphered-only fallback: descramble every `signatureCipher`
  /// entry via the player-JS recipe (cached per player version)
  /// and return a synthesized `streamingData` map the pure parsers
  /// above can read as if the URLs had been direct. Null when there
  /// is nothing ciphered to rescue, or the recipe is unreachable:
  /// the caller rotates to the next disguise as before.
  Future<Map<String, dynamic>?> _rescueCiphered(
    Map<String, dynamic> json,
    String videoId,
  ) async {
    final sd = json['streamingData'];
    if (sd is! Map<String, dynamic>) return null;
    var ciphered = 0;
    for (final key in const ['formats', 'adaptiveFormats']) {
      final list = sd[key];
      if (list is! List) continue;
      for (final f in list) {
        if (f is Map<String, dynamic> &&
            (f['url'] is! String || (f['url'] as String).isEmpty) &&
            f['signatureCipher'] is String) {
          ciphered++;
        }
      }
    }
    if (ciphered == 0) return null;
    final cipher = await PlayerCipher.forVideo(_http, videoId);
    if (cipher == null) return null;
    var rescued = 0;
    Map<String, dynamic> convert(Map<String, dynamic> f) {
      final url = f['url'];
      final sc = f['signatureCipher'];
      if ((url is String && url.isNotEmpty) || sc is! String) return f;
      try {
        final out = Map<String, dynamic>.of(f)
          ..['url'] = cipher.rebuildUrl(sc);
        rescued++;
        return out;
      } catch (e) {
        ArchLog.i('archtube', 'decipher: skipped itag ${f['itag']} ($e)');
        return f;
      }
    }
    final out = <String, dynamic>{};
    for (final e in sd.entries) {
      if ((e.key == 'formats' || e.key == 'adaptiveFormats') &&
          e.value is List) {
        out[e.key] = (e.value as List)
            .map((f) => f is Map<String, dynamic> ? convert(f) : f)
            .toList();
      } else {
        out[e.key] = e.value;
      }
    }
    ArchLog.i(
      'archtube',
      'decipher: rescued $rescued/$ciphered ciphered entries for $videoId',
    );
    return rescued == 0 ? null : out;
  }
}

/// Default transport for [ArchtubeClient]: the shared upstream
/// engine (Cronet first, Dart fallback) behind an [http.BaseClient]
/// face, so the player/search POSTs ride the same stack as the
/// DASH proxy fetches. One client per [ArchtubeClient], closed on
/// dispose. Injected clients (tests) bypass the engine entirely.
class _EngineClient extends http.BaseClient {
  http.BaseClient? _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _inner ??= UpstreamEngine.client();
    return _inner!.send(request);
  }

  @override
  void close() {
    try {
      _inner?.close();
    } catch (_) {}
    _inner = null;
  }
}
