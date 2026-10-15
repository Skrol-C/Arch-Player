import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';

/// Persistent Needle roots. Everything that must survive reboots,
/// reinstalls (-r keeps files), and OS cache eviction lives under
/// the app files dir - NEVER cache. Cache eviction wiped all 8
/// extensions + sessions mid-session; this is the fix.
Future<Directory> needleBaseDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/needle');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// One-time move from the old evictable cache home to [needleBaseDir].
/// Best-effort, runs once per launch; afterwards the old location
/// is ignored.
Future<void> migrateNeedleFromCache() async {
  try {
    final cache = await getApplicationCacheDirectory();
    final oldRoots = <String>[
      '${cache.path}/needle_extensions',
      '${cache.path}/needle_ext',
      '${cache.path}/needle_registry',
      '${cache.path}/needle_smoke',
      '${cache.path}/needle_chain',
    ];
    final fresh = await needleBaseDir();
    final mapping = <String, String>{
      'needle_extensions': 'extensions',
      'needle_ext': 'ext',
      'needle_registry': 'registry',
      'needle_smoke': 'smoke',
      'needle_chain': 'chain',
    };
    var moved = 0;
    for (final oldPath in oldRoots) {
      final old = Directory(oldPath);
      if (!await old.exists()) continue;
      final leaf = oldPath.split('/').last;
      final dest = Directory('${fresh.path}/${mapping[leaf] ?? leaf}');
      try {
        if (await dest.exists()) {
          // Merge: move children over, then clean.
          await for (final e in old.list()) {
            final name = e.path.split('/').last;
            final target = '${dest.path}/$name';
            try {
              if (e is Directory) {
                if (await Directory(target).exists()) {
                  await Directory(target).delete(recursive: true);
                }
                await e.rename(target);
              } else if (e is File) {
                if (await File(target).exists()) await File(target).delete();
                await e.rename(target);
              }
              moved++;
            } catch (_) {}
          }
          try {
            await old.delete(recursive: true);
          } catch (_) {}
        } else {
          await old.rename(dest.path);
          moved++;
        }
      } catch (_) {}
    }
    if (moved > 0) ArchLog.i('needle', 'migrated $moved legacy cache entries');
  } catch (e) {
    ArchLog.w('needle', 'cache migrate failed: $e');
  }
}
