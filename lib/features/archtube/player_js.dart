import 'package:http/http.dart' as http;

import '../../core/log.dart';

/// Player-JS signature decipher + `n` descrambler, written from the
/// wire format up (no borrowed code).
///
/// Mechanism, briefly: ciphered streaming entries carry
/// `signatureCipher = s=<scrambled>&sp=<param>&url=<encoded>`. The
/// descramble recipe lives in YouTube's player `base.js`: one
/// function that splits the signature into chars, runs a short op
/// list (reverse, drop-first-N, swap first element), and joins it
/// back; plus one function that rewrites the `n` query param or
/// the stream is throttled. Both recipes change whenever YouTube
/// ships a new player, so the parsed ops are cached per player
/// version and re-derived on rotation.
///
/// What this solver reads (structural shapes, not copied code):
/// * the decipher is the function applied right after the
///   `"alr","yes"` marker in base.js;
/// * the `n` function is the one applied to the value read from
///   `get("n")`;
/// * both delegate to a small helper object (`H.op(arr, arg)`), or
///   call `reverse`/`splice` inline. Anything else is an unknown
///   shape: the entry is skipped and the wall logs it once, never
///   a crash, never a guessed URL.
///
/// Fallback only: direct URLs are still preferred everywhere. This
/// path runs solely when a response serves nothing but ciphered
/// entries.
class PlayerCipher {
  final String version;
  final List<CipherStep> sigOps;
  final List<CipherStep> nOps;

  const PlayerCipher({
    required this.version,
    required this.sigOps,
    required this.nOps,
  });

  bool get canDescrambleN => nOps.isNotEmpty;

  String descrambleSig(String scrambled) =>
      applyCipherSteps(scrambled, sigOps);

  String descrambleN(String n) =>
      nOps.isEmpty ? n : applyCipherSteps(n, nOps);

  /// Rebuild a playable URL from a `signatureCipher` value:
  /// descramble `s`, re-attach it under `sp` (default `sig`),
  /// refresh `n` when the recipe is known. Unknown recipes throw,
  /// and the caller skips the entry.
  String rebuildUrl(String signatureCipher) {
    final parts = _splitQuery(signatureCipher);
    final scrambled = parts['s'];
    final encoded = parts['url'];
    if (scrambled == null || scrambled.isEmpty || encoded == null) {
      throw StateError('signatureCipher missing s/url');
    }
    if (sigOps.isEmpty) throw StateError('no sig recipe');
    var url = Uri.decodeComponent(encoded);
    final sig = descrambleSig(Uri.decodeComponent(scrambled));
    final sp = (parts['sp'] ?? 'sig').isEmpty ? 'sig' : parts['sp']!;
    url = url.contains('?') ? '$url&$sp=$sig' : '$url?$sp=$sig';
    final uri = Uri.parse(url);
    final n = uri.queryParameters['n'];
    if (n != null && n.isNotEmpty && canDescrambleN) {
      final fresh = descrambleN(n);
      if (fresh != n) url = _replaceQuery(url, 'n', fresh);
    }
    return url;
  }

  // ----------------------------------------------------------------
  // Fetch + per-version cache.
  // ---------------------------------------------------------------

  /// Parsed ciphers by player version. Versions are content hashes:
  /// a cached recipe always matches its player, never a newer one.
  static final Map<String, Future<PlayerCipher?>> _cache = {};

  /// Cipher for [videoId]'s current player, or null when anything
  /// along the way fails (watch page, player URL, fetch, parse).
  /// Nulls are cached too: a dead version stays dead this process.
  static Future<PlayerCipher?> forVideo(
    http.BaseClient client,
    String videoId,
  ) async {
    final watch = await _watchHtml(client, videoId);
    if (watch == null) return null;
    final jsUrl = playerJsUrlOfWatch(watch);
    if (jsUrl == null) {
      ArchLog.w('archtube', 'decipher: no player js url on watch page');
      return null;
    }
    final version = playerVersionOf(jsUrl);
    final hit = _cache[version];
    if (hit != null) return hit;
    if (_cache.length > 8) _cache.remove(_cache.keys.first);
    final fut = _load(client, jsUrl, version);
    _cache[version] = fut;
    return fut;
  }

