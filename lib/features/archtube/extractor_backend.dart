// Copyright (C) 2026 Skrol-C.
// This file is part of Arch Player, which is free software: you can
// redistribute it and/or modify it under the terms of the GNU General
// Public License as published by the Free Software Foundation, either
// version 3 of the License, or (at your option) any later version.
// See the repository LICENSE file for the full text.
//
// Stream tickets via NewPipeExtractor (TeamNewPipe, GPLv3):
// https://github.com/TeamNewPipe/NewPipeExtractor
// Pinned version: v0.26.5 (see android/app/build.gradle.kts). Ticket
// window only: matching (video_match.dart), the quality UI
// (video_stage.dart), and the range proxy (dash_proxy.dart) are
// untouched. Only the ticket source changes.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import 'archtube_client.dart';

/// Which client mints stream tickets. The home-grown InnerTube client
/// stays the default until the extractor passes on-device (Scylla
/// gate: extractor NOT default, no layered fixes past a 403).
enum StreamBackend { archtube, extractor }

/// Default ticket source. Extractor won the on-device pass (2026-10-30:
/// 16 served, zero 403s, same phone/network where the own client
/// walled). The persisted per-device override (below) wins over this.
const kDefaultStreamBackend = StreamBackend.extractor;

/// Ticket source switch, persisted per device. Extractor is default;
/// own client stays parked and selectable.
final streamBackendProvider =
    NotifierProvider<StreamBackendNotifier, StreamBackend>(
      StreamBackendNotifier.new,
    );

class StreamBackendNotifier extends Notifier<StreamBackend> {
  static const _key = 'arch.video.backend';

  @override
  StreamBackend build() {
    _sync();
    return kDefaultStreamBackend;
  }

  Future<void> _sync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      state = StreamBackend.values.asNameMap()[raw] ?? kDefaultStreamBackend;
    } catch (e) {
      ArchLog.w('archtube', 'backend load failed: $e');
    }
  }

  Future<void> set(StreamBackend b) async {
    state = b;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, b.name);
    } catch (e) {
      ArchLog.w('archtube', 'backend save failed: $e');
    }
  }
}

/// One extractor ticket, mirroring the narrow channel map
/// (arch.player/extractor `getStreams`).
class ExtractorTicket {
  final String url;
  final int itag;
  final String quality;
  final bool videoOnly;
  final bool audioOnly;
  final int bitrate;
  final String codec;
  final String delivery;
  final int width;
  final int height;
  final int initStart;
  final int initEnd;
  final int indexStart;
  final int indexEnd;

  const ExtractorTicket({
    required this.url,
    required this.itag,
    required this.quality,
    required this.videoOnly,
    required this.audioOnly,
    required this.bitrate,
    required this.codec,
    required this.delivery,
    required this.width,
    required this.height,
    this.initStart = 0,
    this.initEnd = -1,
    this.indexStart = 0,
    this.indexEnd = -1,
  });

  /// Signed-URL expiry (epoch seconds) from the `expire` query param.
  /// Null when the URL carries none.
  int? get expireSecs =>
      int.tryParse(Uri.tryParse(url)?.queryParameters['expire'] ?? '');

  /// Upstream length from the `clen` query param. Zero means unknown,
  /// and the range proxy answers accordingly.
  int get contentLength =>
      int.tryParse(Uri.tryParse(url)?.queryParameters['clen'] ?? '') ?? 0;

  /// Proxy content type, derived from the codec. The proxy only needs
  /// the family, never the exact original mime.
  String get contentType {
    final c = codec.toLowerCase();
    if (audioOnly) {
      if (c.contains('mp4a')) return 'audio/mp4';
      return 'audio/webm';
    }
    if (c.contains('avc') || c.contains('mp4')) return 'video/mp4';
    return 'video/webm';
  }

  /// Chip label: extractor resolution (video) or quality (audio),
  /// with bitrate/height fallbacks. Empty stays hidden, never guessed.
  String get label {
    if (quality.isNotEmpty) return quality;
    if (audioOnly) return bitrate > 0 ? '${(bitrate / 1000).round()}k' : '';
    return height > 0 ? '${height}p' : '';
  }

  /// Ladder height: the itag field when present, else parsed out of
  /// the resolution string ("720p", "720p60").
  int get parsedHeight {
    if (height > 0) return height;
    final m = RegExp(r'\d+').firstMatch(quality);
    return int.tryParse(m?.group(0) ?? '') ?? 0;
  }
}

/// Narrow channel client: videoId in, tickets out. Throws on
/// extraction failure; callers degrade to the fallback lane.
abstract final class ExtractorTickets {
  static const _channel = MethodChannel('arch.player/extractor');

