import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'beat_grid.dart';
import 'musical_key.dart';

/// Decode to bounded mono 16-bit 11,025 Hz PCM — the analyzer diet
/// for both the beat grid and the key detector. Null when the file
/// can't be decoded. Scratch lives in cache, deleted right after.
Future<Uint8List?> decodeMono11k(String path) async {
  try {
    if (path.isEmpty || !await File(path).exists()) return null;
    final dir = await getTemporaryDirectory();
    final out = '${dir.path}/automix_${path.hashCode}.pcm';
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-v',
      'error',
      '-i',
      path,
      '-ac',
      '1',
      '-ar',
      '11025',
      '-f',
      's16le',
      '-t',
      '25',
      out,
    ]).timeout(const Duration(seconds: 60));
    final code = await session.getReturnCode();
    try {
      if (!ReturnCode.isSuccess(code)) return null;
      final bytes = await File(out).readAsBytes();
      if (bytes.isEmpty) return null;
      return bytes;
    } finally {
      try {
        await File(out).delete();
      } catch (_) {}
    }
  } catch (_) {
    return null;
  }
}

/// Beat grid in an isolate; the engine thread never feels it.
Future<AutoMixBeatGrid> analyzeGrid(Uint8List bytes) =>
    compute(_analyzeGrid, bytes);

AutoMixBeatGrid _analyzeGrid(Uint8List bytes) => analyzeAutomixPcm(bytes);

/// Musical key in an isolate. Null = unknown (silence, no consensus).
Future<DetectedKey?> analyzeKey(Uint8List bytes) =>
    compute(_analyzeKey, bytes);

DetectedKey? _analyzeKey(Uint8List bytes) => detectMusicalKey(bytes);

/// Decode + beat grid. Prefer [decodeMono11k] + the split analyzers
/// when both tempo and key are needed — one decode, not two.
Future<AutoMixBeatGrid?> analyzeFile(String path) async {
  final bytes = await decodeMono11k(path);
  if (bytes == null) return null;
  try {
    return await compute(_analyzeGrid, bytes);
  } catch (_) {
    return null;
  }
}
