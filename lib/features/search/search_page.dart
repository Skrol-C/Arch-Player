import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/art_tone.dart';
import '../../core/badges.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/artist_page.dart';
import '../library/library_providers.dart';
import '../library/album_page.dart' show AlbumPage;
import '../needle/calling.dart';
import '../needle/extension.dart';
import '../needle/extensions.dart';
import '../needle/needle_store.dart';
import '../needle/preview_play.dart';
import '../needle/download_sheet.dart';
import '../needle/fly_to_needle.dart';
import '../player/player_providers.dart';
import '../player/play_guarded.dart';
import '../needle/sandbox.dart';
import '../player/track_menu.dart';
import '../song/song_page.dart';
import 'provider_marks.dart';
import 'router.dart';
import 'search_providers.dart';

/// Search destination: finds and triggers, never manages.
/// Frost-capsule bar (picker prefix, X suffix), icon pills, results
/// grouped Artists / Songs / Albums / Playlists. Artist portraits
/// circular, everything else rounded-rectangle. Artists open their
/// page on tap; albums/playlists expand inline; songs/albums/
/// playlists carry a ... menu. Artists carry no menu.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _Hit {
  final String providerId;
  final String id;
  final String name;
  final String artists;
  final String album;
  final String art;
  final String isrc;
  final int durationMs;
  final String kind;
  final bool explicit;
  final String previewUrl;
  final String releaseType;
  const _Hit({
    required this.providerId,
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.art,
    required this.isrc,
    required this.durationMs,
    required this.kind,
    this.explicit = false,
    this.previewUrl = '',
    this.releaseType = '',
  });
}