  static Future<PlayerCipher?> _load(
    http.BaseClient client,
    String jsUrl,
    String version,
  ) async {
    try {
      final res = await client
          .get(Uri.parse(jsUrl), headers: {'User-Agent': watchUserAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        ArchLog.w(
          'archtube',
          'decipher: base.js HTTP ${res.statusCode} for $version',
        );
        return null;
      }
      final cipher = parsePlayerJs(res.body, version);
      ArchLog.i(
        'archtube',
        'decipher: ready v=$version '
        '(sigOps=${cipher.sigOps.length}, n=${cipher.canDescrambleN ? 'yes' : 'unknown'})',
      );
      return cipher;
    } catch (e) {
      ArchLog.w('archtube', 'decipher: load failed for $version: $e');
      return null;
    }
  }

  static Future<String?> _watchHtml(
    http.BaseClient client,
    String videoId,
  ) async {
    try {
      final res = await client
          .get(
            Uri.parse('https://www.youtube.com/watch?v=$videoId'),
            headers: {'User-Agent': watchUserAgent},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        ArchLog.w(
          'archtube',
          'decipher: watch HTTP ${res.statusCode} for $videoId',
        );
        return null;
      }
      return res.body;
    } catch (e) {
      ArchLog.w('archtube', 'decipher: watch fetch failed: $e');
      return null;
    }
  }

  static void clearCache() => _cache.clear();

  // ----------------------------------------------------------------
  // Pure parsing: every entry point below is unit-tested.
  // ---------------------------------------------------------------

  /// Desktop UA for the watch page + base.js: the player URL and
  /// visitor data ride the web HTML, not the mobile shells.
  static const watchUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// `"PLAYER_JS_URL":"/s/player/<version>/base.js"` to absolute URL.
  static String? playerJsUrlOfWatch(String html) {
    final m = RegExp(
      r'"PLAYER_JS_URL"\s*:\s*"(/s/player/[^"]+?/base\.js)"',
    ).firstMatch(html);
    if (m == null) return null;
    return 'https://www.youtube.com${m.group(1)}';
  }

  /// Player version is the hash segment of its own URL.
  static String playerVersionOf(String jsUrl) {
    final m = RegExp(r'/s/player/([^/]+)/base\.js').firstMatch(jsUrl);
    return m?.group(1) ?? jsUrl;
  }

  /// `"visitorData":"..."` out of watch HTML. Session identity for
  /// the player request (card 3's raw material).
  static String? visitorDataOfWatch(String html) {
    final m = RegExp(r'"visitorData"\s*:\s*"([^"]+)"').firstMatch(html);
    return m?.group(1);
  }

  /// Both recipes out of one base.js body.
  static PlayerCipher parsePlayerJs(String js, String version) {
    final sigFn = _fnAfterAlr(js) ?? _splitJoinFn(js);
    final sigOps = sigFn == null ? const <CipherStep>[] : _opList(js, sigFn);
    final nFn = _nFnName(js);
    final nOps = nFn == null ? const <CipherStep>[] : _opList(js, nFn);
    if (sigOps.isEmpty) {
      throw StateError('unrecognized sig recipe in $version');
    }
    return PlayerCipher(version: version, sigOps: sigOps, nOps: nOps);
  }

  /// The decipher is applied right after the `"alr","yes"` marker:
  /// `...set("alr","yes");c&&(c=FN(c))`.
  static String? _fnAfterAlr(String js) {
    final m = RegExp(
      r'"alr"\s*,\s*"yes"\s*\)\s*;\s*\w+&&\(\w+=([\w$]+)\(\w+\)\)',
    ).firstMatch(js);
    return m?.group(1);
  }

  /// The `n` function is applied to the value read from `get("n")`:
  /// `...(b=a.get("n"))&&(b=FN(b))`.
  static String? _nFnName(String js) {
    final m = RegExp(
      r'\.get\("n"\)\)&&\(\w+=([\w$]+)\(\w+\)\)',
    ).firstMatch(js);
    return m?.group(1);
  }

  /// Fallback anchor for the decipher when the marker moves: a
  /// top-level `FN=function(a){a=a.split("");...;return a.join("")}`
  /// that calls at least one dotted helper.
  static String? _splitJoinFn(String js) {
    final re = RegExp(
      r'([\w$]+)=function\(\w+\)\{\w+=\w+\.split\(""\);'
      r'[\s\S]*?return \w+\.join\(""\);?\}',
    );
    String? found;
    for (final m in re.allMatches(js)) {
      final body = m.group(0)!;
      if (RegExp(r'\w+\.\w+\(\w+').hasMatch(body)) {
        found = m.group(1);
        break;
      }
    }
    return found;
  }

  /// Balanced-brace body of `NAME=function(<params>){...}`.
  static String? _fnBody(String js, String name) {
    final head = RegExp(r'(?:var\s+)?' + RegExp.escape(name) + r'=function\([^)]*\)\{');
    final m = head.firstMatch(js);
    if (m == null) return null;
    var depth = 0;
    for (var i = m.end - 1; i < js.length; i++) {
      if (js[i] == '{') depth++;
      if (js[i] == '}') {
        depth--;
        if (depth == 0) return js.substring(m.end, i);
      }
    }
    return null;
  }

  /// Op list for the recipe function [name]: ordered helper calls
  /// `H.op(arr)` / `H.op(arr, N)` (where `H={` exists in the source)
  /// plus inline `arr.reverse()` / `arr.splice(0, N)`. Throws on the
  /// first unrecognized shape so the caller skips the entry instead
  /// of guessing a URL.
  static List<CipherStep> _opList(String js, String name) {
    final body = _fnBody(js, name);
    if (body == null) throw StateError('recipe $name not found');
    final steps = <CipherStep>[];
    final call = RegExp(r'([\w$]+)\.([\w$]+)\(\w+(?:,(\d+))?\)');
    for (final raw in body.split(';')) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      if (s.startsWith('var ') || s.contains('split("")')) continue;
      if (s.startsWith('return ')) continue;
      final cm = call.firstMatch(s);
      if (cm != null && _isHelperObject(js, cm.group(1)!)) {
        steps.add(
          _classify(
            _helperBody(js, cm.group(1)!, cm.group(2)!),
            cm.group(3),
          ),
        );
        continue;
      }
      if (RegExp(r'^\w+\.reverse\(\)$').hasMatch(s)) {
        steps.add(const CipherStep(CipherOp.reverse, 0));
        continue;
      }
      final sm = RegExp(r'^\w+\.splice\(0,(\d+)\)$').firstMatch(s);
      if (sm != null) {
        steps.add(CipherStep(CipherOp.splice, int.parse(sm.group(1)!)));
        continue;
      }
      throw StateError('unrecognized recipe statement: $s');
    }
    if (steps.isEmpty) throw StateError('empty recipe $name');
    return steps;
  }

