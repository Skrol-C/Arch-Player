import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/art_tone.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../metadata/metadata_providers.dart';
import 'data/folder_store.dart';
import 'data/history_store.dart';
import 'data/library_repository.dart';

enum LibraryTab { songs, albums, artists }

enum SortOrder { title, artist, recent }

enum ViewMode { grid, list }

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => ChannelLibrary(),
);
final folderStoreProvider = Provider<FolderStore>((ref) => FolderStore());
final historyStoreProvider = Provider<HistoryStore>((ref) => HistoryStore());

/// All songs after picked-folder + exclude filtering.
final songsProvider = FutureProvider<List<Song>>((ref) async {
  ArchLog.i('library', 'scan started');
  final repo = ref.watch(libraryRepositoryProvider);
  final store = ref.watch(folderStoreProvider);
  final picked = await store.picked();
  final excluded = await store.excluded();
  final songs = await repo.loadSongs();
  final visible = songs.where((Song s) {
    if (picked.isNotEmpty && !picked.any((p) => s.path.startsWith(p))) {
      return false;
    }
    return !excluded.contains(s.folderKey);
  }).toList();
  ArchLog.i('library', 'scan done (${visible.length}/${songs.length} shown)');
  // Warm metadata for the artists that matter most. Bounded, background.
  // Counts split collaborators individually so featured names warm too.
  Future.microtask(() {
    final counts = <String, int>{};
    for (final s in visible) {
      for (final name in splitArtists(s.artist)) {
        final key = name.toLowerCase();
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final top = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
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

final followedProvider = StateNotifierProvider<FollowedNotifier, Set<String>>((
  ref,
) {
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

/// Search-filtered + sorted songs. In-memory - never re-scans.
final visibleSongsProvider = Provider<List<Song>>((ref) {
  final songs = ref.watch(songsProvider).value ?? [];
  final q = ref.watch(libraryQueryProvider).trim().toLowerCase();
  final sort = ref.watch(librarySortProvider);
  final filtered = q.isEmpty
      ? List<Song>.from(songs)
      : songs
            .where(
              (s) =>
                  s.title.toLowerCase().contains(q) ||
                  s.artist.toLowerCase().contains(q) ||
                  s.album.toLowerCase().contains(q),
            )
            .toList();
  switch (sort) {
    case SortOrder.title:
      filtered.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    case SortOrder.artist:
      filtered.sort((a, b) {
        final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        return c != 0
            ? c
            : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    case SortOrder.recent:
      filtered.sort((a, b) => b.year.compareTo(a.year));
  }
  return filtered;
});

/// Albums grouped by title, merged by track fingerprint: one
/// collaboration album under varying artist tags reunites (same
/// tracks = same album), while genuinely different same-title
/// albums (disjoint tracks) stay separate. Deluxe/superset
/// editions merge upward on track overlap.
final albumsProvider = Provider<List<Album>>((ref) {
  final songs = ref.watch(visibleSongsProvider);
  final byTitle = <String, List<Song>>{};
  for (final s in songs) {
    byTitle.putIfAbsent(normTitle(s.album), () => []).add(s);
  }
  final albums = <Album>[];
  for (final entry in byTitle.values) {
    // Default-merge, split on evidence: songs sharing a normalized
    // title start as one album. They divide only when both track
    // sets AND artist sets are disjoint (genuinely different
    // same-title albums), or when known years disagree below.
    final parent = <int, int>{};
    int find(int x) {
      var r = x;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      return r;
    }

    final keys = <int, String>{};
    for (var i = 0; i < entry.length; i++) {
      parent[i] = i;
      keys[i] =
          '${normTitle(entry[i].title)}:${entry[i].duration.inSeconds ~/ 10}';
    }
    for (var i = 0; i < entry.length; i++) {
      for (var j = i + 1; j < entry.length; j++) {
        final sameTrack = keys[i] == keys[j];
        final sameHands = artistsOverlap(entry[i].artist, entry[j].artist);
        if (sameTrack || sameHands) {
          parent[find(i)] = find(j);
        }
      }
    }
    final merged = <int, List<Song>>{};
    for (var i = 0; i < entry.length; i++) {
      merged.putIfAbsent(find(i), () => []).add(entry[i]);
    }
    // Year split: one merged group holding distinct known years
    // divides per year (same-artist "Untitled" 1999 vs 2005).
    // Untagged songs ride with their track/artist kin, else the
    // largest year-group. Unknown years never force a split.
    final finalGroups = <List<Song>>[];
    for (final list in merged.values) {
      final years = list.map((s) => s.year).where((y) => y > 0).toSet();
      if (years.length <= 1) {
        finalGroups.add(list);
        continue;
      }
      final byYear = <int, List<Song>>{};
      final undated = <Song>[];
      for (final s in list) {
        if (s.year > 0) {
          byYear.putIfAbsent(s.year, () => []).add(s);
        } else {
          undated.add(s);
        }
      }
      for (final u in undated) {
        List<Song>? home;
        for (final g in byYear.values) {
          if (g.any(
            (s) =>
                normTitle(s.title) == normTitle(u.title) ||
                artistsOverlap(s.artist, u.artist),
          )) {
            home = g;
            break;
          }
        }
        home ??= byYear.values.reduce((a, b) => a.length >= b.length ? a : b);
        home.add(u);
      }
      finalGroups.addAll(byYear.values);
      ArchLog.i(
        'library',
        'album year-split: "${entry.first.album}" -> ${byYear.length} (${years.join(",")})',
      );
    }
    // Residue diagnostics: one title still holding multiple albums
    // names the remaining gap. Silent in the common case.
    if (finalGroups.length > 1) {
      final samples = [
        for (final list in finalGroups.take(3))
          '${list.length}tk:${normTitle(list.first.title)}',
      ].join(' | ');
      ArchLog.i(
        'library',
        'album split: "${entry.first.album}" -> ${finalGroups.length} [$samples]',
      );
    }
    for (final list in finalGroups) {
      list.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      albums.add(
        Album(
          key: '${normTitle(list.first.album)}\u0000${albumPrint(list)}',
          title: list.first.album,
          artist: list.first.artist,
          songs: list,
        ),
      );
    }
  }
  albums.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return albums;
});

/// Artists split on collaboration: "A feat. B" credits both pages.
/// Display name = most common raw segment; songs match in any slot.
final artistsProvider = Provider<List<ArtistEntry>>((ref) {
  final songs = ref.watch(visibleSongsProvider);
  final groups = <String, List<Song>>{};
  final display = <String, String>{};
  final counts = <String, Map<String, int>>{};
  for (final s in songs) {
    for (final name in splitArtists(s.artist)) {
      final key = name.toLowerCase();
      groups.putIfAbsent(key, () => []).add(s);
      display.putIfAbsent(key, () => name);
      final variants = counts.putIfAbsent(key, () => {});
      variants[name] = (variants[name] ?? 0) + 1;
    }
  }
  final artists = groups.entries.map((e) {
    final variants = counts[e.key]!;
    var label = display[e.key]!;
    var best = 0;
    for (final v in variants.entries) {
      if (v.value > best) {
        best = v.value;
        label = v.key;
      }
    }
    return ArtistEntry(name: label, songs: e.value);
  }).toList();
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
      .map(
        (e) => MusicFolder(
          key: e.key,
          label: e.value.first.folderLabel,
          count: e.value.length,
        ),
      )
      .toList();
  folders.sort(
    (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
  );
  return folders;
});

Future<void> toggleFolder(WidgetRef ref, String key, bool excluded) async {
  await ref.read(folderStoreProvider).setExcluded(key, excluded);
  ref.invalidate(songsProvider);
  ref.invalidate(excludedProvider);
}

/// Recently added to the device (MediaStore DATE_ADDED). Empty when the
/// scan carries no dates - the rail hides instead of lying.
final recentlyAddedProvider = Provider<List<Song>>((ref) {
  final songs = ref.watch(songsProvider).value ?? [];
  final dated = songs.where((s) => s.addedSecs > 0).toList()
    ..sort((a, b) => b.addedSecs.compareTo(a.addedSecs));
  return dated.take(12).toList();
});

/// Recently played, newest first. Empty until anything plays.
final listenAgainProvider = FutureProvider<List<Song>>((ref) async {
  final songs = ref.watch(songsProvider).value ?? [];
  if (songs.isEmpty) return [];
  final history = await ref.watch(historyStoreProvider).read();
  if (history.isEmpty) return [];
  final byId = {for (final s in songs) s.id: s};
  final entries = history.entries.where((e) => byId.containsKey(e.key)).toList()
    ..sort((a, b) => b.value.lastMs.compareTo(a.value.lastMs));
  return [for (final e in entries.take(10)) byId[e.key]!];
});

/// Album palette from ArtCache bytes already held for the cover -
/// zero extra I/O, session-memoized. Null until art (or bytes)
/// exist; callers hold the neutral wash meanwhile.
final albumPaletteProvider = FutureProvider.family<ArtPalette?, int>((
  ref,
  albumId,
) {
  if (albumId <= 0) return null;
  return ArtTone.paletteFromBytes(
    'art:$albumId',
    () => ArtCache.of(albumId, ArtBucket.large),
  );
});
