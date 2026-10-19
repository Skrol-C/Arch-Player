import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../needle/extensions.dart';
import '../needle/needle_store.dart';
import '../needle/preview_play.dart';
import '../needle/queue_runner.dart';
import '../needle/queue_store.dart';
import '../needle/sandbox.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import '../shell/dock.dart';
import 'artist_page.dart';
import 'library_providers.dart';
import 'song_row.dart';

/// Remote collection page: one provider album or playlist, resolved
/// live through the owning extension. Owned tracks play the file,
/// the rest preview; Pull all enqueues the missing ones. Works for
/// entries the library has never seen — no local model required.
class PlaylistPage extends ConsumerStatefulWidget {
  final String providerId;
  final String providerName;
  final String id;
  final String name;
  final String art;
  final String kind;
  final String artist;

  const PlaylistPage({
    super.key,
    required this.providerId,
    required this.providerName,
    required this.id,
    required this.name,
    this.art = '',
    this.kind = 'playlist',
    this.artist = '',
  });

  static void open(
    BuildContext context, {
    required String providerId,
    required String providerName,
    required String id,
    required String name,
    String art = '',
    String kind = 'playlist',
    String artist = '',
  }) {
    ArchLog.i('nav', 'playlist open: $name ($providerId:$id)');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistPage(
          providerId: providerId,
          providerName: providerName,
          id: id,
          name: name,
          art: art,
          kind: kind,
          artist: artist,
        ),
      ),
    );
  }

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PTrack {
  final String id;
  final String name;
  final String artists;
  final String art;
  final int durationMs;
  final String isrc;
  final Song? owned;
  const _PTrack({
    required this.id,
    required this.name,
    this.artists = '',
    this.art = '',
    this.durationMs = 0,
    this.isrc = '',
    this.owned,
  });
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  late final Future<List<_PTrack>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  String get _entry => widget.kind == 'album' ? 'getAlbum' : 'getPlaylist';

  /// Collection-level facts the provider volunteers (spotify/apple
  /// getAlbum carry label/date/genre; absences stay empty, never
  /// placeholder). Read after [_fetch] completes.
  String _label = '';
  String _date = '';
  String _genre = '';

  /// Track list off the owning extension, each row matched against
  /// the library by title + artist overlap + duration window.
  Future<List<_PTrack>> _fetch() async {
    final songs = ref.read(songsProvider).value ?? [];
    final h = await loadExtension(widget.providerId);
    final fns = await extensionFunctions(h.handle, timeoutMs: 8000);
    if (!fns.contains(_entry)) {
      throw NeedleException('no-entry', '${widget.providerId} has no $_entry');
    }
    final out = await callExtensionFn(h.handle, _entry, [
      widget.id,
    ], timeoutMs: 30000);
    final value = out['value'];
    List items = const [];
    if (value is Map) {
      final t = value['track_list'] ?? value['tracks'];
      if (t is List) items = t;
      if (widget.kind == 'album') {
        _label = (value['label'] ?? '').toString();
        _date = (value['release_date'] ?? value['date'] ?? '').toString();
        _genre = (value['genre'] ?? '').toString();
      }
    } else if (value is List) {
      items = value;
    }
    final out2 = <_PTrack>[];
    for (final t in items) {
      if (t is! Map) continue;
      final name = (t['name'] ?? t['title'] ?? '').toString();
      final id = (t['id'] ?? '').toString();
      if (name.isEmpty || id.isEmpty) continue;
      final artists = (t['artists'] ?? t['artist'] ?? '').toString();
      final durMs = (t['duration_ms'] is num)
          ? (t['duration_ms'] as num).toInt()
          : ((t['duration'] is num)
                ? ((t['duration'] as num).toInt() * 1000)
                : 0);
      out2.add(
        _PTrack(
          id: id,
          name: name,
          artists: artists,
          art: (t['cover_url'] ?? t['images'] ?? widget.art).toString(),
          durationMs: durMs,
          isrc: (t['isrc'] ?? '').toString(),
          owned: _ownedMatch(songs, name, artists, durMs),
        ),
      );
    }
    ArchLog.i(
      'playlist',
      '$_entry ${widget.id}: ${out2.length} tracks (${out2.where((t) => t.owned != null).length} owned)',
    );
    return out2;
  }

  Song? _ownedMatch(List<Song> songs, String title, String artists, int durMs) {
    final nt = normTitle(title);
    if (nt.isEmpty) return null;
    for (final s in songs) {
      if (normTitle(s.title) != nt) continue;
      if (artists.trim().isNotEmpty && !artistsOverlap(s.artist, artists)) {
        continue;
      }
      if (durMs > 0 && !durClose(s.duration.inSeconds, durMs ~/ 1000)) {
        continue;
      }
      return s;
    }
    return null;
  }

  Future<void> _playAll(List<_PTrack> tracks) async {
    HapticFeedback.mediumImpact();
    final owned = [
      for (final t in tracks)
        if (t.owned != null) t.owned!,
    ];
    final handler = ref.read(audioHandlerProvider);
    if (owned.isNotEmpty) {
      await playAndOpen(
        ref,
        context,
        () => handler.playSong(owned.first, owned),
      );
      return;
    }
    final first = tracks.where((t) => t.id.isNotEmpty).firstOrNull;
    if (first == null || !mounted) return;
    await playSearchPreview(
      ref,
      context,
      providerId: widget.providerId,
      providerName: widget.providerName,
      trackId: first.id,
      title: first.name,
      artist: first.artists,
      album: widget.kind == 'album' ? widget.name : '',
      art: first.art,
      previewUrl: '',
    );
  }

  void _pullAll(List<_PTrack> tracks) {
    final missing = [
      for (final t in tracks)
        if (t.owned == null && t.id.isNotEmpty) t,
    ];
    if (missing.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Everything here is already yours.')),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    final downloaders = [
      for (final p in ref.read(installedExtensionsProvider))
        if (p.enabled && p.roles.contains('download')) p,
    ];
    if (downloaders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No download provider enabled')),
      );
      return;
    }
    final quality = ref.read(downloadQualityProvider);
    final queue = ref.read(downloadQueueProvider.notifier);
    for (final t in missing) {
      queue.enqueue(
        title: t.name,
        artist: t.artists,
        album: widget.kind == 'album' ? widget.name : '',
        art: t.art,
        isrc: t.isrc,
        providers: downloaders,
        providerId: widget.providerId,
        quality: quality,
      );
    }
    runQueue(ProviderScope.containerOf(context, listen: false));
    ArchLog.i(
      'playlist',
      'pull all "${widget.name}": ${missing.length} queued',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Queued ${missing.length} — watch it in Needle')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: paper,
      body: DockScrollReporter(
        child: Stack(
          children: [
            FutureBuilder<List<_PTrack>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: archPink,
                      strokeWidth: 2,
                    ),
                  );
                }
                if (snap.hasError) {
                  return _error(snap.error.toString());
                }
                final tracks = snap.data ?? [];
                if (tracks.isEmpty) return _empty();
                return _body(context, tracks);
              },
            ),
            const NowPlayingDock(),
          ],
        ),
      ),
    );
  }

  Widget _error(String detail) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This collection would not open.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: inkDim, fontSize: 13),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => setState(() => _future = _fetch()),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.music_note_2, color: inkDim, size: 48),
            const SizedBox(height: 12),
            Text(
              widget.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'No playable tracks found.',
              style: TextStyle(color: inkDim),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text(
                'Go back',
                style: TextStyle(color: archPink, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<_PTrack> tracks) {
    final ownedCount = tracks.where((t) => t.owned != null).length;
    return CustomScrollView(
      physics: const ClampingScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              const SizedBox(height: 64),
              // Art, title, provider line, actions. Back lives in the
              // leading slot; nothing hides behind anything.
              Row(
                children: [
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: paperRaised,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Icon(
                        CupertinoIcons.chevron_left,
                        color: ink,
                      ),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 8),
              if (widget.art.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: CachedNetworkImage(
                    imageUrl: widget.art,
                    width: 200,
                    height: 200,
                    memCacheWidth: 400,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => _artFallback(),
                  ),
                )
              else
                _artFallback(),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  widget.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'ArchSerif',
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.providerName} · ${tracks.length} track${tracks.length == 1 ? '' : 's'}'
                '${ownedCount > 0 ? ' · $ownedCount yours' : ''}',
                style: const TextStyle(color: inkDim, fontSize: 13),
              ),
              const SizedBox(height: 16),
              if (widget.kind == 'album') _albumMeta(context),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () => _playAll(tracks),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: 14,
                      ),
                      decoration: const BoxDecoration(
                        color: archPink,
                        borderRadius: BorderRadius.all(Radius.circular(28)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.play_fill,
                            color: Colors.white,
                            size: 20,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Play',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => _pullAll(tracks),
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: paperRaised,
                        shape: BoxShape.circle,
                        border: Border.all(color: ink.withValues(alpha: 0.08)),
                      ),
                      child: const Icon(
                        CupertinoIcons.arrow_down_to_line,
                        color: ink,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (context, i) {
            final t = tracks[i];
            final owned = t.owned;
            if (owned != null) {
              return SongRow(
                song: owned,
                isCurrent: ref.watch(currentSongProvider).value?.id == owned.id,
                onTap: () => playAndOpen(
                  ref,
                  context,
                  () => ref.read(audioHandlerProvider).playSong(owned, [
                    for (final x in tracks)
                      if (x.owned != null) x.owned!,
                  ]),
                ),
              );
            }
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 4,
              ),
              leading: t.art.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedNetworkImage(
                        imageUrl: t.art,
                        width: 52,
                        height: 52,
                        memCacheWidth: 104,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _thumbFallback(),
                      ),
                    )
                  : _thumbFallback(),
              title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                t.artists.isEmpty ? 'Unknown artist' : t.artists,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: inkDim),
              ),
              trailing: t.durationMs > 0
                  ? Text(
                      fmtDuration(Duration(milliseconds: t.durationMs)),
                      style: const TextStyle(color: inkDim),
                    )
                  : null,
              onTap: () {
                HapticFeedback.selectionClick();
                playSearchPreview(
                  ref,
                  context,
                  providerId: widget.providerId,
                  providerName: widget.providerName,
                  trackId: t.id,
                  title: t.name,
                  artist: t.artists,
                  album: widget.kind == 'album' ? widget.name : '',
                  art: t.art,
                  previewUrl: '',
                );
              },
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 140)),
      ],
    );
  }

  /// Album grammar: tappable artist + label/year/genre chips, each
  /// rendered only when the provider actually supplied it.
  String get _year {
    final m = RegExp(r'^(\d{4})').firstMatch(_date.trim());
    return m?.group(1) ?? '';
  }

  Widget _albumMeta(BuildContext context) {
    final hasArtist = widget.artist.trim().isNotEmpty;
    final hasChips =
        _year.isNotEmpty ||
        _genre.trim().isNotEmpty ||
        _label.trim().isNotEmpty;
    if (!hasArtist && !hasChips) return const SizedBox.shrink();
    return Column(
      children: [
        if (hasArtist)
          GestureDetector(
            onTap: () => ArtistPage.openIfAbsent(context, widget.artist),
            child: Text(
              widget.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: archPink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (hasChips) ...[
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              if (_year.isNotEmpty) _metaChip(_year),
              if (_genre.trim().isNotEmpty)
                _metaChip(_genre.trim().toUpperCase()),
              if (_label.trim().isNotEmpty) _metaChip(_label.trim()),
            ],
          ),
        ],
      ],
    );
  }

  Widget _metaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ink.withValues(alpha: 0.16)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: inkDim,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _artFallback() {
    return Container(
      width: 200,
      height: 200,
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Icon(CupertinoIcons.music_note, color: inkDim, size: 64),
    );
  }

  Widget _thumbFallback() {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(CupertinoIcons.music_note, color: inkDim, size: 24),
    );
  }
}
