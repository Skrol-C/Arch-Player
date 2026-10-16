import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import '../../core/log.dart';

/// MOV-key decryption (ported mechanism, MIT attribution to
/// SpotiFLAC-Mobile `ffmpeg_decryption.dart`: same command shape,
/// our own code). Encrypted proxy audio (Amazon et al) arrives as
/// cenc-wrapped MP4; `-decryption_key` with key candidates unlocks
/// it via stream copy (no re-encode).
Future<String?> decryptMovKey({
  required String inputPath,
  required String key,
  String inputFormat = 'mov',
  String? outputExtension,
}) async {
  final raw = key.trim();
  if (raw.isEmpty) return inputPath;
  final ext = _preferredExtension(inputPath, outputExtension);
  final demuxer = inputFormat.trim().isEmpty ? 'mov' : inputFormat.trim();
  for (final candidate in _keyCandidates(raw)) {
    final out = await _tryKey(inputPath, candidate, demuxer, ext);
    if (out != null) return out;
    // FLAC-first fallback (reference behavior): encrypted MOV may
    // carry a FLAC suffix; then MP4-forced fallback.
    if (ext == '.flac') {
      final m4a = await _tryKey(inputPath, candidate, demuxer, '.m4a');
      if (m4a != null) return m4a;
    }
    if (ext == '.flac' || ext == '.m4a') {
      final mp4 = await _tryKey(inputPath, candidate, demuxer, '.mp4',
          forceMov: true);
      if (mp4 != null) return mp4;
    }
  }
  ArchLog.w('needle', 'ffmpeg decrypt failed for $inputPath');
  return null;
}

List<String> _keyCandidates(String rawKey) {
  final out = <String>[];
  void add(String k) {
    final t = k.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  final trimmed = rawKey.trim();
  if (trimmed.isEmpty) return out;
  add(trimmed);
  final noPrefix = trimmed.toLowerCase().startsWith('0x')
      ? trimmed.substring(2)
      : trimmed;
  add(noPrefix);
  final compactHex = noPrefix.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (compactHex.isNotEmpty && compactHex.length.isEven) add(compactHex);
  try {
    final decoded = base64Decode(noPrefix.replaceAll(RegExp(r'\s+'), ''));
    if (decoded.isNotEmpty) {
      add(decoded.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    }
  } catch (_) {}
  return out;
}

String _preferredExtension(String inputPath, String? requested) {
  final r = (requested ?? '').trim();
  if (r.isNotEmpty) return r.startsWith('.') ? r : '.$r';
  final low = inputPath.toLowerCase();
  for (final e in ['.mp3', '.opus', '.mp4']) {
    if (low.endsWith(e)) return e;
  }
  return '.flac';
}

Future<String?> _tryKey(
  String inputPath,
  String key,
  String demuxer,
  String extension, {
  bool forceMov = false,
}) async {
  final outPath =
      '${inputPath.substring(0, inputPath.lastIndexOf('.'))}_dec$extension';
  final map = extension == '.flac' ? '-map 0:a ' : '';
  final muxer = forceMov
      ? '-f mov '
      : outPath.toLowerCase().endsWith('.flac')
          ? '-f flac '
          : '';
  // Quotes protect spaces; key candidates are hex/base64 (safe).
  final cmd =
      '-v error -decryption_key "$key" -f $demuxer -i "$inputPath" $map-c copy $muxer"$outPath" -y';
  try {
    final session = await FFmpegKit.execute(cmd).timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        FFmpegKit.cancel();
        throw StateError('decrypt timed out');
      },
    );
    final code = await session.getReturnCode();
    final f = File(outPath);
    if (ReturnCode.isSuccess(code) &&
        await f.exists() &&
        await f.length() > 0) {
      try {
        await File(inputPath).delete();
      } catch (_) {}
      ArchLog.i('needle', 'ffmpeg decrypt ok: $extension');
      return outPath;
    }
  } catch (e) {
    ArchLog.w('needle', 'ffmpeg decrypt attempt failed: $e');
  }
  try {
    await File(outPath).delete();
  } catch (_) {}
  return null;
}
