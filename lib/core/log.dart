import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// File logging from day one: Honor eats logcat, so the app keeps its own.
/// Pulled any time with:
///   adb shell run-as com.archstudios.arch_player cat app_flutter/arch.log
/// (debug builds) or via the app's documents dir on demand.
/// Rotates at 512KB, keeps the current + one spare. Never throws.
abstract final class ArchLog {
  static File? _file;
  static bool _ready = false;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/arch.log');
      if (await _file!.exists() && await _file!.length() > 512 * 1024) {
        final spare = File('${dir.path}/arch.log.1');
        if (await spare.exists()) await spare.delete();
        await _file!.rename(spare.path);
      }
      _ready = true;
      await _write('I', 'log', 'arch.log ready');
    } catch (_) {
      _ready = false;
    }
  }

  static void i(String tag, String msg) => _write('I', tag, msg);
  static void w(String tag, String msg) => _write('W', tag, msg);
  static void e(String tag, Object err, [StackTrace? stack]) =>
      _write('E', tag, '$err${stack == null ? '' : '\n$stack'}');

  static Future<void> _write(String level, String tag, String msg) async {
    final line = '${DateTime.now().toIso8601String()} $level/$tag: $msg';
    debugPrint(line);
    if (!_ready) return;
    try {
      await _file!.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// Absolute path for adb pull instructions. Null until init.
  static String? get path => _file?.path;
}
