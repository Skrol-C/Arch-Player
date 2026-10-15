import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import 'extension.dart';
import 'extensions.dart';
import 'ffmpeg_decrypt.dart';
import 'needle_core.dart';
import 'needle_store.dart';
import 'sandbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Track pull: metadata -> availability -> extension download ->
/// move -> MediaStore scan. One track, fully honestly reported.
/// Throws NeedleException with codes:
/// - `verify-required`: message is `auth_url=<url>`; the caller
///   opens the verify sheet, then retries the same pull.
/// - `unavailable`, `no-entry`, `download-failed`, `move-failed`.
class PulledTrack {
  final String path;
  final String extId;
  final String format;
  const PulledTrack(
      {required this.path, required this.extId, required this.format});
}

/// Scan a landed file into MediaStore (own channel). Best-effort:
/// the file is valid regardless; the library re-query picks it up.
Future<void> scanLandedFile(String path) async {
  try {
    const channel = MethodChannel('arch.player/library');
    await channel.invokeMethod<bool>('scanFile', {'path': path});
  } catch (e) {
    ArchLog.w('needle', 'scan file failed: $e');
  }
}

/// One-time move of pulls stranded in old homes (app-private
/// cache, external app dir) into shared Music via publish.
/// Best-effort; runs at the start of every pull.
Future<void> migrateLegacyPulls() async {
  try {
    final cache = await getApplicationCacheDirectory();
    final candidates = <Directory>[
      Directory('${cache.path}/music'),
      Directory('${cache.path}/needle_ext'),
      Directory('${cache.path}/needle_extensions'),
    ];
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        candidates.add(Directory('${ext.path}/Music'));
      }
    } catch (_) {}
    var moved = 0;
    for (final dir in candidates) {
      if (!await dir.exists()) continue;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split('/').last;
        if (name.isEmpty) continue;
        try {
          await _publishStaged(e.path, _stripExt(name), _extOf(name));
          moved++;
        } catch (_) {}
      }
    }
    if (moved > 0) ArchLog.i('needle', 'migrated $moved legacy pulls');
  } catch (e) {
    ArchLog.w('needle', 'legacy migrate failed: $e');
  }
}

String _stripExt(String name) {
  final i = name.lastIndexOf('.');
  return i > 0 ? name.substring(0, i) : name;
}

String _extOf(String name) {
  final i = name.lastIndexOf('.');
  return i > 0 ? name.substring(i + 1) : '';
}

String _sanitize(String s) {
  var out = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  if (out.isEmpty) out = 'Unknown';
  if (out.length > 80) out = out.substring(0, 80);
  return out;
}

