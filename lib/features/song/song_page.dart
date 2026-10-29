import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/badges.dart';
import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/data/art_previews.dart';
import '../library/data/library_repository.dart';
import '../library/data/media_writes.dart';
import '../library/data/tag_fields.dart';
import '../needle/embed.dart';
import '../needle/enrich.dart';
import '../search/provider_marks.dart';
import '../library/artist_page.dart';
import '../library/library_providers.dart';
import '../library/album_page.dart' show AlbumPage;
import '../library/song_row.dart';
import '../metadata/cover_measure.dart';
import '../metadata/lyrics_providers.dart';
import '../metadata/metadata_providers.dart';
import '../needle/download_sheet.dart';
import '../doctor/doctor_sheet.dart';
import '../needle/fly_to_needle.dart';
import '../needle/needle_store.dart';
import '../player/format_marks.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../player/track_menu.dart';
import '../shell/morph_menu.dart' show showMorphMenu;
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

/// Normalized-title index over the library: rows look up their
/// own title bucket (1-3 songs) instead of regex-normalizing
/// all 500+ songs per row per build. Rebuilt only when the
/// library itself changes. (Per-row full scans were UI-thread
/// jank on every list rebuild - menu travel included.)
final searchOwnedIndexProvider = Provider<Map<String, List<Song>>>((ref) {
  final songs = ref.watch(songsProvider).value ?? [];
  final index = <String, List<Song>>{};
  for (final s in songs) {
    final key = normTitle(s.title);
    if (key.isEmpty) continue;
    (index[key] ??= []).add(s);
  }
  return index;
});

/// Owned-library match using the index. Null = remote-only.
Song? ownedSongFor(WidgetRef ref, String title, String artist) {
  final bucket =
      ref.read(searchOwnedIndexProvider)[normTitle(title)] ?? const [];
  for (final s in bucket) {
    if (artistsOverlap(s.artist, artist)) return s;
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

  /// Delete this track's file. Confirmed first, then written through the
  /// library channel: our own inserts go straight through, and a file we
  /// did not publish asks the OS for write access once before retrying.
  Future<void> _delete(
      BuildContext context, WidgetRef ref, Song song) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this track?'),
        content: Text(
            'Removes the file from this device. This cannot be undone.\n\n'
            '${song.title}\n${song.artist}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: archPink)),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    HapticFeedback.mediumImpact();
    final outcome = await MediaWrites.deleteWithConsent(
      uri: song.uri.toString(),
      path: song.path,
    );
    ArchLog.i('write', 'delete "${song.title}": ${outcome.name}');
    if (!context.mounted) return;
    switch (outcome) {
      case WriteOutcome.ok:
        ref.invalidate(songsProvider);
        Navigator.of(context).maybePop();
      case WriteOutcome.denied:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Not permitted — the file was left alone.')));
      case WriteOutcome.failed:
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not delete '
                '${song.path.isEmpty ? song.title : song.path}')));
    }
  }

  /// Song menu: Doctor lives here; the Lyric Finder is the sheet's
  /// second page, no separate entry.
  Future<void> _openMenu(BuildContext context, WidgetRef ref) async {
    final value = await showMorphMenu(
      context: context,
      items: const [
        MenuAction(
          icon: CupertinoIcons.bandage,
          label: 'Song Doctor',
          value: 'doctor',
        ),
      ],
    );
    if (!context.mounted) return;
    if (value == 'doctor') {
      await showDoctorSheet(context, _r, initialPage: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
          icon: Icon(Icons.arrow_back_rounded,
              color: Theme.of(context).colorScheme.onSurface),
        ),
        actions: [
          if (_r.owned != null)
            IconButton(
              tooltip: 'Delete track',
              onPressed: () => _delete(context, ref, _r.owned!),
              icon: Icon(CupertinoIcons.trash,
                  color: Theme.of(context).colorScheme.onSurface),
            ),
          Builder(
            builder: (btnContext) => IconButton(
              tooltip: 'Options',
              onPressed: () => _openMenu(btnContext, ref),
              icon: Icon(Icons.more_horiz_rounded,
                  color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ],
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
                color: page == i
                    ? archPink
                    : Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.15),
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

/// Formats embedPullMeta can actually write a cover into. Ogg
/// family rides the Vorbis path (base64 PICTURE comment); wav/aac
/// have no reliable cover story in ffmpeg, so the pencil stays
/// hidden there rather than opening a dialog that can only fail.
bool _coverWritable(String path) {
  final ext = path.toLowerCase().split('.').last;
  return const {'mp3', 'flac', 'm4a', 'mp4', 'm4b', 'ogg', 'oga', 'opus'}
      .contains(ext);
}

/// Pencil over the hero art: re-fetch the cover and write it into
/// the file. Owned songs only (remote tracks have no file to write
/// to); consent flow covers rows we didn't publish.
class _CoverPencil extends ConsumerWidget {
  final Song song;
  const _CoverPencil({required this.song});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () async {
        HapticFeedback.selectionClick();
        final ok = await showCoverSheet(context, song);
        if (ok == true && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cover updated.')),
          );
        }
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: paper.withValues(alpha: 0.85),
          border: Border.all(color: ink.withValues(alpha: 0.15)),
        ),
        child: const Icon(CupertinoIcons.pencil, size: 16, color: ink),
      ),
    );
  }
}

