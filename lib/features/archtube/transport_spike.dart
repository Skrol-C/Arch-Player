import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import 'dash_proxy.dart';
import 'okhttp_chunk.dart';
import 'upstream_engine.dart';

/// Skeptic-approved spike ONLY: on-device transport discrimination.
///
/// Fetches ONE known-403 DASH chunk three ways (Dart HttpClient,
/// Cronet, OkHttp), same URL, same closed Range header, and logs
/// verdict lines. Used only by the hidden log-screen long-press;
/// never wired into playback.
///
/// Watch with: `adb logcat | grep "spike:"` (or tail arch.log).
/// The money line is the last one:
///   `spike: dart=403 cronet=403 okhttp=200`
abstract final class TransportSpike {
  static const _legTimeout = Duration(seconds: 25);

  /// Replay the freshest 403 wall: in-memory forensics first, then
  /// the last `dash forensics fullUrl=` line in arch.log. Logs a
  /// hint instead when no wall has been seen yet this install.
  static Future<void> runLastWalled() async {
    final memUrl = DashProxy.lastWalledUrl;
    final memStart = DashProxy.lastWalledStart;
    final memEnd = DashProxy.lastWalledEnd;
    if (memUrl != null && memStart != null && memEnd != null) {
      ArchLog.i('spike', 'replaying in-memory wall');
      await run(url: memUrl, start: memStart, end: memEnd);
      return;
    }
    final logged = await _lastWalledFromLog();
    if (logged == null) {
      ArchLog.i(
        'spike',
        'no walled url yet, play a 403 track first then long-press again',
      );
      return;
    }
    ArchLog.i('spike', 'replaying wall from arch.log');
    await run(url: logged.url, start: logged.start, end: logged.end);
  }

  /// One three-way run against [url] with closed range
  /// `bytes=start-end`. Every leg sends the same browser-shaped
  /// headers the proxy sends, plus the Range header.
  static Future<void> run({
    required String url,
    required int start,
    required int end,
  }) async {
    final range = 'bytes=$start-$end';
    ArchLog.i('spike', 'run range=$range url=$url');
    final dart = await _dartLeg(url, range);
    final cronet = await _cronetLeg(url, range);
    final okhttp = await _okhttpLeg(url, range);
    ArchLog.i('spike', 'dart=$dart cronet=$cronet okhttp=$okhttp');
  }

  /// Dart's own HttpClient, exactly like the proxy fallback (identity
  /// encoding, no content decoding).
  static Future<String> _dartLeg(String url, String range) async {
    final watch = Stopwatch()..start();
    final client = http_io.IOClient(HttpClient()..autoUncompress = false);
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(browserMediaHeaders);
      req.headers['Range'] = range;
      req.headers['Accept-Encoding'] = 'identity';
      final res = await client.send(req).timeout(_legTimeout);
      var bytes = 0;
      await for (final chunk in res.stream.timeout(_legTimeout)) {
        bytes += chunk.length;
      }
      watch.stop();
      ArchLog.i(
        'spike',
        'dart status=${res.statusCode} bytes=$bytes ms=${watch.elapsedMilliseconds}',
      );
      return '${res.statusCode}';
    } on TimeoutException {
      watch.stop();
      ArchLog.i('spike', 'dart status=timeout ms=${watch.elapsedMilliseconds}');
      return 'timeout';
    } catch (e) {
      watch.stop();
      ArchLog.i(
        'spike',
        'dart status=err ms=${watch.elapsedMilliseconds} err=$e',
      );
      return 'err';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Cronet (Chromium stack), exactly like the proxy primary path.
  static Future<String> _cronetLeg(String url, String range) async {
    final watch = Stopwatch()..start();
    final client = UpstreamEngine.client(
      userAgent: browserMediaHeaders['User-Agent'],
    );
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(browserMediaHeaders);
      req.headers['Range'] = range;
      final res = await client.send(req).timeout(_legTimeout);
      var bytes = 0;
      await for (final chunk in res.stream.timeout(_legTimeout)) {
        bytes += chunk.length;
      }
      watch.stop();
      ArchLog.i(
        'spike',
        'cronet status=${res.statusCode} bytes=$bytes ms=${watch.elapsedMilliseconds}',
      );
      return '${res.statusCode}';
    } on TimeoutException {
      watch.stop();
      ArchLog.i(
        'spike',
        'cronet status=timeout ms=${watch.elapsedMilliseconds}',
      );
      return 'timeout';
    } catch (e) {
      watch.stop();
      ArchLog.i(
        'spike',
        'cronet status=err ms=${watch.elapsedMilliseconds} err=$e',
      );
      return 'err';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Real Square OkHttp over the narrow platform channel.
  static Future<String> _okhttpLeg(String url, String range) async {
    final watch = Stopwatch()..start();
    try {
      final out = await OkHttpChunk.fetchChunk(url, {
        ...browserMediaHeaders,
        'Range': range,
      }).timeout(_legTimeout);
      watch.stop();
      if (out.error != null && out.status == -1) {
        ArchLog.i(
          'spike',
          'okhttp status=err ms=${watch.elapsedMilliseconds} err=${out.error}',
        );
        return 'err';
      }
      ArchLog.i(
        'spike',
        'okhttp status=${out.status} bytes=${out.bytes} ms=${watch.elapsedMilliseconds}',
      );
      return '${out.status}';
    } on TimeoutException {
      watch.stop();
      ArchLog.i(
        'spike',
        'okhttp status=timeout ms=${watch.elapsedMilliseconds}',
      );
      return 'timeout';
    } catch (e) {
      watch.stop();
      ArchLog.i(
        'spike',
        'okhttp status=err ms=${watch.elapsedMilliseconds} err=$e',
      );
      return 'err';
    }
  }

  /// Last `dash forensics fullUrl=<url>&range=<s>-<e>` line in
  /// arch.log. The logged URL may itself carry `range`/`rn` params,
  /// so the trailing `&range=s-e` (end of line) is the replay span
  /// and everything before it is the URL.
  static Future<({String url, int start, int end})?> _lastWalledFromLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/arch.log');
      if (!await file.exists()) return null;
      const marker = 'dash forensics fullUrl=';
      String? last;
      await for (final line in file
          .openRead()
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())) {
        if (line.contains(marker)) last = line;
      }
      if (last == null) return null;
      final tail = last.substring(last.indexOf(marker) + marker.length).trim();
      final m = RegExp(r'&range=(\d+)-(\d+)$').firstMatch(tail);
      if (m == null) return null;
      final url = tail.substring(0, m.start);
      final start = int.tryParse(m.group(1)!);
      final end = int.tryParse(m.group(2)!);
      if (url.isEmpty || start == null || end == null) return null;
      return (url: url, start: start, end: end);
    } catch (_) {
      return null;
    }
  }
}
