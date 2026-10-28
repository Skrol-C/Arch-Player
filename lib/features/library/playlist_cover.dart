import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/art_scale.dart';
import '../../core/art_tone.dart';
import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/morph_icon.dart';
import 'data/art_previews.dart';
import 'data/library_repository.dart';
import 'data/playlist_store.dart';
import 'library_providers.dart';
import 'playlist_art.dart';
import 'playlists_providers.dart';
import 'song_row.dart';

/// Change-cover flow: Gallery file, a member track's own cover, or
/// remove back to the auto-gradient. Bytes are bounded to 1024 on
/// the long edge and persisted under app files.
Future<void> changePlaylistCover(
  WidgetRef ref,
  BuildContext context,
  Playlist playlist,
  List<Song> members,
) async {
  if (playlist.isSystem) return;
  HapticFeedback.selectionClick();
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LiquidGlassLens(
        style: ArchGlass.sheet(
            radius: 28, amoled: isAmoledScheme(sheetContext)),
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
                      color: Theme.of(sheetContext)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
                  child: Text(
                    'Playlist cover',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
          CascadeIn(
            delayMs: 0,
            child: ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(sheetContext)
                      .colorScheme
                      .surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  CupertinoIcons.photo,
                  color: archPink,
                ),
              ),
              title: const Text(
                'Choose from gallery',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.of(sheetContext).pop('gallery'),
            ),
          ),
          if (members.isNotEmpty)
            CascadeIn(
              delayMs: 30,
              child: ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(sheetContext)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    CupertinoIcons.music_note_2,
                    color: Theme.of(sheetContext).colorScheme.onSurface,
                  ),
                ),
                title: const Text(
                  'Use a song cover',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                onTap: () => Navigator.of(sheetContext).pop('song'),
              ),
            ),
          if (playlist.hasCustomArt)
            CascadeIn(
              delayMs: 60,
              child: ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(sheetContext)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    CupertinoIcons.arrow_uturn_left,
                    color: Theme.of(sheetContext).colorScheme.onSurface,
                  ),
                ),
                title: const Text(
                  'Remove cover',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Back to the auto-gradient',
                  style: TextStyle(
                    color:
                        Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                onTap: () => Navigator.of(sheetContext).pop('remove'),
              ),
            ),
                ],
              ),
          ),
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final notifier = ref.read(playlistsProvider.notifier);
  switch (choice) {
    case 'remove':
      await notifier.clearCustomArt(playlist.id);
      break;
    case 'gallery':
      await _pickFromGallery(ref, context, playlist);
      break;
    case 'song':
      if (context.mounted) {
        await _pickFromSongs(ref, context, playlist, members);
      }
      break;
  }
}

Future<void> _pickFromGallery(
  WidgetRef ref,
  BuildContext context,
  Playlist playlist,
) async {
  try {
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;
    // Stream-safe read: gallery URIs may carry no filesystem path.
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return;
    final bounded = await shrinkArt(bytes);
    final saved = await PlaylistStore.writeArt(playlist.id, bounded);
    await ref.read(playlistsProvider.notifier).setCustomArt(playlist.id, saved);
    if (context.mounted) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cover updated')));
    }
  } catch (e) {
    ArchLog.w('playlist', 'gallery cover failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not use that image')));
    }
  }
}

/// Member tracks as cover candidates: tap one's art to promote it
/// to the playlist cover.
Future<void> _pickFromSongs(
  WidgetRef ref,
  BuildContext context,
  Playlist playlist,
  List<Song> members,
) async {
  final picked = await showModalBottomSheet<Song>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.88,
    ),
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LiquidGlassLens(
        style: ArchGlass.sheet(
            radius: 28, amoled: isAmoledScheme(sheetContext)),
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
                      color: Theme.of(sheetContext)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
                  child: Text(
                    'Use a song cover',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: members.length,
              itemBuilder: (_, i) {
                final s = members[i];
                return CascadeIn(
                  delayMs: (i.clamp(0, 7)) * 30,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 2,
                    ),
                    leading: FileArtImage(
                      path: s.path,
                      albumId: s.albumId,
                      size: 44,
                    ),
                    title: Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      s.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant,
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(s),
                  ),
                );
              },
            ),
          ),
                ],
              ),
            ),
          ),
        ),
      ),
  );
  if (picked == null || !context.mounted) return;
  try {
    final bytes = await _songArtBytes(picked);
    if (bytes == null || bytes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That song has no cover to use')),
        );
      }
      return;
    }
    final bounded = await shrinkArt(bytes);
    final saved = await PlaylistStore.writeArt(playlist.id, bounded);
    await ref.read(playlistsProvider.notifier).setCustomArt(playlist.id, saved);
    if (context.mounted) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cover updated')));
    }
  } catch (e) {
    ArchLog.w('playlist', 'song cover failed: $e');
  }
}

/// File art first (exact for fresh pulls), album art as fallback.
Future<Uint8List?> _songArtBytes(Song song) async {
  if (song.path.isNotEmpty) {
    try {
      final preview = await ArtPreviews.previewFor(song.path);
      if (preview != null && preview.isNotEmpty) {
        final f = File(preview);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        }
      }
    } catch (_) {}
  }
  if (song.albumId > 0) {
    try {
      return await ArtCache.of(song.albumId, ArtBucket.large);
    } catch (_) {}
  }
  return null;
}

