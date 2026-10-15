import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../search/provider_marks.dart';
import '../library/artist_page.dart';
import '../library/library_providers.dart';
import '../library/library_screen.dart' show AlbumPage;
import '../library/song_row.dart';
import '../metadata/lyrics_providers.dart';
import '../metadata/metadata_providers.dart';
import '../needle/extension.dart';
import '../needle/needle_store.dart';
import '../needle/pull_ui.dart';
import '../player/format_marks.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../shell/dock.dart';

/// A song, owned or remote. Owned carries the library Song (play,
/// file facts, cached lyrics, play count). Remote carries provider
/// facts (art, duration, isrc, source) and adapts every section:
/// owned-only rows hide, remote shows Pull instead of Play.
class SongRef {
  final String title;
  final String artist;
  final String album;
  final String artUrl;
  final int durationMs;
  final int year;
  final String isrc;
  final String providerId;
  final bool explicit;
  final String artFile;
  final Song? owned;

  bool get isOwned => owned != null;

  const SongRef({
    required this.title,
    required this.artist,
    required this.album,
    this.artUrl = '',
    this.durationMs = 0,
    this.year = 0,
    this.isrc = '',
    this.providerId = '',
    this.explicit = false,
    this.artFile = '',
    this.owned,
  });

  factory SongRef.owned(Song s) => SongRef(
        title: s.title,
        artist: s.artist,
        album: s.album,
        durationMs: s.duration.inMilliseconds,
        year: s.year,
        owned: s,
      );

  factory SongRef.remote({
    required String title,
    required String artist,
    String album = '',
    String artUrl = '',
    int durationMs = 0,
    String isrc = '',
    String providerId = '',
    bool explicit = false,
    String artFile = '',
  }) =>
      SongRef(
        title: title,
        artist: artist,
        album: album,
        artUrl: artUrl,
        durationMs: durationMs,
        isrc: isrc,
        providerId: providerId,
        explicit: explicit,
        artFile: artFile,
      );

  String get guardKey => owned != null
      ? 'id:${owned!.id}'
      : 'r:${normTitle(title)}|${artist.toLowerCase()}';
}

/// Owned-library match for a title/artist pair. Null = remote-only,
/// the caller adapts instead of opening air.
Song? ownedSongFor(WidgetRef ref, String title, String artist) {
  final songs = ref.read(songsProvider).value ?? [];
  final want = normTitle(title);
  for (final s in songs) {
    if (normTitle(s.title) == want && artistsOverlap(s.artist, artist)) {
      return s;
    }
  }
  return null;
}

/// Play count for one owned song id. Snapshot per page open.
final playCountProvider = FutureProvider.family<int, int>((ref, songId) async {
  final all = await ref.watch(historyStoreProvider).read();
  return all[songId]?.count ?? 0;
});

/// Player-title entry: previews (albumId 0) carry the live cached
/// cover file plus the remote URL fallback instead of an empty
/// owned ref.
SongRef playerTitleRef(WidgetRef ref, Song song) {
  if (song.albumId <= 0) {
    final extras =
        ref.read(audioHandlerProvider).mediaItem.valueOrNull?.extras;
    final file = extras?['artCacheFile'] as String?;
    final cover = extras?['coverUrl'] as String?;
    return SongRef.remote(
      title: song.title,
      artist: song.artist,
      album: song.album,
      artUrl: cover ?? '',
      durationMs: song.duration.inMilliseconds,
      artFile: file ?? '',
    );
  }
  return SongRef.owned(song);
}

/// Song page: two swipeable sections (Overview = hero + metadata +
/// lyrics, Makers) under a centered display title. Works owned and
/// remote.
class SongPage extends ConsumerStatefulWidget {
  final SongRef ref_;
  const SongPage({super.key, required SongRef songRef}) : ref_ = songRef;

  static final Set<String> _open = {};

