import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/log.dart';
import 'player_js.dart';

/// Session identity for the player request: `visitorData` plus an
/// optional PO token (proof-of-origin), after NewPipe's web-client
/// grammar.
///
/// What we actually do: read `visitorData` once per process out of
/// a watch page, then attach it to every player/search call, both
/// as `context.client.visitorData` and as the `X-Goog-Visitor-Id`
/// header. A minted PO token can be supplied later through
/// [setPoToken] (BotGuard minting lives outside this client); when
/// present it rides as `serviceIntegrityDimensions.poToken`, when
/// absent the request goes out without it, exactly as before.
///
/// Privacy note: visitorData is YouTube's anonymous session crumb,
/// not the user's account. It is fetched, never fabricated: a made
/// up crumb reads worse than none.
///
/// Exactly one log line per process names what is attached.
abstract final class PoTokenSlot {
  static String? _visitorData;
  static String? _poToken;
  static bool _fetching = false;
  static bool _logged = false;

  /// A minted PO token, when something outside this client has one.
  /// Empty clears the slot.
  static void setPoToken(String token) {
    _poToken = token.isEmpty ? null : token;
    _logged = false;
  }

  static String? get visitorData => _visitorData;

  static void clearForTest() {
    _visitorData = null;
    _poToken = null;
    _fetching = false;
    _logged = false;
  }

  /// Start the one watch-page read that yields visitorData.
  /// Fire-and-forget by design: the player request never waits on
  /// it, it simply attaches more identity on later calls.
  static void ensureVisitorData(
    http.BaseClient client,
    String videoId,
  ) {
    if (_visitorData != null || _fetching) return;
    _fetching = true;
    unawaited(_fetch(client, videoId));
  }

  static Future<void> _fetch(http.BaseClient client, String videoId) async {
    try {
      final res = await client
          .get(
            Uri.parse('https://www.youtube.com/watch?v=$videoId'),
            headers: {'User-Agent': PlayerCipher.watchUserAgent},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        _visitorData = PlayerCipher.visitorDataOfWatch(res.body);
      }
    } catch (_) {
      // No identity this round; the next call retries.
    } finally {
      _fetching = false;
    }
  }

  /// Attach session identity to a player/search [body] + [headers].
  /// Safe to call on every request; the state line logs once.
  static void apply(
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) {
    final context = body['context'];
    if (context is Map<String, dynamic>) {
      final clientMap = context['client'];
      if (clientMap is Map<String, dynamic>) {
        final v = _visitorData;
        if (v != null && v.isNotEmpty) {
          clientMap['visitorData'] = v;
          headers['X-Goog-Visitor-Id'] = v;
        }
      }
    }
    final token = _poToken;
    if (token != null && token.isNotEmpty) {
      body['serviceIntegrityDimensions'] = {'poToken': token};
    }
    if (!_logged) {
      _logged = true;
      final v = _visitorData;
      ArchLog.i(
        'archtube',
        'potoken: visitor=${v == null ? 'none' : 'v=${v.substring(0, v.length.clamp(0, 8))}...'} '
        'poToken=${token == null ? 'absent' : 'present'}',
      );
    }
  }
}