/// Add-songs picker: search + checkbox list over the live library,
/// Done appends the missing ones. Explicit empty included.
class PlaylistSongPicker extends ConsumerStatefulWidget {
  final Playlist playlist;
  const PlaylistSongPicker({super.key, required this.playlist});

  @override
  ConsumerState<PlaylistSongPicker> createState() =>
      _PlaylistSongPickerState();
}

class _PlaylistSongPickerState extends ConsumerState<PlaylistSongPicker> {
  String _q = '';
  final _picked = <int>{};

  @override
  Widget build(BuildContext context) {
    final songs = ref.watch(visibleSongsProvider);
    final q = _q.trim().toLowerCase();
    final shown = q.isEmpty
        ? songs
        : songs
              .where(
                (s) =>
                    s.title.toLowerCase().contains(q) ||
                    s.artist.toLowerCase().contains(q) ||
                    s.album.toLowerCase().contains(q),
              )
              .toList();
    final existing =
        ref
            .watch(playlistsProvider)
            .where((p) => p.id == widget.playlist.id)
            .firstOrNull
            ?.songIds
            .toSet() ??
        {};
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        elevation: 0,
        title: Text('Add to ${widget.playlist.name}'),
        actions: [
          TextButton(
            onPressed: _picked.isEmpty
                ? null
                : () async {
                    final fresh = _picked
                        .where((id) => !existing.contains(id))
                        .toList();
                    await ref
                        .read(playlistsProvider.notifier)
                        .addSongs(widget.playlist.id, fresh);
                    if (context.mounted) Navigator.of(context).maybePop();
                  },
            child: Text(
              'Done${_picked.isEmpty ? '' : ' (${_picked.length})'}',
              style: TextStyle(
                color: _picked.isEmpty
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : archPink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: CupertinoSearchTextField(
              placeholder: 'Search library',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      'No songs match.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final s = shown[i];
                      final owned = existing.contains(s.id);
                      return Container(
                        color: owned
                            ? archPink.withValues(alpha: 0.06)
                            : Colors.transparent,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 2,
                          ),
                          leading: FileArtImage(
                            path: s.path,
                            albumId: s.albumId,
                            size: 44,
                          ),
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            s.artist,
                            maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        trailing: owned
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: archPink.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  'Already there',
                                  style: TextStyle(
                                    color: archPink,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              )
                            : Checkbox(
                                value: _picked.contains(s.id),
                                activeColor: archPink,
                                onChanged: (_) => setState(() {
                                  if (_picked.contains(s.id)) {
                                    _picked.remove(s.id);
                                  } else {
                                    _picked.add(s.id);
                                  }
                                }),
                              ),
                        onTap: owned
                            ? null
                            : () => setState(() {
                                if (_picked.contains(s.id)) {
                                  _picked.remove(s.id);
                                } else {
                                  _picked.add(s.id);
                                }
                              }),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Palette of a persisted custom cover for wash + voice color.
Future<ArtPalette?> playlistCoverPalette(String path) {
  if (path.isEmpty) return Future.value(null);
  return ArtTone.paletteFromBytes('playlist:$path', () async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  });
}

/// The playlist tile: custom cover full-bleed with the name centered
/// in its display voice when set, else the auto-gradient with the
/// name top-left. Never blank: neutral tile while resolving.
class PlaylistCoverTile extends StatelessWidget {
  final Playlist playlist;
  final List<Song> songs;
  final double radius;

  const PlaylistCoverTile({
    super.key,
    required this.playlist,
    required this.songs,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    if (playlist.hasCustomArt) {
      return FutureBuilder<Uint8List?>(
        future: PlaylistArt.coverBytes(playlist.customArt),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null || bytes.isEmpty) {
            // Stale path (file gone): fall through to the gradient
            // rather than stranding a grey box.
            return _GradientBody(
              playlist: playlist,
              songs: songs,
              radius: radius,
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(bytes, fit: BoxFit.cover),
                // Fancy name sits on the bottom edge, in the
                // playlist's own display voice.
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                    child: _VoiceName(name: playlist.name, path: playlist.customArt),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    return _GradientBody(playlist: playlist, songs: songs, radius: radius);
  }
}

/// Fancy name in the playlist's own display voice, colored from the
/// cover's vibrant pick (white when too close to its backdrop).
class _VoiceName extends StatelessWidget {
  final String name;
  final String path;
  const _VoiceName({required this.name, required this.path});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ArtPalette?>(
      future: playlistCoverPalette(path),
      builder: (context, snap) {
        final color = PlaylistArt.coverVoiceColor(snap.data);
        final voice = artistVoiceOf(name);
        return Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontFamily: voice,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: voiceSpacing(voice),
            shadows: const [
              Shadow(color: Colors.black45, blurRadius: 12, offset: Offset(0, 2)),
            ],
          ),
        );
      },
    );
  }
}

class _GradientBody extends StatelessWidget {
  final Playlist playlist;
  final List<Song> songs;
  final double radius;

  const _GradientBody({
    required this.playlist,
    required this.songs,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Color>>(
      future: PlaylistArt.gradientFor(songs),
      builder: (context, snap) {
        final stops = snap.data ?? const [Color(0xFFF6F6F8), Color(0xFFE8E8ED)];
        final on = PlaylistArt.onGradient(stops);
        return AnimatedContainer(
          duration: Motion.reduced(context)
              ? Duration.zero
              : const Duration(milliseconds: 400),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: stops,
            ),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                playlist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: on,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
