import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../library/data/history_store.dart';
import '../library/library_providers.dart';
import '../needle/extension.dart';
import '../needle/extensions.dart';
import '../needle/needle_core.dart';
import '../needle/needle_store.dart';

/// One tappable card: a library song, or a provider catalogue entry
/// (track/album/playlist/artist) from an extension home feed.
class FeedItem {
  final String id;
  final String uri;
  final String type;
  final String name;
  final String artists;
  final String coverUrl;
  final String providerId;
  final String providerName;
  final Song? song;

  const FeedItem({
    this.id = '',
    this.uri = '',
    this.type = 'track',
    required this.name,
    this.artists = '',
    this.coverUrl = '',
    this.providerId = '',
    this.providerName = '',
    this.song,
  });

  bool get isLocal => song != null;
}

/// One horizontal rail: local (listening-derived) or one provider
/// section straight off an extension `getHomeFeed` call.
class HomeRail {
  final String key;
  final String title;
  final String subtitle;
  final List<FeedItem> items;
  final String providerName;

  const HomeRail({
    required this.key,
    required this.title,
    this.subtitle = '',
    required this.items,
    this.providerName = '',
  });

  bool get isLocal => providerName.isEmpty;
}

/// Home feed: local rails first (instant, owned), then one rail per
/// extension section from every enabled extension that registers
/// `getHomeFeed`. One dead provider degrades to its absence, never
/// the feed. Extensions without the entry are skipped silently.
final homeFeedProvider = FutureProvider<List<HomeRail>>((ref) async {
  final songs = await ref.watch(songsProvider.future);
  final history = await ref.watch(historyStoreProvider).read();
  final rails = <HomeRail>[
    ..._localRails(songs, history),
    ...await _extensionRails(ref),
  ];
  return rails;
});

List<HomeRail> _localRails(
    List<Song> songs, Map<int, PlayRecord> history) {
  final rails = <HomeRail>[];
  if (songs.isEmpty) return rails;
  final byId = {for (final s in songs) s.id: s};
  final ranked = history.entries.toList()
    ..sort((a, b) => b.value.lastMs.compareTo(a.value.lastMs));
  final recent = [
    for (final e in ranked)
      if (byId.containsKey(e.key)) byId[e.key]!,
    // Twelve: the table pages in threes, uniform all the way.
  ].take(12).toList();
  if (recent.isNotEmpty) {
    rails.add(HomeRail(
      key: 'local-recent',
      title: 'Jump back in',
      subtitle: 'Recently played',
      items: [
        for (final s in recent)
          FeedItem(
            name: s.title,
            artists: s.artist,
            type: 'track',
            song: s,
          ),
      ],
    ));
  }
  final counts = <String, ({String name, int plays, Song cover})>{};
  for (final e in history.entries) {
    final s = byId[e.key];
    if (s == null || s.artist.trim().isEmpty) continue;
    // One play counts for every credited name: "A, B" and
    // "A feat. B" surface A and B as individuals, never as a
    // collaboration string. Exempt names stay whole upstream.
    for (final a in splitArtists(s.artist)) {
      final k = a.trim().toLowerCase();
      if (k.isEmpty || isUnknownSlot(a)) continue;
      final prev = counts[k];
      counts[k] = (
        name: a.trim(),
        plays: (prev?.plays ?? 0) + e.value.count,
        cover: prev?.cover ?? s,
      );
    }
  }
  final artists = topArtists(counts, count: 6);
  if (artists.isNotEmpty) {
    rails.add(HomeRail(
      key: 'local-artists',
      title: 'Your artists',
      subtitle: 'Most played',
      items: [
        for (final a in artists)
          FeedItem(
            name: a.name,
            type: 'artist',
            song: a.cover,
          ),
      ],
    ));
  }
  return rails;
}

