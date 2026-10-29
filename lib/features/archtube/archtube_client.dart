import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/log.dart';
import 'client_identities.dart';

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
/// first that comes back OK with at least one usable progressive
/// stream. A dry or non-OK identity is skipped, never retried for
/// that call. Signature-ciphered URLs are skipped in v1; the
/// decipher slot ([decipherSlot]) is structured for later and logs
/// what it passes over.
class ArchtubeClient {
  final http.Client _http;

  ArchtubeClient([http.Client? httpClient])
      : _http = httpClient ?? http.Client();

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
    try {
      final res = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': id.userAgent,
            },
            body: jsonEncode({
              ...body,
              'context': id.contextPayload(),
            }),
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
  Future<List<ArchtubeStream>> playerStreams(String videoId) async {
    for (final id in archtubeLadder) {
      final json = await _post('player', id, {
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      });
      if (json == null) continue;
      final status =
          json['playabilityStatus'] as Map<String, dynamic>? ?? {};
      if (status['status'] != 'OK') {
        ArchLog.i('archtube', '${id.clientName} player status '
            '${status['status'] ?? 'unknown'} for $videoId');
        continue;
      }
      final streams = parseProgressiveStreams(json);
      if (streams.isEmpty) {
        ArchLog.i('archtube',
            '${id.clientName} dry for $videoId, rotating');
        continue;
      }
      if (!identical(id, archtubeLadder.first)) {
        ArchLog.i('archtube',
            '${id.clientName} served $videoId (${streams.length} streams)');
      }
      return streams;
    }
    ArchLog.w('archtube', 'all disguises dry for $videoId');
    return [];
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

  /// Signature-decipher slot for later breakage bills. v1 never
  /// calls it (ANDROID progressive needs no decipher); when ciphered
  /// formats become unavoidable, implement base.js parsing + n-token
  /// here and stop skipping them in [parseProgressiveStreams].
  static String decipherSlot(String signatureCipher) {
    throw UnimplementedError(
      'Archtube decipher not implemented: ANDROID progressive '
      'needs no decipher. Cipher seen: '
      '${signatureCipher.substring(0, signatureCipher.length.clamp(0, 48))}',
    );
  }
}
