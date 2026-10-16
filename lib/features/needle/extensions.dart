import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import 'bridge/api.dart' as bridge;
import 'needle_core.dart';
import 'needle_dirs.dart';
import 'packages.dart';
import 'sandbox.dart';

/// Extension driver: load installed packages by id, list their
/// registered entries, call them with JSON args. Handles are Rust
/// integers; loading validates manifest + script, nothing executes
/// until a call. Priority ordering lives with callers (installed
/// list is already priority-sorted).
class ExtHandle {
  final String id;
  final int handle;
  const ExtHandle({required this.id, required this.handle});
}

/// Directories for one extension namespace: storage JSON + scoped
/// files, both under persistent app files (never cache - the OS
/// evicted all extensions from cache mid-session).
Future<({String storageDir, String filesDir})> extDirs(
    String namespace) async {
  final base = await needleBaseDir();
  return (
    storageDir: '${base.path}/ext/$namespace/store',
    filesDir: '${base.path}/ext/$namespace/files',
  );
}

/// Load an installed extension. Throws NeedleException on
/// missing/invalid packages.
Future<ExtHandle> loadExtension(String id) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  final dir = await extDirFor(id);
  if (dir == null) {
    throw NeedleException('not-installed', 'No package on disk: $id');
  }
  final dirs = await extDirs(id);
  late final String raw;
  try {
    raw = await bridge.needleExtLoad(
      extDir: dir,
      namespace: id,
      storageDir: dirs.storageDir,
      filesDir: dirs.filesDir,
    );
  } catch (e) {
    throw NeedleException('bridge-error', '$e');
  }
  final env = _envelope(raw, 'load');
  final handle = (env['handle'] as num?)?.toInt();
  if (handle == null || handle <= 0) {
    throw const NeedleException('load-failed', 'No handle issued');
  }
  // Resident settings: the Rust side calls initialize(config) on
  // every invocation (fresh runtime per call), reading this file.
  // Manifest defaults under user values, typed by schema.
  await _writeSettingsFile(id, dir, dirs.storageDir);
  return ExtHandle(id: id, handle: handle);
}

/// Merge manifest setting defaults with `arch.ext.<id>.<key>`
/// prefs into `<storage>/<id>/settings.json`. Best-effort: a
/// missing manifest or prefs only means defaults.
Future<void> _writeSettingsFile(
    String id, String extDir, String storageDir) async {
  try {
    final manifestRaw =
        await File('$extDir/manifest.json').readAsString();
    final manifest = jsonDecode(manifestRaw) as Map<String, dynamic>;
    final decls = (manifest['settings'] as List? ?? []);
    final prefs = await SharedPreferences.getInstance();
    final merged = <String, dynamic>{};
    for (final d in decls) {
      if (d is! Map) continue;
      final key = (d['key'] as String?) ?? '';
      if (key.isEmpty) continue;
      final type = (d['type'] as String?) ?? 'string';
      final def = d['default'];
      final raw = prefs.getString('arch.ext.$id.$key');
      dynamic value = def;
      if (raw != null) {
        value = switch (type) {
          'boolean' => raw == 'true',
          'number' => num.tryParse(raw) ?? def,
          _ => raw,
        };
      }
      if (value != null) merged[key] = value;
    }
    final target = Directory('$storageDir/$id');
    await target.create(recursive: true);
    await File('${target.path}/settings.json')
        .writeAsString(jsonEncode(merged));
  } catch (e) {
    ArchLog.w('needle', 'settings file skipped for $id: $e');
  }
}

/// List registered entry points without invoking anything.
Future<List<String>> extensionFunctions(int handle,
    {int timeoutMs = 5000}) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  late final String raw;
  try {
    raw = await bridge.needleExtFunctions(
        handle: BigInt.from(handle), timeoutMs: timeoutMs);
  } catch (e) {
    throw NeedleException('bridge-error', '$e');
  }
  final env = _envelope(raw, 'functions');
  final list = (env['value'] as List?) ?? [];
  return [for (final e in list) e.toString()];
}

/// Call a registered entry with JSON args. Maps and lists both
/// cross; lists spread positionally (the calling convention real
/// extensions are written against), anything else arrives as the
/// single argument. Real JS values cross in, results leave via
/// JSON.stringify.
Future<Map<String, dynamic>> callExtensionFn(
  int handle,
  String entry,
  dynamic args, {
  int timeoutMs = 15000,
}) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  late final String raw;
  try {
    raw = await bridge.needleExtCall(
      handle: BigInt.from(handle),
      entry: entry,
      argsJson: _encode(args),
      timeoutMs: timeoutMs,
    );
  } catch (e) {
    throw NeedleException('bridge-error', '$e');
  }
  final env = _envelope(raw, 'call');
  return env;
}

Map<String, dynamic> _envelope(String raw, String what) {
  Map<String, dynamic> env;
  try {
    env = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    throw const NeedleException('bad-envelope', 'Reply unparseable');
  }
  if (env['ok'] != true) {
    final err = (env['error'] as String?) ?? 'unknown';
    // The extension's own trace rides failures too (Rust includes
    // logs on both paths): last lines only, the device log stays
    // readable while provider issues stay diagnosable.
    final logs = env['logs'];
    if (logs is List && logs.isNotEmpty) {
      final tail = logs.length > 6 ? logs.sublist(logs.length - 6) : logs;
      ArchLog.w('needle', 'extension $what trace: ${tail.join(' | ')}');
    }
    ArchLog.w('needle', 'extension $what failed: $err');
    throw NeedleException('extension-error', err);
  }
  return env;
}

String _encode(dynamic args) {
  try {
    return jsonEncode(args);
  } catch (_) {
    throw const NeedleException('bad-args', 'Args not JSON-encodable');
  }
}