/// Parental-advisory E mark. Rendered only when a provider says so.
class _EBadge extends StatelessWidget {
  const _EBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: inkDim, width: 1.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'E',
        style: TextStyle(
          color: inkDim,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          height: 1.2,
        ),
      ),
    );
  }
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  String _via = '';
  String? _notice;
  List<_Hit> _hits = const [];
  Map<String, String>? _direct;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<InstalledExtension> _metadataProviders() {
    final all = ref.read(installedExtensionsProvider);
    final sel = ref.read(searchProviderIdProvider);
    final list = [
      for (final p in all)
        if (p.enabled && p.roles.contains('metadata')) p,
    ]..sort((a, b) => a.priority.compareTo(b.priority));
    if (sel.isEmpty) return list;
    return [for (final p in list) if (p.id == sel) p];
  }

  List<InstalledExtension> _downloaders() {
    final all = ref.read(installedExtensionsProvider);
    return [
      for (final p in all)
        if (p.enabled && p.roles.contains('download')) p,
    ];
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _hits = const [];
      _direct = null;
      _via = '';
    });
    HapticFeedback.selectionClick();
    try {
      if (SearchRouter.isUrl(q)) {
        await _searchUrl(q);
      } else {
        await _searchText(q);
      }
    } on NeedleException catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendly(e));
      ArchLog.w('search', 'search failed: ${e.code}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    unawaited(_probePreview());
  }

  Future<void> _searchUrl(String q) async {
    final providers = ref.read(installedExtensionsProvider);
    final resolved = await SearchRouter.resolveUrl(q, providers);
    if (resolved != null) {
      final value = resolved['value'];
      final pid = (resolved['providerId'] ?? '').toString();
      final norm = _fromTyped(value, pid);
      if (!mounted) return;
      setState(() {
        _hits = norm.hits;
        _direct = norm.direct;
        _via = pid;
        if (norm.hits.isEmpty && norm.direct == null) {
          _error = 'Resolved but empty. Try another link.';
        }
      });
      ArchLog.i('search',
          'url "$q": ${norm.hits.length} hits via $pid');
      return;
    }
    final odesli = await OdesliClient.resolve(q);
    if (odesli != null) {
      final direct = _directOfOdesli(odesli);
      if (!mounted) return;
      setState(() {
        _direct = direct;
        _via = 'odesli';
        _notice = 'Matched across services. Pick a result to pull.';
      });
      await _searchText(q, keepDirect: true);
      return;
    }
    if (!mounted) return;
    setState(() => _notice = 'Link not claimed. Showing text results.');
    await _searchText(q, keepDirect: true);
  }

  Future<void> _searchText(String q, {bool keepDirect = false}) async {
    final providers = _metadataProviders();
    final out = await callProviders(
      'metadata',
      'searchTracks',
      [q, 20],
      providers: providers,
      timeoutMs: 30000,
    );
    final hits = _parse(out['value']);
    String via = '';
    for (final h in hits) {
      if (h.providerId.isNotEmpty) {
        via = h.providerId;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _hits = hits;
      if (!keepDirect) _direct = null;
      _via = via;
      if (hits.isEmpty && _direct == null) {
        _error = 'No results. Try another query.';
      }
    });
    ArchLog.i('search', 'text "$q": ${hits.length} hits via $via');
  }

  Future<void> _probePreview() async {
    final ids = <String>{
      for (final h in _hits)
        if (h.providerId.isNotEmpty) h.providerId,
    };
    if (ids.isEmpty) return;
    final known =
        Map<String, bool>.from(ref.read(previewCapableProvider));
    var changed = false;
    for (final id in ids) {
      if (known.containsKey(id)) continue;
      var capable = false;
      try {
        final h = await loadExtension(id);
        final fns = await extensionFunctions(h.handle, timeoutMs: 5000);
        capable = fns.contains('getTrack');
      } catch (_) {}
      known[id] = capable;
      changed = true;
    }
    if (changed && mounted) {
      ref.read(previewCapableProvider.notifier).state =
          Map<String, bool>.unmodifiable(known);
    }
  }

  String _friendly(NeedleException e) {
    return switch (e.code) {
      'no-provider' => 'No search providers enabled. Add one in Settings > Extensions.',
      'bridge-down' => 'Engine unavailable. Restart the app.',
      _ => 'Search failed. Try again.',
    };
  }

  /// Typed handleURL envelope -> direct card + hits. Shapes follow
  /// the registry extensions (MIT): {type:track, track}, {type:album,
  /// album, tracks}, {type:artist, artist}, {type:playlist, tracks,
  /// name, cover_url}. Anything else falls back to the flat parse.
  ({Map<String, String>? direct, List<_Hit> hits}) _fromTyped(
      dynamic value, String pid) {
    if (value is Map && value['type'] is String) {
      final type = (value['type'] as String).toLowerCase();
      if (type == 'track' && value['track'] is Map) {
        final hit = _trackHit(value['track'] as Map, pid);
        if (hit != null) {
          return (
            direct: {
              'title': hit.name,
              'subtitle': hit.artists,
              'art': hit.art,
              'via': pid,
              if (hit.explicit) 'explicit': 'true',
            },
            hits: [hit],
          );
        }
      } else if (type == 'album' && value['album'] is Map) {
        final a = value['album'] as Map;
        final name = (a['name'] ?? '').toString();
        final raw = value['tracks'];
        final hits = [
          for (final t in (raw is List ? raw : const []))
            if (t is Map) _trackHit(t, pid, albumFallback: name),
        ].whereType<_Hit>().toList();
        if (name.isNotEmpty || hits.isNotEmpty) {
          return (
            direct: {
              'title': name,
              'subtitle': (a['artists'] ?? '').toString(),
              'art': (a['cover_url'] ?? a['images'] ?? '').toString(),
              'via': pid,
              if (_explicitOf(a)) 'explicit': 'true',
            },
            hits: hits,
          );
        }
      } else if (type == 'artist' && value['artist'] is Map) {
        final hit =
            _trackHit(value['artist'] as Map, pid, kind: 'artist');
        if (hit != null) {
          return (
            direct: {
              'title': hit.name,
              'subtitle': 'Artist',
              'art': hit.art,
              'via': pid,
            },
            hits: [hit],
          );
        }
      } else if (type == 'playlist') {
        final raw = value['tracks'];
        final name = (value['name'] ?? '').toString();
        final hits = [
          for (final t in (raw is List ? raw : const []))
            if (t is Map)
              _trackHit(t, pid,
                  albumFallback: name,
                  artFallback: (value['cover_url'] ?? '').toString()),
        ].whereType<_Hit>().toList();
        if (name.isNotEmpty || hits.isNotEmpty) {
          return (
            direct: {
              'title': name,
              'subtitle': 'Playlist',
              'art': (value['cover_url'] ?? '').toString(),
              'via': pid,
              if (_explicitOf(value)) 'explicit': 'true',
            },
            hits: hits,
          );
        }
      }
    }
    final hits =
        _parse(value is List ? value : value is Map ? [value] : []);
    return (direct: null, hits: hits);
  }

  /// One extension track/artist map -> hit. Field names vary per
  /// provider (name/title, artists/artist, cover/images/thumbnail,
  /// duration_ms/duration-seconds). Null = unusable row.
  _Hit? _trackHit(Map m, String pid,
      {String kind = 'track',
      String? albumFallback,
      String? artFallback}) {
    final name = (m['name'] ?? m['title'] ?? '').toString();
    if (name.isEmpty) return null;
    final art = (m['cover_url'] ??
            m['images'] ??
            m['thumbnail'] ??
            m['image_url'] ??
            artFallback ??
            '')
        .toString();
    var durMs = 0;
    final dms = m['duration_ms'];
    if (dms is num) {
      durMs = dms.toInt();
    } else {
      final d = m['duration'];
      if (d is num && d > 0) durMs = (d * 1000).toInt();
    }
    return _Hit(
      providerId: (m['provider_id'] ?? m['source'] ?? pid).toString(),
      id: (m['id'] ?? '').toString(),
      name: name,
      artists:
          (m['artists'] ?? m['artist'] ?? m['owner'] ?? '').toString(),
      album:
          (m['album_name'] ?? m['album'] ?? albumFallback ?? '').toString(),
      art: art,
      isrc: (m['isrc'] ?? '').toString(),
      durationMs: durMs,
      kind: kind,
      explicit: _explicitOf(m),
      previewUrl: _previewOf(m),
      releaseType: kind == 'album' ? _releaseTypeOf(m) : '',
    );
  }

  Map<String, String>? _directOfOdesli(Map<String, dynamic> m) {
    try {
      final entities = m['entitiesByUniqueId'] as Map?;
      if (entities == null || entities.isEmpty) return null;
      final first = entities.values.first as Map;
      final title = (first['title'] ?? '').toString();
      if (title.isEmpty) return null;
      return {
        'title': title,
        'subtitle': (first['artistName'] ?? '').toString(),
        'art': (first['thumbnailUrl'] ?? first['thumbnailWidth'] ?? '').toString(),
        'via': 'odesli',
      };
    } catch (_) {
      return null;
    }
  }

  static String _previewOf(Map item) {
    for (final k in ['preview_url', 'previewUrl', 'preview']) {
      final v = (item[k] ?? '').toString();
      if (v.startsWith('http://') || v.startsWith('https://')) return v;
    }
    return '';
  }

  static bool _explicitOf(Map item) {
    final v = item['explicit'] ?? item['is_explicit'] ?? item['isExplicit'];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final t = v.trim().toLowerCase();
      return t == 'true' || t == '1' || t == 'explicit';
    }
    return false;
  }

  /// Release type for the black SINGLE/EP badge: single/ep
  /// only; albums are the default and stay unbadged. Reads the
  /// extension's own album_type/albumType first, empty otherwise.
  static String _releaseTypeOf(Map item) {
    final raw =
        (item['album_type'] ?? item['albumType'] ?? '').toString().toLowerCase();
    // Bare "ep"/"single" item_types that never set album_type.
    final kindRaw = (item['item_type'] ?? item['type'] ?? '').toString().toLowerCase();
    final v = raw.isNotEmpty ? raw : kindRaw;
    if (v.contains('single')) return 'single';
    if (v == 'ep' || v.contains(' e.p') || v.contains('(ep)') || v.contains('ep,')) {
      return 'ep';
    }
    if (v.contains('ep')) {
      // Guarded: "deep", "keep", "sleep" contain ep. Match whole
      // words and the common "Name - EP"/"EP - Name" shapes only.
      final words = v.split(RegExp(r'[^a-z]+'));
      if (words.contains('ep')) return 'ep';
    }
    return '';
  }

  List<_Hit> _parse(dynamic value) {
    final out = <_Hit>[];
    if (value is! List) return out;
    var loggedKeys = false;
    for (final item in value) {
      if (item is! Map) continue;
      final name = (item['name'] ?? item['title'] ?? '').toString();
      if (name.isEmpty) continue;
      final art =
          (item['cover_url'] ?? item['images'] ?? item['thumbnail'] ?? '')
              .toString();
      final rawKind =
          (item['item_type'] ?? item['album_type'] ?? item['type'] ?? 'track')
              .toString()
              .toLowerCase();
      final kind = rawKind.contains('artist')
          ? 'artist'
          : rawKind.contains('playlist')
              ? 'playlist'
              : rawKind.contains('album') ||
                      rawKind.contains('ep') ||
                      rawKind.contains('single')
                  ? 'album'
                  : 'track';
      out.add(_Hit(
        providerId: (item['provider_id'] ?? '').toString(),
        id: (item['id'] ?? '').toString(),
        name: name,
        artists: (item['artists'] ?? item['artist'] ?? item['owner'] ?? '')
            .toString(),
        album: (item['album_name'] ?? item['album'] ?? '').toString(),
        art: art,
        isrc: (item['isrc'] ?? '').toString(),
        durationMs: (item['duration_ms'] is num)
            ? (item['duration_ms'] as num).toInt()
            : 0,
        kind: kind,
        explicit: _explicitOf(item),
        previewUrl: _previewOf(item),
        releaseType: kind == 'album' ? _releaseTypeOf(item) : '',
      ));
      // One diagnostic per search: which keys an album-kind item
      // carries determines badge/label/genre coverage.
      if (!loggedKeys && kind != 'track') {
        loggedKeys = true;
        ArchLog.i(
          'search',
          'item keys ($kind via ${(item['provider_id'] ?? '').toString()}): ${item.keys.map((k) => k.toString()).join(',')}',
        );
      }
    }
    return out;
  }

  /// Visible groups in fixed order. The pills pick one group or all.
  List<({SearchFilter filter, List<_Hit> hits})> _groups() {
    final sel = ref.watch(searchFilterProvider);
    List<_Hit> of(String kind) =>
        [for (final h in _hits) if (h.kind == kind) h];
    final all = [
      (filter: SearchFilter.artists, hits: of('artist')),
      (filter: SearchFilter.songs, hits: of('track')),
      (filter: SearchFilter.albums, hits: of('album')),
      (filter: SearchFilter.playlists, hits: of('playlist')),
    ];
    if (sel == SearchFilter.all) return all;
    return [for (final g in all) if (g.filter == sel) g];
  }

  @override
  Widget build(BuildContext context) {
    final downloaders = _downloaders();
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                'Search',
                style: TextStyle(
                  fontFamily: 'ArchSerif',
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: _SearchBar(
                controller: _controller,
                busy: _busy,
                onSubmit: _search,
                onClear: () {
                  _controller.clear();
                  setState(() {
                    _hits = const [];
                    _direct = null;
                    _error = null;
                    _notice = null;
                    _via = '';
                  });
                },
                onPick: () {
                  if (_controller.text.trim().isNotEmpty) _search();
                },
              ),
            ),
            _filterRow(),
            if (_via.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  'via $_via',
                  style: const TextStyle(color: inkDim, fontSize: 12),
                ),
              ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  _notice!,
                  style: const TextStyle(color: inkDim, fontSize: 12),
                ),
              ),
            Expanded(child: _body(downloaders)),
          ],
        ),
      ),
    );
  }

  Widget _filterRow() {
    final sel = ref.watch(searchFilterProvider);
    const icons = {
      SearchFilter.all: Icons.grid_view_rounded,
      SearchFilter.songs: Icons.music_note_rounded,
      SearchFilter.artists: Icons.person_rounded,
      SearchFilter.albums: Icons.album_rounded,
      SearchFilter.playlists: Icons.queue_music_rounded,
    };
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        itemCount: SearchFilter.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final f = SearchFilter.values[i];
          final on = sel == f;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              ref.read(searchFilterProvider.notifier).state = f;
            },
            child: AnimatedContainer(
              duration: Motion.stateChange,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: on ? archPink : paperRaised,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icons[f], size: 16, color: on ? Colors.white : ink),
                  const SizedBox(width: 6),
                  Text(
                    f.label,
                    style: TextStyle(
                      color: on ? Colors.white : ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _body(List<InstalledExtension> downloaders) {
    if (_busy && _hits.isEmpty && _direct == null) {
      return const Center(child: CircularProgressIndicator(color: archPink));
    }
    if (_error != null && _hits.isEmpty && _direct == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: inkDim, height: 1.5),
          ),
        ),
      );
    }
    if (_hits.isEmpty && _direct == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: const [
          FocalEntrance(
            child: Text(
              'Find it, pull it.',
              style: TextStyle(
                fontFamily: 'ArchSerif',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Search songs, artists, albums, playlists - or paste a link from any installed provider and it resolves here.',
            style: TextStyle(color: inkDim, height: 1.5),
          ),
        ],
      );
    }
    final groups = _groups();
    final totalRows =
        groups.fold<int>(0, (n, g) => n + g.hits.length) +
            (_direct != null ? 1 : 0);
    if (totalRows == 0) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Nothing in this group. Try another pill.',
            textAlign: TextAlign.center,
            style: TextStyle(color: inkDim, height: 1.5),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 48),
      children: [
        if (_direct != null) ...[
          _DirectCard(direct: _direct!),
          const SizedBox(height: 12),
        ],
        for (final g in groups)
          if (g.hits.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              child: Text(
                g.filter.label,
                style: const TextStyle(
                  fontFamily: 'ArchSerif',
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            _GroupCard(
              groupKey:
                  '${g.filter.name}:${g.hits.length}:$_via',
              hits: g.hits,
              downloaders: downloaders,
            ),
          ],
      ],
    );
  }
}

