import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/log.dart';
import 'player_js.dart';

/// Session stamp for the player request: `visitorData` plus an
/// optional PO token (proof-of-origin), after NewPipe's web-client
/// grammar (own implementation, no borrowed code).
///
/// Researched shape (NewPipeExtractor `PoTokenProvider` docs):
/// some InnerTube clients demand device-integrity PO tokens. WEB
/// clients mint them through Google's BotGuard machine, which
/// needs a JavaScript engine with a good DOM implementation; the
/// player request carries one token (minter = videoId) in
/// `serviceIntegrityDimensions.poToken` while streaming URLs carry
/// another (minter = logged-out visitorData) as the `pot` param.
/// ANDROID instead uses DroidGuard, a downloaded native VM run by
/// Play Services whose wire details are not public; iOS has an
/// equivalent (iosGuard, possibly Apple attestation). Our ladder
/// is ANDROID-first, so a PO token is currently optional, but the
/// slot is wired so a minted token rides every request once one
/// exists.
///
/// What this slot actually does:
/// * `visitorData` is read out of a watch page and cached per
///   process, then attached to every player/search call both as
///   `context.client.visitorData` and as the `X-Goog-Visitor-Id`
///   header. It is fetched, never fabricated.
/// * the BotGuard challenge blob (`bgChallenge`) is read out of
///   the same watch page with our own extractor and handed to the
///   configured [PoTokenMinter] as mint input.
/// * a minted token rides as `serviceIntegrityDimensions.poToken`.
///   Until a minter is wired the request goes out without it.
///
/// Narrowest on-device mint path: a hidden platform WebView loading
/// `https://www.youtube.com/embed/<videoId>` and running YouTube's
/// BotGuard VM there (JS + DOM, exactly what the docs demand),
/// returning the token over a JS channel into [setPoToken]. That
/// WebView is not bundled yet; [UnwiredPoTokenMinter] says so
/// plainly and yields null instead of inventing a token.
///
/// Exactly two one-time lines prove the stamp: `visitor=present`
/// once the crumb accrues, `poToken=present` once a minted token
/// lands. The dash proxy forensics (`dash forensics ...`) then
/// show whether freshly stamped URLs still 403.
/// Privacy note: visitorData is YouTube's anonymous session crumb,
/// not the user's account. It is fetched, never made up: a made
/// up crumb reads worse than none.
abstract final class PoTokenSlot {
  static String? _visitorData;
  static String? _bgChallenge;
  static String? _poToken;
  static Future<void>? _stampFlight;
  static PoTokenMinter _minter = const UnwiredPoTokenMinter();
  static bool _loggedVisitor = false;
  static bool _loggedToken = false;

  /// A minted PO token, pushed from outside (e.g. the BotGuard
  /// WebView once it exists). Empty clears the slot.
  static void setPoToken(String token) {
    final next = token.isEmpty ? null : token;
    final changed = next != _poToken;
    _poToken = next;
    if (changed) _loggedToken = false;
    if (next != null && !_loggedToken) {
      _loggedToken = true;
      ArchLog.i('archtube', 'potoken: poToken=present (externally supplied)');
    }
  }

  /// Swap the mint strategy. Defaults to unwired (null tokens).
  static void setMinter(PoTokenMinter minter) {
    _minter = minter;
  }

  static String? get visitorData => _visitorData;
  static String? get poToken => _poToken;
  static String? get bgChallenge => _bgChallenge;

  static void clearForTest() {
    _visitorData = null;
    _bgChallenge = null;
    _poToken = null;
    _stampFlight = null;
    _minter = const UnwiredPoTokenMinter();
    _loggedVisitor = false;
    _loggedToken = false;
  }

  /// Synchronous stamp for one video resolve: await the watch-page
  /// crumb when missing, then await a mint when the crumb is in
  /// hand and no token exists yet. Concurrent resolves share one
  /// flight; failures stay silent so the player request still goes
  /// out (unstamped) instead of wedging.
  static Future<void> ensureStamp(
    http.BaseClient client,
    String? videoId,
  ) {
    final vid = (videoId ?? '').trim();
    if (vid.isEmpty) return Future.value();
    if (_visitorData != null && (_poToken != null || _minter is UnwiredPoTokenMinter)) {
      if (_poToken != null && !_loggedToken) {
        _loggedToken = true;
        ArchLog.i('archtube', 'potoken: poToken=present');
      }
      return Future.value();
    }
    final flight = _stampFlight;
    if (flight != null) return flight;
    final next = _stamp(client, vid).timeout(
      const Duration(seconds: 30),
      onTimeout: () {},
    );
    _stampFlight = next;
    next.whenComplete(() {
      if (identical(_stampFlight, next)) _stampFlight = null;
    });
    return next;
  }

