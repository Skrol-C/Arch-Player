import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../metadata/lyrics_providers.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';

/// Our synced-lyrics stage: Apple mechanics in our skin. Lines are
/// parsed with the lyric package's own parser (zero new parsing
/// code); everything the eye sees is ours.
///
/// - Active line: large ink text with a pink fill sweeping
///   left-to-right through the sung portion, glowing edge.
///   Progress interpolates line timings now; per-word data
///   (Paxsenix later) sharpens the same renderer, never a redesign.
/// - Handoff: rows spring between past/active/future styles; the
///   list eases the active line to center.
/// - Haptic flip: a soft tick as each line turns over (pref-gated,
///   Settings V2 wires the toggle; default on).
/// - Breathing gaps: long instrumental stretches pulse the next
///   line instead of sitting dead.
/// - Duets now: parenthesized backing lines sit smaller and
///   indented beneath the lead. Speaker tags ride the same slot
///   when word-timed data arrives.
/// - Tap any line to seek. Reduced-motion snaps the fill.
class LyricStage extends ConsumerStatefulWidget {
  final String syncedLrc;
  final Duration offset;

  const LyricStage({super.key, required this.syncedLrc, required this.offset});

  @override
  ConsumerState<LyricStage> createState() => _LyricStageState();
}

class _LyricStageState extends ConsumerState<LyricStage> {
  late final List<LyricLine> _lines;
  final _scroller = ScrollController();
  final _keys = <int, GlobalKey>{};
  int _active = -1;
  int _lastJump = 0;
  DateTime? _holdUntil;
  // Single-scroll guard: the tick path and the flip timer race to
  // order the same glide. The loser is ignored.
  int _centeredFor = -2;
  DateTime _centeredAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Exact-time flip: position ticks land ~1/sec, which would flip
  // lines up to a second late. A one-shot timer per line fires the
  // handoff on time; the tick path remains as backstop.
  Timer? _flipTimer;

  bool get _parseOk => _lines.isNotEmpty;

  @override
  void initState() {
    super.initState();
    List<LyricLine> lines = const [];
    try {
      lines = LyricDocument.parse(widget.syncedLrc).lines;
    } catch (_) {
      lines = const [];
    }
    // Blank timestamped lines carry no words; dropping them never
    // loses information (gaps are read from timing, not blanks).
    _lines = [
      for (final l in lines)
        if (l.text.trim().isNotEmpty) l,
    ];
  }

  @override
  void dispose() {
    _flipTimer?.cancel();
    _scroller.dispose();
    super.dispose();
  }

  Duration _windowEnd(int i) {
    if (i + 1 < _lines.length) return _lines[i + 1].start;
    return _lines[i].start + const Duration(seconds: 8);
  }

