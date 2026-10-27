import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../library/data/tag_fields.dart';
import '../library/library_providers.dart';
import '../lyrics/tag_lyrics.dart';
import '../needle/extensions.dart';
import '../needle/needle_store.dart';
import '../needle/sandbox.dart' show NeedleException;
import 'metadata_service.dart';

/// Single owner of the metadata service: DSP passes complete behind
/// playback (single-flight queue), so each completion invalidates every
/// watched [musicalInfoProvider] family key for the track — an open song
/// page redraws with real tempo/key/vocals instead of its shed-time
/// verdict. Buckets are artist+title, lowercased: the completing pass
/// runs under whoever queued first, whose raw spelling/path rarely
/// equals the open page's key, so exact-key invalidation missed live.
final Provider<MetadataService> metadataServiceProvider =
    Provider<MetadataService>((ref) {
  final svc = MetadataService();
  final sub = svc.dspDone.listen((bucket) {
    final parts = bucket.split('\x00');
    for (final k in svc.musicalKeysFor(
      artist: parts.isNotEmpty ? parts.first : '',
      title: parts.length > 1 ? parts[1] : '',
    )) {
      ref.invalidate(musicalInfoProvider(k));
    }
  });
  ref.onDispose(() {
    sub.cancel();
    svc.dispose();
  });
  return svc;
});

/// Every tag the file itself carries, read off the UI thread (compute,
/// not Isolate.run: a closure here would capture this provider's ref
/// and fail to send).
final tagFieldsProvider =
    FutureProvider.autoDispose.family<TagFields, String>((ref, path) {
  if (path.isEmpty) return Future.value(const TagFields({}, 'none'));
  return compute(readTagFields, path);
});


final artistMetaProvider = FutureProvider.family<ArtistMeta, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).enrich(artistName);
});

/// Independent progressive providers: pic, bio, and discography render
/// the moment each lands instead of waiting on the slowest.
final artistPicProvider = FutureProvider.family<String?, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).picFor(artistName);
});

final artistBioProvider = FutureProvider.family<String?, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).bioFor(artistName);
});

final artistReleasesProvider =
    FutureProvider.family<List<ReleaseGroup>, String>((ref, artistName) async {
  final svc = ref.watch(metadataServiceProvider);
  final mb = await svc.releasesFor(artistName);
  if (mb.isNotEmpty) return mb;
  // MusicBrainz drew a blank: Deezer artist albums keep the
  // discography (and its hubs) alive. Types come from Deezer's
  // own record_type, never guessed.
  return svc.dzReleasesFor(artistName);
});

/// True artist wordmark (fanart.tv HD ClearLogo), when one exists.
/// Null = the hero falls back to our display-font voice.
final artistLogoProvider = FutureProvider.family<String?, String>((
  ref,
  artistName,
) {
  return ref.watch(metadataServiceProvider).logoFor(artistName);
});

/// Audience size with an honest label and a market trend arrow.
/// `monthly` is true only when the number actually IS monthly
/// listeners (Spotify lane). Last.fm totals read "listeners",
/// Deezer reads "fans" — never dressed up.
class ArtistListeners {
  final int count;
  final bool monthly;
  final String label;

  /// 1 = up since last sighting, -1 = down, 0 = flat or first seen.
  final int trend;

  const ArtistListeners({
    required this.count,
    required this.monthly,
    required this.label,
    this.trend = 0,
  });
}

String _countShort(int n) {
  if (n >= 1000000) {
    final v = n / 1000000;
    return '${v >= 100 ? v.round() : v.toStringAsFixed(1)}M';
  }
  if (n >= 1000) {
    final v = n / 1000;
    return '${v >= 100 ? v.round() : v.toStringAsFixed(1)}K';
  }
  return '$n';
}

/// Formatted audience line: "18.2M monthly listeners".
String formatListeners(ArtistListeners a) =>
    '${_countShort(a.count)} ${a.label}';

