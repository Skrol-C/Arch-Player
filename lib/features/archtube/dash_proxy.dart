import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

import '../../core/log.dart';

/// Parsed byte range, end inclusive. end < start means unsatisfiable
/// (caller answers 416).
class DashRange {
  final int start;
  final int end;

  const DashRange(this.start, this.end);
}

/// Browser-shaped media headers, after NewPipe's YoutubeHttpDataSource
/// (GPL reference, studied not copied): desktop UA plus Origin,
/// Referer, Sec-Fetch set and TE on googlevideo requests. This is
/// the password the gir wall asks for.
const browserMediaHeaders = {
  // Same identity as the player request (ANDROID disguise): one
  // consistent story across both knocks. Was desktop Firefox UA.
  'User-Agent':
      'com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip',
  'Origin': 'https://www.youtube.com',
  'Referer': 'https://www.youtube.com',
  'Sec-Fetch-Dest': 'empty',
  'Sec-Fetch-Mode': 'cors',
  'Sec-Fetch-Site': 'cross-site',
  'TE': 'trailers',
};

/// Pure range math (unit-tested, no IO): translate one incoming
/// Range header into a closed upstream range against the known
/// content length. Null when the length is unknown and the header
/// must pass through untouched.
DashRange? resolveDashRange(String? header, int contentLength) {
  if (contentLength <= 0) return null;
  final max = contentLength - 1;
  if (header == null) return DashRange(0, max);
  final m =
      RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return DashRange(0, max);
  final a = m.group(1)!;
  final b = m.group(2)!;
  if (a.isEmpty) {
    if (b.isEmpty) return DashRange(0, max);
    final n = int.tryParse(b) ?? 0;
    if (n <= 0) return DashRange(0, max);
    return DashRange((contentLength - n).clamp(0, max), max);
  }
  final start = int.tryParse(a) ?? 0;
  if (start > max) return const DashRange(1, 0);
  final end = (b.isEmpty ? max : (int.tryParse(b) ?? max)).clamp(start, max);
  return DashRange(start, end);
}

/// Local range proxy for DASH media. ExoPlayer opens with bare or
/// open-ended ranges, which googlevideo answers with a redirect
/// into a 403 wall on DASH URLs. Closed ranges serve 206 at full
/// speed, but only up to a point: a range spanning (nearly) the
/// whole file 403s too. So this loopback server translates every
/// incoming request into a capped closed upstream range using the
/// known content length. Upstream fetches ride Cronet's Chromium
/// stack (browser TLS fingerprint) with the Dart stack as fallback.
/// One flight at a time: a seek cancels the stale pipe before
/// opening the next.
class DashProxy {
  final String upstreamUrl;
  final int contentLength;
  final String contentType;
  final Map<String, String> upstreamHeaders;

  HttpServer? _server;
  StreamSubscription<List<int>>? _activeUpstream;
  http.BaseClient? _activeClient;
  bool _closed = false;

  /// Shared Chromium stack for upstream fetches: browser TLS
  /// fingerprint instead of Dart's. Built once, guarded once; when
  /// the provider is missing the Dart stack answers instead.
  static CronetEngine? _cronetEngine;
  static bool _cronetDead = false;
  static bool _loggedEngine = false;

  Future<http.BaseClient> _upstreamClient() async {
    if (!_cronetDead) {
      try {
        _cronetEngine ??= CronetEngine.build(
          cacheMode: CacheMode.disabled,
          userAgent: browserMediaHeaders['User-Agent'],
        );
        if (!_loggedEngine) {
          _loggedEngine = true;
          ArchLog.i('archtube', 'upstream engine: cronet');
        }
        return CronetClient.fromCronetEngine(_cronetEngine!);
      } catch (e) {
        _cronetDead = true;
        ArchLog.w('archtube', 'cronet unavailable, dart fallback: $e');
      }
    }
    if (!_loggedEngine) {
      _loggedEngine = true;
      ArchLog.i('archtube', 'upstream engine: dart');
    }
    return http_io.IOClient(HttpClient()..autoUncompress = false);
  }

  /// First successful serve logs once: later silence is normal.
  bool _loggedServing = false;

  /// One-timer for the full-URL replay test.
  static bool _loggedFullUrl = false;

  /// Upstream range cap: big single ranges 403 (proven 2026-10-29:
  /// same URL 403s at 4MB chunks, 200s at 1MB). Players chain the
  /// chunks seamlessly; loopback roundtrips are cheap.
  static const _upstreamChunk = 1 << 20;

  /// 403 retries with backoff: transient velocity walls usually pass
  /// on a second knock a second later. Deterministic walls burn ~2s
  /// here, then the player degrade path takes over as before.
  static const _maxUpstreamAttempts = 3;
  static const _retryDelay = Duration(milliseconds: 800);