  /// A receiver is a helper object only when assigned an object
  /// literal somewhere (`H={...}`); bare array variables (`b`,
  /// `a`) never are. This keeps inline `b.splice(...)` from
  /// reading as a helper call.
  static bool _isHelperObject(String js, String receiver) =>
      RegExp(RegExp.escape(receiver) + r'\s*=\{').hasMatch(js);

  /// Body of one helper method `H={...op:function(a,b){...}...}`.
  static String _helperBody(String js, String helper, String op) {
    final obj = RegExp(
      RegExp.escape(helper) +
          r'=\{([\w$]+\s*:\s*function\s*\([^)]*\)\s*\{[^}]*\}[,]?)+\};?',
    ).firstMatch(js);
    if (obj == null) throw StateError('helper $helper not found');
    final m = RegExp(
      RegExp.escape(op) +
          r'\s*:\s*function\s*\([^)]*\)\s*\{([^}]*)\}',
    ).firstMatch(obj.group(0)!);
    if (m == null) throw StateError('helper $helper.$op not found');
    return m.group(1)!;
  }

  /// One helper body to one op. The call-site arg rides along for
  /// the ops that take one (splice/swap); reverse ignores it.
  static CipherStep _classify(String helperBody, String? arg) {
    final b = helperBody.replaceAll(RegExp(r'\s+'), '');
    if (b.contains('.reverse()')) {
      return const CipherStep(CipherOp.reverse, 0);
    }
    if (b.contains('.splice(')) {
      if (arg == null) throw StateError('splice without arg');
      return CipherStep(CipherOp.splice, int.parse(arg));
    }
    if (_isSwap(b)) {
      if (arg == null) throw StateError('swap without arg');
      return CipherStep(CipherOp.swap, int.parse(arg));
    }
    throw StateError('unknown helper shape: $helperBody');
  }

  /// Swap-shape: first element traded with another via a temp
  /// (`var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c` families).
  static bool _isSwap(String compact) =>
      compact.contains('a[0]=') &&
      RegExp(r'a\[[^\]]+\]=c[^;]*;?').hasMatch(compact);

  static Map<String, String> _splitQuery(String q) {
    final out = <String, String>{};
    for (final pair in q.split('&')) {
      final i = pair.indexOf('=');
      if (i <= 0) continue;
      out[pair.substring(0, i)] = pair.substring(i + 1);
    }
    return out;
  }

  static String _replaceQuery(String url, String key, String value) {
    final uri = Uri.parse(url);
    final q = Map<String, String>.of(uri.queryParameters);
    q[key] = value;
    return uri.replace(queryParameters: q).toString();
  }
}

/// One descramble step: what to do plus the call-site number.
class CipherStep {
  final CipherOp op;
  final int arg;

  const CipherStep(this.op, this.arg);
}

/// The only ops the recipes have ever needed. Anything else is a
/// new shape, and new shapes throw instead of guessing.
enum CipherOp {
  /// Reverse the whole char list.
  reverse,

  /// Drop the first [CipherStep.arg] chars.
  splice,

  /// Trade index 0 with index [CipherStep.arg] % length.
  swap,
}

/// Apply [steps] to [input], chars as the list. Pure and tested.
String applyCipherSteps(String input, List<CipherStep> steps) {
  final a = input.split('');
  for (final s in steps) {
    switch (s.op) {
      case CipherOp.reverse:
        for (var i = 0, j = a.length - 1; i < j; i++, j--) {
          final t = a[i];
          a[i] = a[j];
          a[j] = t;
        }
      case CipherOp.splice:
        a.removeRange(0, s.arg.clamp(0, a.length));
      case CipherOp.swap:
        if (a.isEmpty) break;
        final j = s.arg % a.length;
        final t = a[0];
        a[0] = a[j];
        a[j] = t;
    }
  }
  return a.join();
}
