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
  final AudioPlayer _a = AudioPlayer();
  final AudioPlayer _b = AudioPlayer();

  /// True while [_a] is the audible side. Swaps each transition.
  bool _aActive = true;

  Timer? _tick;
  bool _disposed = false;
  bool _crossfading = false;

  AudioPlayer get _active => _aActive ? _a : _b;
  AudioPlayer get _idle => _aActive ? _b : _a;

  bool get isCrossfading => _crossfading;
  bool get playing => _active.playing;
  Duration get position => _active.position;
  Duration? get duration => _active.duration;

  /// Stream of the audible side's playback events, for the handler's
  /// notification + UI state.
  Stream<PlaybackEvent> get playbackEventStream => _a.playbackEventStream
      .merge(_b.playbackEventStream)
      .where((_) => !_disposed);

  /// Load [uri] on the audible player and start it. [at] resumes into
  /// a track (switching automix on mid-song). Returns false when the
  /// media can't be prepared — the caller falls back to the normal
  /// single-player path rather than going silent.
  Future<bool> start(Uri uri, {Duration at = Duration.zero}) async {
    if (_disposed) return false;
    try {
      await _active.setAudioSource(AudioSource.uri(uri), preload: false);
      if (_disposed) return false;
      if (at > Duration.zero) await _active.seek(at);
      await _active.setVolume(1.0);
      await _active.play();
      ArchLog.i('automix', 'engine start ${uri.pathSegments.last}');
      return true;
    } catch (e) {
      ArchLog.w('automix', 'engine start failed: $e');
      return false;
    }
  }

  /// Blend the audible track into [next]. [seconds] comes from
  /// [planCrossfade]; [at] seeks the incoming track past its head
  /// (phrase offsets land here later). Returns the new audible side.
  Future<bool> crossfadeTo(Uri next, {required double seconds}) async {
    if (_disposed || _crossfading) return false;
    _crossfading = true;
    final incoming = _idle;
    try {
      await incoming.setAudioSource(AudioSource.uri(next), preload: false);
      if (_disposed) return false;
      await incoming.seek(Duration.zero);
      await incoming.setVolume(0.0);
      await incoming.play();
      final ok = await _ramp(seconds);
      if (!ok) return false;
      // Handoff: the outgoing side is parked (not stopped — stopping
      // releases the decoder and would stall the next preload).
      try {
        await _active.pause();
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
      ArchLog.w('automix', 'crossfade failed: ${e.toString()}');
      // Put the outgoing side back to full so the user still hears
      // something instead of two half-faded players.
      try {
        await _active.setVolume(1.0);
      } catch (_) {}
      return false;
    } finally {
      _crossfading = false;
    }
  }

  /// Equal-power ramp over [seconds]. False when cancelled.
  Future<bool> _ramp(double seconds) {
    final total = math.max(seconds, crossfadeMin);
    final steps = math.max(1, (total / 0.03).round());
    final stepMs = (total * 1000 / steps).round();
    final done = Completer<bool>();
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
      await _active.play();
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
    _tick?.cancel();
    _tick = null;
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
    _tick?.cancel();
    _tick = null;
    try {
      await _a.dispose();
    } catch (_) {}
    try {
      await _b.dispose();
    } catch (_) {}
  }
}

extension _MergeStreams<T> on Stream<T> {
  /// Interleave two streams. Used for the audible-side event feed;
  /// the handler filters by index/position anyway.
  Stream<T> merge(Stream<T> other) {
    late StreamController<T> controller;
    final subs = <StreamSubscription<T>>[];
    controller = StreamController<T>(
      onListen: () {
        subs.add(listen(controller.add, onError: controller.addError));
        subs.add(other.listen(controller.add, onError: controller.addError));
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return controller.stream;
  }
}
