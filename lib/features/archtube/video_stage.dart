import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../core/badges.dart' show TypeBadge;
import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../player/audio_handler.dart';
import '../player/player_providers.dart';
import 'archtube_client.dart';
import 'dash_proxy.dart';
import 'extractor_backend.dart';
import 'video_providers.dart';

/// Song/Video pill above the art: the single entry/exit for video
/// mode, YT-Music grammar. Bordered rounded pill, hairline divider
/// between the lobes, pink = active (selection follows pink).
/// Safe bordered recipe, no lens. A black quality badge rides to the
/// right of the pill while video owns the stage (tap-to-quality
/// lands with the adaptive menu slice).
class VideoModeSwitch extends ConsumerWidget {
  final VideoSong song;
  final ValueChanged<BuildContext>? onQualityTap;

  const VideoModeSwitch({super.key, required this.song, this.onQualityTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final videoMode = ref.watch(videoModeProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: scheme.onSurface.withValues(alpha: 0.12)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ModeLobe(
                icon: CupertinoIcons.music_note,
                label: 'Song',
                active: !videoMode,
                onTap: () {
                  if (!videoMode) return;
                  HapticFeedback.selectionClick();
                  // Handoff while mounted: seek the parked audio to
                  // the mapped song position and play, then drop the
                  // mode. Dispose repeats the same target as a
                  // backstop for abnormal unmounts.
                  final vpos = ref.read(videoPositionProvider);
                  final offset = ref.read(videoOffsetProvider(song.id));
                  final target = Duration(
                    milliseconds: (vpos.inMilliseconds - offset * 1000)
                        .round()
                        .clamp(0, song.duration.inMilliseconds),
                  );
                  unawaited(
                    ref
                        .read(audioHandlerProvider)
                        .resumeFromVideo(target, 'pill tap'),
                  );
                  ref.read(videoModeProvider.notifier).state = false;
                },
              ),
              Container(
                width: 1,
                height: 22,
                color: scheme.onSurface.withValues(alpha: 0.12),
              ),
              _ModeLobe(
                icon: CupertinoIcons.videocam_fill,
                label: 'Video',
                active: videoMode,
                onTap: () {
                  if (!videoMode) {
                    HapticFeedback.selectionClick();
                    ref.read(videoModeProvider.notifier).state = true;
                  }
                },
              ),
            ],
          ),
        ),
        _QualityBadge(song: song, onTap: onQualityTap),
      ],
    );
  }
}

