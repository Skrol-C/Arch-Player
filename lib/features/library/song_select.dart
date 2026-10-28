import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/audio_handler.dart';
import '../player/morph_icon.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'add_to_playlist.dart' show showAddToPlaylistSheet;
import 'data/playlist_store.dart';
import 'playlists_providers.dart';

/// Global select signal: true while ANY host has select mode armed.
/// The shell hides the pill + mini player so the docked sheet owns
/// the bottom edge ("replacing the pill, mini behind it").
final selectionActiveProvider = StateProvider<bool>((ref) => false);

/// Per-host multi-select state. Owned by the hosting page state,
/// dies with it — never global, never persisted. Tap toggles only;
/// exit is explicit (Done, X, back, apply, or uncheck-to-zero).
class SelectionController extends ChangeNotifier {
  bool armed = false;
  final Set<int> ids = {};

  int get count => ids.length;

  void enter(int id) {
    armed = true;
    ids.add(id);
    notifyListeners();
  }

  void toggle(int id) {
    if (!armed) return;
    if (ids.contains(id)) {
      ids.remove(id);
      if (ids.isEmpty) armed = false;
    } else {
      ids.add(id);
    }
    notifyListeners();
  }

  void selectAll(List<int> all) {
    ids.addAll(all);
    notifyListeners();
  }

  void exit() {
    if (!armed && ids.isEmpty) return;
    armed = false;
    ids.clear();
    notifyListeners();
  }
}

/// Songs in host order for the current selection. Bulk ops run in
/// the order the user sees, never id order.
List<Song> selectedOrdered(SelectionController c, List<Song> all) {
  final want = c.ids;
  return [for (final s in all) if (want.contains(s.id)) s];
}

/// Docked two-detent selection sheet (SpotiFLAC grammar in our
/// skin): expanded = header + ONE row of quick actions, drag the
/// grabber down and it becomes a one-row bar (`N selected` +
/// Select all + Done). Never modal — the list stays tappable
/// underneath. Every bulk action applies in list order, toasts,
/// exits.
class SelectionSheet extends ConsumerStatefulWidget {
  final SelectionController controller;
  final List<Song> Function() ordered;

  /// Unowned refs selected alongside (album tracklists). Added as
  /// greyed pending entries; bulk play/queue/star skip them.
  final List<PendingTrack> Function() pendingOrdered;
  final VoidCallback onExit;

  const SelectionSheet({
    super.key,
    required this.controller,
    required this.ordered,
    this.pendingOrdered = _noPending,
    required this.onExit,
  });

  static List<PendingTrack> _noPending() => const [];

  @override
  ConsumerState<SelectionSheet> createState() => _SelectionSheetState();
}