/// Frost-capsule bar: translucent fill, hairline border, soft shadow,
/// pink focus ring. Picker prefix, X suffix. Solid frost, never a
/// refractive lens in content.
class _SearchBar extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;
  final VoidCallback onClear;
  final VoidCallback onPick;
  const _SearchBar({
    required this.controller,
    required this.busy,
    required this.onSubmit,
    required this.onClear,
    required this.onPick,
  });

  @override
  ConsumerState<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends ConsumerState<_SearchBar> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
    widget.controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.isNotEmpty;
    return AnimatedContainer(
      duration: Motion.stateChange,
      decoration: BoxDecoration(
        color: paperRaised.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: _focused ? archPink : ink.withValues(alpha: 0.08),
          width: _focused ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: ink.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _ProviderPicker(onPick: widget.onPick),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => widget.onSubmit(),
              decoration: const InputDecoration(
                hintText: 'Songs, artists, albums, or paste a link',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (widget.busy)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: archPink, strokeWidth: 2),
              ),
            )
          else if (hasText)
            IconButton(
              tooltip: 'Clear',
              onPressed: () {
                HapticFeedback.selectionClick();
                widget.onClear();
              },
              icon: const Icon(Icons.cancel_rounded, color: inkDim),
            ),
        ],
      ),
    );
  }
}

