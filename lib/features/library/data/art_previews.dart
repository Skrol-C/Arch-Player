import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/log.dart';
import 'embedded_art.dart';

/// File-art previews with a disk layer: the missing piece behind
/// every "cover gone after restart" report.
///
/// The old chain read covers three different ways per surface
/// (file walk in the player hero, MediaStore album art in rows and
/// the song hero, a 512px notification copy in the mini player) and
/// held them in memory only. Cold start = placeholder everywhere
/// until each surface finished its own slow read, and MediaStore
/// simply has no art for fresh pulls — so those surfaces stayed
/// blank no matter how long you waited.
///
/// This store is the single source every surface reads through:
/// - keyed by source path + source mtime, so a retagged file can
///   never serve yesterday's art (the key itself changes);
/// - on disk under app support (survives restarts AND cache
///   clears), so the second paint is instant forever;
/// - failures remembered with a 30s cooldown, never session
///   poison: a transient I/O miss retries on demand instead of
///   condemning the file until restart;
/// - bounded: memory LRU, disk entry + byte caps with sweeps.
///
/// Mtime comes from stat, which this sandbox has denied before. The
/// design never depends on it: a missing mtime keys as `unknown`
/// (fail-open read), while our own writes (pull, pencil retag) call
/// [refresh]/[invalidate] explicitly, so correctness never waits on
/// stat working.
abstract final class ArtPreviews {
  static const _version = 'v1';
  static const _memCap = 64;
  static const _diskMaxEntries = 300;
  static const _diskMaxBytes = 120 << 20;
  static const _failCooldown = Duration(seconds: 30);

  static final Map<String, String> _mem = {};
  static final List<String> _order = [];
  static final Map<String, Future<String?>> _inflight = {};
  static final Map<String, DateTime> _failed = {};
  static Future<Directory>? _dirFuture;

  /// Test-only directory override (path_provider has no implementation
  /// under `flutter test`). Production never sets this.
  @visibleForTesting
  static Directory? debugDirOverride;

  /// Test-only memory reset between cases.
  @visibleForTesting
  static void debugReset() {
    _mem.clear();
    _order.clear();
    _inflight.clear();
    _failed.clear();
    _dirFuture = null;
  }

  /// Disk preview path for [path], extracting on a miss. Null when
  /// the file carries no art or can't be read right now. Concurrent
  /// callers for one path share a single extraction.
  static Future<String?> previewFor(String path) {
    if (path.isEmpty) return Future.value();
    final hit = _mem[path];
    if (hit != null) {
      _order.remove(path);
      _order.add(path);
      return Future.value(hit);
    }
    final run = _inflight[path];
    if (run != null) return run;
    final fut = _resolve(path);
    _inflight[path] = fut;
    fut.whenComplete(() => _inflight.remove(path));
    return fut;
  }

  /// Fire-and-forget warmup (pull/retag paths).
  static void warm(String path) {
    if (path.isEmpty) return;
    unawaited(previewFor(path));
  }

  /// Drop everything known about [path] and re-extract now.
  /// Retag/pencil call this after writing: the mtime key changes
  /// anyway, but refresh makes the new art instant instead of
  /// next-paint.
  static Future<String?> refresh(String path) async {
    await invalidate(path);
    return previewFor(path);
  }

