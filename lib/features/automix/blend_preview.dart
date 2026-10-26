// Baked-blend lab trigger: render a bridge from the now-playing track
// into a target song and play it back as a preview. Explicitly a lab
// tool — failures surface as snackbars, the queue is replaced by the
// preview (playPreview semantics), and automix must be off first so
// two transports never speak at once. Removed or promoted when the
// baked pipeline lands.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/models.dart';
import '../metadata/metadata_providers.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'baked_blend.dart';
import 'crossfade.dart' show blendBars;

/// Render current -> [target] and play the bridge. Fire-and-forget.
Future<void> renderBlendPreview(
  WidgetRef ref,
  BuildContext context,
  Song target,
) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String m) {
    if (context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(m)));
    }
  }

  final handler = ref.read(audioHandlerProvider);
  final current = ref.read(currentSongProvider).value;
  if (current == null) {
    say('Play something first — the blend starts there');
    return;
  }
  if (current.id == target.id) {
    say('Pick a different song to blend into');
    return;
  }
  if (ref.read(autoMixProvider)) {
    say('Turn automix off first — one transport at a time');
    return;
  }
  if (current.path.isEmpty || target.path.isEmpty) {
    say('Blend needs local files on both sides');
    return;
  }
  final meta = ref.read(metadataServiceProvider);
  final a = meta.musicalInfoCached(
    title: current.title,
    artist: current.artist,
    path: current.path,
  );
  final b = meta.musicalInfoCached(
    title: target.title,
    artist: target.artist,
    path: target.path,
  );
  final bpmA = a?.bpm;
  final bpmB = b?.bpm;
  if (bpmA == null || bpmB == null) {
    say('Need BPM on both — play each song once first');
    ArchLog.i(
      'automix',
      'blend lab missing bpm: ${current.title}=$bpmA '
      '${target.title}=$bpmB',
    );
    return;
  }
  say('Rendering blend…');
  final bars = blendBars(
    openA: a?.openKey,
    openB: b?.openKey,
    bpmA: bpmA,
    bpmB: bpmB,
    durA: current.duration.inMilliseconds / 1000.0,
    durB: target.duration.inMilliseconds / 1000.0,
  );
  final va = meta.vocalSectionsCached(
    title: current.title,
    artist: current.artist,
  );
  final vb = meta.vocalSectionsCached(
    title: target.title,
    artist: target.artist,
  );
  ArchLog.i(
    'automix',
    'blend lab bars=$bars vocalsA=${va?.length} vocalsB=${vb?.length} '
    '${current.title} -> ${target.title}',
  );
  final out = await renderBlend(
    BlendSpec(
      aPath: current.path,
      bPath: target.path,
      durA: current.duration.inMilliseconds / 1000.0,
      durB: target.duration.inMilliseconds / 1000.0,
      bpmA: bpmA,
      bpmB: bpmB,
      phaseA: a?.phase,
      phaseB: b?.phase,
      firstSoundB: b?.firstSound,
      vocalA: va,
      vocalB: vb,
      bars: bars,
    ),
    tag: '${current.id}_${target.id}',
  );
  if (!context.mounted) return;
  if (out == null) {
    say('Blend failed — live crossfade it is');
    return;
  }
  say('Playing blend preview');
  await playGuarded(
    context,
    () => handler.playPreview(
      uri: Uri.file(out),
      title: 'Blend: ${current.title} → ${target.title}',
      artist: current.artist,
      album: 'Baked blend (lab)',
      coverUrl: null,
      previewId: -1999999,
    ),
  );
}
