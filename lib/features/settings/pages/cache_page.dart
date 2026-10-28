import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/log.dart';
import '../../metadata/metadata_providers.dart';
import '../widgets/setting_bits.dart';

/// Cache: real numbers, per-bucket clearing, one global sweep.
/// Image memory clears instantly, artwork and metadata buckets clear
/// from disk and re-derive on demand. Nothing owned is ever deleted.
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
    var lyricBytes = 0;
    var analysisBytes = 0;
    var artistBytes = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      artBytes += await _dirSize(Directory('${dir.path}/artwork'));
      artBytes += await _dirSize(Directory('${dir.path}/art'));
      final sizes = await ref
          .read(metadataServiceProvider)
          .cacheSizes();
      lyricBytes = sizes['lyrics'] ?? 0;
      analysisBytes = sizes['analysis'] ?? 0;
      artistBytes = sizes['artists'] ?? 0;
    } catch (e) {
      ArchLog.w('settings', 'cache measure failed: $e');
    }
    return _CacheInfo(
      imageCount: img.liveImageCount + img.currentSize,
      imageBytes: img.currentSizeBytes,
      artBytes: artBytes,
      lyricBytes: lyricBytes,
      analysisBytes: analysisBytes,
      artistBytes: artistBytes,
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

  Future<void> _clearAll() async {
    HapticFeedback.mediumImpact();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final name in ['artwork', 'art']) {
        final d = Directory('${dir.path}/$name');
        if (await d.exists()) await d.delete(recursive: true);
      }
      final svc = ref.read(metadataServiceProvider);
      await svc.clearCacheBucket('lyrics');
      await svc.clearCacheBucket('analysis');
      await svc.clearCacheBucket('artists');
    } catch (e) {
      ArchLog.w('settings', 'cache clear-all failed: $e');
    }
    ArchLog.i('settings', 'all caches cleared');
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All caches cleared')),
      );
    }
  }

  Future<void> _clearImages() async {
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

  Future<void> _clearArt() async {
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Artwork cache cleared')),
      );
    }
  }

  Future<void> _clearBucket(String bucket, String label) async {
    HapticFeedback.selectionClick();
    try {
      final freed = await ref
          .read(metadataServiceProvider)
          .clearCacheBucket(bucket);
      ArchLog.i('settings', '$label cache cleared (${_mb(freed)})');
    } catch (e) {
      ArchLog.w('settings', '$label clear failed: $e');
    }
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label cache cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'cache settings open');
    final scheme = Theme.of(context).colorScheme;
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
          final total =
              info.imageBytes + info.artBytes + info.lyricBytes +
              info.analysisBytes +
              info.artistBytes;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              Material(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _mb(total),
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              'across image memory, artwork files, lyrics, analysis and artist metadata',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 13,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        onPressed: _refresh,
                        tooltip: 'Refresh stats',
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.surfaceContainerHighest,
                          foregroundColor: scheme.onSurface,
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _clearAll,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFC3C44),
                  ),
                  child: const Text('Clear all caches'),
                ),
              ),
              SettingGroup(
                title: 'Buckets',
                children: [
                  _BucketRow(
                    icon: Icons.image_rounded,
                    title: 'Image memory',
                    subtitle:
                        '${info.imageCount} live · ${_mb(info.imageBytes)}',
                    onClear: _clearImages,
                  ),
                  _BucketRow(
                    icon: Icons.art_track_rounded,
                    title: 'Cover art files',
                    subtitle: _mb(info.artBytes),
                    onClear: _clearArt,
                  ),
                  _BucketRow(
                    icon: Icons.lyrics_rounded,
                    title: 'Lyrics cache',
                    subtitle: _mb(info.lyricBytes),
                    onClear: () => _clearBucket('lyrics', 'Lyrics'),
                  ),
                  _BucketRow(
                    icon: Icons.graphic_eq_rounded,
                    title: 'Audio analysis',
                    subtitle: _mb(info.analysisBytes),
                    onClear: () => _clearBucket('analysis', 'Analysis'),
                  ),
                  _BucketRow(
                    icon: Icons.person_rounded,
                    title: 'Artist metadata',
                    subtitle: _mb(info.artistBytes),
                    onClear: () => _clearBucket('artists', 'Artist metadata'),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                child: Text(
                  'Clearing re-fetches on demand. '
                  'Nothing you own is ever deleted, only re-derived copies.',
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
}

class _BucketRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onClear;

  const _BucketRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: const Color(0xFFFC3C44)),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
      trailing: TextButton(onPressed: onClear, child: const Text('Clear')),
    );
  }
}

class _CacheInfo {
  final int imageCount;
  final int imageBytes;
  final int artBytes;
  final int lyricBytes;
  final int analysisBytes;
  final int artistBytes;

  const _CacheInfo({
    required this.imageCount,
    required this.imageBytes,
    required this.artBytes,
    required this.lyricBytes,
    required this.analysisBytes,
    required this.artistBytes,
  });
}

String _mb(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