/// Container sniff from magic bytes. Returns the extension to use,
/// or null when unknown (keep the provider's guess).
Future<String?> _sniffExtension(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final head = await f.openRead(0, 12).fold<List<int>>(
        [], (prev, chunk) => prev..addAll(chunk));
    if (head.length < 4) return null;
    // MP4/M4A: size + 'ftyp' at offset 4.
    if (head.length >= 8 &&
        head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70) {
      return 'm4a';
    }
    // FLAC: 'fLaC'.
    if (head[0] == 0x66 &&
        head[1] == 0x4C &&
        head[2] == 0x61 &&
        head[3] == 0x43) {
      return 'flac';
    }
    // MP3: ID3 tag or frame sync.
    if ((head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) ||
        (head[0] == 0xFF && (head[1] & 0xE0) == 0xE0)) {
      return 'mp3';
    }
    // Ogg (Vorbis/Opus).
    if (head[0] == 0x4F &&
        head[1] == 0x67 &&
        head[2] == 0x67 &&
        head[3] == 0x53) {
      return 'ogg';
    }
    // WAV: RIFF....WAVE.
    if (head.length >= 12 &&
        head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46 &&
        head[8] == 0x57 &&
        head[9] == 0x41 &&
        head[10] == 0x56 &&
        head[11] == 0x45) {
      return 'wav';
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Pull one track through a download provider. [isrc] may be empty
/// (name fallback inside the extension). [quality] is the prefs
/// tier ('lossless'/'high'/'normal'), mapped to provider ids.
Future<PulledTrack> pullTrack({
  required InstalledExtension provider,
  required String title,
  required String artist,
  String isrc = '',
  String? quality,
  String? album,
  int? durationMs,
}) async {
  if (!Needle.ready) {
    throw const NeedleException('bridge-down', 'Needle core unavailable');
  }
  final q = quality ?? NeedlePrefs.qualityLossless;
  final wantQuality = switch (q) {
    NeedlePrefs.qualityHigh => 'HIGH',
    NeedlePrefs.qualityNormal => 'NORMAL',
    _ => 'LOSSLESS',
  };
  final h = await loadExtension(provider.id);
  final fns = await extensionFunctions(h.handle);
  for (final need in ['checkAvailability', 'download']) {
    if (!fns.contains(need)) {
      throw NeedleException(
          'no-entry', 'No $need in ${provider.id}');
    }
  }
  // 1. Availability (also resolves the provider track id).
  final avail = await _callGuarded(
    h.handle,
    'checkAvailability',
    [isrc, title, artist],
    provider.id,
  );
  final availV = _value(avail);
  _throwIfVerify(availV, provider);
  if (availV is! Map || availV['available'] != true) {
    throw NeedleException('unavailable',
        'Not available via ${provider.displayName}');
  }
  final trackId = (availV['track_id'] ?? availV['trackId'] ?? '').toString();
  if (trackId.isEmpty) {
    throw const NeedleException('unavailable', 'No provider track id');
  }
  // 2. Stream info (format for the filename; tolerated when absent).
  var format = 'flac';
  if (fns.contains('getDownloadUrl')) {
    final info = await _callGuarded(
        h.handle, 'getDownloadUrl', [trackId, wantQuality], provider.id);
      final infoV = _value(info);
      if (infoV is Map) {
        _throwIfVerify(infoV, provider);
        final f = (infoV['format'] ?? '').toString().toLowerCase();
        if (f.isNotEmpty) format = f;
      }
  }
  // 3. Extension download into its sandbox (scoped file ops).
  final dirs = await extDirs(provider.id);
  final staging =
      '${dirs.filesDir}/pull/${DateTime.now().millisecondsSinceEpoch}.$format';
  ArchLog.i('needle',
      'pull via ${provider.id}: track=$trackId quality=$wantQuality');
  final dl = await _callGuarded(h.handle, 'download',
      [trackId, wantQuality, staging, null], provider.id);
  final dlV = _value(dl);
  _throwIfVerify(dlV, provider);
  if (dlV is! Map || dlV['success'] != true) {
    final shape = '$dlV';
    ArchLog.w('needle',
        'pull via ${provider.id} failed shape: ${shape.length > 400 ? shape.substring(0, 400) : shape}');
    final err = dlV is Map
        ? ((dlV['error'] ?? dlV['error_message'] ?? 'download failed')
            .toString())
        : 'download failed';
    throw NeedleException('download-failed', err);
  }
  final stagedPath =
      ((dlV['file_path'] ?? dlV['path'] ?? staging).toString());
  // 3b. Encrypted containers decrypt in place (Amazon et al return
  // a mov_key descriptor). Unencrypted files pass through.
  final readyPath = await _maybeDecrypt(stagedPath, dlV);
  // 4. Land in shared Music via MediaStore insert (own insert:
  // no permission needed, indexed immediately). App-specific
  // dirs are invisible to MediaStore, so staging there is only
  // ever a waypoint, never the destination.
  await migrateLegacyPulls();
  final landed = await _publishStaged(
    readyPath,
    '${_sanitize(artist)} - ${_sanitize(title)}',
    format,
  );
  ArchLog.i('needle', 'pulled ${provider.id}: $landed');
  return PulledTrack(path: landed, extId: provider.id, format: format);
}

/// Decrypt when the download result carries a key descriptor
/// (`decryption_key` or `decryption.{strategy,key,...}`). Returns
/// the playable path (possibly renamed by decrypt). Unencrypted
/// results pass through untouched.
Future<String> _maybeDecrypt(String stagedPath, dynamic dlV) async {
  if (dlV is! Map) return stagedPath;
  String key = '';
  String strategy = '';
  String inputFormat = 'mov';
  String? outputExt;
  final direct = (dlV['decryption_key'] ?? '').toString();
  if (direct.isNotEmpty) key = direct;
  final desc = dlV['decryption'];
  if (desc is Map) {
    strategy =
        (desc['strategy'] ?? dlV['strategy'] ?? '').toString();
    key = (desc['key'] ?? key).toString();
    inputFormat =
        (desc['input_format'] ?? desc['inputFormat'] ?? 'mov').toString();
    outputExt = (desc['output_extension'] ??
            desc['outputExtension'] ??
            dlV['output_extension'])
        ?.toString();
  }
  if (key.isEmpty) return stagedPath;
  if (strategy.isNotEmpty && strategy != 'ffmpeg.mov_key') {
    ArchLog.w('needle', 'unsupported decrypt strategy: $strategy');
    return stagedPath;
  }
  ArchLog.i('needle', 'decrypting mov_key container...');
  final out = await decryptMovKey(
    inputPath: stagedPath,
    key: key,
    inputFormat: inputFormat,
    outputExtension: outputExt,
  );
  if (out == null || out.isEmpty) {
    throw const NeedleException('download-failed', 'decrypt failed');
  }
  return out;
}

/// Publish one staged file: container-sniff the real extension,
/// optional user-folder copy, else MediaStore insert. Returns the
/// landed identifier (content URI or path). Throws NeedleException
/// when nothing lands.
Future<String> _publishStaged(
  String stagedPath,
  String baseName,
  String formatGuess,
) async {
  final staged = File(stagedPath);
  if (!await staged.exists()) {
    throw const NeedleException('download-failed', 'staged file missing');
  }
  var ext = formatGuess.toLowerCase();
  final sniffed = await _sniffExtension(stagedPath);
  if (sniffed != null) ext = sniffed;
  if (ext.isEmpty) ext = 'bin';
  final displayName = '$baseName.$ext';
  // A user-picked folder wins when it actually accepts the file
  // (scoped storage may refuse: then fall through to publish).
  final prefs = await SharedPreferences.getInstance();
  final configured = prefs.getString('arch.dlDir') ?? '';
  if (configured.isNotEmpty) {
    try {
      final dest = '$configured/$displayName';
      if (await File(dest).exists()) await File(dest).delete();
      await staged.copy(dest);
      await staged.delete();
      await scanLandedFile(dest);
      return dest;
    } catch (e) {
      ArchLog.w('needle', 'picked folder write failed, publishing: $e');
    }
  }
  const channel = MethodChannel('arch.player/library');
  final uri = await channel.invokeMethod<String>('publishAudio', {
    'srcPath': stagedPath,
    'displayName': displayName,
    'mimeType': _mimeFor(ext),
  });
  if (uri == null || uri.isEmpty) {
    throw const NeedleException('download-failed', 'publish failed');
  }
  try {
    await staged.delete();
  } catch (_) {}
  return uri;
}

String _mimeFor(String ext) {
  return switch (ext.toLowerCase()) {
    'm4a' || 'mp4' => 'audio/mp4',
    'flac' => 'audio/flac',
    'mp3' => 'audio/mpeg',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    _ => 'audio/mpeg',
  };
}

/// Extension call with verify challenges mapped to a typed error.
/// A `VERIFY_REQUIRED|<url>` message becomes `verify-required`
/// with `auth_url=<url>`; everything else rethrows untouched.
/// Failures log the extension's own trace (last lines) so the
/// device log alone diagnoses provider issues.
Future<Map<String, dynamic>> _callGuarded(
  int handle,
  String entry,
  dynamic args,
  String extId, {
  int timeoutMs = 30000,
}) async {
  try {
    return await callExtensionFn(handle, entry, args, timeoutMs: timeoutMs);
  } on NeedleException catch (e) {
    final m = e.message;
    if (e.code == 'extension-error' && m.startsWith('VERIFY_REQUIRED|')) {
      throw NeedleException(
          'verify-required', 'auth_url=${m.substring('VERIFY_REQUIRED|'.length)}',
          );
    }
    rethrow;
  }
}

/// Verification challenges arrive three ways: thrown
/// (`VERIFY_REQUIRED|<url>`, mapped in [_callGuarded]), as data
/// (`{success:false, error_type: verification_required, auth_url}`),
/// or as a plain api_error whose message says verification is
/// required (Deezer's shape). All become `verify-required` with
/// `auth_url=<url>` (possibly empty - callers fall back to the
/// persisted pending file).
void _throwIfVerify(dynamic value, InstalledExtension provider) {
  if (value is! Map) return;
  final type = (value['error_type'] ?? '').toString();
  final text = [
    value['error_message'],
    value['error'],
    value['message'],
  ].whereType<String>().join(' ').toLowerCase();
  final needs = value['needsVerification'] == true ||
      type == 'verification_required' ||
      type == 'verify_required' ||
      text.contains('verif');
  if (!needs) return;
  final url = (value['auth_url'] ?? value['authUrl'] ?? '').toString();
  ArchLog.i('needle', 'verify required via ${provider.id}');
  throw NeedleException('verify-required', 'auth_url=$url');
}

dynamic _value(Map<String, dynamic> env) {
  var v = env['value'];
  // Doubly-encoded strings unwrap one layer (mirrors core).
  if (v is String) {
    try {
      return jsonDecode(v);
    } catch (_) {}
  }
  return v;
}
