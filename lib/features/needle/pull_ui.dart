import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../library/library_providers.dart';
import 'extension.dart';
import 'pull.dart';
import 'sandbox.dart';
import 'session_grant.dart';
import 'verify_sheet.dart';

/// Shared pull flow with the verify-grant round-trip: pick provider,
/// pull, surface honest states. Returns true when the track landed.
/// Callers own their spinners; this owns snackbars + the re-pull.
Future<bool> pullWithVerify(
  BuildContext context,
  WidgetRef ref, {
  required InstalledExtension? provider,
  required String providerName,
  required String title,
  required String artist,
  required String isrc,
}) async {
  if (provider == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No download provider enabled')),
      );
    }
    return false;
  }
  HapticFeedback.selectionClick();
  try {
    await pullTrack(
      provider: provider,
      title: title,
      artist: artist,
      isrc: isrc,
    );
    HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(seconds: 2));
    ref.invalidate(songsProvider);
    return true;
  } on NeedleException catch (e) {
    if (!context.mounted) return false;
    if (e.code == 'verify-required') {
      final inlineUrl = e.message.startsWith('auth_url=')
          ? e.message.substring('auth_url='.length)
          : '';
      final url =
          await SessionGrant.resolveAuthUrl(provider.id, inlineUrl);
      if (!context.mounted) return false;
      if (url == null || url.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Verification needed (no URL)')),
        );
        return false;
      }
      final granted = await handleVerifyRequired(
        context,
        extId: provider.id,
        displayName: provider.displayName,
        authUrl: url,
      );
      if (granted && context.mounted) {
        return pullWithVerify(
          context,
          ref,
          provider: provider,
          providerName: providerName,
          title: title,
          artist: artist,
          isrc: isrc,
        );
      }
      return false;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (e.code) {
          'unavailable' => 'Not available from $providerName',
          _ => 'Pull failed. Try again.',
        }),
      ),
    );
    ArchLog.w('needle', 'pull failed: ${e.code} ${e.message}');
    return false;
  }
}
