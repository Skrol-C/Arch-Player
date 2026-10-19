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
      _write('I', 'log', 'arch.log ready');
    } catch (_) {
      _ready = false;
    }
  }

  static void i(String tag, String msg) => _write('I', tag, msg);
  static void w(String tag, String msg) => _write('W', tag, msg);
  static void e(String tag, Object err, [StackTrace? stack]) =>
      _write('E', tag, '$err${stack == null ? '' : '\n$stack'}');

  /// Serialized tail: concurrent async appends used to interleave
  /// mid-line (spliced timestamps, eaten lines), which made the
  /// player fall-through nearly undiagnosable. Every write now
  /// queues behind the last, always newline-terminated.
  static Future<void> _tail = Future.value();

  static void _write(String level, String tag, String msg) {
    final line = '${DateTime.now().toIso8601String()} $level/$tag: $msg\n';
    debugPrint(line);
    if (!_ready) return;
    _tail = _tail.then((_) async {
      try {
        await _file!.writeAsString(line, mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }

  /// Absolute path for adb pull instructions. Null until init.
  static String? get path => _file?.path;
}
