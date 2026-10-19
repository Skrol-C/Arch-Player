import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';

/// Profile picture: picked once via the system picker, copied into
/// app files (picker cache is evictable), path persisted. Home header
/// and profile both read this — one source, never drift.
final profilePicProvider =
    NotifierProvider<ProfilePicNotifier, String?>(ProfilePicNotifier.new);

class ProfilePicNotifier extends Notifier<String?> {
  static const _key = 'arch.profilePic';

  @override
  String? build() {
    _sync();
    return null;
  }

  Future<void> _sync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final p = prefs.getString(_key);
      if (p == null) return;
      if (await File(p).exists()) {
        state = p;
      } else {
        await prefs.remove(_key);
      }
    } catch (_) {}
  }

  /// System image picker, then copy into app files. No-op on cancel.
  Future<void> pick() async {
    String? src;
    try {
      final picked = await FilePickerPlatform.instance.pickFile(
        type: FileType.image,
      );
      src = picked?.path;
    } catch (e) {
      ArchLog.w('profile', 'avatar picker failed: $e');
      return;
    }
    if (src == null || src.isEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory('${dir.path}/profile');
      await folder.create(recursive: true);
      final rawExt = src.split('.').last.toLowerCase();
      const keep = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
      final ext = keep.contains(rawExt) ? rawExt : 'jpg';
      final out = File('${folder.path}/avatar.$ext');
      await File(src).copy(out.path);
      // Drop a stale avatar under a different extension.
      await for (final e in folder.list()) {
        if (e is File && e.path != out.path) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, out.path);
      state = out.path;
      ArchLog.i('profile', 'avatar set');
    } catch (e) {
      ArchLog.w('profile', 'avatar copy failed: $e');
    }
  }

  Future<void> clear() async {
    try {
      final p = state;
      if (p != null) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      state = null;
    } catch (_) {}
  }
}
