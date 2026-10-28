import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../settings/update_service.dart';
import '../settings/widgets/update_dialog.dart';

/// Silent launch check: once per frame budget, never blocking. When a
/// newer release exists the glass dialog lands on top of the shell —
/// urgent (breaking or out of skips) or polite with a Later count.
class UpdateGate extends ConsumerStatefulWidget {
  const UpdateGate({super.key});

  @override
  ConsumerState<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends ConsumerState<UpdateGate> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (_done || !mounted) return;
    _done = true;
    try {
      final info = await checkForUpdate();
      if (info == null || !mounted) return;
      ArchLog.i('updater',
          'update prompt: ${info.current} -> ${info.version} (forced=${info.forced})');
      await showUpdateDialog(context, info: info);
    } catch (e) {
      ArchLog.i('updater', 'gate failed silently: $e');
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