  int _indexFor(Duration pos) {
    var active = -1;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].start <= pos) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  void _afterActive(int next) {
    if (next == _active) return;
    // Grouped duet focus: lead <-> backing moves update the
    // highlight but never re-fire the scroll, so call-and-response
    // stays anchored instead of bouncing.
    final prev = _active;
    final grouped =
        next >= 0 &&
        prev >= 0 &&
        (next - prev).abs() == 1 &&
        (_isBacking(_lines[next].text) || _isBacking(_lines[prev].text));
    setState(() => _active = next);
    if (next < 0) return;
    // Phased handoff: scroll leads, the row grows into place, the
    // haptic lands when it arrives. Same events, staged - never the
    // single-frame snap that read as stiff.
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted && _active == next && !grouped) _center(next);
    });
    final haptics = ref.read(lyricHapticsProvider);
    if (haptics) {
      Future.delayed(const Duration(milliseconds: 140), () {
        if (mounted && _active == next) HapticFeedback.selectionClick();
      });
    }
  }

  void _center(int index, {bool force = false}) {
    if (!mounted || !_scroller.hasClients) return;
    // Finger holds pause the follow; jumps override.
    if (!force && _holdUntil != null && DateTime.now().isBefore(_holdUntil!)) {
      return;
    }
    // One glide per flip: re-orders inside 1.5s are the same race,
    // not new intent.
    final now = DateTime.now();
    if (!force &&
        _centeredFor == index &&
        now.difference(_centeredAt) < const Duration(milliseconds: 1500)) {
      return;
    }
    _centeredFor = index;
    _centeredAt = now;
    final ctx = _keys[index]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.42,
      duration: Motion.reduced(context)
          ? Duration.zero
          : const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_parseOk) return const SizedBox.shrink();
    final tick =
        (ref.watch(positionProvider).value ?? Duration.zero) + widget.offset;
    final playing = ref.watch(playingProvider).value ?? false;
    // Ticks are the truth; the flip timer only wakes the build
    // early so handoffs land on the beat, not on the next tick.
    final pos = tick;
    // Jump requests (toolbar lyrics button) re-center immediately.
    final jump = ref.watch(lyricJumpProvider);
    if (jump != _lastJump) {
      _lastJump = jump;
      _holdUntil = null;
      final current = _active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current >= 0) _center(current, force: true);
      });
    }
    final next = _indexFor(pos);
    if (next != _active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _afterActive(next));
    }
    // Wake for the coming flip so it lands on time, not on tick.
    // Paused pins everything: no flips, no sweeps, no timers.
    _flipTimer?.cancel();
    if (playing && _active + 1 < _lines.length) {
      final delay = _lines[_active + 1].start - pos;
      if (delay > Duration.zero) {
        _flipTimer = Timer(
          delay > const Duration(seconds: 30)
              ? const Duration(seconds: 30)
              : delay,
          () {
            if (mounted) setState(() {});
          },
        );
      }
    }
    // Gap before the next line: breathe instead of sitting dead.
    final upcoming = next + 1 < _lines.length ? next + 1 : -1;
    final gap =
        upcoming >= 0 &&
        _lines[upcoming].start - pos > const Duration(seconds: 10);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // Finger drags pause the follow; programmatic glides never do.
        if (n is ScrollStartNotification && n.dragDetails != null) {
          _holdUntil = DateTime.now().add(const Duration(seconds: 5));
        }
        return false;
      },
      child: ListView.builder(
        controller: _scroller,
        padding: const EdgeInsets.fromLTRB(32, 12, 32, 48),
        itemCount: _lines.length,
        itemBuilder: (context, i) {
          _keys.putIfAbsent(i, () => GlobalKey());
          final line = _lines[i];
          final backing = _isBacking(line.text);
          // Depth blur: active razor sharp, neighbors graded softer
          // with distance. Static between flips (cached layers), so
          // depth costs nothing per frame.
          final dist = (i - _active).abs();
          final sigma = _active < 0
              ? 0.0
              : dist == 0
              ? 0.0
              : dist == 1
              ? 0.7
              : dist == 2
              ? 1.5
              : 2.5;
          Widget row;
          if (i == _active) {
            // Sweep gating: the timed renderer only engages when the
            // line carries word timings. Everything else rests at a
            // static full-pink active - calm, never fake precision.
            final words = line.words;
            if (words != null && words.isNotEmpty) {
              final end = _windowEnd(i);
              final span = end - line.start;
              // Converging sweep: while playing the fill always lands
              // exactly at 1.0 when the window ends (no chase lag);
              // while paused it holds the frozen progress still.
              final frozen = span.inMilliseconds <= 0
                  ? 1.0
                  : ((pos - line.start).inMilliseconds / span.inMilliseconds)
                        .clamp(0.0, 1.0);
              final target = playing ? 1.0 : frozen;
              final chaseMs = playing
                  ? (end - pos).inMilliseconds.clamp(300, 12000)
                  : 200;
              // Sibling trail is handled by rest rows below.
              row = _SungLine(
                key: ValueKey('sung-$i-${line.start}'),
                text: line.text,
                translation: line.translation,
                target: target,
                chaseMs: chaseMs,
                backing: backing,
                onTap: () => _seek(line.start),
              );
            } else {
              // Wordless active: static full pink. The emphasis is
              // real; only the motion waits for word data.
              row = _PinkLine(
                key: ValueKey('pink-$i-${line.start}'),
                text: line.text,
                translation: line.translation,
                backing: backing,
                onTap: () => _seek(line.start),
              );
            }
          } else {
            final stagger = (i - _active).clamp(0, 3) * 70;
            row = _RestLine(
              text: line.text,
              translation: line.translation,
              past: i < _active,
              backing: backing,
              breathe: gap && i == upcoming,
              staggerMs: i > _active ? stagger : 0,
              onTap: () => _seek(line.start),
            );
          }
          if (sigma > 0) {
            row = ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: row,
            );
          }
          // AnimatedSize: row boxes glide between states instead of
          // snapping, so the scroll target never jumps mid-flight.
          // Layout moves; painting follows; one continuous motion.
          return KeyedSubtree(
            key: _keys[i]!,
            child: AnimatedSize(
              duration: Motion.reduced(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: row,
            ),
          );
        },
      ),
    );
  }

  bool _isBacking(String text) {
    final t = text.trim();
    return t.length > 2 && t.startsWith('(') && t.endsWith(')');
  }

  void _seek(Duration at) {
    final handler = ref.read(audioHandlerProvider);
    playGuarded(context, () => handler.seek(at));
  }
}

/// Static active line: full pink, large, no motion. What every
/// wordless line rests at - the emphasis is honest, only the sweep
/// waits for word timings.
class _PinkLine extends StatelessWidget {
  final String text;
  final String? translation;
  final bool backing;
  final VoidCallback onTap;