/// The magnifier IS the provider picker: shows the selected mark
/// (or the glass for Auto), tap for the dropdown. Solid menu, never
/// glass over glass. Marks sit on white-circle tiles so any logo
/// background quirks vanish.
class _ProviderPicker extends ConsumerWidget {
  final VoidCallback onPick;
  const _ProviderPicker({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(installedExtensionsProvider);
    final metas = [
      for (final p in all)
        if (p.roles.contains('metadata')) p,
    ]..sort((a, b) => a.priority.compareTo(b.priority));
    final sel = ref.watch(searchProviderIdProvider);
    InstalledExtension? current;
    for (final p in metas) {
      if (p.id == sel) current = p;
    }
    return PopupMenuButton<String>(
      tooltip: 'Search provider',
      offset: const Offset(0, 52),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: paper,
      onSelected: (id) {
        ref.read(searchProviderIdProvider.notifier).set(id);
        onPick();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: '',
          child: Row(
            children: [
              const ProviderMark(id: '', displayName: '', size: 28),
              const SizedBox(width: 12),
              const Expanded(child: Text('Auto')),
              if (sel.isEmpty)
                const Icon(Icons.check_rounded, color: archPink),
            ],
          ),
        ),
        for (final p in metas)
          PopupMenuItem(
            value: p.id,
            child: Row(
              children: [
                _MenuMark(id: p.id, displayName: p.displayName),
                const SizedBox(width: 12),
                Expanded(child: Text(p.displayName)),
                if (sel == p.id)
                  const Icon(Icons.check_rounded, color: archPink),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (current == null)
              // Auto reads as smart search: sparkles, not the glass.
              const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.auto_awesome_rounded,
                    color: archPink, size: 24),
              )
            else
              Padding(
                padding: const EdgeInsets.all(8),
                child: ProviderMark(
                    id: current.id,
                    displayName: current.displayName,
                    size: 32),
              ),
            const Positioned(
              right: 2,
              bottom: 2,
              child: Icon(
                Icons.arrow_drop_down_rounded,
                color: inkDim,
                size: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Menu-row mark: wide wordmarks get room, square icons stay square,
/// missing marks fall back to a letter tile.
class _MenuMark extends StatelessWidget {
  final String id;
  final String displayName;
  const _MenuMark({required this.id, required this.displayName});

  @override
  Widget build(BuildContext context) {
    final wide = providerMarkWideAsset(id, displayName);
    if (wide != null) {
      return Container(
        width: 52,
        height: 28,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 40,
          child: SvgPicture.asset(wide),
        ),
      );
    }
    return ProviderMark(id: id, displayName: displayName, size: 28);
  }
}

/// Provider mark on a white-circle tile with initial-letter fallback.
/// Never blank, never a broken image.
class ProviderMark extends StatelessWidget {
  final String id;
  final String displayName;
  final double size;
  const ProviderMark(
      {super.key,
      required this.id,
      required this.displayName,
      this.size = 24});

  @override
  Widget build(BuildContext context) {
    final asset = providerMarkAsset(id, displayName);
    Widget inner;
    if (asset == null) {
      final initial = displayName.isEmpty
          ? '?'
          : displayName.substring(0, 1).toUpperCase();
      inner = Text(
        initial,
        style: TextStyle(
            fontWeight: FontWeight.w700, fontSize: size * 0.45),
      );
    } else {
      inner = Padding(
        padding: EdgeInsets.all(size * 0.18),
        child: SvgPicture.asset(asset),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: ink.withValues(alpha: 0.08)),
      ),
      alignment: Alignment.center,
      child: inner,
    );
  }
}

/// Direct-match card: art-first header tinted from the art wash.
/// Solid wash, never a refractive lens in content.
class _DirectCard extends StatelessWidget {
  final Map<String, String> direct;
  const _DirectCard({required this.direct});

  @override
  Widget build(BuildContext context) {
    final art = direct['art'] ?? '';
    final title = direct['title'] ?? '';
    final subtitle = direct['subtitle'] ?? '';
    final via = direct['via'] ?? '';
    return FutureBuilder<ArtPalette?>(
      future: ArtTone.paletteOf(art.isEmpty ? null : art),
      builder: (context, snap) {
        final wash = ArtTone.pageWashOf(snap.data?.wash);
        return Container(
          decoration: BoxDecoration(
            color: wash,
            borderRadius: BorderRadius.circular(18),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: art.isEmpty
                    ? Container(
                        width: 72,
                        height: 72,
                        color: paperRaised,
                        child: const Icon(
                            Icons.music_note_rounded, color: inkDim),
                      )
                    : CachedNetworkImage(
                        imageUrl: art,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        // Bounded decode: 72px display never needs the
                        // full file (menu-travel jank came from this).
                        memCacheWidth: 144,
                        memCacheHeight: 144,
                        maxWidthDiskCache: 256,
                        maxHeightDiskCache: 256,
                        errorWidget: (_, _, _) => Container(
                          width: 72,
                          height: 72,
                          color: paperRaised,
                          child: const Icon(
                              Icons.music_note_rounded, color: inkDim),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 17),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: inkDim, fontSize: 13),
                      ),
                    if (via.isNotEmpty)
                      Row(
                        children: [
                          Text(
                            'via $via',
                            style: const TextStyle(
                                color: archPink,
                                fontSize: 11,
                                fontWeight: FontWeight.w600),
                          ),
                          if ((direct['explicit'] ?? '') == 'true') ...[
                            const SizedBox(width: 8),
                            const _EBadge(),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One continuous group card: rounded ends, hairline dividers
/// between rows (SpotiFLAC's section grammar). Groups stay
/// separated under their display headers.
class _GroupCard extends StatelessWidget {
  final String groupKey;
  final List<_Hit> hits;
  final List<InstalledExtension> downloaders;
  const _GroupCard({
    required this.groupKey,
    required this.hits,
    required this.downloaders,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < hits.length; i++) ...[
            _Row(
              hit: hits[i],
              downloaders: downloaders,
              key: ValueKey('$groupKey:${hits[i].providerId}:${hits[i].id}:${hits[i].kind}'),
            ),
            if (i < hits.length - 1)
              const Divider(
                height: 1,
                thickness: 1,
                indent: 88,
                endIndent: 16,
                color: Color(0x140B0B0D),
              ),
          ],
        ],
      ),
    );
  }
}

class _Row extends ConsumerStatefulWidget {
  final _Hit hit;
  final List<InstalledExtension> downloaders;
  const _Row({super.key, required this.hit, required this.downloaders});

  @override
  ConsumerState<_Row> createState() => _RowState();
}

class _RowState extends ConsumerState<_Row> {
  bool _pulling = false;
  bool _done = false;
  bool _expanded = false;
  bool _resolving = false;

  Future<void> _pull() async {
    // Search pulls go through the download sheet (provider +
    // quality choice); the queue, router, and hub retry live
    // downstream. Verify grants complete from the hub row.
    if (_pulling || _done) return;
    setState(() => _pulling = true);
    HapticFeedback.selectionClick();
    final from = rowRect(context);
    final enqueued = await showDownloadSheet(
      context,
      ref,
      title: widget.hit.name,
      artist: widget.hit.artists,
      album: widget.hit.album,
      art: widget.hit.art,
      isrc: widget.hit.isrc,
      providerId: widget.hit.providerId,
      releaseType: widget.hit.kind == 'track'
          ? (widget.hit.releaseType.isNotEmpty
              ? widget.hit.releaseType
              : 'single')
          : widget.hit.releaseType,
    );
    if (!mounted) return;
    setState(() {
      _pulling = false;
      if (enqueued) _done = true;
    });
    if (enqueued) {
      HapticFeedback.mediumImpact();
      if (from != null) {
        await flyToNeedle(context, art: widget.hit.art, from: from);
      }
    }
  }

  Future<void> _onTap() async {
    final hit = widget.hit;
    if (hit.kind == 'artist') {
      if (hit.name.isNotEmpty) {
        ArtistPage.openIfAbsent(context, hit.name);
      }
      return;
    }
    if (hit.kind == 'album' || hit.kind == 'playlist') {
      setState(() => _expanded = !_expanded);
      HapticFeedback.selectionClick();
      return;
    }
    // Tracks: owned plays the full song, remote previews.
    // Badges above make the outcome visible before the tap.
    if (_resolving) return;
    final owned = ownedSongFor(
      ref,
      hit.name,
      hit.artists.isNotEmpty ? hit.artists : hit.name,
    );
    setState(() => _resolving = true);
    HapticFeedback.selectionClick();
    if (owned != null) {
      final handler = ref.read(audioHandlerProvider);
      await playAndOpen(
        ref,
        context,
        () => handler.playSong(owned, [owned]),
      );
      if (mounted) setState(() => _resolving = false);
      return;
    }
    var providerName = hit.providerId;
    for (final p in ref.read(installedExtensionsProvider)) {
      if (p.id == hit.providerId) {
        providerName = p.displayName;
        break;
      }
    }
    setState(() => _resolving = true);
    HapticFeedback.selectionClick();
    await playSearchPreview(
      ref,
      context,
      providerId: hit.providerId,
      providerName:
          providerName.isEmpty ? 'provider' : providerName,
      trackId: hit.id,
      title: hit.name,
      artist: hit.artists,
      album: hit.album,
      art: hit.art,
      previewUrl: hit.previewUrl,
    );
    if (mounted) setState(() => _resolving = false);
  }

  void _viewArtist() {
    final name = widget.hit.artists.isNotEmpty
        ? widget.hit.artists
        : widget.hit.name;
    if (name.isNotEmpty) ArtistPage.openIfAbsent(context, name);
  }

  void _share() {
    final hit = widget.hit;
    final text = [hit.name, hit.artists]
        .where((s) => s.isNotEmpty)
        .join(' - ');
    if (text.isNotEmpty) {
      SharePlus.instance.share(ShareParams(text: text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    // Owned + previewable badges: index lookup (title bucket),
    // live off the library so a landed pull flips the row.
    Song? owned;
    if (hit.kind == 'track') {
      final bucket =
          ref.watch(searchOwnedIndexProvider)[normTitle(hit.name)] ??
              const <Song>[];
      final who = hit.artists.isNotEmpty ? hit.artists : hit.name;
      for (final s in bucket) {
        if (artistsOverlap(s.artist, who)) {
          owned = s;
          break;
        }
      }
    }
    final capable = ref.watch(previewCapableProvider);
    final previewable = hit.kind == 'track' &&
        owned == null &&
        (hit.previewUrl.isNotEmpty ||
            (capable[hit.providerId] ?? false));
    final dur = hit.durationMs > 0
        ? '${hit.durationMs ~/ 60000}:${((hit.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}'
        : '';
    final tag = switch (hit.kind) {
      'artist' => 'Artist',
      'album' => 'Album',
      'playlist' => 'Playlist',
      _ => dur,
    };
    final image = hit.art.isEmpty
        ? Container(
            width: 64,
            height: 64,
            color: paper,
            child: const Icon(Icons.music_note_rounded,
                color: inkDim, size: 28),
          )
        : CachedNetworkImage(
            imageUrl: hit.art,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            memCacheWidth: 128,
            memCacheHeight: 128,
            maxWidthDiskCache: 256,
            maxHeightDiskCache: 256,
            errorWidget: (_, _, _) => Container(
              width: 64,
              height: 64,
              color: paper,
              child: const Icon(Icons.music_note_rounded,
                  color: inkDim, size: 28),
            ),
          );
    // Every row answers its tap: artists open, albums expand,
    // owned tracks play full, remote tracks preview.
    final leading = hit.kind == 'artist'
        ? ClipOval(child: image)
        : ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: image,
          );
    return Column(
      children: [
        // Own transparent Material: the card Container paints behind
        // this tile, and without one every tap throws the
        // invisible-splash exception per row per frame (menu jank).
        Material(
          type: MaterialType.transparency,
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            leading: leading,
            title: Text(
              hit.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 16),
            ),
            subtitle: Text(
              [hit.artists, tag].where((s) => s.isNotEmpty).join('  |  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: inkDim, fontSize: 13),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (owned != null) ...[
                  const Icon(Icons.check_circle_rounded,
                      color: archPink, size: 20),
                  const SizedBox(width: 8),
                ],
                if (previewable) ...[
                  const Icon(Icons.play_circle_outline_rounded,
                      color: inkDim, size: 20),
                  const SizedBox(width: 8),
                ],
                if (hit.releaseType.isNotEmpty) ...[
                  TypeBadge(label: hit.releaseType),
                  const SizedBox(width: 8),
                ],
                if (hit.explicit) ...[
                  const _EBadge(),
                  const SizedBox(width: 8),
                ],
                _trailing(),
              ],
            ),
            onTap: _onTap,
          ),
        ),
        if (_expanded && (hit.kind == 'album' || hit.kind == 'playlist'))
          _CollectionTracks(
            hit: hit,
            downloaders: widget.downloaders,
          ),
      ],
    );
  }

  Widget _trailing() {
    if (_done) {
      return const Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle_rounded, color: archPink),
      );
    }
    if (_pulling || _resolving) {
      return const Padding(
        padding: EdgeInsets.only(right: 8),
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(color: archPink, strokeWidth: 2),
        ),
      );
    }
    // Artists carry no menu: the whole row opens their page.
    if (widget.hit.kind == 'artist') return const SizedBox.shrink();
    // The house glass popover, anchored at the button - never the
    // generic popup.
    return Builder(
      builder: (btnContext) => GestureDetector(
        onTap: () => _openMenu(btnContext),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.more_horiz_rounded, color: ink),
        ),
      ),
    );
  }

  Future<void> _openMenu(BuildContext btnContext) async {
    final hit = widget.hit;
    // Song page opens for tracks: owned resolves to the library
    // song, remote carries provider facts and adapts. Albums and
    // playlists expand inline instead - their titles must never
    // false-match a same-named song.
    final isTrack = hit.kind == 'track';
    final isAlbum = hit.kind == 'album';
    final owned = isTrack
        ? ownedSongFor(
            ref,
            hit.name,
            hit.artists.isNotEmpty ? hit.artists : hit.name,
          )
        : null;
    // Owned album match for album rows: same discipline as the
    // song hero (normalized title + artist overlap).
    Album? ownedAlbum;
    if (isAlbum) {
      final want = normTitle(hit.name);
      for (final a in ref.read(albumsProvider)) {
        if (normTitle(a.title) == want &&
            a.songs.any((s) => artistsOverlap(s.artist, hit.artists))) {
          ownedAlbum = a;
          break;
        }
      }
    }
    final oa = ownedAlbum;
    final songRef = owned != null
        ? SongRef.owned(owned)
        : isTrack
            ? SongRef.remote(
                title: hit.name,
                artist: hit.artists,
                album: hit.album,
                artUrl: hit.art,
                durationMs: hit.durationMs,
                isrc: hit.isrc,
                providerId: hit.providerId,
                explicit: hit.explicit,
              )
            : null;
    final value = await showTrackMenu(
      context: btnContext,
      groups: [
        [
          if (songRef != null)
            MenuAction(
              icon: CupertinoIcons.music_note,
              label: 'Song page',
              subtitle: hit.name,
              value: 'song',
            ),
          if (oa != null)
            MenuAction(
              icon: CupertinoIcons.music_albums,
              label: 'Open album',
              subtitle: hit.name,
              value: 'album',
            ),
          MenuAction(
            icon: CupertinoIcons.cloud_download,
            label: 'Download',
            subtitle: hit.artists.isNotEmpty ? hit.artists : null,
            value: 'pull',
          ),
          const MenuAction(
            icon: CupertinoIcons.person,
            label: 'View artist',
            value: 'artist',
          ),
          MenuAction(
            icon: CupertinoIcons.square_arrow_up,
            label: 'Share',
            subtitle: hit.name,
            value: 'share',
          ),
        ],
      ],
    );
    if (!mounted) return;
    if (value == 'song' && songRef != null) {
      SongPage.open(context, songRef);
    } else if (value == 'album' && oa != null) {
      final album = oa;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AlbumPage(album: album)),
      );
    } else if (value == 'pull') {
      _pull();
    } else if (value == 'artist') {
      _viewArtist();
    } else if (value == 'share') {
      _share();
    }
  }
}

/// Inline album/playlist track list via the metadata provider's
/// getAlbum/getPlaylist entry. Explicit loading/error/empty/data.
class _CollectionTracks extends ConsumerStatefulWidget {
  final _Hit hit;
  final List<InstalledExtension> downloaders;
  const _CollectionTracks(
      {required this.hit, required this.downloaders});

  @override
  ConsumerState<_CollectionTracks> createState() =>
      _CollectionTracksState();
}

class _CollectionTracksState extends ConsumerState<_CollectionTracks> {
  late final Future<List<_Hit>> _future;

  static bool _explicitMap(Map item) {
    final v =
        item['explicit'] ?? item['is_explicit'] ?? item['isExplicit'];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final t = v.trim().toLowerCase();
      return t == 'true' || t == '1' || t == 'explicit';
    }
    return false;
  }

  static String _previewExpansion(Map item) {
    for (final k in ['preview_url', 'previewUrl', 'preview']) {
      final v = (item[k] ?? '').toString();
      if (v.startsWith('http://') || v.startsWith('https://')) return v;
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  InstalledExtension? _ext() {
    final all = ref.read(installedExtensionsProvider);
    final metas = [
      for (final p in all)
        if (p.enabled && p.roles.contains('metadata')) p,
    ]..sort((a, b) => a.priority.compareTo(b.priority));
    if (metas.isEmpty) return null;
    for (final p in metas) {
      if (p.id == widget.hit.providerId) return p;
    }
    final sel = ref.read(searchProviderIdProvider);
    for (final p in metas) {
      if (p.id == sel) return p;
    }
    return metas.first;
  }

  Future<List<_Hit>> _fetch() async {
    final ext = _ext();
    if (ext == null) throw const NeedleException('no-provider', 'none');
    final entry =
        widget.hit.kind == 'playlist' ? 'getPlaylist' : 'getAlbum';
    final h = await loadExtension(ext.id);
    final fns = await extensionFunctions(h.handle);
    if (!fns.contains(entry)) {
      throw NeedleException(
          'no-entry', 'No $entry in ${ext.displayName}');
    }
    final out = await callExtensionFn(h.handle, entry, [widget.hit.id],
        timeoutMs: 30000);
    final value = out['value'];
    List items = const [];
    if (value is Map) {
      final t = value['track_list'] ?? value['tracks'];
      if (t is List) items = t;
    } else if (value is List) {
      items = value;
    }
    final out2 = <_Hit>[];
    for (final item in items) {
      if (item is! Map) continue;
      final name = (item['name'] ?? item['title'] ?? '').toString();
      if (name.isEmpty) continue;
      out2.add(_Hit(
        providerId: ext.id,
        id: (item['id'] ?? '').toString(),
        name: name,
        artists: (item['artists'] ?? item['artist'] ?? widget.hit.artists)
            .toString(),
        album: widget.hit.name,
        art: (item['cover_url'] ?? item['images'] ?? widget.hit.art)
            .toString(),
        isrc: (item['isrc'] ?? '').toString(),
        durationMs: (item['duration_ms'] is num)
            ? (item['duration_ms'] as num).toInt()
            : 0,
        kind: 'track',
        explicit: _explicitMap(item),
        previewUrl: _previewExpansion(item),
      ));
    }
    ArchLog.i(
        'search', '$entry ${widget.hit.id}: ${out2.length} tracks');
    return out2;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_Hit>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  color: archPink, strokeWidth: 2),
            ),
          );
        }
        if (snap.hasError) {
          final e = snap.error;
          final msg = e is NeedleException && e.code == 'no-entry'
              ? 'Track list not supported by this provider.'
              : 'Could not load tracks. Tap to retry.';
          return InkWell(
            onTap: () => setState(() => _future = _fetch()),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(msg,
                  style:
                      const TextStyle(color: inkDim, fontSize: 13)),
            ),
          );
        }
        final tracks = snap.data ?? [];
        if (tracks.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No tracks listed.',
                style: TextStyle(color: inkDim, fontSize: 13)),
          );
        }
        return Column(
          children: [
            const Divider(height: 1, indent: 16, endIndent: 16),
            for (final t in tracks)
              _SubRow(hit: t, downloaders: widget.downloaders),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

class _SubRow extends ConsumerWidget {
  final _Hit hit;
  final List<InstalledExtension> downloaders;
  const _SubRow({required this.hit, required this.downloaders});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dur = hit.durationMs > 0
        ? '${hit.durationMs ~/ 60000}:${((hit.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}'
        : '';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      title: Text(
        hit.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        [hit.artists, dur].where((s) => s.isNotEmpty).join('  |  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: inkDim, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hit.explicit) ...[
            const _EBadge(),
            const SizedBox(width: 4),
          ],
          _SubPull(hit: hit, downloaders: downloaders),
        ],
      ),
      onTap: () {
        var providerName = hit.providerId;
        for (final p in ref.read(installedExtensionsProvider)) {
          if (p.id == hit.providerId) {
            providerName = p.displayName;
            break;
          }
        }
        playSearchPreview(
          ref,
          context,
          providerId: hit.providerId,
          providerName:
              providerName.isEmpty ? 'provider' : providerName,
          trackId: hit.id,
          title: hit.name,
          artist: hit.artists,
          album: hit.album,
          art: hit.art,
          previewUrl: hit.previewUrl,
        );
      },
    );
  }
}

