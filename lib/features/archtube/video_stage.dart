import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/player_providers.dart';
import 'archtube_client.dart';
import 'video_providers.dart';

/// Film glyph above the art: grey at rest, pink while video owns
/// the stage. The single entry/exit for video mode.
class VideoToggle extends ConsumerWidget {
  const VideoToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(videoModeProvider);
    return SizedBox(
      width: 48,
      height: 40,
      child: IconButton(
        iconSize: 26,
        color: active
            ? archPink
            : Theme.of(context).colorScheme.onSurfaceVariant,
        tooltip: active ? 'Back to song' : 'Watch video',
        onPressed: () {
          HapticFeedback.selectionClick();
          ref.read(videoModeProvider.notifier).state = !active;
        },
        icon: AnimatedScale(
          scale: active ? 1.15 : 1.0,
          duration: Motion.reduced(context)
              ? Duration.zero
              : Motion.stateChange,
          curve: Curves.easeOutBack,
          child: const Icon(CupertinoIcons.videocam_fill),
        ),
      ),
    );
  }
}

/// Video stage: replaces the art box while video mode is on.
/// Link (cached, else one auto-search) then streams, each with
/// explicit loading/error/empty/data. Never a dead screen.
class VideoStage extends ConsumerStatefulWidget {
  final VideoSong song;
  final double width;

  const VideoStage({super.key, required this.song, required this.width});

  @override
  ConsumerState<VideoStage> createState() => _VideoStageState();
}

/// Minimal song surface: VideoStage only needs identity + timing.
class VideoSong {
  final int id;
  final String artist;
  final String title;
  final Duration duration;

  const VideoSong({
    required this.id,
    required this.artist,
    required this.title,
    required this.duration,
  });
}

class _VideoStageState extends ConsumerState<VideoStage> {
  bool _linkEditorOpen = false;

