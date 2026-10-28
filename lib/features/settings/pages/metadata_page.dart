import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import '../../metadata/metadata_providers.dart';
import '../widgets/arch_switch.dart';
import '../widgets/setting_bits.dart';

/// Metadata: which lane every fact comes from, plus the one display
/// toggle the song page actually reads. Lanes are informational only.
/// each row names its source so credit is never ambient.
class MetadataPage extends ConsumerWidget {
  const MetadataPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'metadata settings open');
    final showMusical = ref.watch(showMusicalProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Metadata')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          SettingGroup(
            title: 'Display',
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
                    Icons.graphic_eq_rounded,
                    color: Color(0xFFFC3C44),
                  ),
                ),
                title: const Text(
                  'Harmonic section',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  showMusical
                      ? 'On, BPM and key show on song pages'
                      : 'Off, harmonic details hidden',
                  maxLines: 2,
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                trailing: ArchSwitch(
                  value: showMusical,
                  onChanged: (_) => ref
                      .read(showMusicalProvider.notifier)
                      .toggle(),
                ),
                onTap: () => ref
                    .read(showMusicalProvider.notifier)
                    .toggle(),
              ),
            ],
          ),
          const SettingGroup(
            title: 'Providers',
            children: [
              SettingRow(
                icon: Icons.fingerprint_rounded,
                title: 'MusicBrainz',
                subtitle: 'Identity + discography, 1 req/s gated',
              ),
              SettingRow(
                icon: Icons.portrait_rounded,
                title: 'Deezer',
                subtitle: 'Portraits, fans, top tracks, track numbers',
              ),
              SettingRow(
                icon: Icons.article_rounded,
                title: 'Last.fm',
                subtitle: 'Biographies',
              ),
              SettingRow(
                icon: Icons.image_rounded,
                title: 'fanart.tv',
                subtitle: 'Hi-res thumbs + true artist wordmarks',
              ),
              SettingRow(
                icon: Icons.album_rounded,
                title: 'iTunes',
                subtitle: 'Release facts where Deezer draws blank',
              ),
              SettingRow(
                icon: Icons.speed_rounded,
                title: 'GetSongBPM',
                subtitle: 'Tempo + key when tags carry neither',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
