// Dual-player crossfade runtime: two AudioPlayers take turns being
// audible, so the outgoing tail and the incoming head can overlap
// without either side restarting. One player is always idle — the
// idle one is where the next track is preloaded while the current
// one is still playing.
//
// This class owns transport mechanics only: it does not know about
// the library, the queue, notifications or shuffle. The handler
// decides *which* song comes next and calls in; the engine makes the
// handoff sound continuous.
//
// Ramp: [crossfadeGains] equal-power curve, ticked at ~30ms. Every
// step is clamped and every await is disposable, so a skip mid-blend
// or a shutdown can never wedge a player half-faded.

import 'dart:async';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';

import '../../core/log.dart';
import 'crossfade.dart';

class AutomixEngine {
  // Session activation is handled by the app once (the transport owns
  // audio focus); these players must NOT each request focus, or the
  // incoming one blocks waiting for a grant the parked player still
  // holds — that is the play() hang that killed the first mixes.
  final AudioPlayer _a = AudioPlayer(handleAudioSessionActivation: false);
  final AudioPlayer _b = AudioPlayer(handleAudioSessionActivation: false);

  /// True while [_a] is the audible side. Swaps each transition.
  bool _aActive = true;

  Timer? _tick;
  Completer<bool>? _rampDone;
  bool _disposed = false;
  bool _crossfading = false;

  /// Baked-bridge phase: the active side plays a rendered bridge
  /// file (A-outro + B-intro already mixed) instead of a live ramp.
  /// The clock stays B-mapped throughout, so the scrubber and the
  /// notification glide into B with no jump at either join.
  bool _bridging = false;
  double _bridgeStartB = 0;
  double _bridgeEntryDelay = 0;
  double _bridgeRatio = 1;
  double _bridgeResumeB = 0;
  double _bridgeSeconds = 0;
  Duration? _bridgeDurB;

