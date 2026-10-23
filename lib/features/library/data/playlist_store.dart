import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/log.dart';

/// A local playlist: an ordered list of library song ids plus an
/// auto-gradient hue. Art is NEVER stored — the gradient derives from
/// the member tracks' cover art at render time (the `Yeah` rule), so
/// renames, reorders and art changes just work. A user-picked
/// [customArt] file overrides the gradient wherever set.
class Playlist {
  /// `favourites` = the system star playlist. Never deleted/renamed.
  static const favouritesId = 'favourites';

  final String id;
  final String name;
  final List<int> songIds;
  final int updatedMs;

  /// Absolute path of the user-picked cover file, or empty for the
  /// auto-gradient. Lives under app files, never cache.
  final String customArt;

  const Playlist({
    required this.id,
    required this.name,
    required this.songIds,
    required this.updatedMs,
    this.customArt = '',
  });

  bool get isSystem => id == favouritesId;
  bool get hasCustomArt => customArt.isNotEmpty;

  Playlist copyWith({
    String? name,
    List<int>? songIds,
    int? updatedMs,
    String? customArt,
  }) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      songIds: songIds ?? this.songIds,
      updatedMs: updatedMs ?? this.updatedMs,
      customArt: customArt ?? this.customArt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songIds': songIds,
    'updatedMs': updatedMs,
    if (customArt.isNotEmpty) 'customArt': customArt,
  };

  static Playlist? fromJson(Map<String, dynamic> j) {
    try {
      final id = (j['id'] ?? '').toString();
      final name = (j['name'] ?? '').toString();
      if (id.isEmpty || name.isEmpty) return null;
      final raw = j['songIds'];
      final art = (j['customArt'] ?? '').toString();
      final ids = <int>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is int) {
            ids.add(e);
          } else if (e is num) {
            ids.add(e.toInt());
          }
        }
      }
      final updated = j['updatedMs'];
      return Playlist(
        id: id,
        name: name,
        songIds: ids,
        updatedMs: updated is int
            ? updated
            : DateTime.now().millisecondsSinceEpoch,
        customArt: art,
      );
    } catch (_) {
      return null;
    }
  }
}

/// SharedPreferences-backed playlist list. App prefs, not cache:
/// evictable storage must never own the user's lists.
class PlaylistStore {
  static const _key = 'arch.playlists.v1';

  Future<List<Playlist>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) {
        final seeded = _seed();
        await save(seeded);
        return seeded;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) return _seed();
      final out = <Playlist>[];
      for (final e in decoded) {
        if (e is Map<String, dynamic>) {
          final p = Playlist.fromJson(e);
          if (p != null) out.add(p);
        } else if (e is Map) {
          final p = Playlist.fromJson(Map<String, dynamic>.from(e));
          if (p != null) out.add(p);
        }
      }
      // The system list always exists, even for upgraders.
      if (!out.any((p) => p.id == Playlist.favouritesId)) {
        out.insert(0, _favourites());
      }
      return out;
    } catch (e) {
      ArchLog.w('playlist', 'load failed: $e');
      return _seed();
    }
  }

  Future<void> save(List<Playlist> lists) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode([for (final p in lists) p.toJson()]),
      );
    } catch (e) {
      ArchLog.w('playlist', 'save failed: $e');
    }
  }

  List<Playlist> _seed() => [_favourites()];

  Playlist _favourites() => Playlist(
    id: Playlist.favouritesId,
    name: 'Favourite Songs',
    songIds: const [],
    updatedMs: DateTime.now().millisecondsSinceEpoch,
  );

  /// Persistent cover file for a playlist id. App files, never cache.
  static Future<File> artFile(String id) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/playlist_art');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$id.jpg');
  }

  /// Persist already-bounded art bytes, returning the file path.
  static Future<String> writeArt(String id, List<int> bytes) async {
    final f = await artFile(id);
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  static Future<void> deleteArt(String id) async {
    try {
      final f = await artFile(id);
      if (await f.exists()) await f.delete();
    } catch (e) {
      ArchLog.w('playlist', 'art delete failed: $e');
    }
  }
}
