import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/morph_icon.dart';
import '../shell/dock.dart';
import 'add_to_playlist.dart' show newPlaylistDialog;
import 'data/playlist_store.dart';
import 'library_providers.dart';
import 'playlist_art.dart';
import 'playlist_cover.dart'
    show PlaylistCoverTile, PlaylistSongPicker, changePlaylistCover;
import 'playlist_detail_page.dart';
import 'playlists_providers.dart';

/// Playlists index (WA0011 grammar): title, glass actions pill
/// (+ new / sort / overflow), 2-col gradient cards, name + count
/// below each card. Favourites keeps the red star on paperRaised;
/// every other list wears its auto-gradient full-bleed.
class PlaylistsPage extends ConsumerStatefulWidget {
  const PlaylistsPage({super.key});

  static void open(BuildContext context) {
    ArchLog.i('nav', 'playlists open');
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const PlaylistsPage()));
  }

  @override
  ConsumerState<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends ConsumerState<PlaylistsPage> {
  bool _recentFirst = true;

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(playlistsProvider);
    final songs = ref.watch(songsProvider).value ?? [];
    final ordered = List<Playlist>.of(lists);
    // Favourites always leads; the rest sort by recency or name.
    ordered.sort((a, b) {
      if (a.isSystem != b.isSystem) return a.isSystem ? -1 : 1;
      if (_recentFirst) return b.updatedMs.compareTo(a.updatedMs);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final collapsed = ref.watch(pillCollapsedProvider);
    final bottomClear = collapsed ? 120.0 : 200.0;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: DockScrollReporter(
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 64)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Icon(
                              CupertinoIcons.chevron_left,
                              color:
                                  Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const Spacer(),
                        LiquidGlassLens(
                          style: ArchGlass.capsule(
                              radius: 24, amoled: isAmoledScheme(context)),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: () async {
                                  final p = await newPlaylistDialog(
                                    context,
                                    ref,
                                  );
                                  if (context.mounted && p != null) {
                                    PlaylistDetailPage.open(
                                      context,
                                      playlistId: p.id,
                                    );
                                  }
                                },
                                icon: Icon(Icons.add_rounded,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface),
                                tooltip: 'New playlist',
                              ),
                              IconButton(
                                onPressed: () {
                                  HapticFeedback.selectionClick();
                                  setState(
                                    () => _recentFirst = !_recentFirst,
                                  );
                                },
                                icon: Icon(
                                  _recentFirst
                                      ? CupertinoIcons.sort_down
                                      : CupertinoIcons.textformat_abc,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface,
                                ),
                                tooltip: 'Sort',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: FocalEntrance(
                      child: Text(
                        'Playlists',
                        style: TextStyle(
                          fontFamily: 'ArchSerif',
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                ),
                if (ordered.isEmpty)
                  const SliverToBoxAdapter(child: _PlaylistsEmpty())
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 20,
                            crossAxisSpacing: 16,
                            // Card + two-line caption.
                            mainAxisExtent: 240,
                          ),
                      delegate: SliverChildBuilderDelegate((context, i) {
                        final p = ordered[i];
                        final members = playlistSongs(p, songs);
                        return CascadeIn(
                          delayMs: (i.clamp(0, 7)) * 30,
                          child: _PlaylistCard(
                            playlist: p,
                            members: members,
                            onTap: () => PlaylistDetailPage.open(
                              context,
                              playlistId: p.id,
                            ),
                            onLongPress: () =>
                                _cardMenu(context, ref, p, members),
                          ),
                        );
                      }, childCount: ordered.length),
                    ),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: bottomClear)),
              ],
            ),
            const NowPlayingDock(),
          ],
        ),
      ),
    );
  }

  /// Hold menu: change cover art, add songs, rename, delete.
  /// Favourites only offers add + open — the system star is never
  /// renamed, recovered or deleted.
  Future<void> _cardMenu(
    BuildContext context,
    WidgetRef ref,
    Playlist p,
    List<Song> members,
  ) async {
    HapticFeedback.mediumImpact();
    final value = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      elevation: 0,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: LiquidGlassLens(
          style:
              ArchGlass.sheet(radius: 28, amoled: isAmoledScheme(context)),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
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
                  const SizedBox(height: 8),
            if (!p.isSystem)
              CascadeIn(
                delayMs: 0,
                child: ListTile(
                  leading: const Icon(
                    CupertinoIcons.photo,
                    color: archPink,
                  ),
                  title: const Text('Change cover art'),
                  subtitle: Text(
                    p.hasCustomArt
                        ? 'Change or remove the cover'
                        : 'Gallery or a song cover',
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                        fontSize: 13),
                  ),
                  onTap: () => Navigator.of(context).pop('cover'),
                ),
              ),
            CascadeIn(
              delayMs: 30,
              child: ListTile(
                leading: Icon(
                  CupertinoIcons.person_badge_plus,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: const Text('Add songs'),
                onTap: () => Navigator.of(context).pop('add'),
              ),
            ),
            if (!p.isSystem) ...[
              CascadeIn(
                delayMs: 60,
                child: ListTile(
                  leading: Icon(
                    Icons.drive_file_rename_outline,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  title: const Text('Rename'),
                  onTap: () => Navigator.of(context).pop('rename'),
                ),
              ),
              CascadeIn(
                delayMs: 90,
                child: ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  title: const Text('Delete playlist'),
                  onTap: () => Navigator.of(context).pop('delete'),
                ),
              ),
            ],
            CascadeIn(
              delayMs: p.isSystem ? 60 : 120,
              child: ListTile(
                leading: Icon(
                  Icons.open_in_new_rounded,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                title: const Text('Open'),
                onTap: () => Navigator.of(context).pop('open'),
              ),
            ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!context.mounted || value == null) return;
    final notifier = ref.read(playlistsProvider.notifier);
    switch (value) {
      case 'cover':
        if (context.mounted) {
          await changePlaylistCover(ref, context, p, members);
        }
        break;
      case 'add':
        if (context.mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlaylistSongPicker(playlist: p),
            ),
          );
        }
        break;
      case 'rename':
        newPlaylistDialog(context, ref, existing: p);
        break;
      case 'delete':
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
            title: Text('Delete "${p.name}"?'),
            content: const Text(
              'The songs stay in your library. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'Keep',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: archPink),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirm == true) {
          await notifier.delete(p.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Deleted "${p.name}"')),
            );
          }
        }
        break;
      case 'open':
        if (context.mounted) {
          PlaylistDetailPage.open(context, playlistId: p.id);
        }
        break;
    }
  }
}

class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final List<Song> members;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PlaylistCard({
    required this.playlist,
    required this.members,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final count = members.length;
    final sub = '$count song${count == 1 ? '' : 's'}';
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        onLongPress();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: playlist.isSystem
                ? Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.star_rounded,
                        color: archPink,
                        size: 72,
                      ),
                    ),
                  )
                : PlaylistCoverTile(
                    playlist: playlist,
                    songs: members,
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (playlist.isSystem)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.star_rounded,
                    color: archPink,
                    size: 16,
                  ),
                ),
            ],
          ),
          Text(sub,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13)),
        ],
      ),
    );
  }
}

class _PlaylistsEmpty extends StatelessWidget {
  const _PlaylistsEmpty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 48, 48, 0),
      child: Column(
        children: [
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  PlaylistArt.fallbackTop,
                  PlaylistArt.fallbackBottom,
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No playlists yet',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Build your first mix from any song menu.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// New / rename dialog lives in add_to_playlist.dart (shared with the
/// detail page without an import cycle).