  void _cancelRamp() {
    _tick?.cancel();
    _tick = null;
    final pending = _rampDone;
    _rampDone = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  /// Audible-side events only: the handler publishes these as the
  /// playback state, so the scrubber and notification always read the
  /// player the user can actually hear.
  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  Stream<PlaybackEvent> get events => _events.stream;

  AutomixEngine() {
    _a.playbackEventStream.listen((e) {
      if (_aActive && !_disposed) _events.add(e);
    });
    _b.playbackEventStream.listen((e) {
      if (!_aActive && !_disposed) _events.add(e);
    });
  }

  AudioPlayer get _active => _aActive ? _a : _b;
  AudioPlayer get _idle => _aActive ? _b : _a;

  bool get isCrossfading => _crossfading;
  bool get bridging => _bridging;
  bool get playing => _active.playing;
  bool get completed =>
      _active.processingState == ProcessingState.completed;
  /// B track time during a bridge: the bridge file holds B
  /// tempo-corrected, so file time past the entry delay maps back
  /// through the stretch ratio. Clamped to the track.
  Duration get position {
    if (!_bridging) return _active.position;
    final bp = _active.position.inMilliseconds / 1000.0;
    final bt =
        _bridgeStartB + (bp - _bridgeEntryDelay) * _bridgeRatio;
    final dur = _bridgeDurB?.inMilliseconds ?? 0;
    final ms = (bt * 1000).round().clamp(0, dur > 0 ? dur : 1 << 62);
    return Duration(milliseconds: ms);
  }
  Duration? get duration => _bridging ? _bridgeDurB : _active.duration;

  /// Processing state and buffered position of the audible side, for
  /// the handler's single-source publish tick.
  (ProcessingState, Duration) get processingStates =>
      (_active.processingState, _active.bufferedPosition);
  bool get isPreparing =>
      _active.processingState == ProcessingState.loading ||
      _active.processingState == ProcessingState.buffering;

  /// Load [uri] on the audible player and start it. [at] resumes into
  /// a track (switching automix on mid-song). Returns false when the
  /// media can't be prepared — the caller falls back to the normal
  /// single-player path rather than going silent.
  /// Start playback without trusting `play()`'s future: on some
  /// devices the platform never completes that response even though
  /// audio starts. Poll the real state instead — bounded, honest.
  Future<bool> _startPlaying(AudioPlayer p) async {
    unawaited(p.play().catchError((Object _) {}));
    for (var i = 0; i < 40; i++) {
      if (p.playing) return true;
      if (p.processingState == ProcessingState.completed) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return p.playing;
  }

  Future<bool> start(Uri uri, {Duration at = Duration.zero}) async {
    if (_disposed) return false;
    try {
      // Preload inside setAudioSource so the 15s bound covers the
      // actual decode/load.
      await _active
          .setAudioSource(AudioSource.uri(uri))
          .timeout(const Duration(seconds: 15));
      if (_disposed) return false;
      if (at > Duration.zero) {
        await _active.seek(at).timeout(const Duration(seconds: 5));
      }
      ArchLog.i(
        'automix',
        'loaded: state=${_active.processingState} '
        'dur=${_active.duration?.inSeconds}s',
      );
      await _active.setVolume(1.0);
      final ok = await _startPlaying(_active);
      ArchLog.i(
        'automix',
        'engine start ${uri.pathSegments.last} playing=${_active.playing}',
      );
      return ok;
    } catch (e) {
      ArchLog.w('automix', 'engine start failed: $e');
      return false;
    }
  }

  /// Blend the audible track into [next]. [seconds] comes from
  /// [planCrossfade]. Every await is time-bounded: a stalled load must
  /// degrade to a clean cut, never to a wedged (silent) engine.
  Future<bool> crossfadeTo(
    Uri next, {
    required double seconds,
    Duration startAt = Duration.zero,
  }) async {
    if (_disposed || _crossfading) return false;
    _crossfading = true;
    try {
      final incoming = _idle;
      await incoming
          .setAudioSource(AudioSource.uri(next))
          .timeout(const Duration(seconds: 12));
      if (_disposed) return false;
      // Land the blend on music: intros are usually silence or
      // ambience, which reads as "faded out, then a new song started".
      if (startAt > Duration.zero) {
        try {
          await incoming.seek(startAt).timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      await incoming.setVolume(0.0);
      if (!await _startPlaying(incoming)) {
        await _cutTo(next);
        return false;
      }
      final ok = await _ramp(seconds).timeout(
        Duration(milliseconds: (seconds * 1000).round() + 4000),
      );
      if (!ok) {
        await _cutTo(next);
        return false;
      }
      try {
        await _active.pause().timeout(const Duration(seconds: 4));
        await _active.setVolume(1.0);
      } catch (_) {}
      _aActive = !_aActive;
      ArchLog.i(
        'automix',
        'crossfade ${seconds.toStringAsFixed(1)}s -> '
        '${next.pathSegments.isEmpty ? next : next.pathSegments.last}',
      );
      return true;
    } catch (e) {
      ArchLog.w('automix', 'crossfade failed, cutting: $e');
      await _cutTo(next);
      return false;
    } finally {
      _crossfading = false;
    }
  }

  /// Baked-bridge handoff: play a rendered A+B bridge on the idle
  /// side, then hand the active chair to it. The bridge opens as
  /// pure A, so pausing A at the window and starting the file is a
  /// same-waveform join — no ramp, no gap. Geometry maps the clock
  /// onto B for the whole phase; [finishBridge] lands B itself.
  /// Failure cuts straight to B: a hard cut beats silence.
  Future<bool> bridgeTo({
    required Uri bridgeUri,
    required Uri nextUri,
    required double startB,
    required double entryDelay,
    required double tempoRatio,
    required double resumeB,
    required Duration durB,
    required double bridgeSeconds,
  }) async {
    if (_disposed || _crossfading || _bridging) return false;
    _bridging = true;
    try {
      final incoming = _idle;
      await incoming
          .setAudioSource(AudioSource.uri(bridgeUri))
          .timeout(const Duration(seconds: 12));
      if (_disposed) {
        _bridging = false;
        return false;
      }
      await incoming.setVolume(1.0);
      if (!await _startPlaying(incoming)) {
        _bridging = false;
        await _cutTo(nextUri);
        return false;
      }
      // Micro-fade, not a hard pause: the fresh source needs a
      // beat to sound, and cutting A first reads as a dropout.
      // Both sides carry the same waveform here, so 150ms of
      // overlap under a fade is inaudible.
      try {
        for (var i = 1; i <= 5; i++) {
          if (_disposed || !_bridging) return false;
          await _active.setVolume(1.0 - i / 5);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await _active.pause().timeout(const Duration(seconds: 4));
        await _active.setVolume(1.0);
      } catch (_) {}
      _bridgeStartB = startB;
      _bridgeEntryDelay = entryDelay;
      _bridgeRatio = tempoRatio;
      _bridgeResumeB = resumeB;
      _bridgeSeconds = bridgeSeconds;
      _bridgeDurB = durB;
      _aActive = !_aActive;
      ArchLog.i(
        'automix',
        'bridge on resumeB=${resumeB.toStringAsFixed(1)}s',
      );
      return true;
    } catch (e) {
      ArchLog.w('automix', 'bridge failed, cutting to B: $e');
      _bridging = false;
      await _cutTo(nextUri);
      return false;
    }
  }

  /// Land B after its bridge: load B at [resumeB] on the far side,
  /// start it, take the chair. Same-waveform join at the tail —
  /// the bridge ends as pure B. Failure cuts to B from here.
  Future<bool> finishBridge(Uri nextUri) async {
    if (!_bridging || _disposed) return false;
    try {
      final landing = _idle;
      await landing
          .setAudioSource(AudioSource.uri(nextUri))
          .timeout(const Duration(seconds: 12));
      if (_disposed) return false;
      if (_bridgeResumeB > 0.05) {
        try {
          await landing
              .seek(Duration(milliseconds: (_bridgeResumeB * 1000).round()))
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      // Prime only: prepared, paused, silent. Starting now would
      // silently consume B under the tail and land mid-song; the
      // prepared player starts in milliseconds at the join.
      await landing.setVolume(0.0);
      // Join on completion (50ms poll): waveforms match at the
      // cut, so a hard swap is seamless. Aborted by any interrupt.
      final deadline = DateTime.now().add(
        Duration(seconds: _bridgeSeconds.round() + 30),
      );
      while (!_disposed && _bridging) {
        if (_active.processingState == ProcessingState.completed) break;
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!_bridging || _disposed) return false;
      if (!await _startPlaying(landing)) {
        await _cutTo(nextUri);
        return false;
      }
      await landing.setVolume(1.0);
      try {
        await _active.pause().timeout(const Duration(seconds: 4));
        await _active.setVolume(1.0);
      } catch (_) {}
      _aActive = !_aActive;
      _bridging = false;
      ArchLog.i(
        'automix',
        'bridge landed resumeB=${_bridgeResumeB.toStringAsFixed(1)}s',
      );
      return true;
    } catch (e) {
      ArchLog.w('automix', 'bridge landing failed, cutting: $e');
      await _cutTo(nextUri);
      _bridging = false;
      return false;
    }
  }

  /// Drop a bridge without landing: interrupts (skip, tap, toggle)
  /// stop the file and clear the phase; the caller starts whatever
  /// transport comes next.
  Future<void> dropBridge() async {
    if (!_bridging) return;
    _bridging = false;
    try {
      await _active.stop().timeout(const Duration(seconds: 4));
      await _active.setVolume(1.0);
    } catch (_) {}
    _aActive = true;
  }

  /// Emergency handoff: promote the incoming side at full volume and
  /// park the outgoing one. Used when a load or ramp stalls — a hard
  /// cut is always better than silence.
  Future<void> _cutTo(Uri next) async {
    // A fallback cut ends any bridge phase first: the mapped clock
    // must never outlive the file it describes.
    _bridging = false;
    _bridgeDurB = null;
    final incoming = _idle;
    try {
      if (incoming.processingState == ProcessingState.idle) {
        await incoming
            .setAudioSource(AudioSource.uri(next))
            .timeout(const Duration(seconds: 12));
      }
      await incoming.setVolume(1.0);
      await _startPlaying(incoming);
      try {
        await _active.pause().timeout(const Duration(seconds: 4));
        await _active.setVolume(1.0);
      } catch (_) {}
      _aActive = !_aActive;
      ArchLog.i('automix', 'cut (fallback)');
    } catch (e) {
      ArchLog.w('automix', 'cut failed: $e');
    }
  }

  /// Equal-power ramp over [seconds]. False when cancelled.
  Future<bool> _ramp(double seconds) {
    final total = math.max(seconds, crossfadeMin);
    final steps = math.max(1, (total / 0.03).round());
    final stepMs = (total * 1000 / steps).round();
    final done = Completer<bool>();
    _rampDone = done;
    var i = 0;
    final outgoing = _active;
    final incoming = _idle;
    _tick?.cancel();
    _tick = Timer.periodic(Duration(milliseconds: stepMs), (timer) async {
      if (_disposed) {
        timer.cancel();
        if (!done.isCompleted) done.complete(false);
        return;
      }
      i++;
      final t = (i / steps).clamp(0.0, 1.0);
      final g = crossfadeGains(t);
      try {
        await outgoing.setVolume(g.out);
        await incoming.setVolume(g.in_);
      } catch (_) {}
      if (t >= 1.0) {
        timer.cancel();
        if (!done.isCompleted) done.complete(true);
      }
    });
    return done.future;
  }

  /// Volume for pause/play fades. Handler-owned ramps call this; the
  /// engine itself always ends blends at full gain, so a fresh start
  /// never inherits a faded level.
  Future<void> setVolume(double v) async {
    if (_disposed) return;
    try {
      await _active.setVolume(v);
    } catch (_) {}
  }

  Future<void> pause() async {
    try {
      await _active.pause();
    } catch (_) {}
  }

  /// Resume at an explicit gain (instead of forcing full volume): the
  /// handler fades back in itself, so a resume never punches in loud.
  /// Muting the idle side first preserves the old dual-tail behavior —
  /// a crossfade interrupted mid-blend must not come back doubled.
  Future<void> resumeAt(double volume) async {
    if (_disposed) return;
    try {
      await _idle.setVolume(0.0);
      await _active.setVolume(volume.clamp(0.0, 1.0));
      await _startPlaying(_active);
    } catch (_) {}
  }

  Future<void> seek(Duration to) async {
    try {
      await _active.seek(to);
    } catch (_) {}
  }

  /// Hard stop for shutdown or automix-off: cancels any ramp, stops
  /// both sides, resets gains so a later start is clean.
  Future<void> stop() async {
    _cancelRamp();
    _bridging = false;
    _bridgeDurB = null;
    for (final p in [_a, _b]) {
      try {
        await p.stop();
        await p.setVolume(1.0);
      } catch (_) {}
    }
    _aActive = true;
    _crossfading = false;
  }

  Future<void> dispose() async {
    _disposed = true;
    _cancelRamp();
    await _events.close();
    try {
      await _a.dispose();
    } catch (_) {}
    try {
      await _b.dispose();
    } catch (_) {}
  }
}
