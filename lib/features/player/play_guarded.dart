import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/log.dart';
import 'player_providers.dart';
import 'player_screen.dart';

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

/// One open path for every surface (mini bars, pills, search hits,
/// guarded plays). The player overlay lives in the shell stack,
/// which pushed pages cover — so above the shell the player goes
/// out as a fullscreen route instead of opening invisibly
/// underneath (the old bug: docks hid, no player appeared).
/// Fire-and-forget by design: callers never await the player's
/// lifetime. Double taps collapse into one route.
bool _playerRouteOpen = false;

void openPlayer(WidgetRef ref, BuildContext context) {
  if (!ref.read(playerOpenProvider)) {
    ref.read(playerOpenProvider.notifier).state = true;
  }
  final route = ModalRoute.of(context);
  if (route == null || route.isFirst || _playerRouteOpen) return;
  if (!context.mounted) return;
  _playerRouteOpen = true;
  ref.read(playerRouteOpenProvider.notifier).state = true;
  unawaited(
    Navigator.of(context)
        .push<bool>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => const PlayerScreen(),
          ),
        )
        .then((_) {
      _playerRouteOpen = false;
      // The route may outlive the widget that opened it (dispose
      // during playback): ref reads then throw. Guard, don't crash.
      try {
        ref.read(playerRouteOpenProvider.notifier).state = false;
        ref.read(playerOpenProvider.notifier).state = false;
      } catch (_) {}
    }),
  );
}

/// Crash-card escape: clears both flags when a route push/pop dies
/// mid-flight and leaves the dock hidden with no player on top.
void resetPlayerFlags(WidgetRef ref) {
  _playerRouteOpen = false;
  ref.read(playerRouteOpenProvider.notifier).state = false;
  ref.read(playerOpenProvider.notifier).state = false;
}

/// One close path: flag off everywhere, pop only when the player is
/// out as a route. The shell overlay IS the first route, so it
/// needs no pop — popping there would kill the app.
void closePlayer(WidgetRef ref, BuildContext context) {
  ref.read(playerOpenProvider.notifier).state = false;
  final route = ModalRoute.of(context);
  if (route != null && !route.isFirst) {
    Navigator.of(context).pop();
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
  openPlayer(ref, context);
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
