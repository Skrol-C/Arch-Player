import 'package:flutter/services.dart';

import '../../../core/models.dart';

/// Scan boundary: UI talks to [LibraryRepository], never to a plugin.
/// Own MethodChannel scan (MediaStore) — no stale-plugin risk.
abstract class LibraryRepository {
  Future<List<Song>> loadSongs();
}

class ChannelLibrary implements LibraryRepository {
  static const _channel = MethodChannel('arch.player/library');

  @override
  Future<List<Song>> loadSongs() async {
    final raw = await _channel.invokeMethod<List>('querySongs');
    if (raw == null) return [];
    return [
      for (final item in raw)
        () {
          final m = Map<String, dynamic>.from(item as Map);
          final title = (m['title'] as String?) ?? '';
          final artist = (m['artist'] as String?) ?? '';
          final album = (m['album'] as String?) ?? '';
          final folder = (m['folder'] as String?) ?? 'Unknown folder';
          return Song(
            id: (m['id'] as num?)?.toInt() ?? 0,
            uri: Uri.parse((m['uri'] as String?) ?? ''),
            title: title.isEmpty ? 'Unknown title' : title,
            artist: artist.isEmpty ? 'Unknown artist' : artist,
            album: album.isEmpty ? 'Unknown album' : album,
            albumId: (m['albumId'] as num?)?.toInt() ?? 0,
            duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
            year: 0,
            folderKey: 'media:$folder',
            folderLabel: folder,
          );
        }(),
    ];
  }
}

/// Album art over the same channel. LRU-capped: unbounded growth was a
/// prime suspect in the blank-screen curse (memory pressure kills surfaces
/// while navigation keeps working).
class ArtCache {
  static const _channel = MethodChannel('arch.player/library');
  static const _cap = 100;
  static final Map<int, Uint8List?> _cache = {};
  static final List<int> _order = [];

  static Future<Uint8List?> of(int albumId) async {
    if (albumId <= 0) return null;
    if (_cache.containsKey(albumId)) {
      _order.remove(albumId);
      _order.add(albumId);
      return _cache[albumId];
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('loadArt', {'albumId': albumId});
      _put(albumId, bytes);
      return bytes;
    } catch (_) {
      _put(albumId, null);
      return null;
    }
  }

  static void _put(int albumId, Uint8List? bytes) {
    _cache[albumId] = bytes;
    _order.remove(albumId);
    _order.add(albumId);
    while (_order.length > _cap) {
      _cache.remove(_order.removeAt(0));
    }
  }
}