  static Future<void> _stamp(http.BaseClient client, String videoId) async {
    if (_visitorData == null) {
      try {
        final watch = await _watchHtml(client, videoId);
        if (watch != null) {
          _visitorData = PlayerCipher.visitorDataOfWatch(watch);
          _bgChallenge = botguardChallengeOfWatch(watch);
          if (_visitorData != null && !_loggedVisitor) {
            _loggedVisitor = true;
            final v = _visitorData!;
            final head = v.substring(0, v.length.clamp(0, 8));
            ArchLog.i(
              'archtube',
              'potoken: visitor=present v=$head... '
              'bgChallenge=${_bgChallenge == null ? 'absent' : 'present'}',
            );
          }
        }
      } catch (_) {
        // No identity this round; the next resolve retries.
      }
    }
    final visitor = _visitorData;
    if (visitor == null || visitor.isEmpty) return;
    if (_poToken != null && _poToken!.isNotEmpty) return;
    try {
      final minted = await _minter
          .mint(
            client: client,
            videoId: videoId,
            visitorData: visitor,
            challenge: _bgChallenge,
          )
          .timeout(const Duration(seconds: 20));
      if (minted != null && minted.isNotEmpty) {
        _poToken = minted;
        if (!_loggedToken) {
          _loggedToken = true;
          ArchLog.i('archtube', 'potoken: poToken=present (minted)');
        }
      }
    } catch (_) {
      // Stays absent; the request goes out visitor-stamped only.
    }
  }

  static Future<String?> _watchHtml(
    http.BaseClient client,
    String videoId,
  ) async {
    final res = await client
        .get(
          Uri.parse('https://www.youtube.com/watch?v=$videoId'),
          headers: {'User-Agent': PlayerCipher.watchUserAgent},
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    return res.body;
  }

  /// `bgChallenge` object out of watch HTML, brace-balanced by our
  /// own scan (no borrowed code). Returns the raw object text for
  /// the minter, null when the page carries none. Pure, tested at
  /// the call site only by presence logging.
  static String? botguardChallengeOfWatch(String html) {
    final key = html.indexOf('"bgChallenge"');
    if (key < 0) return null;
    final colon = html.indexOf(':', key + '"bgChallenge"'.length);
    if (colon < 0) return null;
    final open = html.indexOf('{', colon);
    if (open < 0) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = open; i < html.length; i++) {
      final c = html[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return html.substring(open, i + 1);
      }
    }
    return null;
  }

  /// Attach session identity to a player/search [body] + [headers].
  /// Safe to call on every request.
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
    if (!_loggedVisitor && !_loggedToken) {
      _loggedVisitor = true;
      final v = _visitorData;
      ArchLog.i(
        'archtube',
        'potoken: visitor=${v == null ? 'none' : 'present'} '
        'poToken=${token == null ? 'absent' : 'present'}',
      );
    }
  }
}

/// On-device PO-token mint strategy: BotGuard challenge in, token
/// (or null when it cannot mint) out. Must never invent a token:
/// return null when the runtime is missing.
abstract class PoTokenMinter {
  Future<String?> mint({
    required http.BaseClient client,
    required String videoId,
    required String visitorData,
    String? challenge,
  });
}

/// Default until the BotGuard WebView exists: always null, logged
/// once so the gap is visible instead of silent.
class UnwiredPoTokenMinter implements PoTokenMinter {
  const UnwiredPoTokenMinter();

  static bool _logged = false;

  @override
  Future<String?> mint({
    required http.BaseClient client,
    required String videoId,
    required String visitorData,
    String? challenge,
  }) async {
    if (!_logged) {
      _logged = true;
      ArchLog.i(
        'archtube',
        'potoken: minter=unwired (BotGuard needs a hidden WebView '
        'running the embed challenge; poToken stays absent)',
      );
    }
    return null;
  }
}
