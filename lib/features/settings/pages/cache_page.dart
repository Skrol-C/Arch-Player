import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/log.dart';
import '../widgets/setting_bits.dart';

/// Cache: real numbers, real clearing. Image memory cache via the
/// framework, artwork files under app storage, and the log file.
/// each row shows its size and frees it on tap.
class CachePage extends ConsumerStatefulWidget {
  const CachePage({super.key});

  @override
  ConsumerState<CachePage> createState() => _CachePageState();
}

class _CachePageState extends ConsumerState<CachePage> {
  Future<_CacheInfo>? _info;

  @override
  void initState() {
    super.initState();
    _info = _measure();
  }

  Future<_CacheInfo> _measure() async {
    final img = PaintingBinding.instance.imageCache;
    var artBytes = 0;
    var logBytes = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      artBytes += await _dirSize(Directory('${dir.path}/artwork'));
      artBytes += await _dirSize(Directory('${dir.path}/art'));
      final log = File('${dir.path}/arch.log');
      if (await log.exists()) logBytes = await log.length();
    } catch (e) {
      ArchLog.w('settings', 'cache measure failed: $e');
    }
    return _CacheInfo(
      imageCount: img.liveImageCount + img.currentSize,
      imageBytes: img.currentSizeBytes,
      artBytes: artBytes,
      logBytes: logBytes,
    );
  }

  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  void _refresh() => setState(() => _info = _measure());

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'cache settings open');
    return Scaffold(
      appBar: AppBar(title: const Text('Cache')),
      body: FutureBuilder<_CacheInfo>(
        future: _info,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [SettingState.loading('Measuring…')],
            );
          }
          if (snap.hasError || !snap.hasData) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                SettingState.error(
                  'Could not measure caches.',
                  retry: _refresh,
                ),
              ],
            );
          }
          final info = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              SettingGroup(
                title: 'Storage',
                children: [
                  SettingRow(
                    icon: Icons.image_rounded,
                    title: 'Image memory',
                    subtitle:
                        '${info.imageCount} live · ${_mb(info.imageBytes)}',
                    trailing: TextButton(
                      onPressed: () => _clearImages(info),
                      child: const Text('Clear'),
                    ),
                  ),
                  SettingRow(
                    icon: Icons.art_track_rounded,
                    title: 'Artwork files',
                    subtitle: _mb(info.artBytes),
                    trailing: TextButton(
                      onPressed: () => _clearArt(info),
                      child: const Text('Clear'),
                    ),
                  ),
                  SettingRow(
                    icon: Icons.receipt_long_rounded,
                    title: 'Log file',
                    subtitle: _mb(info.logBytes),
                    trailing: TextButton(
                      onPressed: _shareLog,
                      child: const Text('Share'),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(
                  'Clearing artwork re-fetches it on demand. '
                  'nothing you own is ever deleted, only re-derived copies.',
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _clearImages(_CacheInfo info) async {
    HapticFeedback.selectionClick();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    ArchLog.i('settings', 'image cache cleared');
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image cache cleared')),
      );
    }
  }

  Future<void> _clearArt(_CacheInfo info) async {
    HapticFeedback.selectionClick();
    var freed = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final name in ['artwork', 'art']) {
        final d = Directory('${dir.path}/$name');
        if (await d.exists()) {
          freed += await _dirSize(d);
          await d.delete(recursive: true);
        }
      }
      ArchLog.i('settings', 'artwork files cleared (${_mb(freed)})');
    } catch (e) {
      ArchLog.w('settings', 'artwork clear failed: $e');
    }
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Artwork cache cleared')));
    }
  }

  Future<void> _shareLog() async {
    HapticFeedback.selectionClick();
    try {
      final dir = await getApplicationDocumentsDirectory();
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile('${dir.path}/arch.log')],
          subject: 'Arch Player log',
        ),
      );
    } catch (e) {
      ArchLog.w('settings', 'log share failed: $e');
    }
  }
}

class _CacheInfo {
  final int imageCount;
  final int imageBytes;
  final int artBytes;
  final int logBytes;

  const _CacheInfo({
    required this.imageCount,
    required this.imageBytes,
    required this.artBytes,
    required this.logBytes,
  });
}

String _mb(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
