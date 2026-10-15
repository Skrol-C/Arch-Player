import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../player/play_guarded.dart';
import '../player/player_providers.dart';
import 'extensions.dart';
import 'needle_core.dart';
import 'sandbox.dart';

/// Tap-to-preview for search rows: preview URL off the hit, else the
/// provider's getTrack(id) entry under timeout, then the guarded
/// player entry. No URL anywhere = honest snackbar naming the
/// provider, never silence.
Future<void> playSearchPreview(
  WidgetRef ref,
  BuildContext context, {
  required String providerId,
  required String providerName,
  required String trackId,
  required String title,
  required String artist,
  required String album,
  required String art,
  required String previewUrl,
}) async {
  var url = previewUrl;
  if (url.isEmpty && providerId.isNotEmpty && trackId.isNotEmpty) {
    url = await _viaGetTrack(providerId, trackId) ?? '';
  }
  if (url.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No preview from $providerName')),
      );
    }
    ArchLog.i('search', 'no preview url ($providerId:$trackId)');
    return;
  }
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https')) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preview link unusable')),
      );
    }
    return;
  }
  var previewId = 0;
  for (final c in '$providerId:$trackId'.codeUnits) {
    previewId = ((previewId * 31) + c) & 0x7fffffff;
  }
  final handler = ref.read(audioHandlerProvider);
  if (!context.mounted) return;
  await playAndOpen(
    ref,
    context,
    () => handler.playPreview(
      uri: uri,
      title: title,
      artist: artist,
      album: album,
      coverUrl: art.isEmpty ? null : art,
      previewId: previewId,
    ),
  );
}

Future<String?> _viaGetTrack(String providerId, String trackId) async {
  if (!Needle.ready) return null;
  try {
    final h = await loadExtension(providerId);
    final fns = await extensionFunctions(h.handle);
    if (!fns.contains('getTrack')) return null;
    final out = await callExtensionFn(h.handle, 'getTrack', [trackId],
        timeoutMs: 15000);
    final value = out['value'];
    Map? m;
    if (value is Map) {
      m = (value['track'] is Map ? value['track'] : value) as Map;
    }
    if (m == null) return null;
    for (final k in ['preview_url', 'previewUrl', 'preview']) {
      final v = m[k]?.toString() ?? '';
      if (v.startsWith('http://') || v.startsWith('https://')) return v;
    }
    return null;
  } on NeedleException catch (e) {
    ArchLog.w('search', 'getTrack preview failed: ${e.code}');
    return null;
  }
}