/// Cascading audience: a Spotify-ish extension stat first (the only
/// lane allowed to say "monthly"), then Deezer fans, then Last.fm
/// totals. Trend compares against the last sighting stored on
/// device. Null = nobody knows.
final artistListenersProvider =
    FutureProvider.family<ArtistListeners?, String>((ref, artistName) async {
  final svc = ref.watch(metadataServiceProvider);

  final monthly = await _extMonthlyListeners(ref, artistName);
  if (monthly != null && monthly > 0) {
    final trend = await _listenerTrend(artistName, 'monthly', monthly);
    return ArtistListeners(
      count: monthly,
      monthly: true,
      label: 'monthly listeners',
      trend: trend,
    );
  }

  try {
    final fans = await svc
        .dzFansFor(artistName)
        .timeout(const Duration(seconds: 15));
    if (fans != null && fans > 0) {
      final trend = await _listenerTrend(artistName, 'fans', fans);
      return ArtistListeners(
        count: fans,
        monthly: false,
        label: 'fans',
        trend: trend,
      );
    }
  } catch (_) {}

  try {
    final total = await svc
        .lfmListenersFor(artistName)
        .timeout(const Duration(seconds: 15));
    if (total != null && total > 0) {
      final trend = await _listenerTrend(artistName, 'listeners', total);
      return ArtistListeners(
        count: total,
        monthly: false,
        label: 'listeners',
        trend: trend,
      );
    }
  } catch (_) {}
  return null;
});

/// Probe installed extensions for an artist-stats entry. The known
/// download contract has no such function, so this matches by name
/// (getArtist, artistStats, artistInfo, followers, monthlyListeners)
/// and parses defensively — a miss is silent, never a crash.
/// Only extensions with the function get called, never blindly.
Future<int?> _extMonthlyListeners(Ref ref, String artistName) async {
  const cands = [
    'monthlyListeners',
    'getArtistStats',
    'artistStats',
    'getArtist',
    'artistInfo',
    'followers',
  ];
  final exts = ref.read(installedExtensionsProvider);
  for (final ext in exts) {
    if (!ext.enabled) continue;
    try {
      final h = await loadExtension(ext.id);
      final fns = await extensionFunctions(h.handle, timeoutMs: 8000);
      String? fn;
      for (final c in cands) {
        if (fns.contains(c)) {
          fn = c;
          break;
        }
      }
      if (fn == null) continue;
      final out = await callExtensionFn(
        h.handle,
        fn,
        [artistName],
        timeoutMs: 12000,
      );
      final n = _asCount(out['value']);
      if (n != null && n > 0) {
        ArchLog.i('meta', 'listeners live ext ${ext.id}: $n');
        return n;
      }
    } on NeedleException catch (_) {
    } catch (_) {}
  }
  return null;
}

int? _asCount(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) {
    final n = int.tryParse(v.replaceAll(RegExp(r'[^0-9]'), ''));
    if (n != null && n > 0) return n;
  }
  if (v is Map) {
    for (final k in ['monthlyListeners', 'listeners', 'followers', 'count']) {
      final n = _asCount(v[k]);
      if (n != null) return n;
    }
  }
  return null;
}

/// Market trend against the last sighting stored on device. Writes
/// the new sighting; first sighting reads flat.
Future<int> _listenerTrend(String artist, String kind, int count) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final key = 'arch.listeners.${artist.toLowerCase()}\u0000$kind';
    final old = prefs.getInt(key);
    await prefs.setInt(key, count);
    if (old == null || old == count) return 0;
    return count > old ? 1 : -1;
  } catch (_) {
    return 0;
  }
}

/// Chart top tracks, fresh per page open (preview URLs expire).
/// Deezer first; when Deezer draws a blank, Last.fm's chart fills
/// in (ranked, no previews — playback resolves those lazily).
final artistTopProvider = FutureProvider.family<List<TopTrack>, String>((
  ref,
  artistName,
) async {
  final svc = ref.watch(metadataServiceProvider);
  final dz = await svc.topTracks(artistName);
  if (dz.isNotEmpty) return dz;
  return svc.lfmTopTracksFor(artistName);
});

/// Release cover art, resolved lazily per visible item.
final releaseCoverProvider = FutureProvider.family<String?, String>((
  ref,
  rgMbid,
) {
  return ref.watch(metadataServiceProvider).coverFor(rgMbid);
});

/// Show/hide the Harmonic section on the song page. Persisted,
/// default on. The eye toggle in the section header owns it.
final showMusicalProvider = NotifierProvider<ShowMusicalNotifier, bool>(
  ShowMusicalNotifier.new,
);

class ShowMusicalNotifier extends Notifier<bool> {
  @override
  bool build() {
    _sync();
    return true;
  }

  Future<void> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('arch.showMusical') ?? true;
  }

  Future<void> toggle() async {
    final v = !state;
    state = v;
    (await SharedPreferences.getInstance()).setBool('arch.showMusical', v);
  }
}

