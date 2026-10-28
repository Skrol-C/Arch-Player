import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';

/// Sideload install without plugins: the APK streams to the app cache
/// with progress, then the native side fires the system installer
/// through FileProvider. No store, no new packages.
class ApkInstaller {
  static const _channel = MethodChannel('arch.player/updater');

  /// Downloads [url] to cache, reporting 0..1 via [onProgress].
  /// Returns the staged file, or null when anything fails.
  static Future<File?> download(
    String url, {
    required String filename,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$filename');
      if (await file.exists()) {
        await file.delete();
      }
      final req = http.Request('GET', Uri.parse(url));
      final res = await http.Client().send(req);
      if (res.statusCode != 200) {
        ArchLog.w('updater', 'download HTTP ${res.statusCode}');
        return null;
      }
      final total = res.contentLength ?? -1;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in res.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      if (total > 0 && received != total) {
        ArchLog.w('updater', 'download truncated ($received/$total)');
        return null;
      }
      onProgress?.call(1.0);
      return file;
    } catch (e) {
      ArchLog.w('updater', 'download failed: $e');
      return null;
    }
  }

  /// Hands a staged APK to the system installer. False means nothing
  /// was handed over — the caller falls back to the release page.
  static Future<bool> install(File apk) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'installApk',
        {'path': apk.path},
      );
      return ok ?? false;
    } catch (e) {
      ArchLog.w('updater', 'install intent failed: $e');
      return false;
    }
  }
}
