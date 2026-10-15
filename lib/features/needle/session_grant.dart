import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/log.dart';
import 'needle_dirs.dart';

/// Session-grant plumbing for Needle signed sessions (proxy
/// verification challenges). Two native calls over
/// `arch.player/session`, one stash file the Rust side consumes:
///
/// - `pendingDeepLink()` pulls the latest
///   `spotiflac://session-grant?...` link (singleTop re-taps land
///   in onNewIntent; pull avoids engine-attach races).
/// - `openBrowser(url)` fires an ACTION_VIEW intent (system-browser
///   fallback when the in-app WebView cannot do the challenge).
/// - `stashGrant(extId, grant)` writes
///   `sessions/pending.<extId>.grant.json`, which
///   `session.completeGrant()` consumes one-shot.
class SessionGrant {
  static const _channel = MethodChannel('arch.player/session');

  static Future<String?> takePendingLink() async {
    try {
      return await _channel.invokeMethod<String>('pendingDeepLink');
    } catch (e) {
      ArchLog.w('needle', 'pending link failed: $e');
      return null;
    }
  }

  static Future<bool> openBrowser(String url) async {
    try {
      return await _channel.invokeMethod<bool>(
            'openBrowser', {'url': url},
          ) ??
          false;
    } catch (e) {
      ArchLog.w('needle', 'open browser failed: $e');
      return false;
    }
  }

  /// Parse a `spotiflac://session-grant?state=..&grant=..` (or
  /// `code=..`) link. Returns null when it is not a grant link.
  static Map<String, String>? parseGrantLink(String link) {
    Uri? uri;
    try {
      uri = Uri.parse(link);
    } catch (_) {
      return null;
    }
    if (uri.scheme != 'spotiflac') return null;
    final grant = uri.queryParameters['grant'] ?? uri.queryParameters['code'] ?? '';
    if (grant.isEmpty) return null;
    return {
      'grant': grant,
      'state': uri.queryParameters['state'] ?? '',
    };
  }

  /// Read back the challenge URL the Rust bootstrap persisted
  /// (`sessions/*.pending.json`). Used when a provider demands
  /// verification without handing us the URL (Tidal's shape):
  /// the bootstrap already saved it, so the sheet can open anyway.
  /// Returns null when no pending challenge exists.
  static Future<String?> readPendingAuthUrl(String extId) async {
    try {
      final base = await needleBaseDir();
      final dir = Directory(
          '${base.path}/ext/$extId/store/$extId/sessions');
      if (!await dir.exists()) return null;
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.pending.json')) continue;
        try {
          final m =
              jsonDecode(await e.readAsString()) as Map<String, dynamic>;
          final url = (m['auth_url'] ?? m['authUrl'] ?? '').toString();
          if (url.isNotEmpty) {
            ArchLog.i('needle', 'pending challenge found for $extId');
            return url;
          }
        } catch (_) {}
      }
      return null;
    } catch (e) {
      ArchLog.w('needle', 'pending challenge read failed: $e');
      return null;
    }
  }

  /// Resolve the sheet URL: the inline one wins, otherwise the
  /// persisted pending file. Null when neither exists.
  static Future<String?> resolveAuthUrl(
      String extId, String inlineUrl) async {
    if (inlineUrl.isNotEmpty) return inlineUrl;
    return readPendingAuthUrl(extId);
  }

  /// Stash a grant for the Rust exchange. Mirrors the Rust scope
  /// layout (`<storage>/<ns>/sessions/`); returns false when the
  /// extension storage dir is unavailable (caller surfaces).
  static Future<bool> stashGrant(String extId, String grant) async {
    try {
      final base = await needleBaseDir();
      final dir = Directory(
          '${base.path}/ext/$extId/store/$extId/sessions');
      await dir.create(recursive: true);
      final safe = extId.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
      await File('${dir.path}/pending.$safe.grant.json')
          .writeAsString(jsonEncode({'grant': grant}));
      ArchLog.i('needle', 'grant stashed for $extId');
      return true;
    } catch (e) {
      ArchLog.w('needle', 'grant stash failed: $e');
      return false;
    }
  }
}