  /// Forget [path] (memory, cooldown, and every disk variant).
  static Future<void> invalidate(String path) async {
    if (path.isEmpty) return;
    _mem.remove(path);
    _order.remove(path);
    _failed.remove(path);
    try {
      final dir = await _dir();
      final prefix = '${_version}_${_hash(path)}_';
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split('/').last;
        if (!name.startsWith(prefix)) continue;
        try {
          await e.delete();
        } catch (_) {}
        try {
          await File('${e.path}.source').delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<String?> _resolve(String path) async {
    try {
      final mtime = await _mtimeOf(path);
      final dir = await _dir();
      final key = _keyFor(path, mtime);
      final file = File('${dir.path}/$key.jpg');
      if (await file.exists()) {
        if (await _sidecarOk(dir, key, path, mtime) &&
            await file.length() > 0) {
          _putMem(path, file.path);
          return file.path;
        }
        try {
          await file.delete();
        } catch (_) {}
      }
      final failedAt = _failed[path];
      if (failedAt != null &&
          DateTime.now().difference(failedAt) < _failCooldown) {
        return null;
      }
      final art = await compute(readEmbeddedArt, path);
      if (art == null || art.bytes.isEmpty) {
        _failed[path] = DateTime.now();
        ArchLog.i('art', 'preview: none embedded in $path');
        return null;
      }
      await file.writeAsBytes(art.bytes, flush: true);
      await _writeSidecar(dir, key, path, mtime);
      _failed.remove(path);
      _putMem(path, file.path);
      unawaited(_sweep(dir));
      ArchLog.i('art', 'preview: wrote ${art.bytes.length}B for $path');
      return file.path;
    } catch (e) {
      ArchLog.w('art', 'preview failed for $path: $e');
      return null;
    }
  }

  static void _putMem(String path, String preview) {
    _mem[path] = preview;
    _order.remove(path);
    _order.add(path);
    while (_order.length > _memCap) {
      _mem.remove(_order.removeAt(0));
    }
  }

  static String _hash(String path) =>
      sha1.convert(utf8.encode(path)).toString();

  static String _keyFor(String path, int? mtime) =>
      '${_version}_${_hash(path)}_${mtime?.toRadixString(16) ?? 'unknown'}';

  static Future<int?> _mtimeOf(String path) async {
    try {
      final s = await File(path).stat();
      if (s.type == FileSystemEntityType.notFound) return null;
      final ms = s.modified.millisecondsSinceEpoch;
      return ms > 0 ? ms : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _sidecarOk(
    Directory dir,
    String key,
    String path,
    int? mtime,
  ) async {
    try {
      final raw = await File('${dir.path}/$key.jpg.source').readAsString();
      final m = jsonDecode(raw) as Map;
      if ((m['path'] as String?) != path) return false;
      final sm = (m['mtime'] as num?)?.toInt();
      // Fail open: stat denied on both sides is not evidence.
      if (mtime == null || sm == null) return true;
      return sm == mtime;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _writeSidecar(
    Directory dir,
    String key,
    String path,
    int? mtime,
  ) async {
    try {
      await File('${dir.path}/$key.jpg.source')
          .writeAsString(jsonEncode({'path': path, 'mtime': mtime}));
    } catch (_) {}
  }

  static Future<Directory> _dir() {
    if (debugDirOverride != null) return Future.value(debugDirOverride!);
    return _dirFuture ??= () async {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/file_art');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }();
  }

  static Future<void> _sweep(Directory dir) async {
    try {
      final files = <File>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.jpg')) continue;
        try {
          total += await e.length();
          files.add(e);
        } catch (_) {}
      }
      if (files.length <= _diskMaxEntries && total <= _diskMaxBytes) return;
      final mtimes = <String, DateTime>{};
      for (final f in files) {
        try {
          mtimes[f.path] = (await f.stat()).modified;
        } catch (_) {
          mtimes[f.path] = DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
      files.sort((a, b) => mtimes[a.path]!.compareTo(mtimes[b.path]!));
      var remaining = files.length;
      for (final f in files) {
        if (remaining <= _diskMaxEntries && total <= _diskMaxBytes) break;
        // Never sweep a live preview out from under a paint.
        if (_mem.containsValue(f.path)) continue;
        try {
          total -= await f.length();
          await f.delete();
          await File('${f.path}.source').delete();
          remaining--;
        } catch (_) {}
      }
      ArchLog.i('art', 'preview sweep done');
    } catch (_) {}
  }
}