/// One pill lobe: icon + label, pink fill + pink text when active,
/// transparent + dim when idle. Reduced-motion cuts the fill fade.
class _ModeLobe extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ModeLobe({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? archPink.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? archPink : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                color: active ? archPink : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Current quality mark: the house black badge (`TypeBadge` grammar),
/// video-mode only, hidden until a stream label lands. Tap opens the
/// player menu at the video rows (wired by the caller).
class _QualityBadge extends ConsumerWidget {
  final VideoSong song;
  final ValueChanged<BuildContext>? onTap;

  const _QualityBadge({required this.song, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(videoModeProvider)) return const SizedBox.shrink();
    final link = ref.watch(
      videoLinkProvider(
        songQuery(
          songId: song.id,
          artist: song.artist,
          title: song.title,
          songSecs: song.duration.inSeconds,
        ),
      ),
    );
    final videoId = link.value?.videoId;
    if (videoId == null) return const SizedBox.shrink();
    final playback = ref.watch(videoPlaybackProvider(videoId));
    final options = playback.value?.options;
    if (options == null || options.isEmpty) return const SizedBox.shrink();
    final picked =
        ref.watch(selectedItagProvider(videoId)) ?? options.first.itag;
    final option = options.firstWhere(
      (o) => o.itag == picked,
      orElse: () => options.first,
    );
    final label = ref.watch(hybridDashProvider(videoId))
        ? 'HQ AUDIO'
        : (option.label.isEmpty ? _itagLabel(option.itag) : option.label);
    if (label.isEmpty) return const SizedBox.shrink();
    final badge = TypeBadge(label: label);
    final tap = onTap;
    if (tap == null) {
      return Padding(padding: const EdgeInsets.only(left: 8), child: badge);
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Builder(
        builder: (badgeContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.selectionClick();
            tap(badgeContext);
          },
          child: badge,
        ),
      ),
    );
  }
}

/// Fallback labels for the progressive ladder when YouTube serves no
/// `qualityLabel`. Unknown itags stay hidden, never guessed.
String _itagLabel(int itag) => switch (itag) {
  22 => '720p',
  18 => '360p',
  _ => '',
};

/// Video stage: replaces the art box while video mode is on.
/// Link (cached, else one auto-search) then streams, each with
/// explicit loading/error/empty/data. Never a dead screen.
/// [height] is the full box: the player fills it exactly, message
/// states treat it as a minimum so tall editors can still grow.
class VideoStage extends ConsumerStatefulWidget {
  final VideoSong song;
  final double width;
  final double height;

  const VideoStage({
    super.key,
    required this.song,
    required this.width,
    required this.height,
  });

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
    final link = ref.watch(
      videoLinkProvider(
        songQuery(
          songId: widget.song.id,
          artist: widget.song.artist,
          title: widget.song.title,
          songSecs: widget.song.duration.inSeconds,
        ),
      ),
    );
    return SizedBox(
      width: widget.width,
      child: link.when(
        loading: () => _VideoMessage(
          width: widget.width,
          height: widget.height,
          label: 'Finding video...',
          child: const CupertinoActivityIndicator(),
        ),
        error: (e, _) => _VideoMessage(
          width: widget.width,
          height: widget.height,
          icon: CupertinoIcons.exclamationmark_triangle,
          label: 'Video lookup failed',
          detail: '$e',
          actions: [
            TextButton(
              onPressed: () => ref.invalidate(videoLinkProvider),
              child: const Text(
                'Retry',
                style: TextStyle(color: archPink, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _linkEditorOpen = true),
              child: Text(
                'Paste link',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          below: _linkEditorOpen ? _LinkEditor(songId: widget.song.id) : null,
        ),
        data: (resolved) {
          if (resolved == null) {
            return _VideoMessage(
              width: widget.width,
              height: widget.height,
              icon: CupertinoIcons.videocam,
              label: 'No video found',
              detail:
                  'No YouTube match landed in the '
                  'duration window. Paste one below.',
              below: _LinkEditor(songId: widget.song.id),
            );
          }
          return _VideoBox(
            key: ValueKey(resolved.videoId),
            song: widget.song,
            videoId: resolved.videoId,
            width: widget.width,
            height: widget.height,
          );
        },
      ),
    );
  }
}

/// Loading/error/empty shell: scheme surface, centered glyph,
/// label, optional detail + actions + manual entry below.
/// [height] is a minimum: short states hold the full box so the
/// stage never jumps size, tall editors still grow past it.
class _VideoMessage extends StatelessWidget {
  final double width;
  final double height;
  final String label;
  final String? detail;
  final IconData? icon;
  final Widget? child;
  final List<Widget>? actions;
  final Widget? below;

  const _VideoMessage({
    required this.width,
    required this.height,
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
      constraints: BoxConstraints(minHeight: height),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child ??
              Icon(
                icon ?? CupertinoIcons.videocam,
                size: 40,
                color: scheme.onSurfaceVariant,
              ),
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
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
          if (actions != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: actions!,
            ),
          ],
          if (below != null) ...[const SizedBox(height: 12), below!],
        ],
      ),
    );
  }
}

/// Streams gate: loading/error/data around the player box.
/// Quality, aspect, offset, and link rows live in the video menu.
class _VideoBox extends ConsumerWidget {
  final VideoSong song;
  final String videoId;
  final double width;
  final double height;

  const _VideoBox({
    super.key,
    required this.song,
    required this.videoId,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final playback = ref.watch(videoPlaybackProvider(videoId));
    return playback.when(
      loading: () => _VideoMessage(
        width: width,
        height: height,
        label: 'Loading video...',
        child: const CupertinoActivityIndicator(),
      ),
      error: (e, _) => _VideoMessage(
        width: width,
        height: height,
        icon: CupertinoIcons.exclamationmark_triangle,
        label: 'Video unavailable',
        detail:
            'YouTube served no playable stream. '
            'Disguises exhausted.',
        actions: [
          TextButton(
            onPressed: () => ref.invalidate(videoPlaybackProvider(videoId)),
            child: const Text(
              'Retry',
              style: TextStyle(color: archPink, fontWeight: FontWeight.w600),
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
      data: (pb) {
        if (pb.options.isEmpty) {
          return _VideoMessage(
            width: width,
            height: height,
            icon: CupertinoIcons.exclamationmark_triangle,
            label: 'Video unavailable',
            detail:
                'YouTube served no playable stream. '
                'Disguises exhausted.',
            actions: [
              TextButton(
                onPressed: () =>
                    ref.invalidate(videoPlaybackProvider(videoId)),
                child: const Text(
                  'Retry',
                  style: TextStyle(
                    color: archPink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            below: _LinkEditor(songId: song.id),
          );
        }
        final picked =
            ref.watch(selectedItagProvider(videoId)) ?? pb.options.first.itag;
        final option = pb.options.firstWhere(
          (o) => o.itag == picked,
          orElse: () => pb.options.first,
        );
        if (option.dash && pb.dashAudioUrl != null) {
          return _DashPlayer(
            song: song,
            videoId: videoId,
            videoItag: option.itag,
            cpn: pb.cpn,
            videoUrl: option.url,
            videoLength: option.length,
            videoType: option.type,
            audioUrl: pb.dashAudioUrl!,
            audioLength: pb.dashAudioLength,
            audioType: pb.dashAudioType,
            width: width,
            height: height,
          );
        }
        return _StreamPlayer(
          song: song,
          stream: ArchtubeStream(
            itag: option.itag,
            url: option.url,
            mime: '',
            qualityLabel: option.label,
            bitrate: 0,
          ),
          width: width,
          height: height,
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
  final double height;

  const _StreamPlayer({
    required this.song,
    required this.stream,
    required this.width,
    required this.height,
  });

  @override
  ConsumerState<_StreamPlayer> createState() => _StreamPlayerState();
}

class _StreamPlayerState extends ConsumerState<_StreamPlayer> {
  VideoPlayerController? _controller;
  bool _exited = false;
  String? _error;

  /// Song this box was born for. Dispose resumes audio only on a
  /// same-song unmount (mode exit, player close); a song change
  /// belongs to the engine, never to a stale video box.
  late final int _songId = widget.song.id;

  /// Last seen video-clock position. Drives the mapped audio resume
  /// when the box unmounts without the exit path.
  Duration _lastVideoPos = Duration.zero;

  /// Last published whole second: the seekbar follows per second,
  /// not per frame.
  int _lastReportedSec = -1;

  /// Last published play state: the transport mirrors transitions
  /// only, never per-frame value churn.
  bool _lastPlaying = false;

  /// Song audio handle captured while mounted, and the last offset:
  /// dispose cannot use ref, so the backstop resume rides these.
  late ArchAudioHandler _songHandler;
  double _lastOffset = 0;

  void _publishPlaying(bool playingNow) {
    if (playingNow == _lastPlaying) return;
    _lastPlaying = playingNow;
    ref.read(videoPlayingProvider.notifier).state = playingNow;
  }

  /// Video-clock position mapped back to song time (minus offset,
  /// clamped to the song). The song owns the timeline, so every
  /// handoff back to audio lands here, never at the stale pause.
  Duration _songPosOf(Duration videoPos) {
    final offset = ref.read(videoOffsetProvider(widget.song.id));
    final ms = (videoPos.inMilliseconds - offset * 1000)
        .round()
        .clamp(0, widget.song.duration.inMilliseconds);
    return Duration(milliseconds: ms);
  }

  /// Ref-free twin for dispose: ref throws once unmount starts.
  Duration _mappedResume() {
    final ms = (_lastVideoPos.inMilliseconds - _lastOffset * 1000)
        .round()
        .clamp(0, widget.song.duration.inMilliseconds);
    return Duration(milliseconds: ms);
  }

  void _publishClock(Duration pos) {
    _lastVideoPos = pos;
    if (pos.inSeconds == _lastReportedSec) return;
    _lastReportedSec = pos.inSeconds;
    ref.read(videoPositionProvider.notifier).state = pos;
  }

  @override
  void initState() {
    super.initState();
    _songHandler = ref.read(audioHandlerProvider);
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
    _publishPlaying(false);
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
    // Handoff: song parked hard before video owns the timeline.
    // parkForVideo stops cold (no fade window where both play) and
    // holds the flag that eats our own focus events. The entry pause
    // is unconditional; the exit always plays back, so the
    // was-playing flag has no job here.
    final handler = ref.read(audioHandlerProvider);
    try {
      await handler.parkForVideo();
    } catch (e) {
      ArchLog.w('archtube', 'video park failed: $e');
    }
    if (!mounted) return;
    final offset = ref.read(videoOffsetProvider(widget.song.id));
    final songPos = ref.read(positionProvider).value ?? Duration.zero;
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
    _lastVideoPos = safeStart;
    _lastReportedSec = safeStart.inSeconds;
    ref.read(videoPositionProvider.notifier).state = safeStart;
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
    _publishPlaying(false);
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
    _lastVideoPos = from;
    _lastReportedSec = from.inSeconds;
    ref.read(videoPositionProvider.notifier).state = from;
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
    _lastOffset = offset;
    final windowEnd = Duration(
      milliseconds: ((widget.song.duration.inSeconds + offset) * 1000).round(),
    );
    final pos = c.value.position;
    _publishClock(pos);
    _publishPlaying(c.value.isPlaying);
    final dur = c.value.duration;
    final end = windowEnd < dur ? windowEnd : dur;
    if (pos >= end && end > Duration.zero) {
      _exitToSong();
    }
  }

  /// Window end or user exit: video off fully before audio back.
  /// Audio always resumes at the mapped song position and plays:
  /// leaving video means back to the song, never back to silence.
  Future<void> _exitToSong() async {
    if (_exited) return;
    _exited = true;
    final c = _controller;
    Duration resume = _lastVideoPos;
    try {
      resume = c?.value.position ?? _lastVideoPos;
      await c?.pause();
    } catch (_) {}
    _publishPlaying(false);
    if (!mounted) return;
    ref.read(videoModeProvider.notifier).state = false;
    try {
      final handler = ref.read(audioHandlerProvider);
      await handler.resumeFromVideo(_songPosOf(resume), 'window end');
    } catch (e) {
      ArchLog.w('archtube', 'audio resume failed: $e');
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
    // Unmount without the exit path (player close, abnormal drop):
    // back to the song, always playing. A song change belongs to
    // the engine, so a stale box never touches it. The seek chains
    // before the play so a stale play can never jump ahead.
    // Ref-free: ref throws once unmount starts, so the stashed
    // handle answers. Pill-tap exits land here too; the handler
    // dedupes the repeat into a single resume.
    if (!_exited && widget.song.id == _songId) {
      try {
        unawaited(_songHandler.resumeFromVideo(_mappedResume(), 'dispose'));
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
    final aspect = ref.watch(videoAspectProvider);
    // Transport play/pause rings this bell with the target state.
    // Seekbar scrubs ring their own. One controller answers.
    ref.listen(videoPlayRequestProvider, (prev, next) {
      if (prev?.gen == next.gen) return;
      final c = _controller;
      if (c == null || !c.value.isInitialized || _exited) return;
      unawaited(next.play ? c.play() : c.pause());
    });
    ref.listen(videoSeekRequestProvider, (prev, next) {
      if (prev?.gen == next.gen) return;
      final c = _controller;
      if (c == null || !c.value.isInitialized || _exited) return;
      c.seekTo(next.pos);
    });
    ref.listen<int>(videoFullscreenRequestProvider, (prev, next) {
      final c = _controller;
      if (prev == next || c == null || !c.value.isInitialized) return;
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _FullscreenVideo(controller: c)),
      );
    });
    final c = _controller;
    if (_error != null) {
      return _VideoMessage(
        width: widget.width,
        height: widget.height,
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
              style: TextStyle(color: archPink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }
    if (c == null || !c.value.isInitialized) {
      return _VideoMessage(
        width: widget.width,
        height: widget.height,
        label: 'Loading video...',
        child: const CupertinoActivityIndicator(),
      );
    }
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _VideoPicture(controller: c, aspect: aspect),
          Positioned(
            right: 6,
            bottom: 6,
            child: _GlassIconButton(
              icon: Icons.fullscreen,
              tooltip: 'Fullscreen',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _FullscreenVideo(controller: c),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dual player: DASH video-only picture plus the video's own
/// audio-only sound on a second lightweight player. Same handoff
/// contract as the progressive box: song audio parked, mapped
/// resume on exit, window end flips back. The audio clock leads:
/// the picture chases it past the drift budget, and the seekbar
/// follows the audio clock.
class _DashPlayer extends ConsumerStatefulWidget {
  final VideoSong song;
  final String videoId;
  final int videoItag;
  final String cpn;
  final String videoUrl;
  final int videoLength;
  final String videoType;
  final String audioUrl;
  final int audioLength;
  final String audioType;
  final double width;
  final double height;

  const _DashPlayer({
    required this.song,
    required this.videoId,
    required this.videoItag,
    required this.cpn,
    required this.videoUrl,
    required this.videoLength,
    required this.videoType,
    required this.audioUrl,
    required this.audioLength,
    required this.audioType,
    required this.width,
    required this.height,
  });

  @override
  ConsumerState<_DashPlayer> createState() => _DashPlayerState();
}

class _DashPlayerState extends ConsumerState<_DashPlayer> {
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  DashProxy? _videoProxy;
  DashProxy? _audioProxy;
  bool _exited = false;
  String? _error;
  Duration _lastAudioPos = Duration.zero;
  int _lastReportedSec = -1;
  bool _lastPlaying = false;
  int _lastCorrectMs = 0;

  /// Drift past this re-seeks the picture onto the sound.
  static const _driftBudgetMs = 1500;

  late final int _songId = widget.song.id;

  /// Song audio handle captured while mounted: dispose cannot use
  /// ref (it throws once unmount starts), so the backstop resume
  /// rides this instead.
  late ArchAudioHandler _songHandler;

  /// Last seen offset for the ref-free dispose mapping.
  double _lastOffset = 0;

  /// DASH load attempts: the first failure re-resolves fresh URLs
  /// (expiry), a fresh failure bans DASH into progressive fallback.
  int _dashAttempts = 0;

  /// Alive guards: async episodes race dispose (re-resolve swaps URLs
  /// under a running init, the box unmounts mid-hybrid). Every post
  /// await continuation bails through [alive], and the degrade path
  /// never touches ref or a dead player once boxed out.
  bool _disposed = false;
  int _gen = 0;

  /// One degrade per episode: mid-play error ticks (hasError sticks)
  /// must not double-fire re-resolve into an instant ban. Cleared by
  /// every fresh [_init]; the next episode earns its own degrade.
  bool _degrading = false;

  /// Last upstream refresh: the proxy asks per 403, throttled here so
  /// a walled lane never turns into a resolve storm.
  DateTime? _lastRefresh;

  bool _alive(int gen) => mounted && !_disposed && !_exited && gen == _gen;

  /// Ref-free song mapping for dispose: audio clock minus the last
  /// offset, clamped to the song.
  Duration _mappedResume() {
    final ms = (_lastAudioPos.inMilliseconds - _lastOffset * 1000)
        .round()
        .clamp(0, widget.song.duration.inMilliseconds);
    return Duration(milliseconds: ms);
  }

  /// DASH source failure (403, wall, expiry): fresh URLs first,
  /// progressive fallback when fresh fails too. Never an error
  /// screen while another lane can play. Boxed out once the state is
  /// gone (dispose/unmount/exit) or this episode already degraded:
  /// ref and the players are untouchable past that point.
  void _onDashFailure(String detail) {
    if (!mounted || _disposed || _exited || _degrading) return;
    _degrading = true;
    if (_dashAttempts > 0) {
      ArchLog.w('archtube', 'dash failed fresh, falling back: $detail');
      ref.read(dashFailedProvider(widget.videoId).notifier).state = true;
      noteDashFailure(ref, widget.videoId);
      ref.invalidate(videoPlaybackProvider(widget.videoId));
      return;
    }
    _dashAttempts++;
    ArchLog.i('archtube', 'dash failed, re-resolving fresh URLs: $detail');
    ref.invalidate(videoPlaybackProvider(widget.videoId));
  }

  Duration _songPosOf(Duration videoPos) {
    final offset = ref.read(videoOffsetProvider(widget.song.id));
    final ms = (videoPos.inMilliseconds - offset * 1000)
        .round()
        .clamp(0, widget.song.duration.inMilliseconds);
    return Duration(milliseconds: ms);
  }

  void _publishClock(Duration pos) {
    _lastAudioPos = pos;
    if (pos.inSeconds == _lastReportedSec) return;
    _lastReportedSec = pos.inSeconds;
    ref.read(videoPositionProvider.notifier).state = pos;
  }

  void _publishPlaying(bool playingNow) {
    if (playingNow == _lastPlaying) return;
    _lastPlaying = playingNow;
    ref.read(videoPlayingProvider.notifier).state = playingNow;
  }

  @override
  void initState() {
    super.initState();
    _songHandler = ref.read(audioHandlerProvider);
    _init();
  }

  @override
  void didUpdateWidget(covariant _DashPlayer old) {
    super.didUpdateWidget(old);
    if (old.audioUrl != widget.audioUrl) {
      _init();
    } else if (old.videoUrl != widget.videoUrl) {
      // Quality swap: the sound keeps running, only the picture
      // re-inits, landing on the live audio clock.
      _swapVideo();
    }
  }

  Duration _startAt() {
    final offset = ref.read(videoOffsetProvider(widget.song.id));
    final songPos = ref.read(positionProvider).value ?? Duration.zero;
    return Duration(
      milliseconds: ((songPos.inMilliseconds / 1000 + offset) * 1000)
          .round()
          .clamp(0, 1 << 31),
    );
  }

  /// Serve one upstream URL through a fresh loopback proxy,
  /// dropping the previous one. Throws when the bind fails, which
  /// degrades like any other source failure.
  ///
  /// EXPERIMENT (DASH 403): flip [directFetch] true to hand ExoPlayer
  /// the raw googlevideo URL with no proxy in the middle. Proxy vs
  /// transport, one variable. Default false = normal path.
  static bool directFetch = false;

  Future<Uri> _serveVideo() async {
    final old = _videoProxy;
    _videoProxy = null;
    try {
      await old?.close();
    } catch (_) {}
    if (directFetch) {
      ArchLog.i('archtube', 'DIRECT video fetch (no proxy)');
      return Uri.parse(widget.videoUrl);
    }
    final proxy = DashProxy(
      upstreamUrl: widget.videoUrl,
      contentLength: widget.videoLength,
      contentType: widget.videoType.isEmpty ? 'video/mp4' : widget.videoType,
    );
    proxy.refreshUpstream = () => _refreshUpstream(audio: false);
    proxy.contentPlaybackNonce = widget.cpn;
    await proxy.start();
    _videoProxy = proxy;
    return proxy.url;
  }

  Future<Uri> _serveAudio() async {
    final old = _audioProxy;
    _audioProxy = null;
    try {
      await old?.close();
    } catch (_) {}
    final proxy = DashProxy(
      upstreamUrl: widget.audioUrl,
      contentLength: widget.audioLength,
      contentType: widget.audioType.isEmpty ? 'audio/mp4' : widget.audioType,
    );
    proxy.refreshUpstream = () => _refreshUpstream(audio: true);
    proxy.contentPlaybackNonce = widget.cpn;
    await proxy.start();
    _audioProxy = proxy;
    return proxy.url;
  }

  /// Fresh signed URL for one walled proxy leg, same streamingData
  /// lane: picture keeps its itag (quality never jumps mid-play),
  /// sound takes the hottest lane. Throttled: at most one resolve
  /// per 10s no matter how many chunks 403.
  Future<DashUpstream?> _refreshUpstream({required bool audio}) async {
    if (!mounted || _disposed || _exited) return null;
    final now = DateTime.now();
    if (_lastRefresh != null &&
        now.difference(_lastRefresh!) < const Duration(seconds: 10)) {
      return null;
    }
    _lastRefresh = now;
    try {
      final dash = await backendPlayerDash(
        ref.read(streamBackendProvider),
        ref.read(archtubeClientProvider),
        widget.videoId,
        cpn: widget.cpn,
      );
      if (!dash.playable || !mounted || _disposed || _exited) return null;
      if (audio) {
        final a = dash.audios.first;
        return DashUpstream(
          url: a.url,
          contentLength: a.contentLength,
          contentType: a.contentType,
        );
      }
      final match = dash.videos.where((v) => v.itag == widget.videoItag);
      final v = match.isNotEmpty ? match.first : dash.videos.first;
      return DashUpstream(
        url: v.url,
        contentLength: v.contentLength,
        contentType: v.contentType,
      );
    } catch (e) {
      ArchLog.w('archtube', 'dash refresh resolve failed: $e');
      return null;
    }
  }

  Future<void> _closeProxies() async {
    final videoProxy = _videoProxy;
    final audioProxy = _audioProxy;
    _videoProxy = null;
    _audioProxy = null;
    try {
      await videoProxy?.close();
    } catch (_) {}
    try {
      await audioProxy?.close();
    } catch (_) {}
  }

  Future<void> _init() async {
    _gen++;
    final gen = _gen;
    _degrading = false;
    _publishPlaying(false);
    ref.read(hybridDashProvider(widget.videoId).notifier).state = false;
    // Retry-safe: drop any failed pair before building the next.
    final oldVideo = _video;
    final oldAudio = _audio;
    _video = null;
    _audio = null;
    try {
      await oldVideo?.pause();
    } catch (_) {}
    try {
      await oldVideo?.dispose();
    } catch (_) {}
    try {
      await oldAudio?.pause();
    } catch (_) {}
    try {
      await oldAudio?.dispose();
    } catch (_) {}
    if (!_alive(gen)) return;
    late final Uri videoUri;
    try {
      videoUri = await _serveVideo();
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'dash proxy start failed: $e');
      await _tryHybrid('$e', gen);
      return;
    }
    if (!_alive(gen)) return;
    final video = VideoPlayerController.networkUrl(videoUri);
    _video = video;
    try {
      await video.initialize();
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'dash picture init failed: $e');
      _video = null;
      try {
        await video.dispose();
      } catch (_) {}
      await _tryHybrid('$e', gen);
      return;
    }
    if (!_alive(gen)) {
      _video = null;
      try {
        await video.dispose();
      } catch (_) {}
      return;
    }
    // Serialized: the sound proxy starts only after the picture's
    // first bytes land. Parallel range bursts read botty and the
    // whole pair eats the wall together; staggered, each stands
    // on its own.
    late final Uri audioUri;
    try {
      audioUri = await _serveAudio();
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'dash proxy start failed: $e');
      _onDashFailure('$e');
      return;
    }
    if (!_alive(gen)) return;
    final audio = AudioPlayer();
    _audio = audio;
    try {
      await audio.setAudioSource(AudioSource.uri(audioUri));
    } catch (e) {
      if (!_alive(gen)) {
        try {
          await audio.dispose();
        } catch (_) {}
        return;
      }
      ArchLog.w('archtube', 'dash sound init failed: $e');
      _video = null;
      _audio = null;
      try {
        await video.dispose();
      } catch (_) {}
      try {
        await audio.dispose();
      } catch (_) {}
      _onDashFailure('$e');
      return;
    }
    if (!_alive(gen)) {
      _video = null;
      _audio = null;
      try {
        await video.dispose();
      } catch (_) {}
      try {
        await audio.dispose();
      } catch (_) {}
      return;
    }
    // Handoff: song audio parked hard before video sound on.
    // parkForVideo stops cold and holds the focus-eat flag, so the
    // dash sound leg's own focus request never ducks the song.
    final handler = ref.read(audioHandlerProvider);
    try {
      await handler.parkForVideo();
    } catch (e) {
      ArchLog.w('archtube', 'video park failed: $e');
    }
    if (!_alive(gen)) return;
    final startAt = _startAt();
    video.addListener(_onTick);
    final length = video.value.duration;
    final safeStart = startAt > length
        ? Duration.zero
        : startAt > Duration.zero
        ? startAt
        : Duration.zero;
    _publishClock(safeStart);
    try {
      if (safeStart > Duration.zero) {
        await video.seekTo(safeStart);
        await audio.seek(safeStart);
      }
      if (!_alive(gen)) return;
      await audio.play();
      await video.play();
      ref.read(dashFailStreakProvider.notifier).state = 0;
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'dash start failed: $e');
      _onDashFailure('$e');
      return;
    }
    if (mounted) setState(() {});
  }

  /// Hybrid fallback: picture DASH walled, but the sound leg may
  /// still serve. Progressive picture (muted, direct URL) under DASH
  /// sound, same clocks, same sync machinery. Degrades fully when
  /// either leg fails. Stale episodes bail without touching ref.
  Future<void> _tryHybrid(Object videoError, int gen) async {
    if (!_alive(gen)) return;
    final failedVideo = _video;
    _video = null;
    try {
      await failedVideo?.dispose();
    } catch (_) {}
    ArchLog.i('archtube', 'dash picture walled, trying hybrid sound');
    late final Uri audioUri;
    try {
      audioUri = await _serveAudio();
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'hybrid audio proxy failed: $e');
      _onDashFailure('$videoError / $e');
      return;
    }
    if (!_alive(gen)) return;
    final audio = AudioPlayer();
    _audio = audio;
    try {
      await audio.setAudioSource(AudioSource.uri(audioUri));
    } catch (e) {
      if (!_alive(gen)) {
        try {
          await audio.dispose();
        } catch (_) {}
        return;
      }
      ArchLog.w('archtube', 'hybrid sound init failed: $e');
      _audio = null;
      try {
        await audio.dispose();
      } catch (_) {}
      _onDashFailure('$videoError / $e');
      return;
    }
    if (!_alive(gen)) {
      _audio = null;
      try {
        await audio.dispose();
      } catch (_) {}
      return;
    }
    List<ArchtubeStream> prog;
    try {
      prog = await backendPlayerStreams(
        ref.read(streamBackendProvider),
        ref.read(archtubeClientProvider),
        widget.videoId,
        cpn: widget.cpn,
      );
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'hybrid progressive fetch failed: $e');
      _onDashFailure('$videoError / $e');
      return;
    }
    if (!_alive(gen)) return;
    if (prog.isEmpty) {
      _onDashFailure('$videoError / no progressive');
      return;
    }
    final video = VideoPlayerController.networkUrl(Uri.parse(prog.first.url));
    _video = video;
    try {
      await video.initialize();
      await video.setVolume(0);
    } catch (e) {
      if (!_alive(gen)) {
        _video = null;
        try {
          await video.dispose();
        } catch (_) {}
        return;
      }
      ArchLog.w('archtube', 'hybrid picture init failed: $e');
      _video = null;
      try {
        await video.dispose();
      } catch (_) {}
      _onDashFailure('$videoError / $e');
      return;
    }
    if (!_alive(gen)) {
      _video = null;
      _audio = null;
      try {
        await video.dispose();
      } catch (_) {}
      try {
        await audio.dispose();
      } catch (_) {}
      return;
    }
    final handler = ref.read(audioHandlerProvider);
    try {
      await handler.parkForVideo();
    } catch (e) {
      ArchLog.w('archtube', 'video park failed: $e');
    }
    if (!_alive(gen)) return;
    final startAt = _startAt();
    video.addListener(_onTick);
    _publishClock(startAt);
    try {
      if (startAt > Duration.zero) {
        await video.seekTo(startAt);
        await audio.seek(startAt);
      }
      if (!_alive(gen)) return;
      await audio.play();
      await video.play();
      ref.read(dashFailStreakProvider.notifier).state = 0;
      ref.read(hybridDashProvider(widget.videoId).notifier).state = true;
      ArchLog.i('archtube', 'hybrid engaged: muted picture + dash sound');
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'hybrid start failed: $e');
      _onDashFailure('$videoError / $e');
      return;
    }
    if (mounted) setState(() {});
  }

  /// Quality swap mid-play: fresh picture lands on the running
  /// sound clock, resuming only if it was playing.
  Future<void> _swapVideo() async {
    _gen++;
    final gen = _gen;
    final audio = _audio;
    final wasPlaying = _lastPlaying;
    // The sound leg may die under us (re-resolve disposed it): never
    // let a clock read throw the swap off the rails.
    Duration at;
    try {
      at = audio?.position ?? _lastAudioPos;
    } catch (_) {
      at = _lastAudioPos;
    }
    final old = _video;
    old?.removeListener(_onTick);
    _video = null;
    if (mounted) setState(() {});
    try {
      await old?.pause();
    } catch (_) {}
    try {
      await old?.dispose();
    } catch (_) {}
    if (!_alive(gen)) return;
    late final Uri videoUri;
    try {
      videoUri = await _serveVideo();
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'dash swap proxy failed: $e');
      await _dropAudio();
      _onDashFailure('$e');
      return;
    }
    if (!_alive(gen)) return;
    final video = VideoPlayerController.networkUrl(videoUri);
    _video = video;
    try {
      await video.initialize();
    } catch (e) {
      if (!_alive(gen)) {
        _video = null;
        try {
          await video.dispose();
        } catch (_) {}
        return;
      }
      ArchLog.w('archtube', 'dash swap init failed: $e');
      _video = null;
      try {
        await video.dispose();
      } catch (_) {}
      await _dropAudio();
      _onDashFailure('$e');
      return;
    }
    if (!_alive(gen)) {
      _video = null;
      try {
        await video.dispose();
      } catch (_) {}
      return;
    }
    video.addListener(_onTick);
    try {
      await video.seekTo(at);
      if (!_alive(gen)) return;
      if (wasPlaying) await video.play();
      ref.read(hybridDashProvider(widget.videoId).notifier).state = false;
    } catch (e) {
      if (!_alive(gen)) return;
      ArchLog.w('archtube', 'dash swap start failed: $e');
      await _dropAudio();
      _onDashFailure('$e');
      return;
    }
    if (mounted) setState(() {});
  }

  /// Drop the dash sound leg (swap failure): the degrade path mounts
  /// progressive muxed sound, so anything left playing doubles audio.
  /// Ref stays untouched once the state is gone.
  Future<void> _dropAudio() async {
    final a = _audio;
    _audio = null;
    try {
      await a?.pause();
    } catch (_) {}
    try {
      await a?.dispose();
    } catch (_) {}
    if (mounted && !_disposed) {
      ref.read(hybridDashProvider(widget.videoId).notifier).state = false;
    }
  }

  void _onTick() {
    if (_disposed) return;
    final v = _video;
    final a = _audio;
    if (v == null || !v.value.isInitialized || a == null || _exited) return;
    // Mid-play source death (proxy 502s after chunk walls): degrade
    // once per episode instead of holding a dead frame.
    if (v.value.hasError) {
      _onDashFailure('dash picture error: ${v.value.errorDescription}');
      return;
    }
    final vpos = v.value.position;
    final apos = a.position;
    _publishClock(apos);
    _publishPlaying(v.value.isPlaying || a.playing);
    // Picture chases sound, at most one correction a second: seeks
    // are silent skips, never audible jumps.
    final driftMs = (vpos.inMilliseconds - apos.inMilliseconds).abs();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (driftMs > _driftBudgetMs && nowMs - _lastCorrectMs > 1000) {
      _lastCorrectMs = nowMs;
      ArchLog.i('archtube', 'dash drift ${driftMs}ms, chasing');
      unawaited(v.seekTo(apos));
    }
    final offset = ref.read(videoOffsetProvider(widget.song.id));
    _lastOffset = offset;
    final windowEnd = Duration(
      milliseconds: ((widget.song.duration.inSeconds + offset) * 1000).round(),
    );
    var end = windowEnd;
    final vdur = v.value.duration;
    if (vdur < end) end = vdur;
    final adur = a.duration;
    if (adur != null && adur < end) end = adur;
    if (apos >= end && end > Duration.zero) {
      _exitToSong();
    }
  }

  /// Window end: both off fully before song audio back, which always
  /// resumes at the mapped position and plays.
  Future<void> _exitToSong() async {
    if (_exited) return;
    _exited = true;
    final v = _video;
    final a = _audio;
    Duration resume = _lastAudioPos;
    try {
      resume = a?.position ?? _lastAudioPos;
      await a?.pause();
      await v?.pause();
    } catch (_) {}
    _publishPlaying(false);
    if (!mounted || _disposed) return;
    ref.read(videoModeProvider.notifier).state = false;
    try {
      final handler = ref.read(audioHandlerProvider);
      await handler.resumeFromVideo(_songPosOf(resume), 'window end');
    } catch (e) {
      ArchLog.w('archtube', 'audio resume failed: $e');
    }
  }

  @override
  void dispose() {
    // Box out every in-flight episode first: post-await continuations
    // bail on the gen, the degrade path never touches dead ref.
    _disposed = true;
    _gen++;
    final v = _video;
    if (v != null) {
      v.removeListener(_onTick);
      v.pause();
      v.dispose();
    }
    final a = _audio;
    if (a != null) {
      a.pause();
      a.dispose();
    }
    unawaited(_closeProxies());
    // Unmount without the exit path (player close, abnormal drop):
    // back to the song, always playing. A song change belongs to
    // the engine, so a stale box never touches it. Ref-free: ref
    // throws once unmount starts, so the stashed handle answers.
    // Pill-tap exits land here too; the handler dedupes the repeat.
    if (!_exited && widget.song.id == _songId) {
      try {
        unawaited(_songHandler.resumeFromVideo(_mappedResume(), 'dispose'));
      } catch (e) {
        ArchLog.w('archtube', 'dispose resume failed: $e');
      }
    }
    _video = null;
    _audio = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final aspect = ref.watch(videoAspectProvider);
    ref.listen(videoPlayRequestProvider, (prev, next) {
      if (prev?.gen == next.gen) return;
      if (_exited) return;
      final v = _video;
      final a = _audio;
      if (next.play) {
        unawaited(v?.play() ?? Future.value());
        unawaited(a?.play() ?? Future.value());
      } else {
        unawaited(a?.pause() ?? Future.value());
        unawaited(v?.pause() ?? Future.value());
      }
    });
    ref.listen(videoSeekRequestProvider, (prev, next) {
      if (prev?.gen == next.gen) return;
      if (_exited) return;
      unawaited(_video?.seekTo(next.pos) ?? Future.value());
      unawaited(_audio?.seek(next.pos) ?? Future.value());
    });
    ref.listen<int>(videoFullscreenRequestProvider, (prev, next) {
      final v = _video;
      if (prev == next || v == null || !v.value.isInitialized) return;
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _FullscreenVideo(controller: v)),
      );
    });
    final v = _video;
    if (_error != null) {
      return _VideoMessage(
        width: widget.width,
        height: widget.height,
        icon: CupertinoIcons.exclamationmark_triangle,
        label: 'Playback failed',
        detail: _error,
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _error = null);
              _onDashFailure('manual retry');
            },
            child: const Text(
              'Retry',
              style: TextStyle(color: archPink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }
    if (v == null || !v.value.isInitialized) {
      return _VideoMessage(
        width: widget.width,
        height: widget.height,
        label: 'Loading video...',
        child: const CupertinoActivityIndicator(),
      );
    }
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _VideoPicture(controller: v, aspect: aspect),
          Positioned(
            right: 6,
            bottom: 6,
            child: _GlassIconButton(
              icon: Icons.fullscreen,
              tooltip: 'Fullscreen',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _FullscreenVideo(controller: v),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The picture itself, filling whatever box it lands in: fit shows
/// the whole frame letterboxed, fill crops to cover. Zero-size
/// (pre-first-frame) falls back to plain.
class _VideoPicture extends StatelessWidget {
  final VideoPlayerController controller;
  final VideoAspect aspect;

  const _VideoPicture({required this.controller, required this.aspect});

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      return VideoPlayer(controller);
    }
    return FittedBox(
      fit: aspect == VideoAspect.fill ? BoxFit.cover : BoxFit.contain,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: VideoPlayer(controller),
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
    final aspect = ref.watch(videoAspectProvider);
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
                child: _VideoPicture(controller: controller, aspect: aspect),
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
        icon: Icon(
          icon,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 6)],
        ),
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
      await setVideoLink(ref, songId: widget.songId, input: _text.text);
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
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
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
                      color: scheme.onSurface.withValues(alpha: 0.14),
                    ),
                  ),
                ),
                style: TextStyle(color: scheme.onSurface, fontSize: 13),
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
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
