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
import 'baked_blend.dart' show PlannedBlend;
import 'crossfade.dart';
import 'live_blend.dart';

class AutomixEngine {
  // Session activation is handled by the app once (the transport owns
  // audio focus); these players must NOT each request focus, or the
  // incoming one blocks waiting for a grant the parked player still
  // holds — that is the play() hang that killed the first mixes.
  // Per-player EQ for the bass swap: the outgoing lane cuts its lows
  // while the incoming lane runs full-range. Stock just_audio OS
  // effects — no fork, no native dep.
  final AndroidEqualizer _eqA = AndroidEqualizer();
  final AndroidEqualizer _eqB = AndroidEqualizer();
  late final AudioPlayer _a = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [_eqA]),
    handleAudioSessionActivation: false,
  );
  late final AudioPlayer _b = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [_eqB]),
    handleAudioSessionActivation: false,
  );

  /// True while [_a] is the audible side. Swaps each transition.
  bool _aActive = true;

  Timer? _tick;
  Completer<bool>? _rampDone;
  bool _disposed = false;
  bool _crossfading = false;

  /// Live-blend phase: both players audible, gains automated from the
  /// recipe. Bumped on stop/teardown so a stale wait/ramp can never
  /// land late on the new transport.
  bool _live = false;
  int _liveGen = 0;
  // Last automated B gain, so a mid-blend pause/resume restores the
  // mix instead of punching the incoming lane in loud.
  double _lastLiveB = 0.0;

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
  AndroidEqualizer get _activeEq => _aActive ? _eqA : _eqB;

  bool get isCrossfading => _crossfading;
  bool get liveBlending => _live;
  bool get playing => _active.playing || (_live && _idle.playing);
  bool get completed =>
      _active.processingState == ProcessingState.completed;
  Duration get position => _active.position;
  Duration? get duration => _active.duration;

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
    for (var i = 0; i < 80; i++) {
      if (p.playing) return true;
      if (p.processingState == ProcessingState.completed) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return p.playing;
  }

  /// Bass swap on one lane: cut everything under ~200Hz (the baked
  /// highpass=f=160 by ear on device bands) while the lanes overlap,
  /// restore after. Best effort and bounded — a stuck EQ call must
  /// never wedge a blend.
  Future<void> _bassCut(
    AudioPlayer p,
    AndroidEqualizer eq,
    bool cut,
  ) async {
    try {
      final params =
          await eq.parameters.timeout(const Duration(seconds: 4));
      if (cut) {
        for (final band in params.bands) {
          if (band.centerFrequency < 200) {
            await band.setGain(params.minDecibels);
          }
        }
        await eq.setEnabled(true);
      } else {
        await eq.setEnabled(false);
        for (final band in params.bands) {
          if (band.gain != 0.0) await band.setGain(0.0);
        }
      }
    } catch (_) {}
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
    if (_disposed || _crossfading || _live) return false;
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
      // A previous live blend may have left this side tempo-shifted;
      // crossfades always run at natural speed.
      try {
        await incoming.setSpeed(1.0);
      } catch (_) {}
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

  /// Live two-player blend: the outgoing lane keeps playing while the
  /// incoming lane preloads at [planned] entry (tempo-matched, bass
  /// cut on the outgoing side), then both lanes run the recipe gains
  /// with sum limiting. One overlap, one join — no bridge file, no
  /// tail landing. Failures cut straight to B: a hard cut beats
  /// silence. Returns false when superseded (skip/toggle/teardown).
  Future<bool> liveBlendTo({
    required Uri nextUri,
    required PlannedBlend planned,
  }) async {
    if (_disposed || _crossfading || _live) return false;
    _live = true;
    _lastLiveB = 0.0;
    final gen = _liveGen;
    final plan = planned.plan;
    bool live() => _live && gen == _liveGen && !_disposed;
    try {
      final outgoing = _active;
      final outgoingEq = _activeEq;
      final incoming = _idle;
      await incoming
          .setAudioSource(AudioSource.uri(nextUri))
          .timeout(const Duration(seconds: 12));
      if (!live()) return false;
      if (plan.startB > 0.05) {
        try {
          await incoming
              .seek(Duration(milliseconds: (plan.startB * 1000).round()))
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      if ((plan.tempoRatio - 1.0).abs() > 0.0005) {
        try {
          await incoming.setSpeed(plan.tempoRatio);
        } catch (_) {}
      }
      await incoming.setVolume(0.0);
      // Bass swap for the overlap only.
      await _bassCut(outgoing, outgoingEq, true);
      // Precise fire: the tick that armed this ran up to 400ms early,
      // and entryDelay sits inside one beat. Wait on the live clock.
      final fireAt = planned.windowStartA + plan.entryDelay;
      while (live()) {
        double pos;
        try {
          pos = outgoing.position.inMilliseconds / 1000.0;
        } catch (_) {
          break;
        }
        if (pos >= fireAt) break;
        if (outgoing.processingState == ProcessingState.completed) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!live()) {
        await _bassCut(outgoing, outgoingEq, false);
        return false;
      }
      if (!await _startPlaying(incoming)) {
        _live = false;
        await _bassCut(outgoing, outgoingEq, false);
        await _cutTo(nextUri);
        return false;
      }
      // Overlapped recipe: 25ms ticks, both writes batched (sequential
      // platform round-trips zipper on raspy vocals — spike-proven).
      // Reduction rides a smoothed knee (instant attack, slow
      // release) so the limiter glues peaks without pumping A down.
      final t0 = DateTime.now();
      var knee = 1.0;
      while (live()) {
        final t =
            DateTime.now().difference(t0).inMilliseconds / 1000.0;
        if (t >= plan.seconds) break;
        final raw = liveGains(plan, t);
        knee = smoothKnee(knee, limitTarget(raw));
        final g = applyKnee(raw, knee);
        _lastLiveB = g.b;
        await Future.wait([
          outgoing.setVolume(g.a),
          incoming.setVolume(g.b),
        ]);
        if (outgoing.processingState == ProcessingState.completed &&
            t > plan.seconds - 1.0) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      if (!live()) {
        await _bassCut(outgoing, outgoingEq, false);
        return false;
      }
      await incoming.setVolume(1.0);
      try {
        await outgoing.pause().timeout(const Duration(seconds: 4));
        await outgoing.setVolume(1.0);
        await outgoing.setSpeed(1.0);
      } catch (_) {}
      await _bassCut(outgoing, outgoingEq, false);
      _aActive = !_aActive;
      // Ease the tempo home: B entered matched to A, unwind to 1.0x.
      final r0 = plan.tempoRatio;
      if ((r0 - 1.0).abs() > 0.0005) {
        for (var i = 1; i <= 8; i++) {
          if (!live()) break;
          try {
            await _active.setSpeed(1.0 + (r0 - 1.0) * (1 - i / 8));
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        try {
          await _active.setSpeed(1.0);
        } catch (_) {}
      }
      ArchLog.i(
        'automix',
        'live blend on ${plan.seconds.toStringAsFixed(1)}s '
        'ratio=${plan.tempoRatio.toStringAsFixed(4)} '
        'ducks=${plan.ducks.length}',
      );
      return true;
    } catch (e) {
      ArchLog.w('automix', 'live blend failed, cutting to B: $e');
      _live = false;
      await _cutTo(nextUri);
      return false;
    } finally {
      _live = false;
    }
  }

  /// Emergency handoff: promote the incoming side at full volume and
  /// park the outgoing one. Used when a load or ramp stalls — a hard
  /// cut is always better than silence.
  Future<void> _cutTo(Uri next) async {
    _live = false;
    _liveGen++;
    final incoming = _idle;
    try {
      if (incoming.processingState == ProcessingState.idle) {
        await incoming
            .setAudioSource(AudioSource.uri(next))
            .timeout(const Duration(seconds: 12));
      }
      try {
        await incoming.setSpeed(1.0);
        await _bassCut(incoming, _aActive ? _eqB : _eqA, false);
      } catch (_) {}
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
      // Mid-blend the idle lane is audible too: park it or the mix
      // keeps sounding under the pause.
      if (_live) {
        try {
          await _idle.pause();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Resume at an explicit gain (instead of forcing full volume): the
  /// handler fades back in itself, so a resume never punches in loud.
  /// Muting the idle side first preserves the old dual-tail behavior —
  /// a crossfade interrupted mid-blend must not come back doubled.
  Future<void> resumeAt(double volume) async {
    if (_disposed) return;
    try {
      if (_live) {
        // Both lanes back at their last automated gains: resuming at
        // full on one side would punch it in loud over the other.
        await _idle.setVolume(_lastLiveB.clamp(0.0, 1.0));
        await _active.setVolume(volume.clamp(0.0, 1.0));
        await _startPlaying(_active);
        await _startPlaying(_idle);
        return;
      }
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
    _live = false;
    _liveGen++;
    for (final p in [_a, _b]) {
      try {
        await p.stop();
        await p.setVolume(1.0);
        await p.setSpeed(1.0);
      } catch (_) {}
    }
    for (final eq in [_eqA, _eqB]) {
      try {
        await eq.setEnabled(false);
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