  static Future<List<ExtractorTicket>> getStreams(String videoId) async {
    final raw = await _channel.invokeMethod(
      'getStreams',
      {'videoId': videoId},
    );
    final list = (raw as List?) ?? [];
    final out = <ExtractorTicket>[];
    for (final e in list) {
      if (e is! Map) continue;
      final url = '${e['url'] ?? ''}';
      if (url.isEmpty) continue;
      out.add(
        ExtractorTicket(
          url: url,
          itag: (e['itag'] as num?)?.toInt() ?? 0,
          quality: '${e['quality'] ?? ''}',
          videoOnly: e['videoOnly'] == true,
          audioOnly: e['audioOnly'] == true,
          bitrate: (e['bitrate'] as num?)?.toInt() ?? 0,
          codec: '${e['codec'] ?? ''}',
          delivery: '${e['delivery'] ?? ''}',
          width: (e['width'] as num?)?.toInt() ?? 0,
          height: (e['height'] as num?)?.toInt() ?? 0,
          initStart: (e['initStart'] as num?)?.toInt() ?? 0,
          initEnd: (e['initEnd'] as num?)?.toInt() ?? -1,
          indexStart: (e['indexStart'] as num?)?.toInt() ?? 0,
          indexEnd: (e['indexEnd'] as num?)?.toInt() ?? -1,
        ),
      );
    }
    return out;
  }
}

/// Progressive tickets only: the range proxy fetches one URL per leg,
/// so manifests never enter the picture.
List<ExtractorTicket> _progressive(List<ExtractorTicket> all) =>
    all.where((t) => t.delivery == 'PROGRESSIVE_HTTP').toList();

/// Ticket source switch for the progressive lane: the extractor when
/// selected, else the parked own client. Extractor failure answers
/// empty (the caller shows unavailable), never throws.
Future<List<ArchtubeStream>> backendPlayerStreams(
  StreamBackend backend,
  ArchtubeClient client,
  String videoId, {
  String? cpn,
}) async {
  if (backend != StreamBackend.extractor) {
    return client.playerStreams(videoId, cpn: cpn);
  }
  try {
    final muxed = _progressive(
      await ExtractorTickets.getStreams(videoId),
    ).where((t) => !t.videoOnly && !t.audioOnly).toList();
    final out = [
      for (final t in muxed)
        ArchtubeStream(
          itag: t.itag,
          url: t.url,
          mime: t.contentType,
          qualityLabel: t.label,
          bitrate: t.bitrate,
        ),
    ];
    out.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    if (out.isNotEmpty) {
      ArchLog.i(
        'archtube',
        'extractor served $videoId (${out.length} progressive)',
      );
    }
    return out;
  } catch (e) {
    ArchLog.w('archtube', 'extractor streams failed for $videoId: $e');
    return [];
  }
}

/// Ticket source switch for the DASH lane: the extractor when
/// selected, else the parked own client. Same playable contract:
/// empty lanes mean the caller falls back to progressive.
Future<ArchtubeDash> backendPlayerDash(
  StreamBackend backend,
  ArchtubeClient client,
  String videoId, {
  String? cpn,
}) async {
  if (backend != StreamBackend.extractor) {
    return client.playerDash(videoId, cpn: cpn);
  }
  try {
    final tickets = _progressive(await ExtractorTickets.getStreams(videoId));
    final videos = [
      for (final t in tickets.where((t) => t.videoOnly))
        ArchtubeDashVideo(
          itag: t.itag,
          url: t.url,
          qualityLabel: t.label,
          width: t.width,
          height: t.parsedHeight,
          bitrate: t.bitrate,
          mime: t.contentType,
          codecs: t.codec,
          contentLength: t.contentLength,
          contentType: t.contentType,
          initStart: t.initStart,
          initEnd: t.initEnd,
          indexStart: t.indexStart,
          indexEnd: t.indexEnd,
        ),
    ];
    final audios = [
      for (final t in tickets.where((t) => t.audioOnly))
        ArchtubeDashAudio(
          itag: t.itag,
          url: t.url,
          bitrate: t.bitrate,
          mime: t.contentType,
          codecs: t.codec,
          contentLength: t.contentLength,
          contentType: t.contentType,
          initStart: t.initStart,
          initEnd: t.initEnd,
          indexStart: t.indexStart,
          indexEnd: t.indexEnd,
        ),
    ];
    // Same ladder grammar as the own client: AVC first (safest
    // decode), then tallest, then hottest bitrate. Stereo-only and
    // surround skips already happened upstream (extractor lanes).
    videos.sort((a, b) {
      final aAvc = a.mime.contains('mp4');
      final bAvc = b.mime.contains('mp4');
      if (aAvc != bAvc) return aAvc ? -1 : 1;
      if (a.height != b.height) return b.height.compareTo(a.height);
      return b.bitrate.compareTo(a.bitrate);
    });
    audios.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final dash = ArchtubeDash(videos: videos, audios: audios);
    if (dash.playable) {
      ArchLog.i(
        'archtube',
        'extractor DASH for $videoId '
        '(${videos.length}v+${audios.length}a)',
      );
    }
    return dash;
  } catch (e) {
    ArchLog.w('archtube', 'extractor DASH failed for $videoId: $e');
    return const ArchtubeDash(videos: [], audios: []);
  }
}
