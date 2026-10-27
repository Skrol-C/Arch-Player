import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/art_scale.dart';
import '../../core/log.dart';
import '../../core/models.dart';
import '../automix/automix_engine.dart';
import '../automix/harmonic_order.dart' as ho;
import '../automix/baked_blend.dart';
import '../automix/crossfade.dart';
import '../library/data/art_previews.dart';
import '../library/data/library_repository.dart';
import '../metadata/metadata_service.dart';

/// Shuffle order that never repeats itself: every roll is guaranteed
/// different from the previous one (the 1-in-n! collision re-rolls,
/// with a forced swap of two non-pinned slots as the paranoid
/// fallback). [initialIndex] passes straight through so the current
/// track stays pinned — reshuffle never yanks the song under you.
/// Insert/remove/clear stay stock; only the roll is guarded.
class _FreshShuffleOrder extends DefaultShuffleOrder {
  List<int>? _last;

  _FreshShuffleOrder() : super(random: Random());

  @override
  void shuffle({int? initialIndex}) {
    super.shuffle(initialIndex: initialIndex);
    if (_last != null && indices.length > 1 && _same(indices, _last!)) {
      super.shuffle(initialIndex: initialIndex);
    }
    if (_last != null && indices.length > 1 && _same(indices, _last!)) {
      final a = initialIndex == null ? 0 : 1;
      final b = a + 1;
      if (b < indices.length) {
        final t = indices[a];
        indices[a] = indices[b];
        indices[b] = t;
      }
    }
    _last = List.of(indices);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Album art for lock-screen/notification, cached on disk. The native side
/// loads `artCacheFile` preferentially; content URIs resolve via its own
/// ContentResolver path. Failures degrade to no art, never a crash.
class NotifArt {
  static Future<String?> cacheCover(String url) async {
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return await cacheBytes(res.bodyBytes, '${url.hashCode}');
    } catch (e) {
      ArchLog.w('player', 'notif art failed: $e');
      return null;
    }
  }

  /// Raw bytes (embedded art via ArtCache) to a stable notification file.
  /// Capped first: the notification is a system surface and gets the
  /// same bounded image as the app, never a 24 MB scan to decode.
  static Future<String?> cacheBytes(Uint8List bytes, String name) async {
    try {
      if (bytes.isEmpty) return null;
      final sized = await shrinkArt(bytes);
      final dir = await getApplicationCacheDirectory();
      final art = Directory('${dir.path}/notif_art');
      if (!await art.exists()) await art.create(recursive: true);
      final file = File('${art.path}/$name.jpg');
      await file.writeAsBytes(sized, flush: true);
      return file.path;
    } catch (e) {
      ArchLog.w('player', 'notif art bytes failed: $e');
      return null;
    }
  }
}

/// Own heartbeat: background playback. UI may crash; this keeps playing.
/// A rendered bridge waiting for its window. The file already holds
/// the overlap (A-outro + B-intro mixed); the joins are same-waveform
/// cuts and the clock stays B-mapped throughout. Null = nothing
/// ready: run the live fade, never wait.
class _BridgeJob {
  final int from;
  final int next;
  final String file;
  final double startB;
  final double entryDelay;
  final double tempoRatio;
  final double resumeB;
  final double seconds;
  final Duration durB;
  // A track time to fire at: the file starts here, not at
  // (end - length). Firing late replays the tail.
  final double windowStartA;
  const _BridgeJob({
    required this.from,
    required this.next,
    required this.file,
    required this.startB,
    required this.entryDelay,
    required this.tempoRatio,
    required this.resumeB,
    required this.seconds,
    required this.durB,
    required this.windowStartA,
  });
}

class ArchAudioHandler extends BaseAudioHandler {
  final AudioPlayer _player =
      AudioPlayer(shuffleOrder: _FreshShuffleOrder());
  List<Song> _songs = [];
  bool _busy = false;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  int _playGen = 0;
  int _skipGen = 0;

  /// Audible gain, tracked here because neither transport reports it.
  /// Invariant: equals the audible player's gain whenever nothing is
  /// fading. Every gain change funnels through [_setVolume] so a
  /// superseded fade can never leave the app quieter — or louder —
  /// than intended.
  double _vol = 1.0;
  int _fadeGen = 0;

  /// Fade shapes, tuned by ear: pause-out slow enough to feel
  /// intentional, play-in quick enough to feel responsive, tap
  /// crossfades in between.
  static const _pauseFade = Duration(seconds: 2);
  static const _playFade = Duration(seconds: 1);
  static const _tapFadeOut = Duration(milliseconds: 300);
  static const _tapFadeIn = Duration(milliseconds: 600);

  /// Single gain choke point: handler-owned ramps and snaps.
  /// Snaps cancel in-flight ramps (last writer wins): without this
  /// a stale fade-out keeps writing the gain after a newer fade-in
  /// started, and the app sits silent with the seekbar moving.
  Future<void> _setVolume(double v) async {
    _fadeGen++;
    await _applyVolume(v);
  }

  /// Raw gain write: ramps use this so they do not cancel
  /// themselves. Only [_setVolume] and [_rampTo] call it.
  Future<void> _applyVolume(double v) async {
    _vol = v.clamp(0.0, 1.0);
    final engine = _engine;
    try {
      if (engine != null) {
        await engine.setVolume(_vol);
      } else {
        await _player.setVolume(_vol);
      }
    } catch (_) {}
  }

  /// Volume ramp on the audible transport. Superseded calls abort;
  /// the newest fade always wins.
  Future<void> _rampTo(double target, Duration over) async {
    final gen = ++_fadeGen;
    final start = _vol;
    const steps = 12;
    final step = Duration(milliseconds: (over.inMilliseconds / steps).round());
    for (var i = 1; i <= steps; i++) {
      if (gen != _fadeGen) return;
      await _applyVolume(start + (target - start) * (i / steps));
      if (i < steps) await Future<void>.delayed(step);
    }
  }

  Future<void> _fadeOut([Duration? over]) =>
      _rampTo(0.0, over ?? _pauseFade);

  Future<void> _fadeIn([Duration? over]) async {
    if (_vol >= 0.99) {
      await _setVolume(1.0);
      return;
    }
    await _rampTo(1.0, over ?? _playFade);
  }

  /// Automix: when on, the dual-player engine owns transport so the
  /// next track can fade in under the current one. The single-player
  /// playlist stays the queue authority — parked, never closed — so
  /// leaving automix resumes exactly where the engine was.
  MetadataService? _meta;
  AutomixEngine? _engine;
  bool _automixOn = false;
  Timer? _mixTick;
  int _mixIndex = 0;
  bool _mixFiring = false;
  StreamSubscription<PlaybackEvent>? _mixEvents;

  /// Bumped on every engine enter/teardown. A start that finishes after
  /// the user toggled off must not arm a zombie engine.
  int _mixGen = 0;

  /// Harmonic ordering: batches of compatible next tracks, refilled
  /// from the current position (batch of 5 with shuffle, single best
  /// without). Cleared on any queue mutation, tap, or shuffle flip.
  List<int> _harmonicBatch = [];
  /// Recent-play exclusion window for the harmonic pick: songs heard
  /// in the last [_recentWindow] tracks can never be re-picked (hard
  /// exclusion at pick time — two mutual nearest neighbors can't
  /// ping-pong). When the analyzed pool runs dry the batch comes back
  /// short/empty and the neighbor falls back to queue order.
  static const int _recentWindow = 10;
  final List<int> _harmonicRecentIds = [];

  /// Play history for prev/next semantics: song ids in the order they
  /// became audible. Skip-next (and harmonic auto-advance) pushes the
  /// outgoing id and clears the redo stack; prev pops history and
  /// parks the outgoing id on the redo stack; next-after-prev re-pops
  /// redo. Ids resolve against the live queue — a miss (queue rebuilt
  /// under us) falls through to the legacy queue-slot neighbor — and
  /// the stacks are capped so a day-long session can't grow them.
  final List<int> _playHistory = [];
  final List<int> _playFuture = [];
  static const int _historyCap = 200;

  /// Rendered bridge waiting for its window (null = run it live).
  /// Dropped on any invalidation: queue surgery, teardown, supersede.
  _BridgeJob? _bridge;
  /// Pair key the waiting job was rendered for (aId>bId).
  String _bridgePair = '';
  /// Pair key already pre-buffered on the engine's idle side.
  /// Cleared with the job; the engine invalidates its own copy on
  /// any transport change.
  String _primePair = '';
  /// One render at a time: ticks retry while this is set.
  bool _rendering = false;
  /// Pair key that already logged its skip reason: the kick runs
  /// every tick, but the log names each gap once, not 150 times.
  String _renderSkipPair = '';
  /// Refused pairs (aId>bId): failed post-decode (geometry/ratio/
  /// clash) or crashed. Never re-rendered — ticks would burn a full
  /// decode + scan set every 400ms — and never re-picked by the
  /// harmonic walk, so ordering stops offering pairs the renderer
  /// refuses. Cleared on transport change. Pre-decode skips (no
  /// tempo, no path) keep retrying: background analysis can heal
  /// them mid-track.
  final Set<String> _deadPairs = {};

  void _renderSkip(String pair, String reason) {
    if (pair == _renderSkipPair) return;
    _renderSkipPair = pair;
    ArchLog.i('automix', 'bridge skip $pair ($reason)');
  }
  /// One landing flight at a time.
  bool _landing = false;

  /// True while the waiting job still names the live queue.
  /// Appends (autoplay) keep it; moves/removes/rebuilds drop it.
  bool _bridgeValid() {
    final job = _bridge;
    if (job == null || _bridgePair.isEmpty) return false;
    if (job.from < 0 || job.next < 0) return false;
    if (job.from >= _songs.length || job.next >= _songs.length) {
      return false;
    }
    return _bridgePair ==
        '${_songs[job.from].id}>${_songs[job.next].id}';
  }

  /// Delete the waiting file and forget the job. The file is
  /// transient render output: never user data, never referenced
  /// once the window passes.
  void _dropBridgeFile() {
    final f = _bridge?.file;
    _bridge = null;
    _bridgePair = '';
    _primePair = '';
    if (f != null && f.isNotEmpty) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
  }

  /// Autoplay: when the queue runs out, the UI is asked for more music
  /// instead of stopping. Keyed so one exhaustion notifies once.
  bool _autoplayOn = false;
  final StreamController<void> _needMoreController =
      StreamController<void>.broadcast();
  Stream<void> get needMoreMusic => _needMoreController.stream;
  String _needMoreKey = '';

  /// Cache-only musical info (no analysis, no I/O beyond the loaded
  /// cache): the automix planning path and UI badges read here so a
  /// list build can never kick off a decode storm. Null = unknown.
  TrackMusicalInfo? musicalCached({
    required String title,
    required String artist,
    String path = '',
  }) => _meta?.musicalInfoCached(title: title, artist: artist, path: path);

  /// Queue contents for autoplay fills (ids + tail), in play order.
  List<int> get queueSongIds => [for (final s in _songs) s.id];
  Song? get queueTail => _songs.isEmpty ? null : _songs.last;