  const _PinkLine({
    super.key,
    required this.text,
    required this.translation,
    required this.backing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: archPink,
                fontSize: backing ? 17 : 22,
                fontWeight: FontWeight.w800,
                height: 1.35,
              ),
            ),
            if (translation != null && translation!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  translation!.trim(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: inkDim,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The sung line: large heavy ink with the pink fill pouring
/// through the sung portion, feathered glowing edge. The tween
/// converges on the window end (60fps, no tick rebuilds); seeks and
/// line changes restart it from zero via the key. A whisper of a
/// landing pop (never past full size) marks each arrival.
class _SungLine extends StatelessWidget {
  final String text;
  final String? translation;
  final double target;
  final int chaseMs;
  final bool backing;
  final VoidCallback onTap;

  const _SungLine({
    super.key,
    required this.text,
    required this.translation,
    required this.target,
    required this.chaseMs,
    required this.backing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final style = TextStyle(
      color: ink,
      fontSize: backing ? 17 : 22,
      fontWeight: FontWeight.w800,
      height: 1.35,
    );
    Widget line(double p) {
      // Feathered pour: solid fill, soft ~14% falloff through glow
      // to ink. Pours; never wipes.
      final edge = p.clamp(0.0, 1.0);
      final tail = (edge - 0.10).clamp(0.0, 1.0);
      final tip = (edge + 0.04).clamp(0.0, 1.0);
      return ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          colors: const [archPink, archPink, Colors.white, ink, ink],
          stops: [0, tail, edge, tip, 1],
        ).createShader(bounds),
        child: Text(text, textAlign: TextAlign.center, style: style),
      );
    }

    // NOTE: stops stay monotonic in every edge case (0 and 1
    // included); the white stop is the feather's light edge.
    Widget body = GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: target),
              duration: reduced
                  ? Duration.zero
                  : Duration(milliseconds: chaseMs),
              curve: Curves.linear,
              builder: (context, p, _) => line(p),
            ),
            if (translation != null && translation!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  translation!.trim(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: inkDim,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (reduced) return body;
    // Landing pop: a breath past rest, settling back. Felt, not seen.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.96, end: 1.0),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutBack,
      builder: (context, s, _) => Transform.scale(scale: s, child: body),
    );
  }
}

/// Every other line: past sinks, future waits. Style changes ride
/// AnimatedDefaultTextStyle; rows below the focus trail with a
/// capped stagger so the list settles like liquid instead of
/// flipping in lockstep.
class _RestLine extends StatefulWidget {
  final String text;
  final String? translation;
  final bool past;
  final bool backing;
  final bool breathe;
  final int staggerMs;
  final VoidCallback onTap;

  const _RestLine({
    required this.text,
    required this.translation,
    required this.past,
    required this.backing,
    required this.breathe,
    required this.staggerMs,
    required this.onTap,
  });

  @override
  State<_RestLine> createState() => _RestLineState();
}

class _RestLineState extends State<_RestLine> {
  TextStyle? _shown;
  Timer? _timer;

  TextStyle _target() => TextStyle(
    color: widget.past ? inkDim : ink.withValues(alpha: 0.75),
    fontSize: widget.backing ? 13 : 16,
    fontWeight: widget.past ? FontWeight.w600 : FontWeight.w500,
    height: 1.5,
  );

  void _apply(TextStyle style, {int delayMs = 0}) {
    _timer?.cancel();
    if (delayMs <= 0) {
      setState(() => _shown = style);
      return;
    }
    _timer = Timer(Duration(milliseconds: delayMs), () {
      if (mounted) setState(() => _shown = style);
    });
  }

  @override
  void initState() {
    super.initState();
    _shown = _target();
  }

  @override
  void didUpdateWidget(_RestLine old) {
    super.didUpdateWidget(old);
    final reduced = Motion.reduced(context);
    final target = _target();
    final changed =
        old.past != widget.past ||
        old.backing != widget.backing ||
        old.text != widget.text;
    if (changed) {
      _apply(
        target,
        delayMs: reduced || widget.staggerMs <= 0 ? 0 : widget.staggerMs,
      );
    } else {
      // Unrelated rebuild (ticks): hold the shown style, never
      // restart the transition.
      _timer?.cancel();
      _shown = target;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final style = _shown ?? _target();
    Widget body = GestureDetector(
      onTap: widget.onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: 7,
          horizontal: widget.backing ? 24 : 0,
        ),
        child: Column(
          children: [
            AnimatedDefaultTextStyle(
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              style: style,
              textAlign: TextAlign.center,
              child: Text(widget.text),
            ),
            if (widget.translation != null &&
                widget.translation!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  widget.translation!.trim(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: inkDim,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (widget.breathe && !reduced) return _Breathe(child: body);
    return body;
  }
}

/// Slow pulse for the next line across long gaps. Self-contained:
/// lives and dies with its row.
class _Breathe extends StatefulWidget {
  final Widget child;
  const _Breathe({required this.child});

  @override
  State<_Breathe> createState() => _BreatheState();
}

class _BreatheState extends State<_Breathe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) =>
          Opacity(opacity: 0.45 + 0.3 * _anim.value, child: widget.child),
    );
  }
}