/// BPM + musical key for harmonic ordering: embedded tags, then the
/// GetSongBPM lane (disk-cached). Keyed "artist\x00title\x00path" —
/// path empty means network-only. Null = neither lane knew the track.
final musicalInfoProvider =
    FutureProvider.family<TrackMusicalInfo?, String>((ref, key) async {
  final svc = ref.watch(metadataServiceProvider);
  // Register before the fetch: a pass completing mid-flight must find
  // this raw key (case/path variant) when its bucket invalidates.
  svc.noteMusicalKey(key);
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final title = parts.length > 1 ? parts[1] : '';
  final path = parts.length > 2 ? parts[2] : '';
  return svc.musicalInfoFor(title: title, artist: artist, path: path);
});

/// Full album tracklist (Deezer, else MusicBrainz), keyed
/// "artist\x00album" lowercased. Empty = unresolvable - callers
/// render owned-only, never a hole.
final albumTracklistProvider = FutureProvider.family<List<AlbumTrack>, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .albumTracksFor(artist: artist, album: album);
});

/// Album genres, same key shape. Embedded file tags win (your
/// files beat fuzzy matching), then Last.fm / MusicBrainz / Deezer.
/// Empty = the world says nothing.
final albumGenresProvider = FutureProvider.family<List<String>, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  final songs = ref.watch(songsProvider).value ?? [];
  for (final s in songs) {
    if (s.path.isEmpty) continue;
    if (s.artist.toLowerCase() != artist ||
        s.album.toLowerCase() != album) {
      continue;
    }
    final embedded = readEmbeddedGenre(s.path);
    ArchLog.i(
      'meta',
      'genre embedded ${embedded == null ? 'miss' : 'hit'}: $artist - $album',
    );
    if (embedded != null && embedded.isNotEmpty) return [embedded];
    break;
  }
  return ref
      .watch(metadataServiceProvider)
      .genresFor(artist: artist, album: album);
});

/// Album credits for Relationships, same key shape. Cached
/// alongside the tracklist; empty = unknown.
final albumCreditsProvider = FutureProvider.family<List<AlbumCredit>, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .creditsFor(artist: artist, album: album);
});

/// Record label, same key shape. Null = the world says nothing.
final albumLabelProvider = FutureProvider.family<String?, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .labelFor(artist: artist, album: album);
});

/// Release facts (MusicBrainz: label, date, catalog), same key
/// shape. Drives the credits footer. Empty = unknown, and the
/// footer omits what it cannot prove.
final albumFactsProvider = FutureProvider.family<ReleaseFacts, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .releaseFactsFor(artist: artist, album: album);
});

/// Album blurb (Wikipedia summary, Last.fm wiki fallback), same key
/// shape. Null = neither source knows it; the page hides the block.
final albumBlurbProvider = FutureProvider.family<String?, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  return ref
      .watch(metadataServiceProvider)
      .albumBlurbFor(artist: artist, album: album);
});

/// Hi-res album cover URL (Apple 3000px, CAA, fanart, Deezer),
/// keyed "artist\x00album\x00title" — the title disambiguates
/// same-named albums. Null = nothing anywhere; callers keep the
/// embedded art, never a hole.
final albumHiResCoverProvider = FutureProvider.family<String?, String>((
  ref,
  key,
) {
  final parts = key.split('\x00');
  final artist = parts.isNotEmpty ? parts.first : '';
  final album = parts.length > 1 ? parts[1] : '';
  final title = parts.length > 2 ? parts[2] : '';
  return ref
      .watch(metadataServiceProvider)
      .hiResCoverFor(artist: artist, album: album, title: title);
});

/// Remote (unowned) lyrics: same LRCLib ladder, network-only.
/// Key: "title\x00artist\x00album\x00durationSecs".
final remoteLyricsProvider = FutureProvider.family<LyricDoc, String>((
  ref,
  key,
) async {
  final parts = key.split('\x00');
  final title = parts.isNotEmpty ? parts.first : '';
  final artist = parts.length > 1 ? parts[1] : '';
  final album = parts.length > 2 ? parts[2] : '';
  final dur = parts.length > 3 ? int.tryParse(parts[3]) ?? 0 : 0;
  if (title.isEmpty || artist.isEmpty) return const LyricDoc();
  try {
    return await ref
        .watch(metadataServiceProvider)
        .lyricsForRemote(
          artist: artist,
          title: title,
          album: album,
          durationSecs: dur,
        );
  } catch (_) {
    return const LyricDoc();
  }
});
