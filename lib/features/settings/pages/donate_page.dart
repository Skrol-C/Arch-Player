import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/log.dart';
import '../widgets/setting_bits.dart';

/// Donate: why money matters and where it goes. No payment wiring —
/// this screen states the intent and the one channel; when the
/// funding link lands, it lands here.
class DonatePage extends StatelessWidget {
  const DonatePage({super.key});

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'donate open');
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Donate')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFFFC3C44),
                          Color(0xFFB3122E),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.favorite_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Keep Arch independent',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Arch Player is built by one developer, with no '
                    'ads, no trackers, and no investors. Donations pay '
                    'for devices to test on and the hours in between.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SettingGroup(
            title: 'Ways to give',
            children: [
              SettingRow(
                icon: Icons.link_rounded,
                title: 'Funding link',
                subtitle: 'Coming soon — this row lights up first',
                onTap: () {
                  HapticFeedback.selectionClick();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Funding link is being set up — thank you '
                        'for wanting to help',
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
