import 'package:flutter/material.dart';

/// Every play tap funnels here: failures become a snackbar, never a
/// wedged player or a red screen. playSong throws by design (timeouts).
Future<void> playGuarded(BuildContext context, Future<void> Function() play) async {
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