/// Cover picker as a glass sheet (house grammar: one lens, drag
/// handle, no nested lenses). One candidate per lane, side by
/// side; the hero shows the selection at full size. Selecting
/// writes nothing; Use embeds through the Doctor's temp -> embed
/// -> retag path.
Future<bool?> showCoverSheet(BuildContext context, Song song) {
  return showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.88,
    ),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LiquidGlassLens(
        style:
            ArchGlass.sheet(radius: 28, amoled: isAmoledScheme(context)),
        child: _CoverPickerSheet(song: song),
      ),
    ),
  );
}

class _CoverPickerSheet extends ConsumerStatefulWidget {
  final Song song;
  const _CoverPickerSheet({required this.song});

  @override
  ConsumerState<_CoverPickerSheet> createState() =>
      _CoverPickerDialogState();
}

class _CoverPickerDialogState extends ConsumerState<_CoverPickerSheet> {
  List<({String label, String url, String thumb})>? _candidates;

  /// Measured per candidate: exact bytes + decoded dimensions. The
  /// thumbnail reuses the same bytes, so one fetch serves art, size
  /// and resolution — no HEAD guessing, no assumed lane sizes.
  final Map<int, ({int bytes, int width, int height})> _info = {};
  final Set<int> _failed = {};
  int _selected = 0;
  bool _applying = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  /// MediaStore substitutes "Unknown ..." placeholders for missing
  /// tags; searching for those words would only waste three lanes.
  String _clean(String v, String placeholder) =>
      v == placeholder || isUnknownSlot(v) ? '' : v;

  Future<void> _fetch() async {
    final song = widget.song;
    final found = await ref
        .read(metadataServiceProvider)
        .coverCandidatesFor(
          artist: _clean(song.artist, 'Unknown artist'),
          album: _clean(song.album, 'Unknown album'),
          title: _clean(song.title, 'Unknown title'),
        );
    if (!mounted) return;
    setState(() => _candidates = found);
    // Info for every row, in parallel; rows fill in as each lands.
    for (var i = 0; i < found.length; i++) {
      unawaited(_fetchInfo(i, found[i].url));
    }
  }