  static void open(BuildContext context, SongRef songRef) {
    if (_open.contains(songRef.guardKey)) return;
    ArchLog.i('nav', 'song open: ${songRef.title}');
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SongPage(songRef: songRef)),
    );
  }

  @override
  ConsumerState<SongPage> createState() => _SongPageState();
}

class _SongPageState extends ConsumerState<SongPage> {
  final _pager = PageController();
  int _page = 0;

  SongRef get _r => widget.ref_;

  @override
  void initState() {
    super.initState();
    SongPage._open.add(_r.guardKey);
  }

  @override
  void dispose() {
    SongPage._open.remove(_r.guardKey);
    _pager.dispose();
    super.dispose();
  }

  Future<void> _play(Song song, List<Song> queue) async {
    final handler = ref.read(audioHandlerProvider);
    await playAndOpen(ref, context, () => handler.playSong(song, queue));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          'Song Page',
          style: TextStyle(
            fontFamily: 'ArchSerif',
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, color: ink),
        ),
      ),
      body: DockScrollReporter(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Expanded(
                  child: PageView(
                    controller: _pager,
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [
                      _OverviewPage(
                        songRef: _r,
                        onPlay: _play,
                        key: const ValueKey('p-overview'),
                      ),
                      _MakersPage(
                        songRef: _r,
                        onPlay: _play,
                        key: const ValueKey('p-makers'),
                      ),
                    ],
                  ),
                ),
                _Dots(page: _page, count: 2, onTap: (i) {
                  _pager.animateToPage(
                    i,
                    duration: Motion.stateChange,
                    curve: Curves.easeOut,
                  );
                }),
                const SizedBox(height: 8),
              ],
            ),
            const NowPlayingDock(),
          ],
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int page;
  final int count;
  final void Function(int) onTap;
  const _Dots({required this.page, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: Motion.stateChange,
              width: page == i ? 22 : 7,
              height: 7,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: page == i ? archPink : ink.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
      ],
    );
  }
}

double _clearance(WidgetRef ref) {
  final collapsed = ref.watch(pillCollapsedProvider);
  final mini = ref.watch(miniVisibleProvider);
  return (collapsed ? 120.0 : (mini ? 200.0 : 140.0)) + 60.0;
}

/// Page 1: hero, chips, controls, metadata card, lyrics preview.
class _OverviewPage extends ConsumerWidget {
  final SongRef songRef;
  final Future<void> Function(Song, List<Song>) onPlay;
  const _OverviewPage(
      {super.key, required this.songRef, required this.onPlay});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      children: [
        _Hero(songRef: songRef, onPlay: onPlay),
        const SizedBox(height: 20),
        _MetaCard(songRef: songRef),
        const SizedBox(height: 20),
        _LyricsCard(songRef: songRef, onPlay: onPlay),
        SizedBox(height: _clearance(ref)),
      ],
    );
  }
}

