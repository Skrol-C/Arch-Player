import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../metadata/metadata_providers.dart';
import 'data/folder_store.dart';
import 'data/library_repository.dart';

enum LibraryTab { songs, albums, artists }

enum SortOrder { title, artist, recent }

enum ViewMode { grid, list }

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) => ChannelLibrary());
final folderStoreProvider = Provider<FolderStore>((ref) => FolderStore());

/// All songs after picked-folder + exclude filtering.
final songsProvider = FutureProvider<List<Song>>((ref) async {
  ArchLog.i('library', 'scan started');
  final repo = ref.watch(libraryRepositoryProvider);
  final store = ref.watch(folderStoreProvider);
  final picked = await store.picked();
  final excluded = await store.excluded();
  final songs = await repo.loadSongs();
  final visible = songs.where((Song s) {
    if (picked.isNotEmpty &&
        !picked.any((p) => s.path.startsWith(p))) {
      return false;
    }
    return !excluded.contains(s.folderKey);
  }).toList();
  ArchLog.i('library', 'scan done (${visible.length}/${songs.length} shown)');
  // Warm metadata for the artists that matter most. Bounded, background.
  Future.microtask(() {
    final counts = <String, int>{};
    for (final s in visible) {
      counts[s.artist] = (counts[s.artist] ?? 0) + 1;
    }
    final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final svc = ref.read(metadataServiceProvider);
    for (final e in top.take(5)) {
      svc.enrich(e.key).then((_) {}, onError: (_) {});
    }
  });
  return visible;
});

final excludedProvider = FutureProvider<Set<String>>((ref) {
  return ref.watch(folderStoreProvider).excluded();
});

final pickedProvider = FutureProvider<Set<String>>((ref) {
  return ref.watch(folderStoreProvider).picked();
});

final suggestedFoldersProvider = FutureProvider<List<String>>((ref) {
  return ref.watch(libraryRepositoryProvider).suggestFolders();
});

final followedProvider = StateNotifierProvider<FollowedNotifier, Set<String>>((ref) {
  return FollowedNotifier(ref.watch(folderStoreProvider));
});

class FollowedNotifier extends StateNotifier<Set<String>> {
  final FolderStore _store;

  FollowedNotifier(this._store) : super({}) {
    _store.followedArtists().then((v) => state = v);
  }

  Future<void> toggle(String artist) async {
    final next = Set<String>.from(state);
    if (next.contains(artist)) {
      next.remove(artist);
    } else {
      next.add(artist);
    }
    state = next;
    await _store.setFollowed(artist, next.contains(artist));
  }
}

final libraryTabProvider = StateProvider<LibraryTab>((ref) => LibraryTab.songs);
final libraryQueryProvider = StateProvider<String>((ref) => '');
final librarySortProvider = StateProvider<SortOrder>((ref) => SortOrder.title);
final libraryViewProvider = StateProvider<ViewMode>((ref) => ViewMode.grid);

/// Search-filtered + sorted songs. In-memory — never re-scans.
final visibleSongsProvider = Provider<List<Song>>((ref) {
  final songs = ref.watch(songsProvider).value ?? [];
  final q = ref.watch(libraryQueryProvider).trim().toLowerCase();
  final sort = ref.watch(librarySortProvider);
  final filtered = q.isEmpty
      ? List<Song>.from(songs)
      : songs
          .where((s) =>
              s.title.toLowerCase().contains(q) ||
              s.artist.toLowerCase().contains(q) ||
              s.album.toLowerCase().contains(q))
          .toList();
  switch (sort) {
    case SortOrder.title:
      filtered.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    case SortOrder.artist:
      filtered.sort((a, b) {
        final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    case SortOrder.recent:
      filtered.sort((a, b) => b.year.compareTo(a.year));
  }
  return filtered;
});

/// Albums keyed on artist+album so same-name albums stay separate.
final albumsProvider = Provider<List<Album>>((ref) {
  final songs = ref.watch(visibleSongsProvider);
  final groups = <String, List<Song>>{};
  for (final s in songs) {
    groups.putIfAbsent('${s.artist.toLowerCase()}\u0000${s.album.toLowerCase()}', () => []).add(s);
  }
  final albums = groups.values
      .map((list) => Album(
            key: '${list.first.artist}\u0000${list.first.album}',
            title: list.first.album,
            artist: list.first.artist,
            songs: List<Song>.from(list)
              ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
          ))
      .toList();
  albums.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return albums;
});

final artistsProvider = Provider<List<ArtistEntry>>((ref) {
  final songs = ref.watch(visibleSongsProvider);
  final groups = <String, List<Song>>{};
  for (final s in songs) {
    groups.putIfAbsent(s.artist, () => []).add(s);
  }
  final artists =
      groups.entries.map((e) => ArtistEntry(name: e.key, songs: e.value)).toList();
  artists.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return artists;
});

final foldersProvider = Provider<List<MusicFolder>>((ref) {
  final songs = ref.watch(songsProvider).value ?? [];
  final groups = <String, List<Song>>{};
  for (final s in songs) {
    groups.putIfAbsent(s.folderKey, () => []).add(s);
  }
  final folders = groups.entries
      .map((e) => MusicFolder(key: e.key, label: e.value.first.folderLabel, count: e.value.length))
      .toList();
  folders.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return folders;
});

Future<void> toggleFolder(WidgetRef ref, String key, bool excluded) async {
  await ref.read(folderStoreProvider).setExcluded(key, excluded);
  ref.invalidate(songsProvider);
  ref.invalidate(excludedProvider);
}
