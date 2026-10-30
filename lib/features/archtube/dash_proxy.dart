import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../core/log.dart';
import 'po_token.dart';
import 'upstream_engine.dart';

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

/// Fresh upstream for one signed URL: the player re-resolves the same
/// streamingData lane and hands back a live URL. Null means keep the
/// old URL (throttled or re-resolve failed); the proxy retries it.
class DashUpstream {
  final String url;
  final int contentLength;
  final String contentType;

  const DashUpstream({
    required this.url,
    required this.contentLength,
    required this.contentType,
  });
}

/// One upstream attempt: served means the player got its bytes.
/// Otherwise [status] is the wall code (null on transport failure)
/// and [retryAfter] honors a server Retry-After when present.
class _UpstreamOutcome {
  final bool served;
  final int? status;
  final Duration? retryAfter;

  const _UpstreamOutcome(this.served, this.status, this.retryAfter);
}

/// Server Retry-After in seconds, header-name case aside. Null when
/// absent, unparsable, or absurd (dates land here too: the next
/// backoff covers them).
Duration? retryAfterOf(Map<String, String> headers) {
  for (final e in headers.entries) {
    if (e.key.toLowerCase() != 'retry-after') continue;
    final secs = int.tryParse(e.value.trim());
    if (secs != null && secs >= 0 && secs <= 120) {
      return Duration(seconds: secs);
    }
    return null;
  }
  return null;
}

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

/// Upstream end clamp (pure, unit-tested): no upstream fetch may touch
/// the final byte (index contentLength-1, the proven 403 shape), so
/// every fetch ends at len-2 at the latest, regardless of file size,
/// chunk size, or chunk position. Single-chunk files included: a
/// sub-chunk file goes out as one 0..len-2 knock, never 0..len-1.
///
/// Returns null when there is nothing fetchable without touching the
/// final byte (a tail-only ask with start >= len-1): the caller must
/// answer 416 downstream instead of knocking upstream at all.
int? clampUpstreamEnd({
  required int start,
  required int end,
  required int contentLength,
  required int chunkSize,
}) {
  if (contentLength <= 1) {
    return math.min(end, start + chunkSize - 1);
  }
  if (start >= contentLength - 1) return null;
  return math.min(
    math.min(end, start + chunkSize - 1),
    contentLength - 2,
  );
}

/// Local range proxy for DASH media. ExoPlayer opens with bare or
/// open-ended ranges, which googlevideo answers with a redirect
/// into a 403 wall on DASH URLs. Closed ranges serve 206 at full
/// speed, but only up to a point: a range spanning (nearly) the
/// whole file 403s too. So this loopback server translates every
/// incoming request into a capped closed upstream range using the
/// known content length. Upstream fetches ride the shared engine
/// (Cronet's Chromium stack first, Dart fallback), one flight at
/// One flight at a time: a seek cancels the stale pipe before
/// opening the next.
class DashProxy {
  String upstreamUrl;
  int contentLength;
  String contentType;
  final Map<String, String> upstreamHeaders;

  /// Re-resolve hook for expired/walled URLs: on a 403/410 the proxy
  /// asks once per request for a fresh signed URL. Wired by the
  /// player (same streamingData lane); null when nobody wired it.
  Future<DashUpstream?> Function()? refreshUpstream;

  /// Playback nonce for this video play, shared by the picture and
  /// sound legs. Stamped as `cpn` on every upstream fetch, same as
  /// official clients; null/empty fetches bare URLs as before.
  String? contentPlaybackNonce;

  HttpServer? _server;
  StreamSubscription<List<int>>? _activeUpstream;
  http.BaseClient? _activeClient;
  bool _closed = false;

  /// Upstream fetches ride the shared engine (Cronet first, Dart
  /// fallback; the winner logs once). One flight at a time: a seek
  /// cancels the stale pipe before opening the next.
  Future<http.BaseClient> _upstreamClient() async =>
      UpstreamEngine.client(userAgent: browserMediaHeaders['User-Agent']);

  /// First successful serve logs once: later silence is normal.
  bool _loggedServing = false;

  /// One-timer for the full-URL replay test.
  static bool _loggedFullUrl = false;

  /// Upstream range cap: with Range headers (not URL params) size
  /// is no longer the wall — 4MB chunks 206 clean. Bigger chunks =
  /// fewer roundtrips = less stutter. Players chain them seamlessly.
  static const _upstreamChunk = 4 << 20;