class _SelectionSheetState extends ConsumerState<SelectionSheet> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final songs = selectedOrdered(widget.controller, widget.ordered());
        final multi = songs.length > 1;
        return LiquidGlassLens(
          style:
              ArchGlass.sheet(radius: 28, amoled: isAmoledScheme(context)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _expanded = !_expanded),
                  onVerticalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v == 0) return;
                    setState(() => _expanded = v < 0);
                  },
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: ink.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                // Size snaps, content crossfades: no animated layout
                // pass inside the glass lens (that pass red-screened
                // on device). The slide-in still carries the motion.
                AnimatedSwitcher(
                  duration: Motion.reduced(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  switchInCurve: Motion.settle,
                  switchOutCurve: Curves.easeOut,
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: _expanded
                      ? Column(
                          key: const ValueKey('expanded'),
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment:
                              CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${songs.length} selected',
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    HapticFeedback.selectionClick();
                                    widget.controller.selectAll([
                                      for (final s in widget.ordered())
                                        s.id,
                                    ]);
                                  },
                                  child: const Text(
                                    'Select all',
                                    style: TextStyle(
                                      color: archPink,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceEvenly,
                              children: [
                                for (var i = 0; i < 5; i++)
                                  CascadeIn(
                                    key: ValueKey('action$i'),
                                    delayMs: i * 30,
                                    child: _QuickAction(
                                      index: i,
                                      multi: multi,
                                      songs: songs,
                                      onPlay: () => _play(songs),
                                      onPlaylist: () =>
                                          _addToPlaylist(songs),
                                      onNext: () => _queueOp(
                                        songs,
                                        (h) => h.insertNextAll(songs),
                                        'Up next',
                                      ),
                                      onQueue: () => _queueOp(
                                        songs,
                                        (h) => h.appendToQueue(songs),
                                        'Queued',
                                      ),
                                      onStar: () =>
                                          _starAll(songs),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                          ],
                        )
                      : Row(
                          key: const ValueKey('collapsed'),
                          children: [
                            Container(
                              width: 28,
                              height: 4,
                              decoration: BoxDecoration(
                                color: ink.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '${songs.length} selected',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                widget.controller.selectAll([
                                  for (final s in widget.ordered())
                                    s.id,
                                ]);
                              },
                              child: const Text(
                                'Select all',
                                style: TextStyle(
                                  color: archPink,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: widget.onExit,
                              child: const Text(
                                'Done',
                                style: TextStyle(
                                  color: ink,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _play(List<Song> songs) async {
    if (songs.isEmpty) return;
    HapticFeedback.mediumImpact();
    final first = songs.first;
    final queue = List<Song>.of(songs);
    widget.onExit();
    await playAndOpen(
      ref,
      context,
      () => ref.read(audioHandlerProvider).playSong(first, queue),
    );
  }

  Future<void> _addToPlaylist(List<Song> songs) async {
    if (songs.isEmpty && widget.pendingOrdered().isEmpty) return;
    HapticFeedback.selectionClick();
    final ctx = context;
    await showAddToPlaylistSheet(
      ref,
      ctx,
      songs,
      pending: widget.pendingOrdered(),
    );
    widget.onExit();
  }

  Future<void> _queueOp(
    List<Song> songs,
    Future<bool> Function(ArchAudioHandler h) op,
    String verb,
  ) async {
    if (songs.isEmpty) return;
    HapticFeedback.selectionClick();
    final handler = ref.read(audioHandlerProvider);
    final ctx = context;
    final done = await op(handler);
    widget.onExit();
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(
            done
                ? '$verb ${songs.length} song${songs.length == 1 ? '' : 's'}'
                : 'Queue is a preview right now - play a song first',
          ),
        ),
      );
    }
  }

  Future<void> _starAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    HapticFeedback.selectionClick();
    final notifier = ref.read(playlistsProvider.notifier);
    var all = true;
    for (final s in songs) {
      if (!notifier.isStarred(s.id)) {
        all = false;
        break;
      }
    }
    for (final s in songs) {
      final starred = notifier.isStarred(s.id);
      if (all && starred) {
        await notifier.toggleStar(s.id);
      } else if (!all && !starred) {
        await notifier.toggleStar(s.id);
      }
    }
    final ctx = context;
    widget.onExit();
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(
            all ? 'Unstarred ${songs.length}' : 'Starred ${songs.length}',
          ),
        ),
      );
    }
  }
}

/// One quick action: pink Play circle or a frost chip + tiny label.
/// House cascade handles the entrance; reduced-motion is a fade.
class _QuickAction extends ConsumerWidget {
  final int index;
  final bool multi;
  final List<Song> songs;
  final VoidCallback onPlay;
  final VoidCallback onPlaylist;
  final VoidCallback onNext;
  final VoidCallback onQueue;
  final VoidCallback onStar;

  const _QuickAction({
    required this.index,
    required this.multi,
    required this.songs,
    required this.onPlay,
    required this.onPlaylist,
    required this.onNext,
    required this.onQueue,
    required this.onStar,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allStarred = _allStarredSync(ref, songs);
    return switch (index) {
      0 => _chip(
        icon: CupertinoIcons.play_fill,
        label: 'Play',
        pink: true,
        onTap: onPlay,
      ),
      1 => _chip(
        icon: CupertinoIcons.music_note_list,
        label: 'Playlist',
        onTap: onPlaylist,
      ),
      2 => _chip(
        icon: CupertinoIcons.text_insert,
        label: 'Next',
        onTap: onNext,
      ),
      3 => _chip(
        icon: CupertinoIcons.text_append,
        label: 'Queue',
        onTap: onQueue,
      ),
      _ => _chip(
        icon: allStarred
            ? CupertinoIcons.star_fill
            : CupertinoIcons.star,
        label: multi
            ? (allStarred ? 'Unstar' : 'Star all')
            : (allStarred ? 'Unstar' : 'Star'),
        pink: false,
        selected: allStarred,
        onTap: onStar,
      ),
    };
  }

  bool _allStarredSync(WidgetRef ref, List<Song> songs) {
    if (songs.isEmpty) return false;
    final notifier = ref.read(playlistsProvider.notifier);
    for (final s in songs) {
      if (!notifier.isStarred(s.id)) return false;
    }
    return true;
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool pink = false,
    bool selected = false,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: pink
                  ? archPink
                  : selected
                  ? archPink.withValues(alpha: 0.14)
                  : paperRaised,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: pink || selected ? (pink ? Colors.white : archPink) : ink,
              size: 24,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: selected ? archPink : ink,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