class _Hero extends ConsumerWidget {
  final SongRef songRef;
  final Future<void> Function(Song, List<Song>) onPlay;
  const _Hero({required this.songRef, required this.onPlay});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = songRef;
    final owned = r.owned;
    final voice = artistVoiceOf(r.artist.isEmpty ? r.title : r.artist);
    Widget art;
    if (r.artFile.isNotEmpty) {
      art = ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Image.file(
          File(r.artFile),
          width: 320,
          height: 320,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _artFallback(),
        ),
      );
    } else if (owned != null && owned.albumId > 0) {
      art = AlbumArt(albumId: owned.albumId, size: 320, radius: 32);
    } else if (r.artUrl.isNotEmpty) {
      art = ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: CachedNetworkImage(
          imageUrl: r.artUrl,
          width: 320,
          height: 320,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _artFallback(),
        ),
      );
    } else {
      art = _artFallback();
    }
    Album? ownedAlbum;
    if (owned != null) {
      final want = normTitle(r.album);
      for (final a in ref.watch(albumsProvider)) {
        if (normTitle(a.title) == want &&
            a.songs.any((s) => artistsOverlap(s.artist, r.artist))) {
          ownedAlbum = a;
          break;
        }
      }
    }
    final oa = ownedAlbum;
    return Column(
      children: [
        Center(child: SizedBox(width: 320, height: 320, child: art)),
        const SizedBox(height: 20),
        Text(
          r.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: voice,
            fontSize: 36,
            fontWeight: FontWeight.w800,
            letterSpacing: voiceSpacing(voice),
          ),
        ),
        if (r.explicit) ...[
          const SizedBox(height: 8),
          const Center(child: _ExplicitMark()),
        ],
        const SizedBox(height: 10),
        // Split artists: one chip per voice, bands stay whole by
        // the shared split discipline (& never fractures).
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in splitArtists(r.artist))
              GestureDetector(
                onTap: () => ArtistPage.openIfAbsent(context, a),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: paperRaised,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    a,
                    style: const TextStyle(
                      color: archPink,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (r.album.isNotEmpty) ...[
          const SizedBox(height: 12),
          Center(
            child: GestureDetector(
              onTap: oa == null
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => AlbumPage(album: oa)),
                      ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: owned != null && owned.albumId > 0
                        ? AlbumArt(
                            albumId: owned.albumId, size: 44, radius: 12)
                        : r.artUrl.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: CachedNetworkImage(
                                  imageUrl: r.artUrl,
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) =>
                                      _miniArtFallback(),
                                ),
                              )
                            : _miniArtFallback(),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      r.album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: oa == null ? inkDim : archPink,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            _FormatPill(songRef: r),
            if (r.isOwned)
              const _Chip(
                icon: Icons.check_circle_rounded,
                label: 'Owned',
              )
            else
              const _Chip(
                icon: Icons.cloud_outlined,
                label: 'Not in library',
                pink: true,
              ),
            if (!r.isOwned && r.providerId.isNotEmpty)
              _ProviderChip(providerId: r.providerId),
          ],
        ),
        const SizedBox(height: 16),
        _Controls(songRef: r, onPlay: onPlay),
      ],
    );
  }

  static Widget _artFallback() => Container(
        width: 320,
        height: 320,
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(32),
        ),
        child:
            const Icon(CupertinoIcons.music_note, color: inkDim, size: 112),
      );

  static Widget _miniArtFallback() => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(12),
        ),
        child:
            const Icon(CupertinoIcons.music_note, color: inkDim, size: 22),
      );
}

/// Format pill: the house FormatChip (sourced logo + label +
/// lossless tag, geometric fallback) on a dark pill. No path, no
/// mark - falls back to a LOCAL/PREVIEW text chip, never a glyph.
class _FormatPill extends StatelessWidget {
  final SongRef songRef;
  const _FormatPill({required this.songRef});

  @override
  Widget build(BuildContext context) {
    final owned = songRef.owned;
    Widget inner;
    if (owned != null && owned.path.isNotEmpty) {
      inner = FormatChip(path: owned.path, dark: true);
    } else {
      inner = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.audio_file_outlined,
              size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            owned != null ? 'LOCAL' : 'PREVIEW',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(18),
      ),
      child: inner,
    );
  }
}

/// Maker portrait through the cached artist-pic lane. Letter
/// avatar while loading, on error, or when the world has no pic.
class _MakerPic extends ConsumerWidget {
  final String name;
  const _MakerPic({required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget fallback() => Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(
            color: paper,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 20),
          ),
        );
    final async = ref.watch(artistPicProvider(name));
    return async.when(
      loading: fallback,
      error: (_, _) => fallback(),
      data: (url) {
        if (url == null || url.isEmpty) return fallback();
        return ClipOval(
          child: CachedNetworkImage(
            imageUrl: url,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => fallback(),
          ),
        );
      },
    );
  }
}

