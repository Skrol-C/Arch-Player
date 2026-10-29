import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../library/album_page.dart' show AlbumPage;
import '../library/artist_hub_page.dart';
import '../library/library_providers.dart';
import '../library/playlists_providers.dart' show playlistsProvider;
import '../library/song_row.dart' show fmtDuration;
import '../song/song_page.dart';
import '../automix/blend_preview.dart' show renderBlendPreview;
import '../shell/morph_menu.dart' show showMorphMenu;
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
/// Renders through the morph menu.
Future<void> showSongMenu(
  WidgetRef ref,
  BuildContext context,
  Song song,
) async {
  final ownedAlbum = ownedAlbumFor(ref, song);
  final starred = ref.read(playlistsProvider.notifier).isStarred(song.id);
  final value = await showMorphMenu(
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
          icon: starred
              ? CupertinoIcons.star_fill
              : CupertinoIcons.star,
          label: starred ? 'Unstar' : 'Star',
          value: 'star',
          selected: starred,
        ),
        MenuAction(
          icon: CupertinoIcons.square_arrow_up,
          label: 'Share',
          subtitle: '${song.title} - ${song.artist}',
          value: 'share',
        ),
        const MenuAction(
          icon: CupertinoIcons.sparkles,
          label: 'Blend preview (lab)',
          value: 'blend_lab',
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
      ArtistHubPage.openIfAbsent(context, song.artist);
      break;
    case 'star':
      HapticFeedback.selectionClick();
      await ref.read(playlistsProvider.notifier).toggleStar(song.id);
      break;
    case 'share':
      SharePlus.instance.share(
        ShareParams(text: '${song.title} - ${song.artist}'),
      );
      break;
    case 'blend_lab':
      unawaited(renderBlendPreview(ref, context, song));
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
/// One tap, both destinations discoverable. Renders through morph.
Future<void> showTrackNavMenu(
  WidgetRef ref,
  BuildContext context,
  Song song,
) async {
  final ownedAlbum = ownedAlbumFor(ref, song);
  final value = await showMorphMenu(
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
    ArtistHubPage.openIfAbsent(context, song.artist);
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
                                width: 96,
                                child: Text(
                                  rows[i][0],
                                  style: TextStyle(color: sub),
                                ),
                              ),
                              const SizedBox(width: 12),
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
