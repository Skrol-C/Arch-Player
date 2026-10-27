import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import 'extension.dart';

/// Needle prefs: repos, download quality + folder. Engine-agnostic -
/// the sandbox consumes these when it lands; until then every row
/// here reads and writes real persisted state, never a mock.
class NeedlePrefs {
  /// Community registry, preloaded so compatible extensions work
  /// out of the box. Users add their own repos alongside it.
  /// SpotiFLAC-Extension renamed to Mornye-Extension (mornyeapp org);
  /// the old URL is kept below for stored-list migration only.
  static const defaultRegistry =
      'https://raw.githubusercontent.com/mornyeapp/Mornye-Extension/main/registry.json';

  static const legacyRegistry =
      'https://raw.githubusercontent.com/spotiflacapp/SpotiFLAC-Extension/main/registry.json';

  static const qualityLossless = 'lossless';
  static const qualityHigh = 'high';
  static const qualityNormal = 'normal';

  static const qualities = <String, String>{
    qualityLossless: 'Lossless FLAC',
    qualityHigh: 'High (320kbps)',
    qualityNormal: 'Normal (128kbps)',
  };
}

/// Display label for a stored quality id. Unknown ids echo back.
abstract final class NeedleQualitiesLabel {
  static String of(String id) =>
      NeedlePrefs.qualities[id] ?? (id.isEmpty ? '' : id);
}

final repoUrlsProvider = NotifierProvider<RepoUrlsNotifier, List<String>>(
  RepoUrlsNotifier.new,
);

class RepoUrlsNotifier extends Notifier<List<String>> {
  static const _key = 'arch.repos';

  @override
  List<String> build() {
    _sync();
    return const [NeedlePrefs.defaultRegistry];
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_key);
    if (stored == null) return;
    // Pre-rename lists point at the dead SpotiFLAC URL: swap them
    // forward (deduped) and persist, so the community repo heals
    // itself on next launch without a reinstall.
    final migrated = <String>[];
    var changed = false;
    for (final u in stored) {
      final v =
          u == NeedlePrefs.legacyRegistry ? NeedlePrefs.defaultRegistry : u;
      if (v != u) changed = true;
      if (!migrated.contains(v)) migrated.add(v);
    }
    state = List<String>.from(migrated);
    if (changed) {
      await prefs.setStringList(_key, migrated);
      ArchLog.i('needle', 'migrated community registry to Mornye');
    }
  }

  Future<void> add(String url) async {
    final v = url.trim();
    if (v.isEmpty || state.contains(v)) return;
    state = [...state, v];
    (await SharedPreferences.getInstance()).setStringList(_key, state);
  }

  Future<void> remove(String url) async {
    state = state.where((e) => e != url).toList();
    (await SharedPreferences.getInstance()).setStringList(_key, state);
  }

  Future<void> resetDefault() async {
    state = const [NeedlePrefs.defaultRegistry];
    (await SharedPreferences.getInstance()).setStringList(_key, state);
  }
}

final downloadQualityProvider =
    NotifierProvider<DownloadQualityNotifier, String>(
      DownloadQualityNotifier.new,
    );

class DownloadQualityNotifier extends Notifier<String> {
  static const _key = 'arch.dlQuality';

  @override
  String build() {
    _sync();
    return NeedlePrefs.qualityLossless;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (v != null && NeedlePrefs.qualities.containsKey(v)) state = v;
  }

  Future<void> set(String v) async {
    if (!NeedlePrefs.qualities.containsKey(v)) return;
    state = v;
    (await SharedPreferences.getInstance()).setString(_key, v);
  }
}

final downloadDirProvider = NotifierProvider<DownloadDirNotifier, String>(
  DownloadDirNotifier.new,
);

/// Needle library root under shared Music (default `Needle`).
/// Pulls file into Songs/{Artist}, Albums/{Album - Artist},
/// Playlist/{Name} beneath it. Grandfathered pulls stay where
/// they landed; Doctor offers moves later.
final needleRootProvider =
    NotifierProvider<NeedleRootNotifier, String>(
      NeedleRootNotifier.new,
    );