  /// 403 retries with backoff: transient velocity walls usually pass
  /// on a second knock a second later. Deterministic walls burn ~2s
  /// here, then the player degrade path takes over as before.
  static const _maxUpstreamAttempts = 3;
  static const _retryDelay = Duration(milliseconds: 800);

  /// Retry jitter so staggered legs never march in lockstep.
  static final _jitter = math.Random();

  DashProxy({
    required this.upstreamUrl,
    required this.contentLength,
    required this.contentType,
    this.upstreamHeaders = browserMediaHeaders,
  });

  /// Swap to a freshly resolved signed URL mid-play (403/410 path).
  /// Length/type ride along so the tail clamp stays honest.
  void updateUpstream({
    required String url,
    required int contentLength,
    required String contentType,
  }) {
    upstreamUrl = url;
    this.contentLength = contentLength;
    this.contentType = contentType;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${_server!.port}/stream');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    ArchLog.i(
      'archtube',
      'dash proxy on port ${_server!.port} (len=$contentLength)',
    );
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
    // Proven 2026-10-29/30: any request touching the LAST byte
    // (end == contentLength-1) 403s, including a sub-4MB file served
    // as one chunk, while partial ranges 200. So NO upstream fetch
    // may reach the final byte, no exceptions: end clamps to len-2
    // for every fetch regardless of size or position, and a tail-only
    // ask (start >= len-1) answers 416 downstream without knocking.
    var end = clampUpstreamEnd(
      start: range.start,
      end: range.end,
      contentLength: contentLength,
      chunkSize: _upstreamChunk,
    );
    if (end == null) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      req.response.headers.set(
          'Content-Range', 'bytes */$contentLength');
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }
    // Mid-play 403/410 usually means the signed URL expired under us:
    // one fresh re-resolve per request (player hook), retried at once.
    // Anything else rides exponential backoff with jitter, and a
    // server Retry-After wins over our own schedule. Deterministic
    // client walls (400/404/...) never retry: straight to degrade.
    var refreshed = false;
    var attempt = 0;
    while (true) {
      if (_closed) return;
      attempt++;
      final outcome = await _fetchRange(req, range.start, end!);
      if (outcome.served) return;
      final status = outcome.status;
      if ((status == HttpStatus.forbidden || status == HttpStatus.gone) &&
          !refreshed &&
          refreshUpstream != null &&
          !_closed) {
        refreshed = true;
        try {
          final fresh = await refreshUpstream!();
          if (fresh != null && fresh.url.isNotEmpty) {
            updateUpstream(
              url: fresh.url,
              contentLength: fresh.contentLength,
              contentType: fresh.contentType,
            );
            end = clampUpstreamEnd(
              start: range.start,
              end: range.end,
              contentLength: contentLength,
              chunkSize: _upstreamChunk,
            );
            if (end == null) {
              req.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              req.response.headers.set(
                  'Content-Range', 'bytes */$contentLength');
              try {
                await req.response.close();
              } catch (_) {}
              return;
            }
            // Minted-ticket proof: the refresh re-resolves through the
            // stamped player path, so the forensics lines below show
            // whether freshly stamped URLs still 403. Stamp state and
            // the fresh URL's pot param ride this line.
            final freshPot =
                Uri.tryParse(fresh.url)?.queryParameters.containsKey('pot') ??
                    false;
            ArchLog.i(
              'archtube',
              'dash proxy refreshed upstream '
              '(visitor=${PoTokenSlot.visitorData == null ? 'none' : 'present'} '
              'poToken=${PoTokenSlot.poToken == null ? 'absent' : 'present'} '
              'freshPot=${freshPot ? 'present' : 'absent'}), retrying',
            );
          }
        } catch (e) {
          ArchLog.w('archtube', 'dash proxy refresh failed: $e');
        }
        continue;
      }
      if (attempt >= _maxUpstreamAttempts) break;
      if (status != null &&
          status != HttpStatus.forbidden &&
          status != HttpStatus.requestTimeout &&
          status != HttpStatus.tooManyRequests &&
          status >= 400 &&
          status < 500) {
        break;
      }
      final backoff =
          _retryDelay * attempt + Duration(milliseconds: _jitter.nextInt(350));
      await Future<void>.delayed(outcome.retryAfter ?? backoff);
    }
    await _answerBadGateway(req);
  }

  /// One upstream range fetch piped into [req]. Served when the player
  /// got its bytes; wall or transport failure otherwise (the caller
  /// refreshes/retries, then the player degrade path takes over).
  ///
  /// 2026-10-29: chunk #2+ walled while chunk #1 served. Same URL,
  /// same headers — only the URL-param range differed. So no more
  /// URL-param ranges: forward a real Range header instead, exactly
  /// like the working PC probes. rn dropped with the old style.
  ///
  /// Upstream URL with this play's `cpn` stamped on, official-client
  /// grammar. Silent when no nonce is wired or one is already there.
  /// Always strips the `range`/`rn` URL params first: some audio lanes
  /// (itag 251) carry a near-full-file `range` in the URL, the exact
  /// cursed shape the wall 403s. Upstream fetches ride a real Range
  /// header instead (see [_fetchRange]), never URL params.
  Uri _stampedUri() {
    final base = Uri.parse(upstreamUrl);
    final q = Map<String, String>.of(base.queryParameters);
    final stripped = q.remove('range') != null || q.remove('rn') != null;
    final nonce = contentPlaybackNonce;
    final stamp = nonce != null && nonce.isNotEmpty && !q.containsKey('cpn');
    if (stamp) q['cpn'] = nonce;
    if (!stripped && !stamp) return base;
    return base.replace(queryParameters: q);
  }

  Future<_UpstreamOutcome> _fetchRange(
    HttpRequest req,
    int start,
    int end,
  ) async {
    final client = await _upstreamClient();
    _activeClient = client;
    try {
      final upstream = http.Request('GET', _stampedUri());
      upstream.headers.addAll(browserMediaHeaders);
      upstream.headers['Range'] = 'bytes=$start-$end';
      if (!UpstreamEngine.usesCronet) {
        upstream.headers['Accept-Encoding'] = 'identity';
      }
      final res = await client
          .send(upstream)
          .timeout(const Duration(seconds: 25));
      if (res.statusCode != HttpStatus.partialContent &&
          res.statusCode != HttpStatus.ok) {
        ArchLog.w(
          'archtube',
          'dash proxy upstream ${res.statusCode} ($start-$end)',
        );
        // Forensics for the 403 wall: what we sent, what came back.
        ArchLog.w(
          'archtube',
          'dash forensics reqHeaders=${upstream.headers} respHeaders=${res.headers}',
        );
        // One-timer: full URL bytes for the PC replay test. Local log
        // only; the signature dies with the URL in a few hours.
        if (!_loggedFullUrl) {
          _loggedFullUrl = true;
          ArchLog.w(
            'archtube',
            'dash forensics fullUrl=$upstreamUrl&range=$start-$end',
          );
        }
        try {
          await res.stream.drain<void>();
        } catch (_) {}
        return _UpstreamOutcome(
          false,
          res.statusCode,
          retryAfterOf(res.headers),
        );
      }
      // A 200 answers the query range with exactly the scoped body.
      // Anything else (full file against a scoped ask) is a corrupt
      // pipe: refuse it rather than poison the player.
      final want = end - start + 1;
      final got = res.contentLength;
      if (res.statusCode == HttpStatus.ok && got != null && got != want) {
        ArchLog.w(
          'archtube',
          'dash proxy length mismatch ($got vs $want), refusing',
        );
        try {
          await res.stream.drain<void>();
        } catch (_) {}
        return _UpstreamOutcome(false, res.statusCode, null);
      }
      final out = req.response;
      out.statusCode = HttpStatus.partialContent;
      out.headers.set('Content-Type', contentType);
      out.headers.set('Content-Range', 'bytes $start-$end/$contentLength');
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
      return const _UpstreamOutcome(true, HttpStatus.partialContent, null);
    } catch (e) {
      ArchLog.w('archtube', 'dash proxy pipe failed: $e');
      return const _UpstreamOutcome(false, null, null);
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
      final upstream = http.Request('GET', _stampedUri());
      upstream.headers.addAll(browserMediaHeaders);
      if (!UpstreamEngine.usesCronet) {
        upstream.headers['Accept-Encoding'] = 'identity';
      }
      final incoming = req.headers.value('range');
      if (incoming != null) upstream.headers['Range'] = incoming;
      final res = await client
          .send(upstream)
          .timeout(const Duration(seconds: 25));
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