  /// Read by the autoplay fill: random when automix is off,
  /// harmonic only when it is on.
  bool get automixOn => _automixOn;

  Future<void> setAutoplayEnabled(bool on) async {
    _autoplayOn = on;
    ArchLog.i('player', 'autoplay=$on');
  }

  /// Fires when the engine can't take over (load failure). The toggle
  /// provider listens and flips itself off, so the UI never claims
  /// automix is on while the playlist is actually driving.
  final StreamController<void> _automixFailures =
      StreamController<void>.broadcast();
  Stream<void> get automixFailures => _automixFailures.stream;

  ArchAudioHandler({MetadataService? metadata}) {
    _meta = metadata;
    _player.playbackEventStream.listen((event) {
      // Never `.pipe()` here. An addStream holds the controller
      // against every other add, so each shuffle/loop _republish()
      // threw "You cannot add items while items are being added from
      // addStream" and that notification control silently missed its
      // update (twelve of those per cold start, before any tap).
      // A plain listen keeps every emission its own add.
      if (playbackState.isClosed) return;
      // While the engine owns transport its own events are the truth;
      // the parked playlist player must not overwrite them.
      if (_engine != null) return;
      playbackState.add(_toPlaybackState(event));
    });
    // Notification icons mirror engine state (shuffle/repeat), not
    // just playback events: re-publish on those flips.
    _player.shuffleModeEnabledStream.listen((_) => _republish());
    _player.loopModeStream.listen((_) => _republish());
    // The notification only rebuilds on control flips and metadata sets —
    // never on index change alone. So every index change re-sets the
    // media item explicitly: taps, auto-advance, next/prev, lock intents.
    // Routed through _setItem so the known art file rides along and
    // the extra never flaps off and back (that flap is the flicker).
    _player.currentIndexStream.listen((index) {
      if (index == null) return;
      // While the engine owns transport, its track is the truth. The
      // parked playlist player still emits index events (stop/seek)
      // and used to stomp the media item — that was the stale art.
      if (_engine != null) return;
      final items = queue.value;
      if (index < 0 || index >= items.length) return;
      _setItem(items[index]);
      ArchLog.i('player', 'index -> ${items[index].title}');
      // Auto-advance lands artless (see above): attach behind, guarded.
      if (index < _songs.length) {
        final s = _songs[index];
        if (items[index].id == s.uri.toString()) {
          unawaited(_attachArtFile(s));
        }
      }
    });
    // Autoplay without automix: the playlist player runs out of queue
    // at the last track. Engine mode never reaches here (guarded) and
    // previews never match (empty queue).
    _player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) return;
      if (_engine != null || !_autoplayOn || _songs.isEmpty) return;
      if (_player.loopMode != LoopMode.off) return;
      final idx = _player.currentIndex;
      if (idx == null || idx < _songs.length - 1) return;
      _requestMoreMusic();
    });
    unawaited(_configureSession());
  }

  /// Autoplay request, keyed so one queue exhaustion notifies once.
  /// Re-arm happens naturally: new songs change the key.
  void _requestMoreMusic() {
    final n = _songs.length;
    final key = '$n:$_mixIndex:${_player.currentIndex}';
    if (key == _needMoreKey) return;
    _needMoreKey = key;
    ArchLog.i(
      'automix',
      'autoplay exhausted n=${_songs.length} — requesting more',
    );
    if (!_needMoreController.isClosed) {
      _needMoreController.add(null);
    }
  }

  /// Re-publish the current state (notification icon refresh). Reads
  /// the live event so nothing else has to be threaded through.
  /// Overrides paint the intended state immediately while the engine
  /// catches up — the toggle answers on tap, not after a reshuffle.
  void _republish({bool? shuffle, LoopMode? loop}) {
    try {
      if (playbackState.isClosed) return;
      playbackState.add(
        _toPlaybackState(
          _player.playbackEvent,
          shuffleOverride: shuffle,
          loopOverride: loop,
        ),
      );
    } catch (e) {
      ArchLog.w('player', 'republish failed: $e');
    }
  }

  /// Last-known art file per media id: every mediaItem assignment
  /// routes through [_setItem] so a known file rides along and the
  /// extra never flaps off and back (that flap is the art flicker).
  final Map<String, String> _artFiles = {};
  static const _artCap = 64;

  /// Last song id whose notification art was attached. Index flips
  /// re-fire per flip (fall-through, seeks) — without this the same
  /// song re-resolves + re-sets art on every flip (low-RAM killer).
  int _lastNotifArtSongId = -1;

  /// Song ids that already logged an art miss: misses repeat on
  /// every index flip, and the log must name the gap once, not
  /// spam it.
  final Set<int> _artMissIds = {};

  void _logArtMiss(Song song) {
    if (!_artMissIds.add(song.id)) return;
    while (_artMissIds.length > 128) {
      _artMissIds.remove(_artMissIds.first);
    }
    ArchLog.w('player', 'notif art miss id=${song.id} '
        'album=${song.albumId} pathEmpty=${song.path.isEmpty}');
  }

  void _rememberArt(String id, String path) {
    if (id.isEmpty || path.isEmpty) return;
    _artFiles[id] = path;
    while (_artFiles.length > _artCap) {
      _artFiles.remove(_artFiles.keys.first);
    }
  }

  /// Same frame re-emitted (index storms, art re-resolves) must
  /// not churn the notification: audio_service reposts on every
  /// assignment, so a no-change write reads as flicker or a new
  /// notification on button presses.
  bool _sameItem(MediaItem a, MediaItem b) {
    final ea = a.extras ?? const <String, dynamic>{};
    final eb = b.extras ?? const <String, dynamic>{};
    return a.id == b.id &&
        a.title == b.title &&
        a.artist == b.artist &&
        a.album == b.album &&
        a.duration == b.duration &&
        '${ea['songId']}' == '${eb['songId']}' &&
        '${ea['albumId']}' == '${eb['albumId']}' &&
        '${ea['artCacheFile']}' == '${eb['artCacheFile']}' &&
        '${ea['coverUrl']}' == '${eb['coverUrl']}';
  }

  void _setItem(MediaItem item) {
    final cur = mediaItem.value;
    if (cur != null && _sameItem(cur, item)) return;
    var extras = item.extras;
    final has = (extras?['artCacheFile'] as String?) ?? '';
    if (has.isNotEmpty) {
      _rememberArt(item.id, has);
    } else {
      final known = _artFiles[item.id];
      if (known != null && known.isNotEmpty) {
        item = item.copyWith(extras: {...?extras, 'artCacheFile': known});
      }
    }
    mediaItem.value = item;
  }

  /// Explicit audio session (their wheel, our policy): media usage,
  /// full gain (calls and nav still interrupt — never music-over-calls),
  /// and OS ducking for transient pings (notification sounds dip the
  /// volume instead of stopping the music). Full pause only for real
  /// takeovers. Auto-resume is foreground-gated: never surprise-resume
  /// while the user is inside another app.
  /// Every event logs — focus issues are diagnosable forever after this.
  bool _pausedForInterruption = false;

  Future<void> _configureSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          // False = the OS dips our volume itself on duckable
          // transients (notification pings). True used to park the
          // whole track for every ping — that was the full pause.
          androidWillPauseWhenDucked: false,
        ),
      );
      session.interruptionEventStream.listen((e) async {
        ArchLog.i('player', 'interruption begin=${e.begin} type=${e.type}');
        try {
          if (!e.begin) {
            if (_pausedForInterruption) {
              _pausedForInterruption = false;
              // Resume only if we're the foreground app. An app like
              // TikTok abandons focus every time it pauses a video —
              // resuming unconditionally is what kept pulling music
              // back while the user was still inside it.
              final foregrounded =
                  WidgetsBinding.instance.lifecycleState ==
                  AppLifecycleState.resumed;
              if (foregrounded && !_player.playing) {
                await _player.play();
                ArchLog.i('player', 'resumed after interruption');
              } else if (!foregrounded) {
                ArchLog.i(
                  'player',
                  'interruption ended in background - staying paused',
                );
              }
            }
            return;
          }
          // Duckable transient (notification ping, nav prompt): the OS
          // handles the dip — keep playing, touch nothing.
          if (e.type == AudioInterruptionType.duck) {
            ArchLog.i('player', 'ducking under transient');
            return;
          }
          if (_player.playing) {
            _pausedForInterruption = true;
            await _player.pause();
          }
        } catch (err) {
          ArchLog.w('player', 'interruption handling failed: $err');
        }
      });
      session.becomingNoisyEventStream.listen((_) async {
        ArchLog.i('player', 'becoming noisy (output lost)');
        try {
          if (_player.playing) await _player.pause();
        } catch (err) {
          ArchLog.w('player', 'noisy-pause failed: $err');
        }
      });
      ArchLog.i('player', 'audio session configured (gain, pause-on-duck)');
    } catch (e) {
      ArchLog.w('player', 'audio session config failed: $e');
    }
  }

  /// Queue as a stream for the queue sheet. Every mutation flows through
  /// [_emitQueue] so the audio_service value and the UI stream stay one
  /// truth - never drift.
  /// Engine truth for notification-initiated flips: the providers
  /// converge off these same streams the notification icons read.
  Stream<bool> get shuffleModeEnabledStream => _player.shuffleModeEnabledStream;
  Stream<LoopMode> get loopModeStream => _player.loopModeStream;

  void _emitQueue(List<MediaItem> items) {
    queue.value = items;
    // Queue mutations invalidate harmonic positions (index-based).
    // The next tick refills from the new truth; display follows.
    _harmonicBatch.clear();
    // A waiting bridge names queue positions: drops itself when
    // they no longer name its pair (appends keep a valid one).
    if (!_bridgeValid()) _dropBridgeFile();
    _republishOrder();
  }

  /// Recompute the harmonic batch when it's missing or stale. Called
  /// from tick-safe places (never inside a pure read); republish keeps
  /// Up Next truthful without per-tick stream churn.
  void _ensureHarmonicBatch() {
    if (!_automixOn || _engine == null || _songs.length < 2) return;
    if (_harmonicBatch.isNotEmpty) return;
    final k = _player.shuffleModeEnabled ? 5 : 1;
    // One lookup per song per refill: scoring touches every pair,
    // and every lookup does sync file tag I/O without this.
    final memo = <int, TrackMusicalInfo?>{};
    TrackMusicalInfo? infoOf(Song s) => memo.putIfAbsent(
      s.id,
      () => _meta?.musicalInfoCached(
        title: s.title,
        artist: s.artist,
        path: s.path,
      ),
    );
    final fromId = (_mixIndex >= 0 && _mixIndex < _songs.length)
        ? _songs[_mixIndex].id
        : -1;
    // Refused nexts are banned for this position: ordering stops
    // offering pairs the renderer already rejected (vocal clash,
    // geometry, ratio). Data-driven refusals only — heals (tempo
    // arriving late) were never dead, so they still retry.
    final deadNext = <int>{
      for (final p in _deadPairs)
        if (p.startsWith('$fromId>'))
          int.tryParse(p.split('>').last) ?? -1,
    }..remove(-1);
    final picked = ho.pickHarmonicBatch(
      songs: _songs,
      infoOf: infoOf,
      fromId: fromId,
      recentIds: {..._harmonicRecentIds, ...deadNext},
      k: k,
    );
    _harmonicBatch = [
      for (final id in picked)
        _songs.indexWhere((s) => s.id == id),
    ].where((i) => i >= 0).toList();
    if (_harmonicBatch.isNotEmpty) {
      final fromId = (_mixIndex >= 0 && _mixIndex < _songs.length)
          ? _songs[_mixIndex].id
          : -1;
      ArchLog.i(
        'automix',
        'harmonic batch k=$k from=$fromId '
        '-> ${_harmonicBatch.map((i) => _songs[i].id).join(',')}',
      );
      _republishOrder();
    }
  }

  /// Next harmonic index without consuming. Null = nothing known
  /// enough to order; the caller falls back to the old behavior.
  int? _harmonicPeek() {
    if (!_automixOn || _engine == null || _songs.length < 2) return null;
    if (_harmonicBatch.isEmpty) return null;
    final i = _harmonicBatch.first;
    if (i < 0 || i >= _songs.length) return null;
    return i;
  }

  void _harmonicConsume(int index) {
    if (_harmonicBatch.isNotEmpty && _harmonicBatch.first == index) {
      _harmonicBatch.removeAt(0);
    }
    if (index >= 0 && index < _songs.length) {
      _harmonicRecentIds.add(_songs[index].id);
      while (_harmonicRecentIds.length > _recentWindow) {
        _harmonicRecentIds.removeAt(0);
      }
    }
  }

  int? _queueIndexOfId(int id) {
    final i = _songs.indexWhere((s) => s.id == id);
    return i < 0 ? null : i;
  }

  void _historyPushBounded(List<int> stack, int id) {
    stack.add(id);
    while (stack.length > _historyCap) {
      stack.removeAt(0);
    }
  }

  /// Forward move to a new track: the outgoing id becomes history and
  /// any redo branch dies (a new branch starts here). Same-id moves
  /// (loop-one, re-tap) record nothing.
  void _historyAdvance(int oldId, int newId) {
    if (oldId == newId) return;
    if (_playHistory.isEmpty || _playHistory.last != oldId) {
      _historyPushBounded(_playHistory, oldId);
    }
    _playFuture.clear();
  }

  /// Backward move: pop history for the target, park the outgoing id
  /// on the redo stack. Null = no usable history: the caller keeps the
  /// legacy queue-slot neighbor.
  int? _historyStepBack(int currentId) {
    while (_playHistory.isNotEmpty) {
      final id = _playHistory.removeLast();
      if (id == currentId) continue;
      final idx = _queueIndexOfId(id);
      if (idx == null) continue; // queue rebuilt: keep popping
      _historyPushBounded(_playFuture, currentId);
      return idx;
    }
    return null;
  }

  /// Next after a prev: re-pop the redo stack, re-push the outgoing
  /// id onto history. Null = no redo branch: the caller picks the
  /// fresh harmonic/queue neighbor.
  int? _historyStepForward(int currentId) {
    while (_playFuture.isNotEmpty) {
      final id = _playFuture.removeLast();
      if (id == currentId) continue;
      final idx = _queueIndexOfId(id);
      if (idx == null) continue; // queue rebuilt: keep popping
      if (_playHistory.isEmpty || _playHistory.last != currentId) {
        _historyPushBounded(_playHistory, currentId);
      }
      return idx;
    }
    return null;
  }

  /// Up Next order: the engine's shuffle permutation when shuffling,
  /// true order otherwise. Same MediaItems as the audio_service queue,
  /// only the order differs — previews and single-source queues ride through
  /// untouched. Fires on every queue mutation and every shuffle flip
  /// so the sheet mirrors what the engine will actually play.
  StreamController<List<MediaItem>>? _orderController;

  Stream<List<MediaItem>> get effectiveQueueStream {
    _orderController ??= StreamController<List<MediaItem>>.broadcast(
      onListen: () => _orderController?.add(_currentOrder()),
    );
    return _orderController!.stream;
  }

  /// Up Next display order in automix mode: the current track, the
  /// harmonic batch, then everything else in queue order. Unknowns
  /// and unpicked tracks stay visible — ordering never hides music.
  List<int> _harmonicDisplayOrder() {
    final order = <int>[];
    if (_automixOn &&
        _engine != null &&
        _mixIndex >= 0 &&
        _mixIndex < _songs.length) {
      order.add(_mixIndex);
    }
    for (final i in _harmonicBatch) {
      if (i >= 0 && i < _songs.length && !order.contains(i)) order.add(i);
    }
    for (var i = 0; i < _songs.length; i++) {
      if (!order.contains(i)) order.add(i);
    }
    return order;
  }

  List<MediaItem> _currentOrder() {
    final items = List<MediaItem>.of(queue.value);
    if (items.isNotEmpty &&
        _automixOn &&
        _engine != null &&
        items.length == _songs.length) {
      final order = _harmonicDisplayOrder();
      if (order.length == items.length) {
        return [for (final i in order) items[i]];
      }
    }
    final idx = _player.shuffleIndices;
    if (_player.shuffleModeEnabled &&
        items.isNotEmpty &&
        idx.length == items.length) {
      return [for (final i in idx) items[i]];
    }
    return items;
  }

  void _republishOrder() {
    if (_orderController?.hasListener ?? false) {
      _orderController!.add(_currentOrder());
    }
  }

  /// Display position (Up Next) to engine source position. Harmonic
  /// order first when the engine owns transport, then the legacy
  /// shuffle mapping, then identity.
  int _toSource(int display) {
    if (_automixOn && _engine != null) {
      final order = _harmonicDisplayOrder();
      if (display >= 0 && display < order.length) return order[display];
      return display;
    }
    final idx = _player.shuffleIndices;
    if (_player.shuffleModeEnabled &&
        idx.length == _songs.length &&
        display >= 0 &&
        display < idx.length) {
      return idx[display];
    }
    return display;
  }

  /// Shuffled tap: sources always land in true order; the engine owns
  /// the permutation and the start is a random index. One sequential
  /// path — no Dart pre-shuffle, no concurrent toggle race.
  Future<void> playShuffled(List<Song> ordered) async {
    if (ordered.isEmpty) return;
    final start = Random().nextInt(ordered.length);
    await playSong(ordered[start], ordered, shuffleAfterLoad: true);
  }

  Future<void> setQueueSongs(List<Song> songs, {int startIndex = 0}) async {
    _songs = List<Song>.from(songs);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    // No preload: the tap answers now, media prepares behind the open
    // player screen. Preloading whole-library queues is what made taps
    // feel dead for seconds.
    await _player.setAudioSources(
      _songs.map((s) => AudioSource.uri(s.uri)).toList(),
      initialIndex: startIndex,
      preload: false,
    );
  }

  /// Atomic tap: newest wins, superseded calls bail silently, failure
  /// is verified before it surfaces. Every decision is logged: the
  /// next "it didn't switch" report diagnoses from one tap's lines
  /// instead of a week of guesses.
  Future<void> playSong(
    Song song,
    List<Song> context, {
    bool shuffleAfterLoad = false,
  }) async {
    // Automix: a tap hands transport back to the playlist long enough
    // to rebuild the queue, then the engine takes over at the new
    // track. Never leave two transports running.
    final wasEngine = _engine != null;
    if (wasEngine) {
      // Manual crossfade out of the engine: fade before the hard
      // teardown so a tap bends out of the mix instead of cutting it.
      // Bounded: a stuck gain write must never wedge the tap —
      // teardown stops the engine anyway, so an unfinished fade
      // degrades to a cut.
      try {
        await _rampTo(0.0, _tapFadeOut).timeout(const Duration(seconds: 2));
      } catch (e) {
        ArchLog.w('player', 'tap fade-out slow: $e');
      }
      await _teardownEngine(resume: false);
    }
    try {
      await _playSongImpl(song, context, shuffleAfterLoad: shuffleAfterLoad);
    } finally {
      if (wasEngine && _automixOn && _songs.isNotEmpty) {
        final idx = (_player.currentIndex ?? 0).clamp(0, _songs.length - 1);
        await _enterEngineAt(idx, at: _player.position);
      }
    }
  }

  Future<void> _playSongImpl(
    Song song,
    List<Song> context, {
    bool shuffleAfterLoad = false,
  }) async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) {
      ArchLog.i('player', 'tap debounced id=${song.id}');
      return;
    }
    _lastTap = now;
    // Newest tap wins: an in-flight older call bails at its next
    // checkpoint instead of landing late and reading as an auto-skip.
    final gen = ++_playGen;
    final watch = Stopwatch()..start();
    // If the engine is held by an older call, nudge it loose first
    // (stop aborts a pending load), then wait briefly for release.
    // Never pile a second setAudioSources onto a live one.
    if (_busy) {
      ArchLog.i('player', 'tap preempt id=${song.id}');
      unawaited(
        _player.stop().timeout(const Duration(seconds: 2)).catchError((_) {}),
      );
    }
    var waited = 0;
    while (_busy && waited < 30) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited++;
    }
    if (gen != _playGen) return;
    if (_busy) {
      ArchLog.w(
        'player',
        'tap engine still held id=${song.id} waited=${watch.elapsedMilliseconds}ms - taking over',
      );
    }
    _busy = true;
    // Rollback target: the UI commits optimistically below; on failure
    // it goes back to this instead of stranding on a silent song.
    final prevItem = mediaItem.value;
    // Outgoing audible id for the play history: the engine cursor when
    // automix owns transport, the playlist index otherwise. A tap
    // starts a new branch — recorded on success below.
    final int? prevAudibleId = _engine != null
        ? ((_mixIndex >= 0 && _mixIndex < _songs.length)
              ? _songs[_mixIndex].id
              : null)
        : () {
            final cur = _player.currentIndex;
            return (cur != null && cur >= 0 && cur < _songs.length)
                ? _songs[cur].id
                : null;
          }();
    // Manual crossfade: fade the outgoing track out *while* the new
    // queue loads, so a tap bends into the next track instead of
    // cutting mid-word. Fire-and-forget: the fade-in below re-owns
    // the gain when the new track starts.
    unawaited(_fadeOut(_tapFadeOut));
    final sameQueue =
        _songs.length == context.length &&
        _songs.every((s) => context.any((c) => c.id == s.id));
    // Tap-jump from a shuffled Up Next hands display order: resolve
    // the seek against engine sources when the set matches, against
    // the context only when it becomes the new queue.
    final index = sameQueue
        ? _songs.indexWhere((s) => s.id == song.id)
        : context.indexWhere((s) => s.id == song.id);
    try {
      ArchLog.i(
        'player',
        'play id=${song.id} title=${song.title} scheme=${song.uri.scheme}',
      );
      if (index < 0) {
        ArchLog.w('player', 'tap song missing from context id=${song.id}');
        // The fade-out above already ran: restore audibility.
        await _setVolume(1.0);
        return;
      }
      if (!sameQueue) {
        // Network previews can stall forever (expired URL, captive
        // portal). Bound it; failure surfaces, never wedges.
        await setQueueSongs(
          context,
          startIndex: index,
        ).timeout(const Duration(seconds: 20));
        if (gen != _playGen) return;
        ArchLog.i(
          'player',
          'queue rebuilt id=${song.id} n=${context.length} in=${watch.elapsedMilliseconds}ms',
        );
      } else {
        // Fire-and-poll: the seek response occasionally never
        // completes on-device even though the transport obeyed (the
        // engine polls play() for the same reason). Same 10s bound
        // and TimeoutException the direct await had — the tap guards
        // (late-success check, rollback, rethrow) don't move, only
        // the hang does.
        await _seekReady(index);
        if (gen != _playGen) return;
        ArchLog.i(
          'player',
          'same-queue seek id=${song.id} index=$index in=${watch.elapsedMilliseconds}ms',
        );
      }
      // Shuffle owns nothing until sources land: enabling the engine
      // before setAudioSources lets the rebuild reset indices to
      // identity (the old in-order bug). Sources in true order first,
      // engine shuffle after — one owner, sequential, no race.
      if (shuffleAfterLoad) {
        await setShuffleEnabled(true).timeout(const Duration(seconds: 10));
        if (gen != _playGen) return;
        ArchLog.i('player', 'shuffle applied id=${song.id}');
      }
      // currentIndexStream fires too, but set it now so the first
      // notification frame is already correct — never one stale behind.
      _setItem(song.toMediaItem());
      // Manual crossfade, second half: the new track starts silent
      // (whatever survived of the fade-out is irrelevant now) and
      // rises into the mix.
      await _setVolume(0.0);
      // Fire-and-poll, same as the seek above: the platform often
      // starts audio without ever completing the play response, and
      // with automix juggling three players that wedge ate every tap
      // (10s stall, then 'late success'). Bounded at the old 10s.
      await _playReady();
      if (gen != _playGen) return;
      await _fadeIn(_tapFadeIn);
      if (gen != _playGen) return;
      // Audibility gate: seek resolving is not playback — with lazy
      // sources the engine can sit silent for seconds, then fall
      // through to the neighbor. Confirm the index actually sounds;
      // on failure pause the fall-through, roll the UI back, surface.
      final landed = await _awaitAudible(index, gen);
      if (!landed) {
        if (gen != _playGen) return;
        ArchLog.w(
          'player',
          'tap inaudible id=${song.id} index=$index actual=${_player.currentIndex}',
        );
        try {
          await _player.pause();
        } catch (_) {}
        if (prevItem != null) _setItem(prevItem);
        throw StateError('tap inaudible id=${song.id}');
      }
      ArchLog.i(
        'player',
        'playing id=${song.id} in=${watch.elapsedMilliseconds}ms',
      );
      // A tap starts a new branch: the outgoing track becomes history,
      // any prev-redo dies here.
      if (prevAudibleId != null) _historyAdvance(prevAudibleId, song.id);
      // Backfill behind playback: the lane probe went cache-only
      // (it raced ExoPlayer prepare), so plain taps must schedule
      // their own analysis — delayed past prepare, dropped when
      // the track moves on. Automix covers its own via _warmUpcoming.
      final warmGen = gen;
      final warmIdx = index;
      unawaited(() async {
        await Future<void>.delayed(const Duration(seconds: 5));
        try {
          if (warmGen != _playGen) return;
          if (warmIdx < 0 || warmIdx >= _songs.length) return;
          if (_songs[warmIdx].id != song.id) return;
          await _meta?.musicalInfoFor(
            title: song.title,
            artist: song.artist,
            path: song.path,
          );
        } catch (_) {}
      }());
      // Art follows behind the tap (zero tap cost): re-set the item
      // with a file-backed cover once resolved. Triple-guarded so a
      // slow fetch can never paint stale art over a newer track.
      unawaited(_attachArtFile(song));
    } catch (e) {
      // Superseded: silent by design, the newer tap owns the UI now.
      if (gen != _playGen) return;
      // Whatever failed, the gain must be whole again: a failed
      // tap must never strand the old track faded out, nor the
      // new one faded in-but-broken.
      await _setVolume(1.0);
      // Late success beats the error: if the engine actually sounds
      // the requested index, a toast would be a lie. Log and swallow.
      if (_player.playing && _player.currentIndex == index) {
        ArchLog.i('player', 'tap late success id=${song.id} '
            'in=${watch.elapsedMilliseconds}ms after $e');
        if (prevAudibleId != null) _historyAdvance(prevAudibleId, song.id);
        unawaited(_attachArtFile(song));
        return;
      }
      rethrow;
    } finally {
      if (gen == _playGen) _busy = false;
    }
  }

  /// Fire-and-poll seek: the seek response occasionally never
  /// completes on-device even though the transport obeyed (the engine
  /// polls `play()` for the same reason — see AutomixEngine). Same
  /// 10s bound and TimeoutException the direct await had, so the tap
  /// guards (late-success check, rollback, rethrow) don't move.
  Future<void> _seekReady(int index) async {
    try {
      unawaited(_player.seek(Duration.zero, index: index).catchError((_) {}));
    } catch (_) {}
    for (var i = 0; i < 100; i++) {
      if (_player.currentIndex == index) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('seek index $index unconfirmed');
  }

  /// Fire-and-poll play: same disease, same cure. The platform often
  /// starts audio without ever completing the play response — with
  /// automix juggling three players that wedge ate every tap (10s
  /// stall, then 'late success'). Bounded at the old 10s.
  Future<void> _playReady() async {
    try {
      unawaited(_player.play().catchError((_) {}));
    } catch (_) {}
    for (var i = 0; i < 100; i++) {
      if (_player.playing) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('play unconfirmed');
  }

  /// True once the engine audibly holds [index]. Fails fast the
  /// moment the index drifts elsewhere (fall-through), times out
  /// otherwise. Never throws: the caller decides.
  Future<bool> _awaitAudible(int index, int gen) async {
    for (var i = 0; i < 40; i++) {
      if (gen != _playGen) return false;
      final current = _player.currentIndex;
      // Index moved under us: the engine fell through to a neighbor.
      if (current != null && current != index) return false;
      if (_player.playing &&
          _player.processingState == ProcessingState.ready &&
          current == index) {
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return _player.playing && _player.currentIndex == index;
  }

  /// Bounded fast pass over the warm caches (memory + disk, no
/// network): when art is already around, the first notification
/// carries it instead of posting artless and hoping a later
/// re-set fixes it. Returns true when it attached anything.
Future<bool> _attachArtFast(Song song, String id) async {
  try {
    if (song.path.isNotEmpty) {
      final preview = await ArtPreviews.previewFor(song.path)
          .timeout(const Duration(milliseconds: 300));
      if (preview != null && preview.isNotEmpty) {
        if (mediaItem.value?.id != id) return false;
        _setItem(
          mediaItem.value!.copyWith(
            extras: {...?mediaItem.value!.extras,
                'artCacheFile': preview},
          ),
        );
        _lastNotifArtSongId = song.id;
        return true;
      }
    }
    if (song.albumId > 0) {
      final bytes = await ArtCache.of(song.albumId)
          .timeout(const Duration(milliseconds: 300));
      if (bytes != null && bytes.isNotEmpty) {
        if (mediaItem.value?.id != id) return false;
        final file = await NotifArt.cacheBytes(bytes, 'album_${song.albumId}')
            .timeout(const Duration(seconds: 2));
        if (file == null || mediaItem.value?.id != id) return false;
        _setItem(
          mediaItem.value!.copyWith(
            extras: {...?mediaItem.value!.extras,
                'artCacheFile': file},
          ),
        );
        _lastNotifArtSongId = song.id;
        return true;
      }
    }
  } catch (_) {}
  return false;
}

Future<void> _attachArtFile(Song song, {bool retry = true}) async {
  try {
    // Warm cache first: when art is already on disk this attaches
    // before the first notification posts (no 8s fetch on the
    // first paint). Cold art falls through to the slow path.
    final fastId = song.uri.toString();
    if (await _attachArtFast(song, fastId)) return;
      // Dedupe: index flips re-fire per flip for the same song.
      // Only the first attach per song id does work; real song
      // changes (different id) still attach as before.
      if (song.id == _lastNotifArtSongId) return;
      // File-art previews first: instant when warm, exact for owned
      // files, and independent of MediaStore album art (missing for
      // fresh pulls — the old path silently attached nothing there).
      if (song.path.isNotEmpty) {
        final id = song.uri.toString();
        if (mediaItem.value?.id != id) return;
        final preview = await ArtPreviews.previewFor(song.path)
            .timeout(const Duration(seconds: 8));
        if (preview != null && preview.isNotEmpty) {
          if (mediaItem.value?.id != id) return;
          _setItem(
            mediaItem.value!.copyWith(
              extras: {...?mediaItem.value!.extras, 'artCacheFile': preview},
            ),
          );
          _lastNotifArtSongId = song.id;
          ArchLog.i('player', 'notif art preview id=${song.id}');
          return;
        }
      }
      if (song.albumId <= 0) {
        _logArtMiss(song);
        return;
      }
      final id = song.uri.toString();
      if (mediaItem.value?.id != id) return;
      final bytes = await ArtCache.of(song.albumId)
          .timeout(const Duration(seconds: 8));
      if (bytes == null || bytes.isEmpty) {
        _logArtMiss(song);
        return;
      }
      if (mediaItem.value?.id != id) return;
      final file = await NotifArt.cacheBytes(bytes, 'album_${song.albumId}');
      if (file == null || mediaItem.value?.id != id) return;
      final current = mediaItem.value;
      if (current == null) return;
      _setItem(
        current.copyWith(extras: {...?current.extras, 'artCacheFile': file}),
      );
      _lastNotifArtSongId = song.id;
      ArchLog.i('player', 'notif art attached id=${song.id}');
    } catch (_) {
      // A tap storm can abort every attach attempt for the current
      // track and leave the notification artless with nobody left
      // to retry. One bounded retry, re-reading the CURRENT item
      // (not the stale caller arg), then silence.
      if (retry && !playbackState.isClosed) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!playbackState.isClosed) {
          final cur = mediaItem.value;
          final art = cur?.extras?['artCacheFile'] as String?;
          if (cur != null && (art == null || art.isEmpty)) {
            final id = cur.extras?['songId'] as int?;
            Song? again;
            if (id != null) {
              for (final t in _songs) {
                if (t.id == id) {
                  again = t;
                  break;
                }
              }
            }
            await _attachArtFile(again ?? song, retry: false);
          }
        }
      }
    }
  }

  /// Preview with cover art: item + audio go first so the first
  /// tap answers instantly; the cover downloads behind and patches
  /// the extras when it lands (same recipe as _attachArtFile).
  Future<void> playPreview({
    required Uri uri,
    required String title,
    required String artist,
    required String album,
    required String? coverUrl,
    required int previewId,
  }) async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 400) {
      ArchLog.i('player', 'preview debounced title=$title');
      return;
    }
    _lastTap = now;
    final watch = Stopwatch()..start();
    var waited = 0;
    while (_busy && waited < 50) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited++;
    }
    if (_busy) {
      ArchLog.w('player', 'preview busy-wait capped title=$title - resetting');
      _busy = false;
    }
    _busy = true;
    try {
      ArchLog.i('player', 'preview title=$title');
      final item = MediaItem(
        id: uri.toString(),
        title: title,
        artist: artist,
        album: album,
        duration: const Duration(seconds: 30),
        artUri: null,
        // coverUrl rides from frame one so art has a network leg
        // while the file caches behind; the file patches in next.
        extras: {
          'songId': previewId,
          'albumId': 0,
          if (coverUrl != null && coverUrl.isNotEmpty) 'coverUrl': coverUrl,
        },
      );
      _songs = [];
      _emitQueue([item]);
      // Previews promise instant audible playback: never inherit
      // a faded-out gain from an interrupted pause.
      await _setVolume(1.0);
      await _player
          .setAudioSource(AudioSource.uri(uri), preload: false)
          .timeout(const Duration(seconds: 20));
      _setItem(item);
      await _player.play().timeout(const Duration(seconds: 10));
      ArchLog.i(
        'player',
        'preview playing title=$title in=${watch.elapsedMilliseconds}ms',
      );
      if (coverUrl != null && coverUrl.isNotEmpty) {
        final artFile = await NotifArt.cacheCover(coverUrl);
        if (artFile != null && mediaItem.value?.id == item.id) {
          _setItem(
            item.copyWith(
              extras: {
                ...?item.extras,
                'artCacheFile': artFile,
                'coverUrl': coverUrl,
              },
            ),
          );
        }
      }
    } finally {
      _busy = false;
    }
  }

  @override
  /// Play with a fade-in: resuming from a faded pause rises instead
  /// of punching in, and a cold start blooms instead of cracking in.
  /// A no-op when already at full gain.
  Future<void> play() async {
    final engine = _engine;
    if (engine != null) {
      await engine.resumeAt(_vol);
    } else {
      await _applyVolume(_vol);
      await _player.play();
    }
    await _fadeIn();
  }

  /// Turn automix on/off. On: the engine takes over transport at the
  /// current song and position. Off: the playlist player resumes there.
  /// Any failure falls back to the playlist path — automix must never
  /// be able to leave the app silent.
  Future<void> setAutomixEnabled(bool on) async {
    if (on == _automixOn) return;
    _automixOn = on;
    ArchLog.i('automix', 'enabled=$on');
    if (on) {
      await _enterEngine();
    } else {
      await _teardownEngine(resume: true);
    }
  }

  Future<void> _enterEngine() async {
    if (_songs.isEmpty) return;
    final cur = (_player.currentIndex ?? 0).clamp(0, _songs.length - 1);
    await _enterEngineAt(cur, at: _player.position);
  }

  /// Start the engine at [index]. Tears down any previous engine first,
  /// so this is also the "restart automix here" path for taps and skips.
  Future<void> _enterEngineAt(int index, {Duration at = Duration.zero}) async {
    if (_songs.isEmpty) return;
    if (index < 0 || index >= _songs.length) return;
    final song = _songs[index];
    await _teardownEngine(resume: false);
    // Teardown bumped the generation; this start owns the next one.
    final gen = ++_mixGen;
    // Pause-park keeps the prepared source warm so the next tap\u2019s
    // seek+play resumes instead of re-preparing: stop-park stalled
    // play() for 10s after every automix teardown (log-proven).
    // The old pause-park engine hang predates the explicit session
    // activation below; engine start stays bounded with a playlist
    // fallback, so a regression surfaces instead of wedging.
    try {
      // Fire-and-poll: pause/stop responses go uncompleted on the same
      // devices that eat play() futures (the 'engine start failed:
      // TimeoutException 0:00:05' in the log). Poll the state instead —
      // same 5s bounds, stop fallback preserved.
      unawaited(_player.pause().catchError((_) {}));
      var waited = 0;
      while (_player.playing && waited < 50) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waited++;
      }
      if (_player.playing) {
        unawaited(_player.stop().catchError((_) {}));
        waited = 0;
        while (_player.playing && waited < 50) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          waited++;
        }
      }
      await _setVolume(1.0);
      ArchLog.i(
        'automix',
        'parked playlist: state=${_player.processingState} '
        'playing=${_player.playing}',
      );
    } catch (e) {
      ArchLog.w('automix', 'park failed: $e');
    }
    final engine = AutomixEngine();
    _engine = engine;
    _mixIndex = index;
    // New transport anchor: drop the old batch, remember the track
    // (anti-repeat), refill + prefetch below.
    _harmonicBatch.clear();
    if (index >= 0 && index < _songs.length) {
      _harmonicRecentIds.add(_songs[index].id);
      while (_harmonicRecentIds.length > _recentWindow) {
        _harmonicRecentIds.removeAt(0);
      }
    }
    _mixEvents = engine.events.listen((_) => _publishEngineState());
    // One explicit activation for the app: the engine players do not
    // request focus themselves. Without this they wait on a grant the
    // parked playlist player still holds and play() never returns.
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (_) {}
    try {
      await _meta?.warmMusical();
    } catch (_) {}
    final ok = await engine.start(song.uri, at: at);
    if (gen != _mixGen) {
      // Superseded while loading: drop it, never arm a zombie.
      await engine.stop();
      await engine.dispose();
      return;
    }
    if (!ok) {
      ArchLog.w(
        'automix',
        'engine start failed idx=$index - falling back to playlist',
      );
      _automixOn = false;
      await _teardownEngine(resume: true);
      // Re-anchor: the failed start's cursor dies with the engine —
      // the playlist index is the truth from here. A stale _mixIndex
      // would poison the next engine entry's neighbor computation.
      _mixIndex = (_player.currentIndex ?? index).clamp(0, _songs.length - 1);
      ArchLog.i('automix', 'engine fallback anchored idx=$_mixIndex');
      _republishOrder();
      if (!_automixFailures.isClosed) _automixFailures.add(null);
      return;
    }
    _setItem(song.toMediaItem());
    unawaited(_attachArtFile(song));
    _mixTick?.cancel();
    _mixTick = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) {
        _publishEngineState();
        unawaited(_maybeMix());
      },
    );
    _publishEngineState();
    ArchLog.i('automix', 'armed idx=$index at=${at.inSeconds}s');
    // Fresh transport, fresh harmonic batch from the new position.
    // Always republish: a tap can land on an unanalyzed track whose
    // batch refills empty, and without this the Up Next list keeps
    // showing the pre-tap order while the new song plays.
    _harmonicBatch.clear();
    _ensureHarmonicBatch();
    _republishOrder();
    // Pre-analysis runs ahead of the needle from here: the next two
    // tracks resolve while this one plays.
    unawaited(_warmUpcoming());
  }

  /// Park or end the engine. [resume] hands transport back to the
  /// playlist player at the engine's exact position and index.
  Future<void> _teardownEngine({required bool resume}) async {
    _mixGen++;
    // Abandon the pipeline with the phase: the render guard and
    // the landing wait both bail on the generation/flag.
    _dropBridgeFile();
    _deadPairs.clear();
    _landing = false;
    _mixTick?.cancel();
    _mixTick = null;
    final engine = _engine;
    if (engine == null) return;
    ArchLog.i('automix', 'teardown resume=$resume idx=$_mixIndex');
    final pos = engine.position;
    final idx = _mixIndex;
    final wasPlaying = engine.playing;
    await _mixEvents?.cancel();
    _mixEvents = null;
    _engine = null;
    // Bounded: a stuck platform stop/dispose used to wedge every tap
    // and skip with automix on. Log and move on — the players are
    // dropped either way and the playlist transport is independent.
    try {
      await engine.stop().timeout(const Duration(seconds: 4));
    } catch (e) {
      ArchLog.w('automix', 'teardown stop slow: $e');
    }
    try {
      await engine.dispose().timeout(const Duration(seconds: 4));
    } catch (e) {
      ArchLog.w('automix', 'teardown dispose slow: $e');
    }
    if (!resume) return;
    if (idx < 0 || idx >= _songs.length) return;
    try {
      await _player.seek(pos, index: idx);
      // Hand back the transport in the state the user left it: a
      // paused engine must not start playing on toggle-off.
      if (wasPlaying) {
        await _player.play();
        await _setVolume(_vol);
        await _fadeIn();
      }
      _setItem(_songs[idx].toMediaItem());
    } catch (e) {
      ArchLog.w('automix', 'handback failed: $e');
    }
  }

  /// Watcher: start the blend once the remaining runtime fits the plan.
  Future<void> _maybeMix() async {
    final engine = _engine;
    if (engine == null) return _mixWhy('no engine');
    if (!_automixOn) return _mixWhy('automix off');
    if (_mixFiring) return _mixWhy('already firing');
    if (engine.isCrossfading) return _mixWhy('crossfading');
    if (engine.bridging) {
      // The file plays; B lands itself at the join (one flight).
      unawaited(_landBridge());
      return _mixWhy('bridging');
    }
    // A track that already ran out still needs the next one: treat
    // completion as "window open now" so automix never dies at a
    // boundary just because a tick landed late.
    final finished = engine.completed;
    if (!engine.playing && !finished) return _mixWhy('not playing');
    if (_mixIndex < 0 || _mixIndex >= _songs.length) return _mixWhy('index oob');
    // Engine duration first, queue metadata second: a content:// load
    // can sit without a duration for a while and silently starve the
    // mix. The library always knows how long the track is.
    final known = engine.duration;
    final fallback = _songs[_mixIndex].duration;
    final total = (known != null && known > Duration.zero)
        ? known
        : (fallback > Duration.zero ? fallback : null);
    if (total == null) return _mixWhy('no duration');
    // Harmonic batches refill here (once per exhaustion, not per tick:
    // _ensureHarmonicBatch is a no-op while the batch holds).
    _ensureHarmonicBatch();
    final next = _mixNeighborIndex(1);
    if (next == null || next == _mixIndex) {
      // Queue ran dry mid-automix: with autoplay on, ask the UI for
      // more instead of stopping. Without it, same as before.
      if (_automixOn && _autoplayOn) {
        _requestMoreMusic();
        return _mixWhy('autoplay wait');
      }
      return _mixWhy('no next');
    }
    // One bridge rendering ahead: flag-guarded per tick, once per
    // pair. The render runs beside playback; the window uses it or
    // falls back to the live fade below.
    if (_bridge == null && !_rendering) {
      unawaited(_renderBridgeFor(_mixIndex, next));
    }
    // The window follows the waiting bridge, not the live plan: a
    // 16-bar file fires ~30s out, not at the 10s live clamp. Firing
    // a long bridge at the short window jumps A backward instead of
    // blending — the live plan must never time a baked file.
    final pair = '${_songs[_mixIndex].id}>${_songs[next].id}';
    final job = (_bridgeValid() && _bridgePair == pair) ? _bridge! : null;
    final plan = _mixPlan(_mixIndex, next);
    final window = job != null
        ? Duration(milliseconds: (job.seconds * 1000).round())
        : plan.duration;
    // Bridges fire at their file start: the mix-out point can
    // sit well before EOF, and firing at (end - length) replays
    // the tail.
    final fireAt = job != null
        ? Duration(milliseconds: (job.windowStartA * 1000).round())
        : null;
    final remaining = finished ? -const Duration(seconds: 1) : total - engine.position;
    _mixProbe(engine, total, remaining, next, plan, window, fireAt);
    if (job != null) {
      // Pre-buffer the bridge on the idle side while it approaches:
      // the fire then costs a seek+play, not a load. Once per pair.
      if (!finished &&
          remaining <= window + const Duration(seconds: 8) &&
          _primePair != pair) {
        _primePair = pair;
        unawaited(engine.primeBridge(Uri.file(job.file)));
      }
      if (!finished && engine.position < fireAt!) return;
    } else if (remaining > window) {
      return;
    }
    _mixFiring = true;
    try {
      final song = _songs[next];
      // Baked bridge first: the file holds the overlap, the joins
      // are same-waveform and the clock stays B-mapped. Anything
      // missing or stale falls through to the live fade below.
      if (job != null) {
        ArchLog.i(
          'automix',
          'bridge fire id=${song.id} '
              '${job.seconds.toStringAsFixed(1)}s',
        );
        final bridged = await engine
            .bridgeTo(
              bridgeUri: Uri.file(job.file),
              nextUri: song.uri,
              startB: job.startB,
              entryDelay: job.entryDelay,
              tempoRatio: job.tempoRatio,
              resumeB: job.resumeB,
              durB: song.duration,
              bridgeSeconds: job.seconds,
              windowStartA: job.windowStartA,
            )
            .timeout(Duration(seconds: job.seconds.round() + 30))
            .catchError((Object e) {
          ArchLog.w('automix', 'bridge timeout: $e');
          return false;
        });
        if (bridged) {
          _historyAdvance(_songs[_mixIndex].id, song.id);
          _mixIndex = next;
          _harmonicConsume(next);
          _setItem(song.toMediaItem());
          unawaited(_attachArtFile(song));
          _republishOrder();
          ArchLog.i('automix', 'bridge on id=${song.id}');
          unawaited(_warmUpcoming());
          return;
        }
        // Spent either way: never retry a dead file each tick.
        _dropBridgeFile();
      }
      final startAt = _mixStartOffset(next);
      // Belt and braces: the engine bounds its own awaits, but the
      // flag must clear no matter what, or every later tick bails.
      final ok = await engine
          .crossfadeTo(song.uri, seconds: plan.seconds, startAt: startAt)
          .timeout(Duration(seconds: plan.seconds.round() + 30))
          .catchError((Object e) {
        ArchLog.w('automix', 'crossfade timeout: $e');
        return false;
      });
      if (ok) {
        _historyAdvance(_songs[_mixIndex].id, song.id);
        _mixIndex = next;
        _harmonicConsume(next);
        _setItem(song.toMediaItem());
        unawaited(_attachArtFile(song));
        _republishOrder();
        ArchLog.i(
          'automix',
          'mixing id=${song.id} ${plan.seconds.toStringAsFixed(1)}s (${plan.reason})',
        );
        // The horizon moved: warm the next pair before its window.
        unawaited(_warmUpcoming());
      }
    } catch (e) {
      ArchLog.w('automix', 'mix failed: $e');
    } finally {
      _mixFiring = false;
    }
  }

  /// Throttled diagnostic: without it a starved mix is undiagnosable
  /// (nothing logs when the watcher simply returns early).
  DateTime _mixProbeAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _mixWhy(String reason) {
    final now = DateTime.now();
    if (now.difference(_mixProbeAt).inSeconds < 5) return;
    _mixProbeAt = now;
    ArchLog.i('automix', 'wait: $reason');
  }

  void _mixProbe(
    AutomixEngine engine,
    Duration total,
    Duration remaining,
    int next,
    CrossfadePlan plan,
    Duration window,
    Duration? fireAt,
  ) {
    final now = DateTime.now();
    if (now.difference(_mixProbeAt).inSeconds < 5) return;
    _mixProbeAt = now;
    final fireTag = fireAt == null ? '' : 'fireAt=${fireAt.inSeconds}s ';
    ArchLog.i(
      'automix',
      'probe total=${total.inSeconds}s pos=${engine.position.inSeconds}s '
      'left=${remaining.inSeconds}s plan=${plan.seconds.toStringAsFixed(1)}s '
      'win=${window.inSeconds}s ${fireTag}next=$next',
    );
  }

  /// Neighbour of the engine's current index in play order. Honours
  /// the engine's shuffle permutation and loop-all wrap; null at the
  /// end with loop off (the mix simply stops, like a playlist would).
  /// Next/previous while the engine owns transport. Forward prefers
  /// the harmonic batch and falls back to the legacy order when
  /// nothing is known enough to order (unanalyzed libraries play
  /// exactly like before); backward keeps the legacy behavior —
  /// history has no harmonic walk to replay.
  int? _mixNeighborIndex(int delta) {
    if (_automixOn && _engine != null && delta > 0) {
      return _harmonicPeek() ?? _mixNeighborIndexAt(_mixIndex, delta);
    }
    return _mixNeighborIndexAt(_mixIndex, delta);
  }

  /// Neighbour of an arbitrary index in play order — the lookahead
  /// primitive. Same order rules as the engine cursor.
  int? _mixNeighborIndexAt(int index, int delta) {
    if (_songs.length < 2) return null;
    final List<int> order;
    if (_player.shuffleModeEnabled &&
        _player.shuffleIndices.length == _songs.length) {
      order = _player.shuffleIndices;
    } else {
      order = List<int>.generate(_songs.length, (i) => i);
    }
    final pos = order.indexOf(index);
    if (pos < 0) return null;
    final p = pos + delta;
    if (p < 0 || p >= order.length) {
      if (_player.loopMode != LoopMode.all) return null;
      return order[(p + order.length) % order.length];
    }
    return order[p];
  }

  /// Queue-ahead pre-analysis: resolve musical info for the next two
  /// tracks while the current one plays, so every transition is fully
  /// planned before it fires. Follows the harmonic horizon first
  /// (what will actually play), queue order only past it.
  /// Fire-and-forget and sequential — never on the playback path,
  /// never parallel decodes. Superseded the moment transport moves
  /// on (generation guard).
  /// Render the bridge for [aIdx] -> [bIdx] beside playback. One
  /// at a time (ticks retry while busy); cache-only inputs, so the
  /// only heavy work is the decode + FFmpeg render itself — never
  /// on the tap/skip/play path, always generation-guarded. Owned
  /// files only; tempo-less pairs with a key fit still render (no
  /// stretch), anything else stays live.
  Future<void> _renderBridgeFor(int aIdx, int bIdx) async {
    if (_rendering) return;
    if (aIdx < 0 || bIdx < 0) return;
    if (aIdx >= _songs.length || bIdx >= _songs.length) return;
    final meta = _meta;
    final a = _songs[aIdx];
    final b = _songs[bIdx];
    final pair = '${a.id}>${b.id}';
    if (pair == _bridgePair && _bridge != null) return;
    if (_deadPairs.contains(pair)) return;
    if (meta == null || !_automixOn || _engine == null) {
      _renderSkip(pair, 'not ready');
      return;
    }
    if (a.path.isEmpty || b.path.isEmpty) {
      _renderSkip(pair, 'no file path');
      return;
    }
    if (!a.path.startsWith('/') || !b.path.startsWith('/')) {
      _renderSkip(pair, 'non-file uri');
      return;
    }
    final gen = _mixGen;
    _rendering = true;
    try {
      final ia = meta.musicalInfoCached(
        title: a.title,
        artist: a.artist,
        path: a.path,
      );
      final ib = meta.musicalInfoCached(
        title: b.title,
        artist: b.artist,
        path: b.path,
      );
      // Effective grid: known tempos when both sides have them, else
      // blend on key/energy instead of skipping outright — no stretch
      // (grid from the known side, else a nominal 120, so ratio is
      // exactly 1.0 and atempo stays transparent). Beat placement
      // degrades, the blend still renders. Pairs with no key either
      // keep retrying: background analysis can heal them mid-track.
      var bpmA = ia?.bpm;
      var bpmB = ib?.bpm;
      var bars = 16;
      var keyBlend = false;
      if (bpmA == null || bpmB == null) {
        final rel = ho.harmonicRelation(
          ia?.openKey.isEmpty ?? true ? null : ia?.openKey,
          ib?.openKey.isEmpty ?? true ? null : ib?.openKey,
        );
        switch (rel) {
          case ho.HarmonicRel.same:
          case ho.HarmonicRel.relative:
          case ho.HarmonicRel.adjacent:
          case ho.HarmonicRel.energy:
            final known = bpmA ?? bpmB ?? 120.0;
            bpmA = known;
            bpmB = known;
            bars = 8;
            keyBlend = true;
            ArchLog.i('automix', 'bridge key-blend $pair (${rel.name})');
          case ho.HarmonicRel.far:
          case ho.HarmonicRel.unknown:
            _renderSkip(pair, 'no tempo, no key');
            return;
        }
      }
      // Same band as the renderer (tight ±8%: 0.92–1.08). In-gate
      // pairs tempo-blend; tempo-known but out-of-gate pairs fall
      // to the echo-out bridge (no stretch) instead of dying here.
      // Key-blend pins ratio=1.0 so it never trips this. Unplannable
      // geometry still dies in the renderer and stays dead.
      final ratio = bpmA / bpmB;
      var echoOut = false;
      if (ratio < 0.92 || ratio > 1.08) {
        echoOut = true;
        ArchLog.i(
          'automix',
          'bridge echo-out $pair (ratio ${ratio.toStringAsFixed(2)})',
        );
      }
      final rb = await renderBridge(
        BlendSpec(
          aPath: a.path,
          bPath: b.path,
          durA: a.duration.inMilliseconds / 1000.0,
          durB: b.duration.inMilliseconds / 1000.0,
          bpmA: bpmA,
          bpmB: bpmB,
          phaseA: ia?.phase,
          phaseB: ib?.phase,
          firstSoundB: ib?.firstSound,
          vocalA: meta.vocalSectionsCached(
            title: a.title,
            artist: a.artist,
          ),
          vocalB: meta.vocalSectionsCached(
            title: b.title,
            artist: b.artist,
          ),
          bars: echoOut ? 8 : bars,
        ),
        tag: 'live_${a.id}_${b.id}',
        echoOut: echoOut,
      );
      // Transport moved on mid-render: the file is orphaned. Loud,
      // because renders take minutes and taps take seconds — every
      // skip during a render restarts its clock.
      if (gen != _mixGen || !_automixOn || _engine == null) {
        if (rb != null) {
          try {
            File(rb.file).deleteSync();
          } catch (_) {}
        }
        ArchLog.i('automix', 'bridge orphan $pair (transport moved on)');
        return;
      }
      if (rb == null) {
        _deadPairs.add(pair);
        return;
      }
      // Queue moved under the render: same orphan rule.
      if (aIdx >= _songs.length ||
          bIdx >= _songs.length ||
          _songs[aIdx].id != a.id ||
          _songs[bIdx].id != b.id) {
        try {
          File(rb.file).deleteSync();
        } catch (_) {}
        ArchLog.i('automix', 'bridge orphan $pair (queue moved)');
        return;
      }
      if (_bridge != null && _bridgePair != pair) _dropBridgeFile();
      _bridge = _BridgeJob(
        from: aIdx,
        next: bIdx,
        file: rb.file,
        startB: rb.plan.startB,
        entryDelay: rb.plan.entryDelay,
        tempoRatio: rb.plan.tempoRatio,
        resumeB: rb.resumeB,
        seconds: rb.plan.seconds,
        durB: b.duration,
        windowStartA: rb.windowStartA,
      );
      _bridgePair = pair;
      ArchLog.i(
        'automix',
        'bridge ready ${a.id}>${b.id} '
            '${rb.plan.seconds.toStringAsFixed(1)}s '
            '(${rb.plan.bars} bars${keyBlend ? ', key' : ''}${echoOut ? ', echo send=${echoSendSecs.toStringAsFixed(1)}s taps=$echoTapDecays tail=${echoTailSecs.toStringAsFixed(1)}s' : ''})',
      );
    } catch (e) {
      ArchLog.w('automix', 'bridge render failed: $e');
      _deadPairs.add(pair);
    } finally {
      _rendering = false;
    }
  }

  /// Land B under a playing bridge. One flight at a time; the
  /// engine flips exactly at the join, then the file is deleted.
  /// Interrupts clear the phase via stop(), and the wait bails.
  Future<void> _landBridge() async {
    if (_landing) return;
    _landing = true;
    try {
      final engine = _engine;
      final job = _bridge;
      if (engine == null || job == null || !_bridgeValid()) return;
      final b = _songs[job.next];
      final ok = await engine.finishBridge(b.uri);
      // Landed or cut: the file is done either way.
      _dropBridgeFile();
      if (ok) {
        _republishOrder();
        ArchLog.i('automix', 'bridge landed id=${b.id}');
        unawaited(_warmUpcoming());
      }
    } finally {
      _landing = false;
    }
  }

  Future<void> _warmUpcoming() async {
    try {
      final meta = _meta;
      if (meta == null || !_automixOn || _engine == null) return;
      final gen = _mixGen;
      _ensureHarmonicBatch();
      final targets = <int>[];
      for (final i in _harmonicBatch) {
        if (targets.length >= 2) break;
        if (i >= 0 && i < _songs.length && i != _mixIndex) {
          targets.add(i);
        }
      }
      var idx = _mixIndex;
      final seen = <int>{idx};
      while (targets.length < 2) {
        final next = _mixNeighborIndexAt(idx, 1);
        if (next == null || next < 0 || next >= _songs.length) break;
        // Seen or wrapped around: nothing new left to warm.
        if (!seen.add(next)) break;
        if (next != _mixIndex && !targets.contains(next)) {
          targets.add(next);
        }
        idx = next;
      }
      for (final t in targets) {
        final s = _songs[t];
        await meta.musicalInfoFor(
          title: s.title,
          artist: s.artist,
          path: s.path,
        );
        if (gen != _mixGen || !_automixOn) return;
      }
    } catch (_) {}
  }

  /// Where the incoming track should begin. Its first audible sound,
  /// nudged onto the nearest beat when the grid is known — an intro of
  /// silence is not something to fade into.
  Duration _mixStartOffset(int index) {
    try {
      final info = _meta?.musicalInfoCached(
        title: _songs[index].title,
        artist: _songs[index].artist,
        path: _songs[index].path,
      );
      final first = info?.firstSound;
      if (first == null || first <= 0.05) return Duration.zero;
      var offset = first;
      // Snap to the beat grid so the entrance lands in time.
      final phase = info?.phase;
      final bpm = info?.bpm;
      if (phase != null && bpm != null && bpm > 0) {
        final period = 60.0 / bpm;
        final k = ((offset - phase) / period).round();
        offset = phase + k * period;
      }
      if (offset < 0) offset = first;
      // Never skip more than a few seconds of a track.
      offset = offset.clamp(0.0, 8.0);
      return Duration(milliseconds: (offset * 1000).round());
    } catch (_) {
      return Duration.zero;
    }
  }

  /// Adaptive blend length from cached musical facts only — no
  /// network, no DSP on the playback path. Unknowns go neutral.
  CrossfadePlan _mixPlan(int a, int b) {
    TrackMusicalInfo? ia;
    TrackMusicalInfo? ib;
    try {
      ia = _meta?.musicalInfoCached(
        title: _songs[a].title,
        artist: _songs[a].artist,
        path: _songs[a].path,
      );
      ib = _meta?.musicalInfoCached(
        title: _songs[b].title,
        artist: _songs[b].artist,
        path: _songs[b].path,
      );
    } catch (_) {}
    // Live lengths stay on the grid too: bar counts from the same
    // planner the bridges use, clamped to the live band (long
    // blends are the bridge's job - a 32-bar live fade sprawls).
    final bars = blendBars(
      openA: ia?.openKey,
      openB: ib?.openKey,
      bpmA: ia?.bpm,
      bpmB: ib?.bpm,
      durA: _songs[a].duration.inMilliseconds / 1000.0,
      durB: _songs[b].duration.inMilliseconds / 1000.0,
    );
    final bpmA = ia?.bpm;
    if (bpmA != null && bpmA > 0) {
      final secs = (bars * 4 * 60.0 / bpmA).clamp(
        crossfadeMin,
        crossfadeMax,
      );
      return CrossfadePlan(seconds: secs, reason: '${bars}bars');
    }
    return planCrossfade(
      openA: ia?.openKey,
      openB: ib?.openKey,
      bpmA: ia?.bpm,
      bpmB: ib?.bpm,
    );
  }

  /// Publish the engine's state from ONE source — the engine itself.
  /// Two players' event streams interleaving is what made the scrubber
  /// jump backwards (old track's position, then new track's).
  void _publishEngineState() {
    final engine = _engine;
    if (engine == null || playbackState.isClosed) return;
    final shuffle = _player.shuffleModeEnabled;
    final loop = _player.loopMode;
    final states = engine.processingStates;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.custom(
            androidIcon: shuffle
                ? 'drawable/ic_notif_shuffle_on'
                : 'drawable/ic_notif_shuffle_off',
            label: 'Shuffle',
            name: 'notif_shuffle',
          ),
          MediaControl.skipToPrevious,
          engine.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.custom(
            androidIcon: switch (loop) {
              LoopMode.all => 'drawable/ic_notif_repeat_all',
              LoopMode.one => 'drawable/ic_notif_repeat_one',
              _ => 'drawable/ic_notif_repeat_off',
            },
            label: 'Repeat',
            name: 'notif_repeat',
          ),
        ],
        androidCompactActionIndices: const [1, 2, 3],
        systemActions: const {MediaAction.seek},
        processingState: switch (states.$1) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: engine.playing,
        updatePosition: engine.position,
        bufferedPosition: states.$2,
        speed: 1.0,
        queueIndex: _mixIndex,
      ),
    );
  }

  @override
  /// Pause with a fade-out: hard stops read as glitches next to
  /// blended transitions. Skips the ramp when already silent.
  Future<void> pause() async {
    final playing = _engine?.playing ?? _player.playing;
    if (playing) await _rampTo(0.0, _pauseFade);
    if (_engine != null) {
      await _engine!.pause();
    } else {
      await _player.pause();
    }
  }

  @override
  Future<void> seek(Duration position) =>
      _engine?.seek(position) ?? _player.seek(position);

  /// Manual skip, optimistic: the target commits to the UI in-frame
  /// (deterministic order only — shuffle order lives inside the
  /// engine and is never guessed), then the engine follows. Supersede
  /// token shared with taps: a second skip retargets instead of
  /// racing. Fully logged: intent, expectation, landing.
  Future<void> _skip(int dir) async {
    // Automix: skipping restarts the engine at the neighbour. The
    // engine's own index is the truth here, not the parked playlist.
    if (_engine != null) {
      // Refill first: a tap right after another tap can land while
      // the batch is still cleared, and a silent no-op reads broken.
      _ensureHarmonicBatch();
      // History first, queue slots second: prev returns what was just
      // heard (not the queue slot behind the harmonic jump), and next
      // after a prev restores the redo branch instead of re-picking.
      final curId = (_mixIndex >= 0 && _mixIndex < _songs.length)
          ? _songs[_mixIndex].id
          : null;
      int? target;
      var viaHistory = false;
      if (curId != null) {
        target = dir < 0
            ? _historyStepBack(curId)
            : _historyStepForward(curId);
        viaHistory = target != null;
      }
      target ??= _mixNeighborIndex(dir > 0 ? 1 : -1);
      if (target == null) return;
      if (!viaHistory && curId != null) {
        final tid = (target >= 0 && target < _songs.length)
            ? _songs[target].id
            : null;
        if (tid != null) _historyAdvance(curId, tid);
      }
      ArchLog.i('automix', 'skip fade-out, then jump');
      // Bounded like the tap path: a stuck gain write degrades to a
      // cut instead of wedging the skip.
      try {
        await _rampTo(0.0, _tapFadeOut).timeout(const Duration(seconds: 2));
      } catch (e) {
        ArchLog.w('automix', 'skip fade-out slow: $e');
      }
      ArchLog.i(
        'automix',
        'skip ${dir > 0 ? 'next' : 'prev'} -> $target'
        '${viaHistory ? ' (history)' : ''}',
      );
      await _enterEngineAt(target);
      return;
    }
    final n = _songs.length;
    if (n == 0) return;
    final gen = ++_skipGen;
    final from = _player.currentIndex;
    int? expect;
    final deterministic =
        !_player.shuffleModeEnabled &&
        _player.loopMode != LoopMode.one &&
        from != null;
    if (deterministic) {
      var t = from + dir;
      if (_player.loopMode == LoopMode.all) {
        t = (t + n) % n;
      } else {
        t = t.clamp(0, n - 1);
        // Loop-off rail: clamping a next on the last slot yields
        // expect=from and seekToNext() no-ops there (log-proven 0ms
        // landing on the same song). A manual next always advances —
        // wrap to the head instead of standing still.
        if (dir > 0 && t == from && n > 1) t = (from + 1) % n;
      }
      expect = t;
      if (t >= 0 && t < queue.value.length) _setItem(queue.value[t]);
    }
    final watch = Stopwatch()..start();
    ArchLog.i(
      'player',
      'skip ${dir > 0 ? 'next' : 'prev'} from=$from expect=$expect',
    );
    if (dir > 0) {
      await _player.seekToNext();
    } else {
      await _player.seekToPrevious();
    }
    // Rail fallback: the transport above no-ops at the loop-off end
    // of the queue, so land the optimistic target explicitly and
    // keep every skip a real move.
    if (gen == _skipGen &&
        expect != null &&
        expect != from &&
        _player.currentIndex == from &&
        expect >= 0 &&
        expect < _songs.length) {
      ArchLog.i('player', 'skip rail fallback seek=$expect');
      await _player.seek(null, index: expect);
    }
    if (gen != _skipGen) {
      ArchLog.i('player', 'skip superseded');
      return;
    }
    ArchLog.i(
      'player',
      'skip landed index=${_player.currentIndex} in=${watch.elapsedMilliseconds}ms',
    );
    // Forward moves join the play history (prev pops it); a delegated
    // prev records nothing — history pops happen in the engine branch
    // above, and a queue-slot prev must never overwrite the redo.
    if (dir > 0 && from != null && from >= 0 && from < n) {
      final landed = _player.currentIndex;
      if (landed != null && landed >= 0 && landed < n) {
        _historyAdvance(_songs[from].id, _songs[landed].id);
      }
    }
  }

  @override
  Future<void> skipToNext() => _skip(1);

  @override
  Future<void> skipToPrevious() => _skip(-1);

  /// The song a manual skip in [dir] would land on (-1 = next, 1 =
  /// previous), or null past the end with loop off. Follows the
  /// engine's shuffle order when shuffling — the carousel peek must
  /// show the truth, never a guess. Null-safe by construction: empty
  /// queue, unknown index and order gaps all read as "no neighbor".
  Song? neighborSong(int dir) {
    if (_songs.isEmpty) return null;
    // Automix: the engine's cursor is the truth; the playlist player
    // is parked on the old index and would peek the wrong track.
    // Forward peek follows the harmonic batch when automix owns it.
    if (_automixOn && _engine != null && dir > 0) {
      final n = _harmonicPeek();
      if (n != null && n >= 0 && n < _songs.length) return _songs[n];
    }
    final cur = _engine != null
        ? _mixIndex
        : _player.currentIndex;
    if (cur == null || cur < 0 || cur >= _songs.length) return null;
    final List<int> order;
    if (_player.shuffleModeEnabled && _player.shuffleIndices.isNotEmpty) {
      order = _player.shuffleIndices;
    } else {
      order = List<int>.generate(_songs.length, (i) => i);
    }
    final pos = order.indexOf(cur);
    if (pos < 0) return null;
    final p = pos + dir;
    if (p < 0 || p >= order.length) {
      if (_player.loopMode != LoopMode.all) return null;
      return _songs[order[(p + order.length) % order.length]];
    }
    return _songs[order[p]];
  }

  /// Shuffle + repeat land here (providers own the state, prefs own the
  /// memory). Applied to the live player and logged like everything.
  /// A shuffle flip changes the harmonic batch size (batches on, walk
  /// off), so the batch rebuilds from here on out.
  Future<void> setShuffleEnabled(bool enabled) async {
    await _player.setShuffleModeEnabled(enabled);
    if (enabled) await _player.shuffle();
    _harmonicBatch.clear();
    _republishOrder();
    ArchLog.i(
      'player',
      'shuffle=$enabled order=${_player.shuffleIndices.take(8).join(',')}',
    );
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _player.setLoopMode(mode);
    ArchLog.i('player', 'loop=$mode');
  }

  /// Sleep timer: wall-clock countdown, survives track changes, fires
  /// once (pause + clear). Ticks drive the remaining-time provider.
  final _sleepController = StreamController<Duration?>.broadcast();
  Timer? _sleepTick;
  DateTime? _sleepAt;

  Stream<Duration?> get sleepStream => _sleepController.stream;

  Future<void> startSleep(Duration after) async {
    cancelSleep();
    _sleepAt = DateTime.now().add(after);
    _sleepController.add(after);
    ArchLog.i('player', 'sleep in=${after.inMinutes}m');
    _sleepTick = Timer.periodic(const Duration(seconds: 1), (_) async {
      final at = _sleepAt;
      if (at == null) return;
      final remaining = at.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        await pause();
        cancelSleep();
        ArchLog.i('player', 'sleep fired');
      } else if (!_sleepController.isClosed) {
        _sleepController.add(remaining);
      }
    });
  }

  void cancelSleep() {
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepAt = null;
    if (!_sleepController.isClosed) _sleepController.add(null);
  }

  /// Queue surgery for the queue sheet. The just_audio playlist and the
  /// mirrored [_songs]/audio_service queue move together - one truth,
  /// never drift. Single-source (preview) queues ignore move/remove.
  /// Player-level ops (not the deprecated ConcatenatingAudioSource
  /// surface). Names avoid the BaseAudioHandler queue-item overrides.
  Future<void> moveQueueIndex(int oldIndex, int newIndex) async {
    // Up Next speaks display positions; the engine and mirror move in
    // source positions. Mapped first so drag-reorder works shuffled.
    oldIndex = _toSource(oldIndex);
    newIndex = _toSource(newIndex);
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= _songs.length ||
        newIndex >= _songs.length) {
      return;
    }
    if (_songs.length < 2) return;
    await _player.moveAudioSource(oldIndex, newIndex);
    final s = _songs.removeAt(oldIndex);
    _songs.insert(newIndex, s);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    ArchLog.i('player', 'queue move $oldIndex -> $newIndex');
  }

  Future<void> removeQueueIndex(int index) async {
    index = _toSource(index);
    if (index < 0 || index >= _songs.length) return;
    if (_songs.length == 1) {
      await clearQueue();
      return;
    }
    await _player.removeAudioSourceAt(index);
    final removed = _songs.removeAt(index);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    ArchLog.i('player', 'queue remove id=${removed.id} index=$index');
  }

  /// True when the live queue is a streaming preview (single source,
  /// no library context). Queue surgery targets library queues only:
  /// callers show a snackbar instead of wedging here.
  bool get isPreviewQueue =>
      _songs.isEmpty && mediaItem.value != null;

  /// Play next: splice after the current index, order-preserving for
  /// bulks. Empty library queue (nothing playing ever) just takes
  /// the songs, paused. Preview queue: false, caller explains.
  Future<bool> insertNextAll(List<Song> songs) async {
    if (songs.isEmpty) return true;
    if (isPreviewQueue) return false;
    if (_songs.isEmpty) {
      await setQueueSongs(songs);
      ArchLog.i('player', 'play-next on empty queue: took ${songs.length}');
      return true;
    }
    var pos = (_player.currentIndex ?? _songs.length - 1) + 1;
    pos = pos.clamp(0, _songs.length);
    final fresh = [
      for (final s in songs)
        if (!_songs.any((q) => q.id == s.id)) s,
    ];
    if (fresh.isEmpty) return true;
    await _player.insertAudioSources(
      pos,
      [for (final s in fresh) AudioSource.uri(s.uri)],
    );
    _songs.insertAll(pos, fresh);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    ArchLog.i('player', 'play-next ${fresh.length} at $pos');
    return true;
  }

  Future<bool> insertNext(Song song) => insertNextAll([song]);

  /// Add to queue: end-append, order-preserving, de-duped against
  /// the live queue. Same empty/preview contract as insertNextAll.
  Future<bool> appendToQueue(List<Song> songs) async {
    if (songs.isEmpty) return true;
    if (isPreviewQueue) return false;
    if (_songs.isEmpty) {
      await setQueueSongs(songs);
      ArchLog.i('player', 'append on empty queue: took ${songs.length}');
      return true;
    }
    final fresh = [
      for (final s in songs)
        if (!_songs.any((q) => q.id == s.id)) s,
    ];
    if (fresh.isEmpty) return true;
    await _player.addAudioSources(
      [for (final s in fresh) AudioSource.uri(s.uri)],
    );
    _songs.addAll(fresh);
    _emitQueue(_songs.map((s) => s.toMediaItem()).toList());
    ArchLog.i('player', 'append ${fresh.length}');
    return true;
  }

  Future<void> clearQueue() async {
    await _player.stop();
    _songs = [];
    _emitQueue([]);
    mediaItem.value = null;
    cancelSleep();
    ArchLog.i('player', 'queue cleared');
  }

  @override
  Future<void> stop() async {
    // Shutdown path: kill the engine first so no fade timer survives.
    _automixOn = false;
    await _teardownEngine(resume: false);
    await _player.stop();
  }

  PlaybackState _toPlaybackState(
    PlaybackEvent event, {
    bool? shuffleOverride,
    LoopMode? loopOverride,
  }) {
    final shuffle = shuffleOverride ?? _player.shuffleModeEnabled;
    final loop = loopOverride ?? _player.loopMode;
    return PlaybackState(
      controls: [
        MediaControl.custom(
          androidIcon: shuffle
              ? 'drawable/ic_notif_shuffle_on'
              : 'drawable/ic_notif_shuffle_off',
          label: 'Shuffle',
          name: 'notif_shuffle',
        ),
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.custom(
          androidIcon: switch (loop) {
            LoopMode.all => 'drawable/ic_notif_repeat_all',
            LoopMode.one => 'drawable/ic_notif_repeat_one',
            _ => 'drawable/ic_notif_repeat_off',
          },
          label: 'Repeat',
          name: 'notif_repeat',
        ),
      ],
      androidCompactActionIndices: const [1, 2, 3],
      // SEEK is what makes the notification seekbar scrubbable.
      // Without it Android shows progress display-only.
      systemActions: const {MediaAction.seek},
      processingState: switch (_player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    );
  }

  /// Notification shuffle/repeat land here. Engine flips first, then
  /// the loop/shuffle streams re-publish state (icons) and the
  /// providers sync prefs off those same streams — one truth.
  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    switch (name) {
      case 'notif_shuffle':
        final v = !_player.shuffleModeEnabled;
        // Paint first, reshuffle behind: setShuffleEnabled awaits a
        // full queue reorder, which is what made the icon feel stuck.
        _republish(shuffle: v);
        await setShuffleEnabled(v);
        ArchLog.i('player', 'notif shuffle=$v');
      case 'notif_repeat':
        final v = LoopMode.values[(_player.loopMode.index + 1) % 3];
        _republish(loop: v);
        await setLoopMode(v);
        ArchLog.i('player', 'notif loop=$v');
    }
  }
}

extension on Song {
  /// No content:// artUri: the notification loader can stall on the
  /// resolver and take the whole post (and foreground protection)
  /// down with it. Art arrives file-backed via [_attachArtFile]
  /// instead — same preferred path previews already use.
  MediaItem toMediaItem() => MediaItem(
    id: uri.toString(),
    title: title,
    artist: artist,
    album: album,
    duration: duration.inMilliseconds <= 0 ? null : duration,
    artUri: null,
    extras: {'songId': id, 'albumId': albumId},
  );
}
