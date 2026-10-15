import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/log.dart';
import '../needle/extension.dart';
import '../needle/extensions.dart';
import '../needle/needle_core.dart';
import '../needle/needle_dirs.dart';
import '../needle/packages.dart';
import '../needle/sandbox.dart';

/// Query router: one entry point, three depths (locked search plan).
/// URLs are detected by scheme, never regex soup. Non-URLs never
/// touch the URL path.
class SearchRouter {
  /// True for URLs and app URIs (http/https + spotify:/deezer:/tidal:).
  static bool isUrl(String q) {
    final s = q.trim();
    if (s.isEmpty) return false;
    if (s.startsWith('http://') || s.startsWith('https://')) return true;
    final idx = s.indexOf(':');
    if (idx <= 0 || idx > 16) return false;
    final scheme = s.substring(0, idx).toLowerCase();
    if (scheme.contains(' ') || scheme.contains('/')) return false;
    return {'spotify', 'deezer', 'tidal', 'qobuz', 'soundcloud', 'youtube'}
        .contains(scheme);
  }

  static String _hostOf(String url) {
    try {
      final u = Uri.parse(url);
      if (u.host.isNotEmpty) return u.host.toLowerCase();
    } catch (_) {}
    return '';
  }

  /// Extension cascade: providers whose urlHandler patterns match,
  /// in priority order, handleURL -> typed result. Entries may carry
  /// `*.` CDN-family wildcards; userinfo + ports are stripped before
  /// matching. A lone `*` never matches.
  static bool handlerMatches(String pattern, String url) {
    var p = pattern.trim().toLowerCase();
    if (p.isEmpty || p == '*') return false;
    final at = p.lastIndexOf('@');
    if (at >= 0) p = p.substring(at + 1);
    final colon = p.lastIndexOf(':');
    if (colon >= 0 && !p.endsWith(']')) p = p.substring(0, colon);
    final host = _hostOf(url);
    final target = host.isNotEmpty ? host : url.toLowerCase();
    if (p.startsWith('*.')) {
      final suffix = p.substring(2);
      return target == suffix || target.endsWith('.$suffix');
    }
    if (p.contains('://') || p.contains('/')) {
      return url.toLowerCase().contains(p);
    }
    return target == p || target.endsWith('.$p') || target.contains(p);
  }

  /// Resolve a URL through claiming extensions. Patterns come from
  /// the live on-disk manifest (installed records predate the
  /// urlHandler field and may carry none). Both `handleURL` and
  /// `handleUrl` spellings are tried: registry extensions disagree
  /// on the capital. Envelopes with success == false are rejections,
  /// not resolutions. Returns {providerId, value} on first ok.
  static const _urlEntries = ['handleURL', 'handleUrl'];

  static Future<Map<String, dynamic>?> resolveUrl(
    String url,
    List<InstalledExtension> providers, {
    int timeoutMs = 15000,
  }) async {
    if (!Needle.ready) return null;
    final candidates = [
      for (final e in providers)
        if (e.enabled && e.roles.contains('metadata')) e,
    ]..sort((a, b) => a.priority.compareTo(b.priority));
    final patterns = <String, List<String>>{};
    for (final e in candidates) {
      try {
        final m = await readInstalledManifest(e.id);
        patterns[e.id] =
            m != null ? m.urlHandlers : e.urlHandlers;
      } catch (_) {
        patterns[e.id] = e.urlHandlers;
      }
    }
    final matched = <InstalledExtension>[];
    final rest = <InstalledExtension>[];
    for (final e in candidates) {
      final claims = (patterns[e.id] ?? const [])
          .any((h) => handlerMatches(h, url));
      if (claims) {
        matched.add(e);
      } else {
        rest.add(e);
      }
    }
    // Claiming handlers first, then the rest (they may still answer
    // via a generic handler). Priority order inside each group.
    for (final e in [...matched, ...rest]) {
      try {
        final h = await loadExtension(e.id);
        final fns = await extensionFunctions(h.handle);
        String? entry;
        for (final en in _urlEntries) {
          if (fns.contains(en)) {
            entry = en;
            break;
          }
        }
        if (entry == null) continue;
        final out = await callExtensionFn(h.handle, entry, [url],
            timeoutMs: timeoutMs);
        final value = out['value'];
        if (value == null) continue;
        if (value is Map && value['success'] == false) {
          ArchLog.w('search',
              'handleURL via ${e.id} rejected: ${value['error']}');
          continue;
        }
        ArchLog.i('search', 'url resolved via ${e.id} ($entry)');
        return {'providerId': e.id, 'value': value};
      } on NeedleException catch (err) {
        ArchLog.w('search', 'handleURL via ${e.id} failed: ${err.code}');
        continue;
      }
    }
    ArchLog.i('search', 'url unclaimed by extensions');
    return null;
  }
}

/// Odesli fallback: keyless per-platform IDs + ISRCs, disk-cached
/// under app files (never cache). Single client on the `http` dep.
class OdesliClient {
  static const _endpoint = 'https://api.song.link/v1-alpha.1/links';
  static const _ttl = Duration(days: 7);

  static String _key(String url) {
    var h = 0;
    for (var i = 0; i < url.length; i++) {
      h = ((h * 31) + url.codeUnitAt(i)) & 0x7fffffff;
    }
    return 'odesli_$h.json';
  }

  static Future<Directory> _dir() async {
    final base = await needleBaseDir();
    final dir = Directory('${base.path}/search_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Map<String, dynamic>?> resolve(String url) async {
    try {
      final dir = await _dir();
      final file = File('${dir.path}/${_key(url)}');
      if (await file.exists()) {
        try {
          final stat = await file.stat();
          if (DateTime.now().difference(stat.modified) < _ttl) {
            final raw = await file.readAsString();
            final m = jsonDecode(raw) as Map<String, dynamic>;
            ArchLog.i('search', 'odesli cache hit');
            return m;
          }
        } catch (_) {}
      }
      final uri = Uri.parse(
          '$_endpoint?url=${Uri.encodeComponent(url)}');
      final res = await http
          .get(uri)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final m = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      try {
        await file.writeAsString(jsonEncode(m), flush: true);
      } catch (_) {}
      ArchLog.i('search', 'odesli resolved');
      return m;
    } catch (e) {
      ArchLog.w('search', 'odesli failed: $e');
      return null;
    }
  }
}
