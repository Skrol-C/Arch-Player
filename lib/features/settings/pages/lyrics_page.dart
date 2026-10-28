import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import '../../metadata/lyrics_providers.dart';
import '../widgets/arch_switch.dart';
import '../widgets/setting_bits.dart';

/// Lyrics: resolution order plus the haptic tick the lyric stage
/// actually reads. One order, stated plainly.
class LyricsPage extends ConsumerWidget {
  const LyricsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'lyrics settings open');
    final haptics = ref.watch(lyricHapticsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Lyrics')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Feel',
            children: [
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.vibration_rounded,
                    color: Color(0xFFFC3C44),
                  ),
                ),
                title: const Text(
                  'Haptic tick',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  haptics
                      ? 'On, a tap as lyric lines turn over'
                      : 'Off, lines turn silently',
                  maxLines: 2,
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                trailing: ArchSwitch(
                  value: haptics,
                  onChanged: (_) => ref
                      .read(lyricHapticsProvider.notifier)
                      .set(!haptics),
                ),
                onTap: () => ref
                    .read(lyricHapticsProvider.notifier)
                    .set(!haptics),
              ),
            ],
          ),
          const SettingGroup(
            title: 'Resolution order',
            children: [
              SettingRow(
                icon: Icons.touch_app_rounded,
                title: '1 · Your pick',
                subtitle: 'A Finder choice always wins the line',
              ),
              SettingRow(
                icon: Icons.tag_rounded,
                title: '2 · Embedded tags',
                subtitle: 'Synced or plain lyrics inside the file',
              ),
              SettingRow(
                icon: Icons.cloud_rounded,
                title: '3 · LRCLib network',
                subtitle: 'Synced search by artist, title, duration',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
