import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import 'data/playlist_store.dart';
import 'playlist_art.dart';

final playlistStoreProvider = Provider<PlaylistStore>((ref) => PlaylistStore());

/// Local playlists, system Favourites first. Persisted on every
/// mutation; song ids that no longer resolve are filtered at read
/// time (stale files drop silently, never crash).
final playlistsProvider =
    StateNotifierProvider<PlaylistsNotifier, List<Playlist>>(
      (ref) => PlaylistsNotifier(ref.watch(playlistStoreProvider)),
    );

class PlaylistsNotifier extends StateNotifier<List<Playlist>> {
  final PlaylistStore _store;

  PlaylistsNotifier(this._store) : super([]) {
    _store.load().then((v) {
      state = v;
    });
  }

  Future<void> _persist() => _store.save(state);

  /// Favourite star state for one song.
  bool isStarred(int songId) {
    for (final p in state) {
      if (p.id == Playlist.favouritesId) return p.songIds.contains(songId);
    }
    return false;
  }

  Future<void> toggleStar(int songId) async {
    final next = [
      for (final p in state)
        if (p.id == Playlist.favouritesId)
          p.copyWith(
            songIds: p.songIds.contains(songId)
                ? (List<int>.of(p.songIds)..remove(songId))
                : (List<int>.of(p.songIds)..insert(0, songId)),
            updatedMs: DateTime.now().millisecondsSinceEpoch,
          )
        else
          p,
    ];
    state = next;
    ArchLog.i('playlist', 'star toggle song=$songId');
    await _persist();
  }

  Future<Playlist> create(String name) async {
    final now = DateTime.now();
    final p = Playlist(
      id: 'pl_${now.millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'New Playlist' : name.trim(),
      songIds: const [],
      updatedMs: now.millisecondsSinceEpoch,
    );
    state = [...state, p];
    ArchLog.i('playlist', 'created "${p.name}"');
    await _persist();
    return p;
  }

  Future<void> rename(String id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    state = [
      for (final p in state)
        if (p.id == id && !p.isSystem)
          p.copyWith(name: clean, updatedMs: nowMs())
        else
          p,
    ];
    ArchLog.i('playlist', 'renamed $id');
    await _persist();
  }

  Future<void> delete(String id) async {
    if (id == Playlist.favouritesId) return;
    state = [for (final p in state) if (p.id != id) p];
    ArchLog.i('playlist', 'deleted $id');
    await _persist();
    await PlaylistStore.deleteArt(id);
  }

  /// Point a playlist at a persisted cover file (or clear it back
  /// to the auto-gradient with an empty path). Memoized bytes for a
  /// reused path are evicted first — same-path overwrites must
  /// never serve the previous image.
  Future<void> setCustomArt(String id, String path) async {
    if (id == Playlist.favouritesId) return;
    PlaylistArt.evictCover(path);
    state = [
      for (final p in state)
        if (p.id == id)
          p.copyWith(customArt: path, updatedMs: nowMs())
        else
          p,
    ];
    ArchLog.i('playlist', 'cover set $id');
    await _persist();
  }

  Future<void> clearCustomArt(String id) async {
    if (id == Playlist.favouritesId) return;
    final old = [
      for (final p in state)
        if (p.id == id) p.customArt,
    ].firstOrNull;
    await PlaylistStore.deleteArt(id);
    PlaylistArt.evictCover(old ?? '');
    state = [
      for (final p in state)
        if (p.id == id)
          p.copyWith(customArt: '', updatedMs: nowMs())
        else
          p,
    ];
    ArchLog.i('playlist', 'cover cleared $id');
    await _persist();
  }

  Future<void> addSong(String id, int songId) async {
    state = [
      for (final p in state)
        if (p.id == id && !p.songIds.contains(songId))
          p.copyWith(
            songIds: [...p.songIds, songId],
            updatedMs: nowMs(),
          )
        else
          p,
    ];
    await _persist();
  }

  Future<void> addSongs(String id, List<int> songIds) async {
    state = [
      for (final p in state)
        if (p.id == id)
          p.copyWith(
            songIds: [
              ...p.songIds,
              for (final s in songIds)
                if (!p.songIds.contains(s)) s,
            ],
            updatedMs: nowMs(),
          )
        else
          p,
    ];
    ArchLog.i('playlist', 'added ${songIds.length} to $id');
    await _persist();
  }

  Future<void> removeSong(String id, int songId) async {
    state = [
      for (final p in state)
        if (p.id == id)
          p.copyWith(
            songIds: [for (final s in p.songIds) if (s != songId) s],
            updatedMs: nowMs(),
          )
        else
          p,
    ];
    await _persist();
  }

  Future<void> reorder(String id, int oldIndex, int newIndex) async {
    for (final p in state) {
      if (p.id != id) continue;
      final list = List<int>.of(p.songIds);
      if (oldIndex < 0 ||
          newIndex < 0 ||
          oldIndex >= list.length ||
          newIndex > list.length) {
        return;
      }
      // Indices arrive adjusted (drop target already accounts for the
      // removed item): plain remove + insert.
      final s = list.removeAt(oldIndex);
      list.insert(newIndex.clamp(0, list.length), s);
      state = [
        for (final q in state)
          if (q.id == id) q.copyWith(songIds: list, updatedMs: nowMs()) else q,
      ];
      ArchLog.i('playlist', 'reorder $id $oldIndex -> $newIndex');
      await _persist();
      return;
    }
  }

  static int nowMs() => DateTime.now().millisecondsSinceEpoch;
}

/// Resolve a playlist's ids against the live library. Missing files
/// filter out here so the detail page never renders a dead row.
List<Song> playlistSongs(Playlist p, List<Song> all) {
  final byId = {for (final s in all) s.id: s};
  return [for (final id in p.songIds) if (byId[id] != null) byId[id]!];
}

/// "Updated 2w ago" for detail headers. Quiet, relative, honest.
String updatedAgo(int ms) {
  final d = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(ms),
  );
  if (d.inMinutes < 1) return 'Updated just now';
  if (d.inHours < 1) return 'Updated ${d.inMinutes}m ago';
  if (d.inDays < 1) return 'Updated ${d.inHours}h ago';
  if (d.inDays < 7) return 'Updated ${d.inDays}d ago';
  if (d.inDays < 30) return 'Updated ${d.inDays ~/ 7}w ago';
  if (d.inDays < 365) return 'Updated ${d.inDays ~/ 30}mo ago';
  return 'Updated ${d.inDays ~/ 365}y ago';
}
