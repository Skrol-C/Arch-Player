import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/library_providers.dart';
import 'calling.dart';
import 'extension.dart';
import 'needle_store.dart';
import 'pull.dart';
import 'sandbox.dart';
import 'verify_sheet.dart';
import 'session_grant.dart';

/// Needle search + pull: query across metadata providers, art-led
/// rows, per-row download with honest states. First-ok-wins search
/// (matches engine semantics); the row remembers which provider
/// answered so the pull goes back to the same source.
class NeedleSearchPage extends ConsumerStatefulWidget {
  const NeedleSearchPage({super.key});

  @override
  ConsumerState<NeedleSearchPage> createState() => _NeedleSearchPageState();
}

class _SearchHit {
  final String providerId;
  final String id;
  final String name;
  final String artists;
  final String album;
  final String art;
  final String isrc;
  final int durationMs;
  const _SearchHit({
    required this.providerId,
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.art,
    required this.isrc,
    required this.durationMs,
  });
}

class _NeedleSearchPageState extends ConsumerState<NeedleSearchPage> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  String _via = '';
  List<_SearchHit> _hits = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _hits = const [];
      _via = '';
    });
    HapticFeedback.selectionClick();
    try {
      final providers = ref.read(installedExtensionsProvider);
      final out = await callProviders(
        'metadata',
        'searchTracks',
        [q, 10],
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
        _via = via;
        if (hits.isEmpty) _error = 'No results. Try another query.';
      });
      ArchLog.i('needle', 'search "$q": ${hits.length} hits via $via');
    } on NeedleException catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendly(e));
      ArchLog.w('needle', 'search failed: ${e.code}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(NeedleException e) {
    return switch (e.code) {
      'no-provider' => 'No search providers enabled. Add one in Settings > Extensions.',
      'bridge-down' => 'Engine unavailable. Restart the app.',
      _ => 'Search failed. Try again.',
    };
  }

  List<_SearchHit> _parse(dynamic value) {
    final out = <_SearchHit>[];
    if (value is! List) return out;
    for (final item in value) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final art = (item['cover_url'] ?? item['images'] ?? '').toString();
      out.add(_SearchHit(
        providerId: (item['provider_id'] ?? '').toString(),
        id: (item['id'] ?? '').toString(),
        name: name,
        artists: (item['artists'] ?? '').toString(),
        album: (item['album_name'] ?? '').toString(),
        art: art,
        isrc: (item['isrc'] ?? '').toString(),
        durationMs: (item['duration_ms'] is num)
            ? (item['duration_ms'] as num).toInt()
            : 0,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final providers = ref.watch(installedExtensionsProvider);
    final downloaders = [
      for (final p in providers)
        if (p.enabled && p.roles.contains('download')) p,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Needle')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: 'Search songs to pull',
                      prefixIcon: Icon(Icons.search_rounded,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant),
                      filled: true,
                      fillColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _busy ? null : _search,
                  style: IconButton.styleFrom(backgroundColor: archPink),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.arrow_forward_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
          if (_via.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'via $_via',
                  style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12),
                ),
              ),
            ),
          Expanded(
            child: _buildBody(downloaders),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(List<InstalledExtension> downloaders) {
    if (_error != null && _hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5),
          ),
        ),
      );
    }
    if (_hits.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: [
          FocalEntrance(
            child: Text(
              'Needle',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Music, gotten inside the app. Search above, pull a track, find it in your library.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5),
          ),
          if (downloaders.isEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'No download providers enabled yet.',
              style: TextStyle(color: archPink, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 48),
      itemCount: _hits.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (_, i) {
        final hit = _hits[i];
        return _HitRow(
          hit: hit,
          downloaders: downloaders,
          key: ValueKey('${hit.providerId}:${hit.id}'),
        );
      },
    );
  }
}

class _HitRow extends ConsumerStatefulWidget {
  final _SearchHit hit;
  final List<InstalledExtension> downloaders;
  const _HitRow({super.key, required this.hit, required this.downloaders});

  @override
  ConsumerState<_HitRow> createState() => _HitRowState();
}

class _HitRowState extends ConsumerState<_HitRow> {
  bool _busy = false;
  bool _done = false;
  String? _error;

  InstalledExtension? _providerFor(String providerId) {
    for (final p in widget.downloaders) {
      if (p.id == providerId) return p;
    }
    return widget.downloaders.isEmpty ? null : widget.downloaders.first;
  }

  Future<void> _pull() async {
    if (_busy || _done) return;
    final provider = _providerFor(widget.hit.providerId);
    if (provider == null) {
      setState(() => _error = 'No download provider');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    HapticFeedback.selectionClick();
    try {
      await pullTrack(
        provider: provider,
        title: widget.hit.name,
        artist: widget.hit.artists,
        isrc: widget.hit.isrc,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
      HapticFeedback.mediumImpact();
      // The scan lands on MediaStore's own time: give it a beat,
      // then re-query so the track appears in Library.
      await Future<void>.delayed(const Duration(seconds: 2));
      ref.invalidate(songsProvider);
    } on NeedleException catch (e) {
      if (!mounted) return;
      if (e.code == 'verify-required') {
        final inlineUrl = e.message.startsWith('auth_url=')
            ? e.message.substring('auth_url='.length)
            : '';
        final url = await SessionGrant.resolveAuthUrl(
            provider.id, inlineUrl);
        if (!mounted) return;
        if (url == null || url.isEmpty) {
          setState(() {
            _busy = false;
            _error = 'Verification needed (no URL)';
          });
          return;
        }
        setState(() => _busy = false);
        final granted = await handleVerifyRequired(
          context,
          extId: provider.id,
          displayName: provider.displayName,
          authUrl: url,
        );
        if (granted && mounted) _pull();
        return;
      }
      setState(() {
        _busy = false;
        _error = switch (e.code) {
          'unavailable' => 'Not available from ${provider.displayName}',
          _ => 'Pull failed. Tap to retry.',
        };
      });
      ArchLog.w('needle', 'pull failed: ${e.code} ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    final dur = hit.durationMs > 0
        ? '${hit.durationMs ~/ 60000}:${((hit.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}'
        : '';
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: hit.art.isEmpty
              ? Container(
                  width: 48,
                  height: 48,
                  color: Theme.of(context).colorScheme.surface,
                  child: Icon(Icons.music_note_rounded,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant),
                )
              : CachedNetworkImage(
                  imageUrl: hit.art,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorWidget: (ctx, _, _) => Container(
                    width: 48,
                    height: 48,
                    color: Theme.of(ctx).colorScheme.surface,
                    child: Icon(Icons.music_note_rounded,
                        color: Theme.of(ctx)
                            .colorScheme
                            .onSurfaceVariant),
                  ),
                ),
        ),
        title: Text(
          hit.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Text(
          [hit.artists, dur].where((s) => s.isNotEmpty).join('  ·  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12),
        ),
        trailing: _trailing(),
        onTap: _error != null ? _pull : null,
      ),
    );
  }

  Widget _trailing() {
    if (_done) {
      return const Icon(Icons.check_circle_rounded, color: archPink);
    }
    if (_busy) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(color: archPink, strokeWidth: 2),
      );
    }
    if (_error != null) {
      return const Icon(Icons.refresh_rounded, color: archPink);
    }
    return IconButton(
      onPressed: _pull,
      icon: Icon(Icons.cloud_download_outlined,
          color: Theme.of(context).colorScheme.onSurface),
    );
  }
}
