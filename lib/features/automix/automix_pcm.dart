import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'beat_grid.dart';

/// Decode + analyze one file to an [AutoMixBeatGrid]. Mono 16-bit
/// 11,025 Hz, first 25s only — the analyzer's native diet. Runs the
/// DSP in an isolate; the engine thread never feels it.
/// Null = undecodable or no reliable beat. Scratch PCM lives in
/// cache and is deleted right after analysis.
Future<AutoMixBeatGrid?> analyzeFile(String path) async {
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
      return await compute(_analyze, bytes);
    } finally {
      try {
        await File(out).delete();
      } catch (_) {}
    }
  } catch (_) {
    return null;
  }
}

AutoMixBeatGrid _analyze(Uint8List bytes) => analyzeAutomixPcm(bytes);
