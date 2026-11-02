library;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';

/// On-device home for the Kokoro fp32 English model. Downloaded
/// once to app files (never cache: the OS may evict cache and a
/// 305 MB re-download is not a shrug), removable from Settings.

class ModelStore {
  static const modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'tts-models/kokoro-en-v0_19.tar.bz2';

  /// Files we keep from the tarball, tarball member to local name.
  static const _wanted = {
    'model.onnx': 'model.onnx',
    'voices.bin': 'voices.bin',
    'tokens.txt': 'tokens.txt',
  };

  static const _lexicons = [
    'lexicon-us-en.txt',
    'lexicon-custom.txt',
  ];

  static Future<Directory> modelDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/archfm/kokoro');
  }

  static Future<bool> isInstalled() async {
    final dir = await modelDir();
    for (final name in [..._wanted.values, ..._lexicons]) {
      final f = File('${dir.path}/$name');
      if (!f.existsSync() || f.lengthSync() <= 0) return false;
    }
    return true;
  }

  /// Stream the tarball to disk with progress. Returns false on
  /// cancel or any failure, cleaning up the partial file.
  static Future<bool> download({
    required void Function(double progress) onProgress,
    required bool Function() isCancelled,
  }) async {
    final dir = await modelDir();
    await dir.create(recursive: true);
    final part = File('${dir.path}/model.tar.bz2.part');
    final done = File('${dir.path}/model.tar.bz2');
    final client = http.Client();
    try {
      final resp = await client.send(
        http.Request('GET', Uri.parse(modelUrl)),
      );
      final total = resp.contentLength ?? 0;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in resp.stream) {
          if (isCancelled()) {
            await sink.close();
            if (part.existsSync()) part.deleteSync();
            return false;
          }
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(got / total);
        }
      } finally {
        await sink.close();
      }
      if (part.lengthSync() <= 0) return false;
      if (done.existsSync()) done.deleteSync();
      part.renameSync(done.path);
      return true;
    } catch (e) {
      ArchLog.w('archfm', 'model download failed: $e');
      if (part.existsSync()) {
        try {
          part.deleteSync();
        } catch (_) {}
      }
      return false;
    } finally {
      client.close();
    }
  }

  /// Extract the three model files with a manual tar walk over a
  /// lazy bzip2 stream: bounded memory (64 KB buffer) instead of
  /// holding 300 MB in RAM. Skips anything not in [_wanted].
  static Future<bool> extract() async {
    final dir = await modelDir();
    final archive = File('${dir.path}/model.tar.bz2');
    if (!archive.existsSync()) return false;
    final input = InputFileStream(archive.path);
    try {
      final decoded = BZip2Decoder().decodeLazy(input);
      final found = <String>{};
      while (true) {
        final header = _readExactly(decoded, 512);
        if (header == null) break;
        if (header.every((b) => b == 0)) break;
        final name = String.fromCharCodes(
          header.sublist(0, 100),
        ).split('\x00').first;
        final sizeOct = String.fromCharCodes(
          header.sublist(124, 136),
        ).split('\x00').first.trim();
        if (sizeOct.isEmpty) break;
        final size = int.parse(sizeOct, radix: 8);
        final base = name.split('/').last;
        final target = _wanted[base];
        if (target != null && size > 0) {
          final out = File('${dir.path}/$target').openWrite();
          try {
            var remaining = size;
            while (remaining > 0) {
              final chunk = decoded.readBytes(
                remaining > 65536 ? 65536 : remaining,
              );
              if (chunk.length == 0) break;
              out.add(chunk.toUint8List());
              remaining -= chunk.length;
            }
          } finally {
            await out.close();
          }
          found.add(base);
          _skipPad(decoded, size);
        } else {
          _skipFully(
            decoded,
            size > 0 ? ((size + 511) ~/ 512) * 512 : 0,
          );
        }
      }
      return _wanted.keys.every(found.contains);
    } catch (e) {
      ArchLog.w('archfm', 'model extract failed: $e');
      return false;
    } finally {
      input.close();
    }
  }

  /// Copy the bundled lexicons (stock plus house additions) next
  /// to the model. Assets keep this offline-safe: no fragile
  /// third-party raw URL at runtime.
  static Future<bool> installLexicons() async {
    final dir = await modelDir();
    try {
      for (final name in _lexicons) {
        final data = await rootBundle.load('assets/kokoro/$name');
        await File(
          '${dir.path}/$name',
        ).writeAsBytes(data.buffer.asUint8List());
      }
      return true;
    } catch (e) {
      ArchLog.w('archfm', 'lexicon install failed: $e');
      return false;
    }
  }

  static Future<void> remove() async {
    final dir = await modelDir();
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        ArchLog.w('archfm', 'model remove failed: $e');
      }
    }
  }

  static Uint8List? _readExactly(InputStream s, int n) {
    final out = <int>[];
    while (out.length < n) {
      final chunk = s.readBytes(n - out.length);
      if (chunk.length == 0) return null;
      out.addAll(chunk.toUint8List());
    }
    return Uint8List.fromList(out);
  }

  static void _skipFully(InputStream s, int n) {
    var remaining = n;
    while (remaining > 0) {
      final chunk = s.readBytes(remaining > 65536 ? 65536 : remaining);
      if (chunk.length == 0) break;
      remaining -= chunk.length;
    }
  }

  static void _skipPad(InputStream s, int size) {
    final pad = (512 - (size % 512)) % 512;
    if (pad > 0) _skipFully(s, pad);
  }
}
