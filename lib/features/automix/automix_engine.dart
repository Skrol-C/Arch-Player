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
  bool get playing => _active.playing;
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

  /// Emergency handoff: promote the incoming side at full volume and
  /// park the outgoing one. Used when a load or ramp stalls — a hard
  /// cut is always better than silence.
  Future<void> _cutTo(Uri next) async {
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

  Future<void> pause() async {
    try {
      await _active.pause();
    } catch (_) {}
  }

  Future<void> resume() async {
    if (_disposed) return;
    try {
      // Both sides may hold a tail from an interrupted blend; the
      // audible one is the only voice that should rise.
      await _idle.setVolume(0.0);
      await _active.setVolume(1.0);
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