class _SubPull extends ConsumerStatefulWidget {
  final _Hit hit;
  final List<InstalledExtension> downloaders;
  const _SubPull({required this.hit, required this.downloaders});

  @override
  ConsumerState<_SubPull> createState() => _SubPullState();
}

class _SubPullState extends ConsumerState<_SubPull> {
  bool _busy = false;
  bool _done = false;

  Future<void> _pull() async {
    if (_busy || _done) return;
    setState(() => _busy = true);
    HapticFeedback.selectionClick();
    final from = rowRect(context);
    final enqueued = await showDownloadSheet(
      context,
      ref,
      title: widget.hit.name,
      artist: widget.hit.artists,
      album: widget.hit.album,
      art: widget.hit.art,
      isrc: widget.hit.isrc,
      providerId: widget.hit.providerId,
      releaseType: '',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (enqueued) _done = true;
    });
    if (enqueued && from != null) {
      await flyToNeedle(context, art: widget.hit.art, from: from);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_done) {
      return const Icon(Icons.check_circle_rounded,
          color: archPink, size: 20);
    }
    if (_busy) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(color: archPink, strokeWidth: 2),
      );
    }
    return IconButton(
      onPressed: _pull,
      icon: const Icon(Icons.cloud_download_outlined,
          color: ink, size: 20),
    );
  }
}