  @override
  void didUpdateWidget(covariant VideoStage old) {
    super.didUpdateWidget(old);
    if (old.song.id != widget.song.id) {
      // New song owns a new stage: drop back to song mode. Audio
      // resume rides the player dispose (it knows if audio played).
      ref.read(videoModeProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = ref.watch(videoLinkProvider(
      songQuery(
        songId: widget.song.id,
        artist: widget.song.artist,
        title: widget.song.title,
        songSecs: widget.song.duration.inSeconds,
      ),
    ));
    return SizedBox(
      width: widget.width,
      child: link.when(
        loading: () => _VideoMessage(
          width: widget.width,
          label: 'Finding video...',
          child: const CupertinoActivityIndicator(),
        ),
        error: (e, _) => _VideoMessage(
          width: widget.width,
          icon: CupertinoIcons.exclamationmark_triangle,
          label: 'Video lookup failed',
          detail: '$e',
          actions: [
            TextButton(
              onPressed: () =>
                  ref.invalidate(videoLinkProvider),
              child: const Text(
                'Retry',
                style: TextStyle(
                  color: archPink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () =>
                  setState(() => _linkEditorOpen = true),
              child: Text(
                'Paste link',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          below: _linkEditorOpen
              ? _LinkEditor(songId: widget.song.id)
              : null,
        ),
        data: (resolved) {
          if (resolved == null) {
            return _VideoMessage(
              width: widget.width,
              icon: CupertinoIcons.videocam,
              label: 'No video found',
              detail: 'No YouTube match landed in the '
                  'duration window. Paste one below.',
              below: _LinkEditor(songId: widget.song.id),
            );
          }
          return _VideoBox(
            key: ValueKey(resolved.videoId),
            song: widget.song,
            videoId: resolved.videoId,
            width: widget.width,
          );
        },
      ),
    );
  }
}

/// Loading/error/empty shell: scheme surface, centered glyph,
/// label, optional detail + actions + manual entry below.
class _VideoMessage extends StatelessWidget {
  final double width;
  final String label;
  final String? detail;
  final IconData? icon;
  final Widget? child;
  final List<Widget>? actions;
  final Widget? below;

  const _VideoMessage({
    required this.width,
    required this.label,
    this.detail,
    this.icon,
    this.child,
    this.actions,
    this.below,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child ??
              Icon(icon ?? CupertinoIcons.videocam,
                  size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(
              detail!,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ],
          if (actions != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: actions!,
            ),
          ],
          if (below != null) ...[
            const SizedBox(height: 12),
            below!,
          ],
        ],
      ),
    );
  }
}

/// Streams gate: loading/error/data around the player box, plus the
/// quality picker, offset nudge, and unlink once a stream plays.
class _VideoBox extends ConsumerWidget {
  final VideoSong song;
  final String videoId;
  final double width;

  const _VideoBox({
    super.key,
    required this.song,
    required this.videoId,
    required this.width,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final streams = ref.watch(videoStreamsProvider(videoId));
    return streams.when(
      loading: () => _VideoMessage(
        width: width,
        label: 'Loading video...',
        child: const CupertinoActivityIndicator(),
      ),
      error: (e, _) => _VideoMessage(
        width: width,
        icon: CupertinoIcons.exclamationmark_triangle,
        label: 'Video unavailable',
        detail: 'YouTube served no playable stream. '
            'Disguises exhausted.',
        actions: [
          TextButton(
            onPressed: () =>
                ref.invalidate(videoStreamsProvider(videoId)),
            child: const Text(
              'Retry',
              style: TextStyle(
                  color: archPink, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () async {
              await clearVideoLink(ref, song.id);
            },
            child: Text(
              'Unlink',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      data: (list) {
        if (list.isEmpty) {
          return _VideoMessage(
            width: width,
            icon: CupertinoIcons.exclamationmark_triangle,
            label: 'Video unavailable',
            detail: 'YouTube served no playable stream. '
                'Disguises exhausted.',
            actions: [
              TextButton(
                onPressed: () =>
                    ref.invalidate(videoStreamsProvider(videoId)),
                child: const Text(
                  'Retry',
                  style: TextStyle(
                      color: archPink,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
            below: _LinkEditor(songId: song.id),
          );
        }
        final picked =
            ref.watch(selectedItagProvider(videoId)) ?? list.first.itag;
        final stream = list.firstWhere(
          (s) => s.itag == picked,
          orElse: () => list.first,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StreamPlayer(
              song: song,
              stream: stream,
              width: width,
            ),
            const SizedBox(height: 8),
            _QualityRow(
                streams: list, videoId: videoId, picked: stream.itag),
            _OffsetRow(song: song),
          ],
        );
      },
    );
  }
}

/// The player itself. Audio handoff: pause just_audio before the
/// first video frame, resume on exit only if audio played on entry.
/// Never both at once. The song owns the timeline: the video starts
/// at song position + offset and exits at offset + song length.
class _StreamPlayer extends ConsumerStatefulWidget {
  final VideoSong song;
  final ArchtubeStream stream;
  final double width;

  const _StreamPlayer({
    required this.song,
    required this.stream,
    required this.width,
  });

  @override
  ConsumerState<_StreamPlayer> createState() => _StreamPlayerState();
}

class _StreamPlayerState extends ConsumerState<_StreamPlayer> {
  VideoPlayerController? _controller;
  bool _audioWasPlaying = false;
  bool _exited = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init(widget.stream.url);
  }

  @override
  void didUpdateWidget(covariant _StreamPlayer old) {
    super.didUpdateWidget(old);
    if (old.stream.url != widget.stream.url) {
      final pos = _controller?.value.position ?? Duration.zero;
      _swap(widget.stream.url, from: pos);
    }
  }

  Future<void> _init(String url) async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    try {
      await controller.initialize();
    } catch (e) {
      ArchLog.w('archtube', 'player init failed: $e');
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    // Handoff: audio off fully before video on. Never both.
    _audioWasPlaying =
        ref.read(playingProvider).value ?? false;
    final handler = ref.read(audioHandlerProvider);
    try {
      await handler.pause();
    } catch (e) {
      ArchLog.w('archtube', 'audio pause failed: $e');
    }
    if (!mounted) return;
    final offset = ref.read(videoOffsetProvider(widget.song.id));
    final songPos =
        ref.read(positionProvider).value ?? Duration.zero;
    final startAt = Duration(
      milliseconds: ((songPos.inMilliseconds / 1000 + offset) * 1000)
          .round()
          .clamp(0, 1 << 31),
    );
    controller.addListener(_onTick);
    final length = controller.value.duration;
    final safeStart = startAt > length
        ? Duration.zero
        : startAt > Duration.zero
            ? startAt
            : Duration.zero;
    try {
      if (safeStart > Duration.zero) {
        await controller.seekTo(safeStart);
      }
      if (!mounted || _exited) return;
      await controller.play();
    } catch (e) {
      ArchLog.w('archtube', 'video start failed: $e');
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _swap(String url, {required Duration from}) async {
    final old = _controller;
    old?.removeListener(_onTick);
    _controller = null;
    if (mounted) setState(() {});
    try {
      await old?.pause();
    } catch (_) {}
    try {
      await old?.dispose();
    } catch (_) {}
    if (!mounted) return;
    await _initAt(url, from);
  }

  /// Re-init preserving the handoff: audio is already ours, so no
  /// second pause, just seek + play.
  Future<void> _initAt(String url, Duration from) async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    try {
      await controller.initialize();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted || _exited) {
      await controller.dispose();
      return;
    }
    controller.addListener(_onTick);
    try {
      await controller.seekTo(from);
      await controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (mounted) setState(() {});
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _exited) return;
    final offset = ref.read(videoOffsetProvider(widget.song.id));
    final windowEnd = Duration(
      milliseconds:
          ((widget.song.duration.inSeconds + offset) * 1000).round(),
    );
    final pos = c.value.position;
    final dur = c.value.duration;
    final end = windowEnd < dur ? windowEnd : dur;
    if (pos >= end && end > Duration.zero) {
      _exitToSong();
    }
  }

  /// Window end or user exit: video off fully before audio back.
  Future<void> _exitToSong() async {
    if (_exited) return;
    _exited = true;
    final c = _controller;
    try {
      await c?.pause();
    } catch (_) {}
    if (!mounted) return;
    ref.read(videoModeProvider.notifier).state = false;
    if (_audioWasPlaying) {
      try {
        await ref.read(audioHandlerProvider).play();
      } catch (e) {
        ArchLog.w('archtube', 'audio resume failed: $e');
      }
    }
  }

  @override
  void dispose() {
    final c = _controller;
    if (c != null) {
      c.removeListener(_onTick);
      c.pause();
      c.dispose();
    }
    // Unmount without the exit path (song change, player close):
    // hand transport back only when audio played on entry and the
    // mode is still ours.
    if (!_exited && _audioWasPlaying) {
      try {
        ref.read(audioHandlerProvider).play();
      } catch (e) {
        ArchLog.w('archtube', 'dispose resume failed: $e');
      }
    }
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = _controller;
    if (_error != null) {
      return _VideoMessage(
        width: widget.width,
        icon: CupertinoIcons.exclamationmark_triangle,
        label: 'Playback failed',
        detail: _error,
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _error = null);
              _swap(widget.stream.url, from: Duration.zero);
            },
            child: const Text(
              'Retry',
              style: TextStyle(
                  color: archPink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }
    if (c == null || !c.value.isInitialized) {
      return _VideoMessage(
        width: widget.width,
        label: 'Loading video...',
        child: const CupertinoActivityIndicator(),
      );
    }
    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: VideoPlayer(c),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: _GlassIconButton(
              icon: Icons.fullscreen,
              tooltip: 'Fullscreen',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      _FullscreenVideo(controller: c),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fullscreen: same controller, no second player. Pops itself the
/// moment video mode ends (window end, song change, toggle off).
class _FullscreenVideo extends ConsumerWidget {
  final VideoPlayerController controller;

  const _FullscreenVideo({required this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(videoModeProvider);
    if (!active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: VideoPlayer(controller),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: _GlassIconButton(
                icon: Icons.fullscreen_exit,
                tooltip: 'Exit fullscreen',
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small floating control over video: glass lens only (floating
/// control, never content), white glyph for the artwork inversion.
class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        iconSize: 22,
        color: Colors.white,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.35),
        ),
        onPressed: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        icon: Icon(icon, shadows: const [
          Shadow(color: Colors.black54, blurRadius: 6),
        ]),
      ),
    );
  }
}

/// Quality picker: one chip per progressive stream, ladder best
/// pre-picked. Pink = selected (selection follows pink).
class _QualityRow extends ConsumerWidget {
  final List<ArchtubeStream> streams;
  final String videoId;
  final int picked;

  const _QualityRow({
    required this.streams,
    required this.videoId,
    required this.picked,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (streams.length < 2) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          for (final s in streams)
            ChoiceChip(
              label: Text(
                s.qualityLabel.isEmpty ? 'itag ${s.itag}' : s.qualityLabel,
                style: const TextStyle(fontSize: 12),
              ),
              selected: s.itag == picked,
              selectedColor: archPink.withValues(alpha: 0.18),
              labelStyle: TextStyle(
                color: s.itag == picked
                    ? archPink
                    : scheme.onSurfaceVariant,
                fontWeight: s.itag == picked
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
              side: BorderSide(
                color: scheme.onSurface.withValues(alpha: 0.12),
              ),
              onSelected: (_) {
                HapticFeedback.selectionClick();
                ref
                    .read(selectedItagProvider(videoId).notifier)
                    .state = s.itag;
              },
            ),
        ],
      ),
    );
  }
}

/// Offset nudge: -/+1s around the auto 0, persisted to the link.
class _OffsetRow extends ConsumerWidget {
  final VideoSong song;

  const _OffsetRow({required this.song});

  Future<void> _nudge(WidgetRef ref, double by) async {
    final notifier = ref.read(videoOffsetProvider(song.id).notifier);
    final next = (notifier.state + by).clamp(0.0, 30.0);
    notifier.state = next;
    try {
      final store = ref.read(videoLinkStoreProvider);
      final link = await store.load(song.id);
      if (link != null) {
        await store.save(song.id, link.withOffset(next));
      }
    } catch (e) {
      ArchLog.w('archtube', 'offset persist failed: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final offset = ref.watch(videoOffsetProvider(song.id));
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            iconSize: 18,
            color: scheme.onSurfaceVariant,
            tooltip: 'Video starts 1s earlier',
            onPressed: () => _nudge(ref, -1),
            icon: const Icon(CupertinoIcons.minus_circled),
          ),
          Text(
            'Offset ${offset.toStringAsFixed(0)}s',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          IconButton(
            iconSize: 18,
            color: scheme.onSurfaceVariant,
            tooltip: 'Video starts 1s later',
            onPressed: () => _nudge(ref, 1),
            icon: const Icon(CupertinoIcons.plus_circled),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () async {
              HapticFeedback.selectionClick();
              await clearVideoLink(ref, song.id);
            },
            child: Text(
              'Unlink',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Manual override entry: paste an ID or URL, it becomes the cached
/// link. Invalid input explains itself, never throws to the surface.
class _LinkEditor extends ConsumerStatefulWidget {
  final int songId;

  const _LinkEditor({required this.songId});

  @override
  ConsumerState<_LinkEditor> createState() => _LinkEditorState();
}

class _LinkEditorState extends ConsumerState<_LinkEditor> {
  late final TextEditingController _text;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final wasDark = Theme.of(context).brightness == Brightness.dark;
    try {
      await setVideoLink(ref,
          songId: widget.songId, input: _text.text);
    } catch (e) {
      if (!mounted) return;
      // Theme verdict captured before the await above; the copy
      // below is scheme-read, never hardcoded.
      setState(() {
        _error = e is FormatException
            ? 'That is not a video ID or link.'
            : 'Save failed: $e';
        _saving = false;
      });
      ArchLog.w('archtube', 'manual link rejected dark=$wasDark: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                enabled: !_saving,
                decoration: InputDecoration(
                  hintText: 'Video ID or YouTube link',
                  hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant
                        .withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color:
                          scheme.onSurface.withValues(alpha: 0.14),
                    ),
                  ),
                ),
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CupertinoActivityIndicator(),
                    )
                  : const Text(
                      'Link',
                      style: TextStyle(
                        color: archPink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}