/// Most recent plays by one artist, newest first — the fan-out list.
final artistRecentProvider =
    FutureProvider.family<List<Song>, String>((ref, name) async {
  final songs = await ref.watch(songsProvider.future);
  final history = await ref.watch(historyStoreProvider).read();
  final byId = {for (final s in songs) s.id: s};
  final key = name.trim().toLowerCase();
  final entries = [
    for (final e in history.entries)
      if (byId.containsKey(e.key) &&
          byId[e.key]!.artist.trim().toLowerCase() == key)
        e,
  ]..sort((a, b) => b.value.lastMs.compareTo(a.value.lastMs));
  return [
    for (final e in entries.take(5))
      if (byId.containsKey(e.key)) byId[e.key]!,
  ];
});

/// Ranked artist aggregates for rails and profile: most played first.
List<({String name, int plays, Song cover})> topArtists(
  Map<String, ({String name, int plays, Song cover})> counts, {
  int count = 6,
}) {
  final artists = counts.values.toList()
    ..sort((a, b) => b.plays.compareTo(a.plays));
  return artists.take(count).toList();
}

Future<List<HomeRail>> _extensionRails(Ref ref) async {
  if (!Needle.ready) return const [];
  final exts = [
    for (final e in ref.watch(installedExtensionsProvider))
      if (e.enabled) e,
  ]..sort((a, b) => a.priority.compareTo(b.priority));
  if (exts.isEmpty) return const [];
  final perExt = await Future.wait([
    for (final e in exts) _feedFor(e),
  ]);
  return [for (final rails in perExt) ...rails];
}

/// Curated home rails: provider id -> title fragments (lowercase
/// contains-match). Everything else is filtered out — Home shows
/// these shelves and nothing else. Tune from the log line below,
/// which prints every section title each provider actually serves.
const _curatedRails = <String, List<String>>{
  'spotify-web': ['popular artists', 'featured charts', 'new this week'],
  'amazon': ['hot albums', 'hot artist'],
};

Future<List<HomeRail>> _feedFor(InstalledExtension e) async {
  try {
    final h = await loadExtension(e.id);
    final fns = await extensionFunctions(h.handle, timeoutMs: 8000);
    if (!fns.contains('getHomeFeed')) return const [];
    final out = await callExtensionFn(h.handle, 'getHomeFeed', [],
        timeoutMs: 25000);
    final value = out['value'];
    if (value is! Map) {
      ArchLog.w('home', 'feed via ${e.id}: no value envelope');
      return const [];
    }
    if (value['success'] == false) {
      ArchLog.w('home', 'feed via ${e.id} rejected: ${value['error']}');
      return const [];
    }
    final sections = value['sections'];
    if (sections is! List) return const [];
    final allow = _curatedRails[e.id] ?? const <String>[];
    final seen = <String>[
      for (final s in sections)
        if (s is Map) (s['title'] ?? '').toString().trim(),
    ].where((t) => t.isNotEmpty).toList();
    ArchLog.i('home', 'sections via ${e.id}: ${seen.join(' | ')}');
    final rails = <HomeRail>[];
    for (final s in sections.take(30)) {
      if (s is! Map) continue;
      final title = (s['title'] ?? '').toString().trim();
      final items = s['items'];
      if (title.isEmpty ||
          items is! List ||
          !allow.any((k) => title.toLowerCase().contains(k))) {
        continue;
      }
      final feed = <FeedItem>[];
      for (final it in items.take(12)) {
        if (it is! Map) continue;
        final f = _feedItem(it, e);
        if (f != null) feed.add(f);
      }
      if (feed.isEmpty) continue;
      rails.add(HomeRail(
        key: '${e.id}:${(s['uri'] ?? title).toString()}',
        title: title,
        items: feed,
        providerName: e.displayName,
      ));
    }
    ArchLog.i('home', 'feed via ${e.id}: ${rails.length} rails');
    return rails;
  } catch (err) {
    ArchLog.w('home', 'feed via ${e.id} failed: $err');
    return const [];
  }
}