  /// Chips without the megabytes: HEAD for bytes, 64KB Range for
  /// dims, bounded full GET only as fallback (see cover_measure).
  /// Display pixels ride separate small URLs, so measuring never
  /// pays for them.
  Future<void> _fetchInfo(int index, String url) async {
    final m = await measureCoverArt(url);
    if (!mounted) return;
    setState(() {
      if (m != null) {
        _info[index] = m;
      } else {
        _failed.add(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cands = _candidates;
    final body = cands == null
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator(
                  color: archPink, strokeWidth: 2),
            ),
          )
        : cands.isEmpty
            ? Text(
                'No covers found anywhere.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _hero(cands),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 132,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: cands.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: 10),
                      itemBuilder: (_, i) =>
                          _candidateStrip(cands[i], i),
                    ),
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 8),
                    Text(_status!,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 13)),
                  ],
                  if (_applying) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(color: archPink),
                  ],
                ],
              );
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Cover art',
              style: TextStyle(
                fontFamily: 'ArchSerif',
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            body,
            if (cands != null && cands.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _applying ? null : () => _useSelected(cands),
                      child: Text(_applying ? 'Writing…' : 'Use'),
                    ),
                  ),
                  TextButton(
                    onPressed: _applying
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ] else if (cands != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Close'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _useSelected(
      List<({String label, String url, String thumb})> cands) {
    final i = _selected.clamp(0, cands.length - 1);
    if (_failed.contains(i)) return;
    _apply(cands[i].url);
  }

  /// The selection at full size, with its measured chips. This is
  /// what Use writes — no 56px guessing.
  Widget _hero(List<({String label, String url, String thumb})> cands) {
    final i = _selected.clamp(0, cands.length - 1);
    final cand = cands[i];
    final info = _info[i];
    final failed = _failed.contains(i);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 200,
            width: double.infinity,
            child: failed
                ? Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(Icons.album_outlined,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                        size: 48),
                  )
                : CachedNetworkImage(
                    imageUrl: cand.url,
                    memCacheWidth: 800,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Center(
                        child: CircularProgressIndicator(
                            color: archPink, strokeWidth: 2),
                      ),
                    ),
                    errorWidget: (_, _, _) => Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Icon(Icons.album_outlined,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                          size: 48),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                cand.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            if (info != null) ...[
              if (info.width >= kHqSide || info.height >= kHqSide)
                _chip('HQ', hot: true),
              _chip('${info.width} × ${info.height}'),
              _chip(formatArtBytes(info.bytes)),
            ] else if (failed)
              Text("couldn't load",
                  style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12))
            else
              SizedBox(
                height: 12,
                width: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color:
                        Theme.of(context).colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ],
    );
  }

  Widget _candidateStrip(
      ({String label, String url, String thumb}) cand, int i) {
    final selected = _selected == i;
    final failed = _failed.contains(i);
    final thumbUrl = cand.thumb.isNotEmpty ? cand.thumb : cand.url;
    return GestureDetector(
      onTap: (_applying || failed)
          ? null
          : () {
              HapticFeedback.selectionClick();
              setState(() => _selected = i);
            },
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: failed ? 0.45 : 1.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? archPink : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  imageUrl: thumbUrl,
                  width: 84,
                  height: 84,
                  memCacheWidth: 168,
                  memCacheHeight: 168,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => Container(
                    width: 84,
                    height: 84,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ),
                  ),
                  errorWidget: (_, _, _) => Container(
                    width: 84,
                    height: 84,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(Icons.album_outlined,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                        size: 28),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 88,
              child: Text(
                cand.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, {bool hot = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: hot ? archPink : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: hot ? Colors.white : scheme.onSurfaceVariant,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _apply(String url) async {
    final song = widget.song;
    // Captured before any await: popping after async work must not
    // touch context across the gap.
    final navigator = Navigator.of(context);
    setState(() {
      _applying = true;
      _status = null;
    });
    HapticFeedback.mediumImpact();
    String? tempIn;
    String? tagged;
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final ext = song.path.split('.').last.toLowerCase();
      tempIn = '${dir.path}/cover_$stamp.$ext';
      await File(song.path).copy(tempIn);
      // Cover-only record: every tag field stays empty so tag()
      // skips it and the file's own metadata is untouched.
      tagged = await embedPullMeta(
        tempIn,
        PullMeta(title: '', artist: '', album: '', coverUrl: url),
      );
      if (tagged == tempIn) {
        throw StateError('cover not written');
      }
      final outcome = await MediaWrites.retagWithConsent(
        uri: song.uri.toString(),
        srcPath: tagged,
        path: song.path,
      );
      ArchLog.i('cover', 'pencil "${song.title}": ${outcome.name}');
      if (!mounted) return;
      if (outcome == WriteOutcome.ok) {
        // Refresh the preview now (mtime key changed anyway) so the
        // hero paints instantly instead of next-paint; the album-row
        // memory cache is dropped so MediaStore gets re-queried too.
        await ArtPreviews.refresh(song.path);
        ArtCache.evictAlbum(song.albumId);
        ref.invalidate(songsProvider);
        navigator.pop(true);
      } else if (outcome == WriteOutcome.denied) {
        setState(() {
          _applying = false;
          _status = 'Not permitted — the file was left alone.';
        });
      } else {
        setState(() {
          _applying = false;
          _status = 'Could not write ${song.path}.';
        });
      }
    } catch (e) {
      ArchLog.w('cover', 'pencil apply failed: $e');
      if (mounted) {
        setState(() {
          _applying = false;
          _status = 'Cover fetch failed — nothing changed.';
        });
      }
    } finally {
      for (final p in [tempIn, tagged]) {
        if (p == null) continue;
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
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
          errorBuilder: (ctx, _, _) => _artFallback(ctx),
        ),
      );
    } else if (owned != null && owned.albumId > 0) {
      art = FileArtImage(
          path: owned.path,
          albumId: owned.albumId,
          size: 320,
          radius: 32,
          detail: true);
    } else if (r.artUrl.isNotEmpty) {
      art = ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: CachedNetworkImage(
            memCacheWidth: 640,
            memCacheHeight: 640,
            maxWidthDiskCache: 512,
            maxHeightDiskCache: 512,
          imageUrl: r.artUrl,
          width: 320,
          height: 320,
          fit: BoxFit.cover,
          errorWidget: (ctx, _, _) => _artFallback(ctx),
        ),
      );
    } else {
      art = _artFallback(context);
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
        Center(
          child: SizedBox(
            width: 320,
            height: 320,
            child: Stack(
              children: [
                art,
                if (owned != null &&
                    owned.path.isNotEmpty &&
                    _coverWritable(owned.path))
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: _CoverPencil(song: owned),
                  ),
              ],
            ),
          ),
        ),
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
                  padding: const EdgeInsets.only(
                      left: 4, right: 16, top: 4, bottom: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MakerPic(name: a, size: 32),
                      const SizedBox(width: 8),
                      Text(
                        a,
                        style: const TextStyle(
                          color: archPink,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ],
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
                        ? FileArtImage(
                            path: owned.path,
                            albumId: owned.albumId,
                            size: 44,
                            radius: 12)
                        : r.artUrl.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: CachedNetworkImage(
            memCacheWidth: 88,
            memCacheHeight: 88,
            maxWidthDiskCache: 512,
            maxHeightDiskCache: 512,
                                  imageUrl: r.artUrl,
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorWidget: (ctx, _, _) =>
                                      _miniArtFallback(ctx),
                                ),
                              )
                            : _miniArtFallback(context),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      r.album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: oa == null
                            ? Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                            : archPink,
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

  Widget _artFallback(BuildContext context) => Container(
        width: 320,
        height: 320,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(32),
        ),
        child: Icon(CupertinoIcons.music_note,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            size: 112),
      );

  Widget _miniArtFallback(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(CupertinoIcons.music_note,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            size: 22),
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
    } else {      inner = Row(
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
  final double size;
  const _MakerPic({required this.name, this.size = 48});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget fallback() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: size * 0.42),
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
            memCacheWidth: 96,
            memCacheHeight: 96,
            maxWidthDiskCache: 512,
            maxHeightDiskCache: 512,
            imageUrl: url,
            width: size,
            height: size,
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurfaceVariant, width: 1.4),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        'EXPLICIT',
        style: TextStyle(
          color: scheme.onSurfaceVariant,
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
    setState(() => _busy = true);
    HapticFeedback.selectionClick();
    final from = rowRect(context);
    // Song-page pulls are loose tracks by construction (owned or
    // remote single views), never album filings.
    final enqueued = await showDownloadSheet(
      context,
      ref,
      title: r.title,
      artist: r.artist,
      album: r.album,
      art: r.artUrl,
      isrc: r.isrc,
      providerId: r.providerId,
      releaseType: 'single',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (enqueued) _done = true;
    });
    if (enqueued && from != null) {
      await flyToNeedle(context, art: r.artUrl, from: from);
    }
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
          icon: Icon(Icons.share_outlined,
              color: Theme.of(context).colorScheme.onSurface),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Artist',
          onPressed: () =>
              ArtistPage.openIfAbsent(context, primaryArtist(r.artist)),
          icon: Icon(Icons.person_outline_rounded,
              color: Theme.of(context).colorScheme.onSurface),
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
          error: (_, _) => Text(
            'Makers unavailable right now.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
          ),
          data: (credits) {
            if (credits.isEmpty) {
              return Text(
                'No makers known for this one yet.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
              );
            }
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < credits.length; i++) ...[
                    _creditRow(credits[i], r),
                    if (i < credits.length - 1)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: 68,
                        endIndent: 16,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.08),
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
        // Own transparent Material (invisible-splash exceptions).
        Material(
          type: MaterialType.transparency,
          child: ListTile(
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
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          trailing: matches.isEmpty
              ? null
              : Icon(
                  open
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          onTap: matches.isEmpty
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  setState(() => _expanded = open ? null : c.name);
                },
        ),
        ),
        if (open)
          for (final s in matches.take(8))
            Material(
              type: MaterialType.transparency,
              child: ListTile(
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
                    TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
              ),
              trailing: const Icon(Icons.play_arrow_rounded,
                  color: archPink),
              onTap: () => widget.onPlay(s, [s]),
            ),
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
          error: (_, _) => Text(
            'Lyrics unavailable right now.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
          ),
          data: (doc) {
            if (doc.instrumental && !doc.hasSynced && !doc.hasPlain) {
              return Text(
                'Instrumental - no words to show.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
              );
            }
            final preview = _preview(doc.syncedLrc, doc.plain);
            if (preview.isEmpty) {
              return Text(
                'No lyrics for this track yet.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
              );
            }
            return Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preview,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 16,
                        height: 1.7),
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
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Pull it to follow along in the player.',
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 12),
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

/// Metadata facts in one grouped card, plus a collapsible "Tags"
/// section holding every remaining field the file actually carries.
/// The card is the human summary; Tags is the raw truth. Label wears
/// its ℗ mark; unknown fields are omitted, never blank rows.
///
/// The FILE wins over providers here: it is what the track really is,
/// it answers offline, and it does not vanish when you leave search.
class _MetaCard extends ConsumerStatefulWidget {
  final SongRef songRef;
  const _MetaCard({required this.songRef});

  @override
  ConsumerState<_MetaCard> createState() => _MetaCardState();
}

class _MetaCardState extends ConsumerState<_MetaCard> {
  bool _tagsOpen = false;

  @override
  Widget build(BuildContext context) {
    final reduce = Motion.reduced(context);
    final r = widget.songRef;
    final owned = r.owned;
    final key =
        '${r.artist.toLowerCase()}\x00${r.album.toLowerCase()}';
    final genresAsync = ref.watch(albumGenresProvider(key));
    final labelAsync = ref.watch(albumLabelProvider(key));
    final countAsync =
        owned != null ? ref.watch(playCountProvider(owned.id)) : null;
    final tagsAsync = (owned != null && owned.path.isNotEmpty)
        ? ref.watch(tagFieldsProvider(owned.path))
        : null;
    final fields = tagsAsync?.value;
    final showMusical = ref.watch(showMusicalProvider);
    final musicalAsync = ref.watch(
      musicalInfoProvider(
        '${r.artist}\x00${r.title}\x00${owned?.path ?? ''}',
      ),
    );
    final musical = musicalAsync.value;

    final fileYear = _yearOf(fields);
    final fileGenre = fields?[kGenre];
    final fileLabel = fields?[kLabel];
    final fileIsrc = fields?[kIsrc];
    final fileAlbumArtist = fields?[kAlbumArtist];
    final fileTrack = fields?.numbered(kTrack, kTrackTotal);
    final fileDisc = fields?.numbered(kDisc, kDiscTotal);

    final rows = <List<String>>[
      ['Artist', r.artist],
      if (r.album.isNotEmpty) ['Album', r.album],
      if (fileAlbumArtist case String albumArtist) ...[
        ['Album artist', albumArtist]
      ],
      if (fileTrack case String track) ...[
        ['Track', track]
      ],
      if (fileDisc case String disc) ...[
        ['Disc', disc]
      ],
      if (fileYear != null)
        ['Year', fileYear]
      else if (r.year > 0)
        ['Year', '${r.year}'],
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
      if (fileGenre != null) ['Genre', fileGenre],
      if (fileIsrc != null)
        ['ISRC', fileIsrc]
      else if (r.isrc.isNotEmpty)
        ['ISRC', r.isrc],
    ];

    // Everything the file carries that the card above does not already
    // state. Title/artist/album are the page's own subject; date, genre,
    // label, ISRC, album artist, track and disc live in the card;
    // totals fold into Track/Disc.
    final tagRows = <List<String>>[];
    if (fields != null) {
      for (final k in tagFieldOrder.keys) {
        if (k == kTitle ||
            k == kArtist ||
            k == kAlbum ||
            k == kAlbumArtist ||
            k == kTrack ||
            k == kDisc ||
            k == kDate ||
            k == kGenre ||
            k == kLabel ||
            k == kIsrc ||
            k == kTrackTotal ||
            k == kDiscTotal) {
          continue;
        }
        final v = fields[k];
        if (v == null || v.isEmpty) continue;
        tagRows.add([tagFieldOrder[k]!, v]);
      }
    }
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
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                data: (genres) => (genres.isEmpty || fileGenre != null)
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
                data: (label) => (label == null ||
                        label.isEmpty ||
                        fileLabel != null)
                    ? const SizedBox.shrink()
                    : Column(
                        children: [
                          const _FactDivider(),
                          _factRow('Label', '\u2117 $label'),
                        ],
                      ),
              ),
              if (fileLabel != null) ...[
                const _FactDivider(),
                _factRow('Label', '\u2117 $fileLabel'),
              ],
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
        // Harmonic: Camelot key on its wheel color + tempo, resolved
        // from tags, network or on-device DSP (same lane as automix).
        // Unknown tracks omit the section, never a blank row; the eye
        // toggle owns visibility and persists across restarts.
        if (musical case final info? when !info.isEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              const Text(
                'Harmonic',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(showMusicalProvider.notifier).toggle();
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    showMusical
                        ? CupertinoIcons.eye_fill
                        : CupertinoIcons.eye_slash_fill,
                    color: showMusical
                        ? archPink
                        : Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          if (showMusical) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (info.openKey.isNotEmpty)
                  KeyBadge(openKey: info.openKey),
                if (info.openKey.isNotEmpty) const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    [
                      if (info.keyOf.isNotEmpty) info.keyOf,
                      if (info.bpm != null)
                        '${_fmtBpm(info.bpm!)} BPM',
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
        // The file's remaining tags, folded away until asked for: a
        // long raw list should not push the card around.
        if (tagRows.isNotEmpty) ...[
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _tagsOpen = !_tagsOpen),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Text(
                  'Tags',
                  style: const TextStyle(
                    fontFamily: 'ArchSerif',
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${tagRows.length}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _tagsOpen ? 0.5 : 0,
                  duration: reduce ? Duration.zero : Motion.stateChange,
                  curve: Motion.arrival,
                  child: Icon(
                    CupertinoIcons.chevron_down,
                    size: 18,
                    color:
                        Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          AnimatedCrossFade(
            duration: reduce ? Duration.zero : Motion.overlay,
            crossFadeState: _tagsOpen
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Column(
                children: [
                  for (var i = 0; i < tagRows.length; i++) ...[
                    if (i > 0) const _FactDivider(),
                    _factRow(tagRows[i][0], tagRows[i][1]),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Year from a tag date ("2001", "2001-05-15", "2001.05.15").
  static String? _yearOf(TagFields? t) {
    final date = t?[kDate];
    if (date == null) return null;
    final m = RegExp(r'(\d{4})').firstMatch(date);
    return m?.group(1);
  }

  /// BPM display: whole when it reads whole (128), one decimal
  /// otherwise (111.0). Embedded tags land whole; DSP floats.
  static String _fmtBpm(double bpm) {
    final r = bpm.roundToDouble();
    return (bpm - r).abs() < 0.05 ? '${r.toInt()}' : bpm.toStringAsFixed(1);
  }

  Widget _factRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              k,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
            ),
          ),
          const SizedBox(width: 12),
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
    return Divider(
      height: 1,
      thickness: 1,
      color:
          Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
    );
  }
}