/// Parental-advisory E mark. Rendered only when a provider says so.
class _ExplicitMark extends StatelessWidget {
  const _ExplicitMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: inkDim, width: 1.4),
        borderRadius: BorderRadius.circular(5),
      ),
      child: const Text(
        'EXPLICIT',
        style: TextStyle(
          color: inkDim,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          height: 1.2,
        ),
      ),
    );
  }
}

/// Dark chip: ink pill, white icon + text. Pink variant only for
/// the not-owned state.
class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool pink;
  const _Chip({required this.icon, required this.label, this.pink = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: pink ? archPink : ink,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Source chip carrying the provider's own mark.
class _ProviderChip extends ConsumerWidget {
  final String providerId;
  const _ProviderChip({required this.providerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(installedExtensionsProvider);
    String name = providerId;
    for (final p in all) {
      if (p.id == providerId) {
        name = p.displayName;
        break;
      }
    }
    final asset = providerMarkAsset(providerId, name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (asset != null)
            Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: SvgPicture.asset(asset),
              ),
            )
          else
            const Icon(Icons.cloud_outlined,
                size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Controls: Play for owned, Pull for remote, plus Share/Artist.
/// Album lives on the hero row; no control invented twice.
class _Controls extends ConsumerStatefulWidget {
  final SongRef songRef;
  final Future<void> Function(Song, List<Song>) onPlay;
  const _Controls({required this.songRef, required this.onPlay});

  @override
  ConsumerState<_Controls> createState() => _ControlsState();
}

class _ControlsState extends ConsumerState<_Controls> {
  bool _busy = false;
  bool _done = false;

  Future<void> _pull() async {
    if (_busy || _done) return;
    final r = widget.songRef;
    final all = ref.read(installedExtensionsProvider);
    InstalledExtension? provider;
    for (final p in all) {
      if (p.enabled &&
          p.roles.contains('download') &&
          (r.providerId.isEmpty || p.id == r.providerId)) {
        provider = p;
        break;
      }
    }
    provider ??= () {
      for (final p in all) {
        if (p.enabled && p.roles.contains('download')) return p;
      }
      return null;
    }();
    if (!mounted) return;
    setState(() => _busy = true);
    final ok = await pullWithVerify(
      context,
      ref,
      provider: provider,
      providerName: provider?.displayName ?? 'provider',
      title: r.title,
      artist: r.artist,
      isrc: r.isrc,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.songRef;
    final owned = r.owned;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (owned != null)
          FilledButton.icon(
            onPressed: () => widget.onPlay(owned, [owned]),
            style: FilledButton.styleFrom(backgroundColor: archPink),
            icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
            label: const Text('Play',
                style: TextStyle(color: Colors.white)),
          )
        else
          FilledButton.icon(
            onPressed: _busy || _done ? null : _pull,
            style: FilledButton.styleFrom(backgroundColor: archPink),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2),
                  )
                : Icon(
                    _done
                        ? Icons.check_rounded
                        : Icons.cloud_download_outlined,
                    color: Colors.white),
            label: Text(_done ? 'Pulled' : 'Pull',
                style: const TextStyle(color: Colors.white)),
          ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Share',
          onPressed: () {
            final text = [r.title, r.artist]
                .where((s) => s.isNotEmpty)
                .join(' - ');
            if (text.isNotEmpty) {
              SharePlus.instance.share(ShareParams(text: text));
            }
          },
          icon: const Icon(Icons.share_outlined, color: ink),
        ),
        IconButton(
          tooltip: 'Artist',
          onPressed: () =>
              ArtistPage.openIfAbsent(context, primaryArtist(r.artist)),
          icon: const Icon(Icons.person_outline_rounded, color: ink),
        ),
      ],
    );
  }
}

/// Makers with per-maker library matches, playable inline.
class _MakersPage extends ConsumerStatefulWidget {
  final SongRef songRef;
  final Future<void> Function(Song, List<Song>) onPlay;
  const _MakersPage(
      {super.key, required this.songRef, required this.onPlay});

  @override
  ConsumerState<_MakersPage> createState() => _MakersPageState();
}

class _MakersPageState extends ConsumerState<_MakersPage> {
  String? _expanded;

  List<Song> _matches(String name) {
    final songs = ref.watch(songsProvider).value ?? [];
    return [
      for (final s in songs)
        if (artistsOverlap(s.artist, name)) s,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.songRef;
    final key =
        '${r.artist.toLowerCase()}\x00${r.album.toLowerCase()}';
    final async = ref.watch(albumCreditsProvider(key));
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      children: [
        const Text(
          'Makers',
          style: TextStyle(
            fontFamily: 'ArchSerif',
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        async.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: archPink, strokeWidth: 2),
              ),
            ),
          ),
          error: (_, _) => const Text(
            'Makers unavailable right now.',
            style: TextStyle(color: inkDim, fontSize: 14),
          ),
          data: (credits) {
            if (credits.isEmpty) {
              return const Text(
                'No makers known for this one yet.',
                style: TextStyle(color: inkDim, fontSize: 14),
              );
            }
            return Container(
              decoration: BoxDecoration(
                color: paperRaised,
                borderRadius: BorderRadius.circular(18),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < credits.length; i++) ...[
                    _creditRow(credits[i], r),
                    if (i < credits.length - 1)
                      const Divider(
                        height: 1,
                        thickness: 1,
                        indent: 68,
                        endIndent: 16,
                        color: Color(0x140B0B0D),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
        SizedBox(height: _clearance(ref)),
      ],
    );
  }

  Widget _creditRow(AlbumCredit c, SongRef r) {
    final matches = _matches(c.name)
        .where((s) => r.owned == null || s.id != r.owned!.id)
        .toList();
    final open = _expanded == c.name;
    return Column(
      children: [
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: _MakerPic(name: c.name),
          title: Text(
            c.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 16),
          ),
          subtitle: Text(
            matches.isEmpty
                ? c.role
                : '${c.role}  |  ${matches.length} in your library',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: inkDim, fontSize: 13),
          ),
          trailing: matches.isEmpty
              ? null
              : Icon(
                  open
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: inkDim,
                ),
          onTap: matches.isEmpty
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  setState(() => _expanded = open ? null : c.name);
                },
        ),
        if (open)
          for (final s in matches.take(8))
            ListTile(
              dense: true,
              contentPadding:
                  const EdgeInsets.fromLTRB(80, 0, 8, 0),
              title: Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14),
              ),
              subtitle: Text(
                s.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: inkDim, fontSize: 12),
              ),
              trailing: const Icon(Icons.play_arrow_rounded,
                  color: archPink),
              onTap: () => widget.onPlay(s, [s]),
            ),
        if (open) const SizedBox(height: 8),
      ],
    );
  }
}

