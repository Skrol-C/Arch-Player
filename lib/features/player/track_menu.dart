import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../library/artist_page.dart';
import '../library/library_providers.dart';
import '../library/library_screen.dart' show AlbumPage;
import '../library/song_row.dart' show fmtDuration;
import '../song/song_page.dart';
import 'morph_icon.dart';

/// One row in a context menu. Tap pops [value] back to the caller -
/// the menu stays dumb, callers switch on the result.
class MenuAction {
  final IconData icon;
  final String label;
  final String? subtitle;
  final String value;
  final bool selected;

  const MenuAction({
    required this.icon,
    required this.label,
    required this.value,
    this.subtitle,
    this.selected = false,
  });
}

/// Bounds of the tapped control in root-overlay coordinates. Tall
/// callers (rows) get null and the menu centers instead.
Rect? menuAnchor(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  if (box.size.height > MediaQuery.sizeOf(context).height * 0.65) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Frosted anchored popover: appears at its resting anchor with
/// fade + rise (no travel, no scale - the blur region stays static
/// so the filter resolves once). Dismisses on barrier tap with
/// fade only. Reduced-motion gets a plain fade. Returns the tapped
/// row's value, or null on dismiss.
Future<String?> showTrackMenu({
  required BuildContext context,
  List<MenuAction> quick = const [],
  required List<List<MenuAction>> groups,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final target = menuAnchor(context);
  // Keyboard trap: if the library search field holds focus (keyboard
  // up), pushing the route moves focus to the dialog and popping it
  // hands focus back to search - keyboard rising on every close.
  // Unfocusing first clears the restore target: nothing to return
  // to, no keyboard. The route scope below (no keyboard requests)
  // covers the other direction.
  FocusManager.instance.primaryFocus?.unfocus();
  ArchLog.i(
    'nav',
    'menu open anchor=${target == null ? 'centered' : '${target.width.toStringAsFixed(0)}x${target.height.toStringAsFixed(0)}@${target.left.toStringAsFixed(0)},${target.top.toStringAsFixed(0)}'} focus=${FocusManager.instance.primaryFocus}',
  );
  return navigator.push<String>(
    RawDialogRoute<String>(
      barrierColor: Colors.black.withValues(alpha: 0.12),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 450),
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (context, animation, _) {
        final media = MediaQuery.of(context);
        return AnimatedBuilder(
          animation: animation,
          // Rows build once and stay cached; the choreography below
          // is their 1:1 recipe: travel + grow + glass reveal.
          child: _MenuRows(quick: quick, groups: groups),
          builder: (context, child) {
            // One lens from frame zero, morphed params, no cover,
            // no swap: travel plays on the lens at paper state
            // (opaque white, zero blur, zero bend - visually paper,
            // backdrop cost trivial), then tint, blur and bend grow
            // together. The morph starts inside the fastest part of
            // the travel (12%) so its most visible stretch hides
            // where the eye is busiest. Nothing swaps, so no swap
            // frame can flash.
            final t = animation.value;
            final raw = const Interval(
              0,
              0.5,
              curve: Curves.easeOutCubic,
            ).transform(t);
            final motion = raw;
            final glide = Curves.easeOutCubic.transform(raw);
            final morphRaw = ((t - 0.12) / 0.88).clamp(0.0, 1.0);
            final morph = (morphRaw * morphRaw * (3 - 2 * morphRaw)).clamp(
              0.0,
              1.0,
            );
            return FocusScope(
              // The menu takes no text: never let it (or a focus
              // reclaim across rapid reopen) summon the keyboard.
              canRequestFocus: false,
              skipTraversal: true,
              child: CustomSingleChildLayout(
                delegate: _MenuLayout(
                  anchor: target,
                  maxWidth: 300,
                  padding: media.padding,
                  progress: glide,
                ),
                child: Transform.scale(
                  scale: 0.15 + 0.85 * glide,
                  child: IgnorePointer(
                    ignoring:
                        motion < 1 ||
                        animation.status == AnimationStatus.reverse,
                    child: _MenuShell(morph: morph, child: child!),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class _MenuLayout extends SingleChildLayoutDelegate {
  final Rect? anchor;
  final EdgeInsets padding;
  final double maxWidth;
  final double progress;
  static const _margin = 16.0;

  const _MenuLayout({
    required this.anchor,
    required this.padding,
    required this.maxWidth,
    required this.progress,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      maxWidth,
      math.max(0.0, constraints.maxWidth - padding.horizontal - _margin * 2),
    );
    final height = math.max(
      0.0,
      constraints.maxHeight - padding.vertical - _margin * 2,
    );
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = padding.left + _margin;
    final top = padding.top + _margin;
    final right = math.max(
      left,
      size.width - padding.right - _margin - childSize.width,
    );
    final bottom = math.max(
      top,
      size.height - padding.bottom - _margin - childSize.height,
    );
    Offset resting;
    if (anchor == null) {
      resting = Offset(
        (size.width - childSize.width) / 2,
        size.height * 0.3 - childSize.height / 2,
      );
    } else {
      final below = anchor!.bottom + 8;
      final above = anchor!.top - childSize.height - 8;
      final y = below <= bottom
          ? below
          : above >= top
          ? above
          : bottom;
      resting = Offset(
        (anchor!.right - childSize.width).clamp(left, right),
        y.clamp(top, bottom),
      );
    }
    final origin = anchor?.center;
    if (origin == null) return resting;
    return Offset.lerp(
      origin - childSize.center(Offset.zero),
      resting,
      progress,
    )!;
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      anchor != old.anchor ||
      padding != old.padding ||
      maxWidth != old.maxWidth ||
      progress != old.progress;
}

class _MenuShell extends StatelessWidget {
  final double morph;
  final Widget child;
  const _MenuShell({required this.morph, required this.child});

  @override
  Widget build(BuildContext context) {
    // One lens, always mounted, params morphed: at morph=0 it is
    // visually paper (opaque white, no blur, no bend), at morph=1
    // the full menu recipe. No cover, no swap, no blend - the tree
    // never changes shape, so no frame can flash or seam.
    return Stack(
      children: [
        Positioned.fill(
          child: LiquidGlassLens(
            style: ArchGlass.menuMorphed(morph),
            child: SizedBox.expand(),
          ),
        ),
        child,
      ],
    );
  }
}

/// Menu rows: quick chips first, then groups top to bottom.
class _MenuRows extends StatelessWidget {
  final List<MenuAction> quick;
  final List<List<MenuAction>> groups;

  const _MenuRows({required this.quick, required this.groups});

  @override
  Widget build(BuildContext context) {
    // Cascade order: quick chips first, then groups top to bottom.
    // 30ms apart with fast fades, so every row is visible inside
    // the emergence glide - the bloom plays to an audience,
    // never an empty stage.
    var k = 0;
    // Material canvas for the rows: ListTile paints ink on the
    // nearest Material ancestor, and a bare dialog route provides
    // none - without this every open throws Material.of null.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (quick.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final a in quick)
                      CascadeIn(
                        delayMs: (k++) * 30,
                        child: _QuickChip(action: a),
                      ),
                  ],
                ),
              ),
              const Divider(height: 12, indent: 16, endIndent: 16),
            ],
            for (var g = 0; g < groups.length; g++) ...[
              if (g > 0) const Divider(height: 8, indent: 16, endIndent: 16),
              for (final a in groups[g])
                CascadeIn(
                  delayMs: (k++) * 30,
                  child: _MenuRow(action: a),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  final MenuAction action;
  const _QuickChip({required this.action});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).pop(action.value);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: action.selected
                  ? archPink.withValues(alpha: 0.14)
                  : paperRaised,
              shape: BoxShape.circle,
            ),
            child: Icon(
              action.icon,
              color: action.selected ? archPink : ink,
              size: 24,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            action.label,
            style: TextStyle(
              color: action.selected ? archPink : ink,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final MenuAction action;
  const _MenuRow({required this.action});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      leading: Icon(action.icon, color: action.selected ? archPink : inkDim),
      title: Text(
        action.label,
        style: TextStyle(
          color: action.selected ? archPink : ink,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: action.subtitle == null
          ? null
          : Text(
              action.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: inkDim, fontSize: 13),
            ),
      trailing: action.selected
          ? const Icon(CupertinoIcons.checkmark, color: archPink)
          : null,
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).pop(action.value);
      },
    );
  }
}

/// Owned-album lookup shared by every menu: normalized title plus
/// artist overlap (collaborations merged at grouping, so any shared
/// name counts). Null = remote/preview - the row hides, never a
/// fake page.
Album? ownedAlbumFor(WidgetRef ref, Song song) {
  final title = normTitle(song.album);
  for (final a in ref.read(albumsProvider)) {
    if (normTitle(a.title) != title) continue;
    if (a.songs.any((s) => artistsOverlap(s.artist, song.artist))) {
      return a;
    }
  }
  return null;
}

/// Sleep subtitle for menu rows: countdown or the plain label.
String sleepLabel(Duration? d) {
  if (d == null) return 'Sleep timer';
  if (d.inHours > 0) return 'Stops in ${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return 'Stops in ${d.inMinutes}m';
  return 'Stops in ${d.inSeconds}s';
}

/// Shared song menu: Go to Album (owned only), Go to Artist, Share,
/// Details. Handles routing internally; callers just open it.
Future<void> showSongMenu(
  WidgetRef ref,
  BuildContext context,
  Song song,
) async {
  final ownedAlbum = ownedAlbumFor(ref, song);
  final value = await showTrackMenu(
    context: context,
    groups: [
      [
        const MenuAction(
          icon: CupertinoIcons.music_note,
          label: 'Song page',
          subtitle: null,
          value: 'song',
        ),
        if (ownedAlbum != null)
          MenuAction(
            icon: CupertinoIcons.music_albums,
            label: 'Go to Album',
            subtitle: song.album,
            value: 'album',
          ),
        MenuAction(
          icon: CupertinoIcons.person,
          label: 'Go to Artist',
          subtitle: song.artist,
          value: 'artist',
        ),
        const MenuAction(
          icon: CupertinoIcons.info_circle,
          label: 'Details',
          value: 'details',
        ),
      ],
      [
        MenuAction(
          icon: CupertinoIcons.square_arrow_up,
          label: 'Share',
          subtitle: '${song.title} - ${song.artist}',
          value: 'share',
        ),
      ],
    ],
  );
  if (!context.mounted) return;
  switch (value) {
    case 'song':
      SongPage.open(context, SongRef.owned(song));
      break;
    case 'album':
      if (ownedAlbum != null) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => AlbumPage(album: ownedAlbum)));
      }
      break;
    case 'artist':
      ArtistPage.openIfAbsent(context, song.artist);
      break;
    case 'share':
      SharePlus.instance.share(
        ShareParams(text: '${song.title} - ${song.artist}'),
      );
      break;
    case 'details':
      showModalBottomSheet(
        context: context,
        builder: (_) => TrackDetailsSheet(song: song),
      );
      break;
  }
}

/// Title/artist nav menu: Go to Artist always, Go to Album when owned.
/// One tap, both destinations discoverable.
Future<void> showTrackNavMenu(
  WidgetRef ref,
  BuildContext context,
  Song song,
) async {
  final ownedAlbum = ownedAlbumFor(ref, song);
  final value = await showTrackMenu(
    context: context,
    groups: [
      [
        if (ownedAlbum != null)
          MenuAction(
            icon: CupertinoIcons.music_albums,
            label: 'Go to Album',
            subtitle: song.album,
            value: 'album',
          ),
        MenuAction(
          icon: CupertinoIcons.person,
          label: 'Go to Artist',
          subtitle: song.artist,
          value: 'artist',
        ),
      ],
    ],
  );
  if (!context.mounted) return;
  if (value == 'album' && ownedAlbum != null) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AlbumPage(album: ownedAlbum)));
  } else if (value == 'artist') {
    ArtistPage.openIfAbsent(context, song.artist);
  }
}

/// Honest file facts: what we know, nothing we don't. Unknown fields
/// are omitted, never guessed. Follows the caller's surface: dark on
/// the player, light everywhere else.
class TrackDetailsSheet extends StatelessWidget {
  final Song song;
  final bool dark;
  const TrackDetailsSheet({super.key, required this.song, this.dark = false});

  @override
  Widget build(BuildContext context) {
    final title = dark ? moon : ink;
    final sub = dark ? moonDim : inkDim;
    String? size;
    try {
      final bytes = File(song.path).lengthSync();
      size = bytes > 1048576
          ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
          : '${(bytes / 1024).toStringAsFixed(0)} KB';
    } catch (_) {}
    final ext = song.path.contains('.')
        ? song.path.split('.').last.toUpperCase()
        : null;
    String? added;
    if (song.addedSecs > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(song.addedSecs * 1000);
      added =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }
    final rows = <List<String>>[
      ['Title', song.title],
      ['Artist', song.artist],
      ['Album', song.album],
      ['Length', fmtDuration(song.duration)],
      if (ext != null) ['Format', ext],
      if (size != null) ['Size', size],
      if (added != null) ['Added', added],
      ['Folder', song.folderLabel],
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Details',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: title),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      CascadeIn(
                        delayMs: i * 30,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 88,
                                child: Text(
                                  rows[i][0],
                                  style: TextStyle(color: sub),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  rows[i][1],
                                  style: TextStyle(
                                    color: title,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