class NeedleRootNotifier extends Notifier<String> {
  static const _key = 'arch.needleRoot';

  static String sanitizeSegment(String s) {
    var out = s.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '').replaceAll(
        RegExp(r'\s+'), ' ');
    if (out.isEmpty) return 'Unknown';
    if (out.length > 80) out = out.substring(0, 80).trim();
    return out.isEmpty ? 'Unknown' : out;
  }

  @override
  String build() {
    _sync();
    return 'Needle';
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final v = (prefs.getString(_key) ?? '').trim();
    if (v.isNotEmpty) state = v;
  }

  Future<void> set(String v) async {
    final clean = v
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final next = clean.isEmpty ? 'Needle' : clean;
    state = next;
    (await SharedPreferences.getInstance()).setString(_key, next);
  }
}

class DownloadDirNotifier extends Notifier<String> {
  static const _key = 'arch.dlDir';

  @override
  String build() {
    _sync();
    return '';
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_key) ?? '';
  }

  Future<void> set(String v) async {
    state = v;
    (await SharedPreferences.getInstance()).setString(_key, v);
  }
}

/// Installed extensions: real persisted records. The engine
/// slice fills these in on install/remove; enable/disable and
/// priority reorder work from day one against whatever is here.
final installedExtensionsProvider =
    NotifierProvider<InstalledExtensionsNotifier, List<InstalledExtension>>(
        InstalledExtensionsNotifier.new);

class InstalledExtensionsNotifier
    extends Notifier<List<InstalledExtension>> {
  static const _key = 'arch.extensions';

  @override
  List<InstalledExtension> build() {
    _sync();
    return const [];
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final list = decodeInstalledList(raw);
    list.sort((a, b) => a.priority.compareTo(b.priority));
    state = list;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key,
        '[${state.map((e) => _encode(e)).join(',')}]');
  }

  String _encode(InstalledExtension e) {
    String q(String s) =>
        '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    final roles = e.roles.map(q).join(',');
    final handlers = e.urlHandlers.map(q).join(',');
    return '{"id":${q(e.id)},"displayName":${q(e.displayName)},'
        '"version":${q(e.version)},"description":${q(e.description)},'
        '"roles":[$roles],"enabled":${e.enabled},"priority":${e.priority},'
        '"urlHandlers":[$handlers],'
        '"searchPlaceholder":${e.searchPlaceholder == null ? 'null' : q(e.searchPlaceholder!)},'
        '"searchIcon":${e.searchIcon == null ? 'null' : q(e.searchIcon!)},'
        '"searchPrimary":${e.searchPrimary}}';
  }

  /// Upsert after install: new entries land at the end (lowest
  /// priority); upgrades keep position and settings.
  Future<void> upsert(InstalledExtension e) async {
    final i = state.indexWhere((x) => x.id == e.id);
    if (i < 0) {
      state = [...state, e.copyWith(priority: state.length)];
    } else {
      state = [
        for (var j = 0; j < state.length; j++)
          if (j == i)
            e.copyWith(
                enabled: state[j].enabled, priority: state[j].priority)
          else
            state[j],
      ];
    }
    await _save();
  }

  Future<void> remove(String id) async {
    state = state.where((e) => e.id != id).toList();
    await _save();
  }

  Future<void> setEnabled(String id, bool on) async {
    state = [
      for (final e in state)
        if (e.id == id) e.copyWith(enabled: on) else e,
    ];
    await _save();
  }

  Future<void> move(String id, int dir) async {
    final ordered = List<InstalledExtension>.from(state)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final i = ordered.indexWhere((e) => e.id == id);
    final j = i + dir;
    if (i < 0 || j < 0 || j >= ordered.length) return;
    final tmp = ordered[i];
    ordered[i] = ordered[j];
    ordered[j] = tmp;
    state = [
      for (var k = 0; k < ordered.length; k++)
        ordered[k].copyWith(priority: k),
    ];
    await _save();
  }
}