FeedItem? _feedItem(Map it, InstalledExtension e) {
  final name = (it['name'] ?? '').toString().trim();
  if (name.isEmpty) return null;
  var type = (it['type'] ?? 'track').toString().trim().toLowerCase();
  if (type == 'song') type = 'track';
  if (!const {'track', 'album', 'playlist', 'artist'}.contains(type)) {
    return null;
  }
  return FeedItem(
    id: (it['id'] ?? '').toString(),
    uri: (it['uri'] ?? '').toString(),
    type: type,
    name: name,
    artists: displayArtists(it['artists']),
    coverUrl: (it['cover_url'] ?? it['featured_cover_url'] ?? '').toString(),
    providerId: e.id,
    providerName: e.displayName,
  );
}

/// Reshuffle nonce: bumped by the deck's dice button. Added to the
/// daily seed so a re-deal never repeats the current layout. Any
/// non-zero nonce switches the deal from the stable daily cut to a
/// weighted lottery across the whole library.
final deckReshuffleProvider = StateProvider<int>((ref) => 0);

/// Fast local slice: deck + local rails. No network, resolves
/// immediately so Home paints before providers answer.
final homeLocalProvider =
    FutureProvider<({List<Song> deck, List<HomeRail> rails})>((ref) async {
  final songs = await ref.watch(songsProvider.future);
  final history = await ref.watch(historyStoreProvider).read();
  final nonce = ref.watch(deckReshuffleProvider);
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final seed = day.millisecondsSinceEpoch ~/ 86400000 + nonce * 7919;
  return (
    deck: dealDeck(songs, history, seed, now: now, lottery: nonce > 0),
    rails: _localRails(songs, history),
  );
});

/// Slow extension slice: one rail per provider section. Lags behind
/// local; the UI renders it as it lands instead of blocking Home.
final homeExtensionProvider = FutureProvider<List<HomeRail>>((ref) async {
  return _extensionRails(ref);
});

/// Pure deal: deterministic for a seed, testable off-device.
/// Score = plays x2, +3 played this week, +1 this month; seeded
/// double breaks ties so equal scores still vary day to day. The
/// lottery instead draws without replacement with probability
/// proportional to score (+1 base so the unplayed shelf stays
/// drawable). Either way, when the cut holds no unplayed song and
/// the library has any, the last card is re-dealt from the unplayed
/// pool.
List<Song> dealDeck(
  List<Song> songs,
  Map<int, PlayRecord> history,
  int seed, {
  required DateTime now,
  int count = 5,
  bool lottery = false,
}) {
  if (songs.isEmpty) return const [];
  final rand = Random(seed);
  double weightOf(Song s) {
    final rec = history[s.id];
    final plays = rec?.count ?? 0;
    var bonus = 0;
    if (rec != null) {
      final days =
          now.difference(DateTime.fromMillisecondsSinceEpoch(rec.lastMs)).inDays;
      if (days <= 7) {
        bonus = 3;
      } else if (days <= 30) {
        bonus = 1;
      }
    }
    return 1.0 + plays * 2 + bonus;
  }

  final List<Song> deck;
  if (!lottery) {
    final scored = songs.map((s) {
      return (song: s, score: weightOf(s), tie: rand.nextDouble());
    }).toList();
    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.tie.compareTo(b.tie);
    });
    deck = scored.take(count).map((e) => e.song).toList();
  } else {
    final bag = songs.map((s) => (song: s, weight: weightOf(s))).toList();
    deck = [];
    while (deck.length < count && bag.isNotEmpty) {
      var total = 0.0;
      for (final e in bag) {
        total += e.weight;
      }
      var r = rand.nextDouble() * total;
      var idx = 0;
      for (; idx < bag.length - 1; idx++) {
        r -= bag[idx].weight;
        if (r <= 0) break;
      }
      deck.add(bag.removeAt(idx).song);
    }
  }
  final hasUnplayed = deck.any((s) => (history[s.id]?.count ?? 0) == 0);
  if (!hasUnplayed) {
    final unplayed = songs
        .where((s) => (history[s.id]?.count ?? 0) == 0)
        .toList(growable: false);
    if (unplayed.isNotEmpty && deck.isNotEmpty) {
      deck[deck.length - 1] = unplayed[rand.nextInt(unplayed.length)];
    }
  }
  return deck;
}
