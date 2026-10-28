import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';

/// Update source of truth. GitHub releases on Skrol-C/arch-player;
/// the repo does not need to exist for the rest of the app to work —
/// the check just fails silent and the manual button says so.
const updateRepoOwner = 'Skrol-C';
const updateRepoName = 'arch-player';

/// Later taps allowed per version before the prompt goes Update-only.
const updateMaxSkips = 5;

/// One newer release, fully resolved: what it is, whether it can be
/// skipped, and where the APK lives (empty when the release carries
/// no APK — the caller falls back to opening the release page).
class UpdateInfo {
  final String current;
  final String version;
  final String tag;
  final String notes;
  final String apkUrl;
  final String pageUrl;
  final bool breaking;
  final bool forced;
  final int skips;

  const UpdateInfo({
    required this.current,
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.pageUrl,
    required this.breaking,
    required this.forced,
    required this.skips,
  });
}

/// Numeric X.Y.Z compare. Garbage compares as 0.0.0 — a tag we cannot
/// parse never counts as newer.
@visibleForTesting
List<int> versionParts(String v) {
  final clean = v.trim().replaceAll(RegExp(r'^[vV]'), '').split('+').first;
  return [
    for (final p in clean.split('.'))
      int.tryParse(RegExp(r'\d+').firstMatch(p)?.group(0) ?? '') ?? 0,
    0,
    0,
  ].take(3).toList();
}

/// True when [latest] is strictly newer than [current].
@visibleForTesting
bool isNewer(String current, String latest) {
  final a = versionParts(current);
  final b = versionParts(latest);
  for (var i = 0; i < 3; i++) {
    if (b[i] != a[i]) return b[i] > a[i];
  }
  return false;
}

/// A major bump is a breaking release: it installs immediately,
/// no skips, no Later button.
bool isBreaking(String current, String latest) =>
    versionParts(current)[0] != versionParts(latest)[0];

/// Silent daily check, manual on demand. Returns null when there is
/// nothing newer, the network failed, or the repo is not public yet.
/// Never throws.
Future<UpdateInfo?> checkForUpdate({bool manual = false}) async {
  return (await checkForUpdateDetailed(manual: manual)).update;
}

/// Same check, but tells up-to-date apart from unreachable for the
/// manual button. `reached` is false when GitHub never answered.
Future<({UpdateInfo? update, bool reached})> checkForUpdateDetailed(
    {bool manual = false}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (!manual) {
      final last = prefs.getInt(_lastCheckKey) ?? 0;
      final dayMs = const Duration(days: 1).inMilliseconds;
      if (DateTime.now().millisecondsSinceEpoch - last < dayMs) {
        return (update: null, reached: true);
      }
    }
    final pkg = await PackageInfo.fromPlatform();
    final current = pkg.version;
    final res = await http
        .get(
          Uri.parse(
            'https://api.github.com/repos/$updateRepoOwner/$updateRepoName/releases/latest',
          ),
          headers: const {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 15));
    await prefs.setInt(
        _lastCheckKey, DateTime.now().millisecondsSinceEpoch);
    if (res.statusCode != 200) {
      ArchLog.i('updater', 'check: GitHub ${res.statusCode}');
      return (update: null, reached: false);
    }
    final body = jsonDecode(res.body) as Map;
    final tag = '${body['tag_name'] ?? ''}';
    final version = tag.replaceAll(RegExp(r'^[vV]'), '').split('+').first;
    if (version.isEmpty || !isNewer(current, version)) {
      return (update: null, reached: true);
    }
    String apkUrl = '';
    final assets = body['assets'] as List? ?? const [];
    for (final a in assets) {
      final name = '${(a as Map)['name'] ?? ''}';
      final url = '${a['browser_download_url'] ?? ''}';
      if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
        apkUrl = url;
        break;
      }
    }
    final breaking = isBreaking(current, version);
    final skips = prefs.getInt('$_skipsPrefix$version') ?? 0;
    ArchLog.i('updater',
        'update available: $current -> $version (breaking=$breaking, skips=$skips)');
    return (
      update: UpdateInfo(
        current: current,
        version: version,
        tag: tag,
        notes: '${body['body'] ?? ''}'.trim(),
        apkUrl: apkUrl,
        pageUrl: '${body['html_url'] ?? ''}',
        breaking: breaking,
        forced: breaking || skips >= updateMaxSkips,
        skips: skips,
      ),
      reached: true,
    );
  } catch (e) {
    ArchLog.i('updater', 'check failed: $e');
    return (update: null, reached: false);
  }
}

/// One Later tap: counted against this version only. Installing (or a
/// newer release appearing) starts the count over by construction.
Future<void> recordUpdateSkip(String version) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_skipsPrefix$version';
    final next = (prefs.getInt(key) ?? 0) + 1;
    await prefs.setInt(key, next);
    ArchLog.i('updater', 'skipped $version ($next/$updateMaxSkips)');
  } catch (_) {}
}

const _lastCheckKey = 'arch.update.lastCheck';
const _skipsPrefix = 'arch.update.skips.';
