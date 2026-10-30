import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

import '../../core/log.dart';

/// Shared native-stack transport for every YouTube knock: the
/// DASH proxy's googlevideo fetches, the player/search POSTs, and
/// the player-JS / watch-page fetches behind the decipher.
///
/// Cronet first (Chromium TLS fingerprint, same story as the
/// browser-shaped headers), Dart's own stack as fallback. The
/// winning engine is logged exactly once per process; later
/// silence is normal. A missing Cronet provider (desktop test,
/// stripped build) falls back quietly, never fatally.
abstract final class UpstreamEngine {
  static CronetEngine? _engine;
  static bool _dead = false;
  static bool _logged = false;

  /// A fresh client on the winning engine. Callers own it and
  /// close it when done, as before; the Cronet engine itself is
  /// shared and never closed here.
  static http.BaseClient client({String? userAgent}) {
    if (!_dead) {
      try {
        _engine ??= CronetEngine.build(
          cacheMode: CacheMode.disabled,
          userAgent: userAgent,
        );
        _logOnce('cronet');
        return CronetClient.fromCronetEngine(_engine!);
      } catch (e) {
        _dead = true;
        ArchLog.w('archtube', 'cronet unavailable, dart fallback: $e');
      }
    }
    _logOnce('dart');
    return http_io.IOClient(HttpClient()..autoUncompress = false);
  }

  /// Whether upstream clients currently ride Cronet (Chromium
  /// handles content encoding itself, so the Dart fallback alone
  /// pins `Accept-Encoding: identity`).
  static bool get usesCronet => !_dead && _engine != null;

  static void _logOnce(String engine) {
    if (_logged) return;
    _logged = true;
    ArchLog.i('archtube', 'upstream engine: $engine');
  }
}
