import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import '../../library/library_providers.dart';
import '../../player/player_providers.dart';
import '../widgets/setting_bits.dart';

/// Shortcuts: one-tap actions for the things people reach for mid-day.
/// Every tile does its job immediately — no configuration screens,
/// no dead ends.
class ShortcutsPage extends ConsumerWidget {
  const ShortcutsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'shortcuts open');
    final automix = ref.watch(autoMixProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Shortcuts')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Quick actions',
            children: [
              _Action(
                icon: Icons.refresh_rounded,
                title: 'Rescan library',
                subtitle: 'Pick up new and removed files',
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.invalidate(songsProvider);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Rescanning the library…'),
                    ),
                  );
                },
              ),
              _Action(
                icon: Icons.tune_rounded,
                title: automix ? 'Stop automix' : 'Start automix',
                subtitle: automix
                    ? 'Back to playing as queued'
                    : 'Harmonic flow between tracks',
                onTap: () =>
                    ref.read(autoMixProvider.notifier).toggle(),
              ),
              _Action(
                icon: Icons.repeat_rounded,
                title: 'Cycle repeat',
                subtitle: 'Off → queue → track',
                onTap: () =>
                    ref.read(loopProvider.notifier).cycle(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _Action({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.bolt_rounded,
          color: Color(0xFFFC3C44),
        ),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
      trailing: Icon(
        Icons.play_arrow_rounded,
        color: scheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
