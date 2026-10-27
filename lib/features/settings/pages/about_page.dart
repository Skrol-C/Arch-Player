import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/log.dart';
import '../widgets/setting_bits.dart';
import 'changelog_page.dart';
import 'updater_page.dart';

/// About: who builds Arch, what version this is, and what it stands
/// on. The lead developer card caches its portrait and falls back to
/// initials offline. Attributions name every engine and package that
/// does real work inside the app.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _version = '${info.version}+${info.buildNumber}';
        });
      }
    } catch (e) {
      ArchLog.w('about', 'version read failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'about open');
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 60,
                      height: 60,
                      child: CachedNetworkImage(
                        imageUrl: 'https://github.com/Skrol-C.png',
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            const _InitialsFace(),
                        errorWidget: (_, _, _) =>
                            const _InitialsFace(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Skrol-C',
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Lead developer & creator',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                        if (_version.isNotEmpty)
                          Text(
                            'Arch Player $_version',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SettingGroup(
            title: 'Build',
            children: [
              const SettingRow(
                icon: Icons.system_update_rounded,
                title: 'Check for updates',
                subtitle: 'Newest build + what changed',
                push: UpdaterPage(),
              ),
              const SettingRow(
                icon: Icons.history_rounded,
                title: 'What’s new',
                subtitle: 'Commits bundled with this build',
                push: ChangelogPage(),
              ),
            ],
          ),
          const SettingGroup(
            title: 'Stands on',
            children: [
              SettingRow(
                icon: Icons.audiotrack_rounded,
                title: 'FFmpeg',
                subtitle: 'Decoding, transcoding, format sniffing',
              ),
              SettingRow(
                icon: Icons.play_circle_rounded,
                title: 'just_audio + audio_service',
                subtitle: 'Playback engine + background controls',
              ),
              SettingRow(
                icon: Icons.memory_rounded,
                title: 'Rust core (Needle)',
                subtitle: 'Sandboxed extensions, DSP analysis',
              ),
              SettingRow(
                icon: Icons.extension_rounded,
                title: 'Open packages',
                subtitle: 'Riverpod, cached_network_image, file_picker, '
                    'share_plus, path_provider, permission_handler, '
                    'flutter_rust_bridge, archive, webview_flutter, yaml',
              ),
              SettingRow(
                icon: Icons.cloud_rounded,
                title: 'Metadata lanes',
                subtitle: 'MusicBrainz · Deezer · Last.fm · fanart.tv · '
                    'iTunes · GetSongBPM · LRCLib',
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Arch Player — the most visual player on Android. '
              'Art is the front matter; nothing important renders '
              'without artwork.',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InitialsFace extends StatelessWidget {
  const _InitialsFace();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      alignment: Alignment.center,
      child: Text(
        'S',
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
