import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/log.dart';
import 'player_providers.dart';

/// Every play tap funnels here: failures become a snackbar, never a
/// wedged player or a red screen. playSong throws by design (timeouts).
Future<void> playGuarded(
  BuildContext context,
  Future<void> Function() play,
) async {
  try {
    await play();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play this track')),
      );
    }
  }
}

/// The single play entry for the whole app: the player screen opens
/// FIRST so every tap answers instantly, and the (possibly slow) queue
/// swap resolves behind it. Never await play before opening - a tap
/// that answers seconds later reads as broken.
Future<void> playAndOpen(
  WidgetRef ref,
  BuildContext context,
  Future<void> Function() play,
) async {
  ref.read(playerOpenProvider.notifier).state = true;
  unawaited(_ensureNotification(context));
  await playGuarded(context, play);
}

bool _notifChecked = false;

/// Once per session: if notifications are denied, playback controls
/// can never appear - say so with a way out, not silence.
Future<void> _ensureNotification(BuildContext context) async {
  if (_notifChecked) return;
  _notifChecked = true;
  try {
    final s = await Permission.notification.status;
    if (!s.isGranted && context.mounted) {
      ArchLog.w(
        'player',
        'notification permission denied - controls cannot post',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Allow notifications for playback controls'),
          action: SnackBarAction(
            label: 'Settings',
            onPressed: () => openAppSettings(),
          ),
        ),
      );
    }
  } catch (_) {}
}
