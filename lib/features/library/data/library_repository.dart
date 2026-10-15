import 'package:flutter/services.dart';

import '../../../core/log.dart';
import '../../../core/models.dart';

/// Scan boundary: UI talks to [LibraryRepository], never to plugins.
/// Own MethodChannel scan (MediaStore + SAF trees) - no stale-plugin risk.
abstract class LibraryRepository {
  Future<List<Song>> loadSongs();
  Future<List<String>> suggestFolders();
}

class ChannelLibrary implements LibraryRepository {
  static const _channel = MethodChannel('arch.player/library');

  @override
  Future<List<Song>> loadSongs() async {
    ArchLog.i('scan', 'querySongs start');
    final raw = await _channel.invokeMethod<List>('querySongs');
    final out = <Song>[];
    if (raw != null) {
      for (final item in raw) {
        final m = Map<String, dynamic>.from(item as Map);
        final title = (m['title'] as String?) ?? '';
        final artist = (m['artist'] as String?) ?? '';
        final album = (m['album'] as String?) ?? '';
        final folder = (m['folder'] as String?) ?? 'Unknown folder';
        out.add(
          Song(
            id: (m['id'] as num?)?.toInt() ?? 0,
            uri: Uri.parse((m['uri'] as String?) ?? ''),
            title: title.isEmpty ? 'Unknown title' : title,
            artist: artist.isEmpty ? 'Unknown artist' : artist,
            album: album.isEmpty ? 'Unknown album' : album,
            albumId: (m['albumId'] as num?)?.toInt() ?? 0,
            duration: Duration(
              milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0,
            ),
            year: (m['year'] as num?)?.toInt() ?? 0,
            folderKey: 'media:$folder',
            folderLabel: folder,
            path: (m['path'] as String?) ?? '',
            addedSecs: (m['addedSecs'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }
    ArchLog.i('scan', 'querySongs done (${out.length})');
    return out;
  }

  @override
  Future<List<String>> suggestFolders() async {
    try {
      final raw = await _channel.invokeMethod<List>('suggestFolders');
      return raw?.map((e) => '$e').toList() ?? [];
    } catch (e) {
      ArchLog.w('scan', 'suggestFolders failed: $e');
      return [];
    }
  }

  /// Nudge MediaStore over one landed file (Needle pulls). The scan
  /// lands on its own time; callers re-query after a short delay.
  Future<bool> scanFile(String path) async {
    try {
      return await _channel.invokeMethod<bool>(
            'scanFile', {'path': path},
          ) ??
          false;
    } catch (e) {
      ArchLog.w('scan', 'scanFile failed: $e');
      return false;
    }
  }
}

/// Album art over the same channel, bucketed by display size.
/// small (512px) covers 3x density at every row, rail, grid, and card
/// size; large (1024px) serves the player hero. LRU-capped: unbounded
/// growth once starved Impeller textures until content painted black.
enum ArtBucket {
  small(512),
  large(1024);

  const ArtBucket(this.px);
  final int px;
}

class ArtCache {
  static const _channel = MethodChannel('arch.player/library');
  static const _cap = 60;
  static final Map<String, Uint8List?> _cache = {};
  static final List<String> _order = [];

  static Future<Uint8List?> of(
    int albumId, [
    ArtBucket bucket = ArtBucket.small,
  ]) async {
    if (albumId <= 0) return null;
    final key = '${bucket.px}:$albumId';
    if (_cache.containsKey(key)) {
      _order.remove(key);
      _order.add(key);
      return _cache[key];
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('loadArt', {
        'albumId': albumId,
        'targetPx': bucket.px,
      });
      _put(key, bytes);
      return bytes;
    } catch (e) {
      ArchLog.w('scan', 'loadArt($albumId, ${bucket.px}) failed: $e');
      _put(key, null);
      return null;
    }
  }

  static void _put(String key, Uint8List? bytes) {
    _cache[key] = bytes;
    _order.remove(key);
    _order.add(key);
    while (_order.length > _cap) {
      _cache.remove(_order.removeAt(0));
    }
  }
}