  DashProxy({
    required this.upstreamUrl,
    required this.contentLength,
    required this.contentType,
    this.upstreamHeaders = browserMediaHeaders,
  });

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}/stream');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    ArchLog.i('archtube',
        'dash proxy on port ${_server!.port} (len=$contentLength)');
    _server!.listen(_handle);
  }

  Future<void> close() async {
    _closed = true;
    await _cancelUpstream();
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  Future<void> _cancelUpstream() async {
    try {
      await _activeUpstream?.cancel();
    } catch (_) {}
    _activeUpstream = null;
    try {
      _activeClient?.close();
    } catch (_) {}
    _activeClient = null;
  }

  Future<void> _handle(HttpRequest req) async {
    if (_closed) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }
    if (req.method != 'GET') {
      req.response.statusCode = HttpStatus.methodNotAllowed;
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }
    await _cancelUpstream();
    final range =
        resolveDashRange(req.headers.value('range'), contentLength);
    if (range == null) {
      await _forwardPassthrough(req);
      return;
    }
    if (range.end < range.start) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      req.response.headers.set(
          'Content-Range', 'bytes */$contentLength');
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }
    // Cap the span: full-file ranges 403 even closed. Players chain
    // the chunks seamlessly; loopback roundtrips are cheap.
    // Proven 2026-10-29: one request touching the LAST byte (end ==
    // contentLength-1, e.g. a <4MB file in one chunk) 403s while the
    // same URL with a partial range 200s. So never let a request
    // reach the final byte unless it STARTS at the tail.
    var end = math.min(range.end, range.start + _upstreamChunk - 1);
    if (contentLength > 1 && range.start <= contentLength - 2) {
      end = math.min(end, contentLength - 2);
    }
    for (var attempt = 1; attempt <= _maxUpstreamAttempts; attempt++) {
      if (_closed) return;
      if (await _fetchRange(req, range.start, end)) return;
      if (attempt < _maxUpstreamAttempts) {
        await Future<void>.delayed(_retryDelay * attempt);
      }
    }
    await _answerBadGateway(req);
  }

  /// One upstream range fetch piped into [req]. True when the player
  /// got its bytes; false on wall or transport failure (caller
  /// retries, then the player degrade path takes over).
  ///
  /// 2026-10-29: chunk #2+ walled while chunk #1 served. Same URL,
  /// same headers — only the URL-param range differed. So no more
  /// URL-param ranges: forward a real Range header instead, exactly
  /// like the working PC probes. rn dropped with the old style.
  Future<bool> _fetchRange(HttpRequest req, int start, int end) async {
    final client = await _upstreamClient();
    _activeClient = client;
    try {
      final upstream = http.Request('GET', Uri.parse(upstreamUrl));
      upstream.headers.addAll(browserMediaHeaders);
      upstream.headers['Range'] = 'bytes=$start-$end';
      if (client is! CronetClient) {
        upstream.headers['Accept-Encoding'] = 'identity';
      }
      final res =
          await client.send(upstream).timeout(const Duration(seconds: 25));
      if (res.statusCode != HttpStatus.partialContent &&
          res.statusCode != HttpStatus.ok) {
        ArchLog.w('archtube',
            'dash proxy upstream ${res.statusCode} ($start-$end)');
        // Forensics for the 403 wall: what we sent, what came back.
        ArchLog.w('archtube',
            'dash forensics reqHeaders=${upstream.headers} respHeaders=${res.headers}');
        // One-timer: full URL bytes for the PC replay test. Local log
        // only; the signature dies with the URL in a few hours.
        if (!_loggedFullUrl) {
          _loggedFullUrl = true;
          ArchLog.w('archtube', 'dash forensics fullUrl=$upstreamUrl&range=$start-$end');
        }
        try {
          await res.stream.drain<void>();
        } catch (_) {}
        return false;
      }
      // A 200 answers the query range with exactly the scoped body.
      // Anything else (full file against a scoped ask) is a corrupt
      // pipe: refuse it rather than poison the player.
      final want = end - start + 1;
      final got = res.contentLength;
      if (res.statusCode == HttpStatus.ok && got != null && got != want) {
        ArchLog.w('archtube',
            'dash proxy length mismatch ($got vs $want), refusing');
        try {
          await res.stream.drain<void>();
        } catch (_) {}
        return false;
      }
      final out = req.response;
      out.statusCode = HttpStatus.partialContent;
      out.headers.set('Content-Type', contentType);
      out.headers.set(
          'Content-Range', 'bytes $start-$end/$contentLength');
      out.headers.set('Content-Length', '${end - start + 1}');
      out.headers.set('Accept-Ranges', 'bytes');
      if (!_loggedServing) {
        _loggedServing = true;
        ArchLog.i('archtube', 'dash proxy serving');
      }
      final sub = res.stream.listen(
        out.add,
        onError: (_) {},
        onDone: () async {
          try {
            await out.close();
          } catch (_) {}
        },
        cancelOnError: true,
      );
      _activeUpstream = sub;
      await sub.asFuture();
      return true;
    } catch (e) {
      ArchLog.w('archtube', 'dash proxy pipe failed: $e');
      return false;
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Final failure answer after retries: the player treats any 502
  /// as a source failure and degrades.
  Future<void> _answerBadGateway(HttpRequest req) async {
    try {
      req.response.statusCode = HttpStatus.badGateway;
      await req.response.close();
    } catch (_) {}
  }

  /// Unknown length: forward the request untouched. May hit the
  /// redirect wall; the player degrade path guards the outcome.
  Future<void> _forwardPassthrough(HttpRequest req) async {
    final client = await _upstreamClient();
    _activeClient = client;
    try {
      final upstream = http.Request('GET', Uri.parse(upstreamUrl));
      upstream.headers.addAll(browserMediaHeaders);
      if (client is! CronetClient) {
        upstream.headers['Accept-Encoding'] = 'identity';
      }
      final incoming = req.headers.value('range');
      if (incoming != null) upstream.headers['Range'] = incoming;
      final res =
          await client.send(upstream).timeout(const Duration(seconds: 25));
      req.response.statusCode = res.statusCode;
      res.headers.forEach((name, value) {
        if (name.toLowerCase() == 'transfer-encoding') return;
        req.response.headers.add(name, value);
      });
      final sub = res.stream.listen(
        req.response.add,
        onError: (_) {},
        onDone: () async {
          try {
            await req.response.close();
          } catch (_) {}
        },
        cancelOnError: true,
      );
      _activeUpstream = sub;
      await sub.asFuture();
    } catch (e) {
      ArchLog.w('archtube', 'dash proxy passthrough failed: $e');
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      try {
        client.close();
      } catch (_) {}
    }
  }
}