/// Lyrics preview card. Owned resolves embedded -> LRCLib
/// (cached); remote runs the same ladder network-only.
class _LyricsCard extends ConsumerWidget {
  final SongRef songRef;
  final Future<void> Function(Song, List<Song>) onPlay;
  const _LyricsCard({required this.songRef, required this.onPlay});

  static String _preview(String? synced, String? plain) {
    final raw = plain?.trim().isNotEmpty == true
        ? plain!
        : (synced ?? '').replaceAll(RegExp(r'\[[^\]]*\]'), '');
    final lines = [
      for (final l in raw.split('\n')) l.trim(),
    ].where((l) => l.isNotEmpty).take(6).toList();
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = songRef;
    final owned = r.owned;
    final async = owned != null
        ? ref.watch(lyricsDocProvider(owned.id))
        : ref.watch(remoteLyricsProvider(
            '${r.title}\x00${r.artist}\x00${r.album}\x00${(r.durationMs ~/ 1000)}'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Lyrics',
          style: TextStyle(
            fontFamily: 'ArchSerif',
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        async.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: archPink, strokeWidth: 2),
              ),
            ),
          ),
          error: (_, _) => const Text(
            'Lyrics unavailable right now.',
            style: TextStyle(color: inkDim, fontSize: 14),
          ),
          data: (doc) {
            if (doc.instrumental && !doc.hasSynced && !doc.hasPlain) {
              return const Text(
                'Instrumental - no words to show.',
                style: TextStyle(color: inkDim, fontSize: 14),
              );
            }
            final preview = _preview(doc.syncedLrc, doc.plain);
            if (preview.isEmpty) {
              return const Text(
                'No lyrics for this track yet.',
                style: TextStyle(color: inkDim, fontSize: 14),
              );
            }
            return Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: paperRaised,
                borderRadius: BorderRadius.circular(18),
              ),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preview,
                    style: const TextStyle(
                        color: ink, fontSize: 16, height: 1.7),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: owned != null
                        ? TextButton(
                            onPressed: () => onPlay(owned, [owned]),
                            child: const Text(
                              'Play to follow along',
                              style: TextStyle(
                                color: archPink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Pull it to follow along in the player.',
                              style: TextStyle(
                                  color: inkDim, fontSize: 12),
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Metadata facts in one grouped card. Label wears its ℗ mark;
/// unknown fields are omitted, never blank rows.
class _MetaCard extends ConsumerWidget {
  final SongRef songRef;
  const _MetaCard({required this.songRef});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = songRef;
    final owned = r.owned;
    final key =
        '${r.artist.toLowerCase()}\x00${r.album.toLowerCase()}';
    final genresAsync = ref.watch(albumGenresProvider(key));
    final labelAsync = ref.watch(albumLabelProvider(key));
    final countAsync =
        owned != null ? ref.watch(playCountProvider(owned.id)) : null;
    final rows = <List<String>>[
      ['Artist', r.artist],
      if (r.album.isNotEmpty) ['Album', r.album],
      if (r.year > 0) ['Year', '${r.year}'],
      if (r.durationMs > 0)
        [
          'Length',
          '${r.durationMs ~/ 60000}:${((r.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}'
        ],
      if (owned != null) ...[
        if (owned.folderLabel.isNotEmpty)
          ['Folder', owned.folderLabel],
        if (owned.path.isNotEmpty)
          ['Format', owned.path.split('.').last.toUpperCase()],
        if (owned.addedSecs > 0)
          [
            'Added',
            DateTime.fromMillisecondsSinceEpoch(owned.addedSecs * 1000)
                .toIso8601String()
                .substring(0, 10),
          ],
      ] else ...[
        if (r.providerId.isNotEmpty) ['Source', r.providerId],
      ],
      if (r.isrc.isNotEmpty) ['ISRC', r.isrc],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Metadata',
          style: TextStyle(
            fontFamily: 'ArchSerif',
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: paperRaised,
            borderRadius: BorderRadius.circular(18),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const _FactDivider(),
                _factRow(rows[i][0], rows[i][1]),
              ],
              genresAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (genres) => genres.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        children: [
                          const _FactDivider(),
                          _factRow(
                              'Genre', genres.join('  |  ')),
                        ],
                      ),
              ),
              labelAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (label) => label == null || label.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        children: [
                          const _FactDivider(),
                          _factRow('Label', '\u2117 $label'),
                        ],
                      ),
              ),
              if (countAsync != null)
                countAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (n) => n <= 0
                      ? const SizedBox.shrink()
                      : Column(
                          children: [
                            const _FactDivider(),
                            _factRow('Plays', '$n'),
                          ],
                        ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static Widget _factRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              k,
              style: const TextStyle(color: inkDim, fontSize: 14),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _FactDivider extends StatelessWidget {
  const _FactDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 1,
      color: Color(0x140B0B0D),
    );
  }
}
