import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/theme.dart';
import '../library/library_providers.dart';
import '../needle/download_page.dart';
import '../needle/extensions_page.dart';
import '../needle/repo_page.dart';
import '../profile/profile_pic.dart';
import '../profile/profile_screen.dart';
import '../shell/dock.dart';
import 'log_screen.dart';
import 'pages/about_page.dart';
import 'pages/app_page.dart';
import 'pages/appearance_page.dart';
import 'pages/backup_page.dart';
import 'pages/cache_page.dart';
import 'pages/donate_page.dart';
import 'pages/files_page.dart';
import 'pages/library_page.dart';
import 'pages/lyrics_page.dart';
import 'pages/metadata_page.dart';
import 'pages/playback_page.dart';
import 'pages/shortcuts_page.dart';
import 'pages/updater_page.dart';
import 'widgets/setting_bits.dart';

/// Settings hub: five cards, search across every entry, profile
/// header. Every row lands somewhere real. No teasers, no dead
/// ends. Playback houses automix; Logs and Cache are full screens.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _Entry {
  final String card;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;

  const _Entry({
    required this.card,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.page,
  });
}

final _entries = [
  _Entry(
    card: 'System',
    icon: Icons.library_music_rounded,
    title: 'Library',
    subtitle: 'Scan state, counts, rescan',
    page: LibraryPage(),
  ),
  _Entry(
    card: 'System',
    icon: Icons.hub_rounded,
    title: 'Metadata',
    subtitle: 'Provider lanes plus display',
    page: MetadataPage(),
  ),
  _Entry(
    card: 'System',
    icon: Icons.lyrics_rounded,
    title: 'Lyrics',
    subtitle: 'Resolution order plus haptics',
    page: LyricsPage(),
  ),
  _Entry(
    card: 'System',
    icon: Icons.tune_rounded,
    title: 'Playback',
    subtitle: 'Automix, shuffle, repeat, autoplay, video',
    page: PlaybackPage(),
  ),
  _Entry(
    card: 'Needle',
    icon: Icons.extension_rounded,
    title: 'Extensions',
    subtitle: 'Providers plug in here, sandboxed',
    page: ExtensionsPage(),
  ),
  _Entry(
    card: 'Needle',
    icon: Icons.store_rounded,
    title: 'Repositories',
    subtitle: 'Community default preloaded',
    page: RepoPage(),
  ),
  _Entry(
    card: 'Needle',
    icon: Icons.download_rounded,
    title: 'Downloads',
    subtitle: 'Where Needle files land',
    page: DownloadPage(),
  ),
  _Entry(
    card: 'Needle',
    icon: Icons.folder_rounded,
    title: 'Files',
    subtitle: 'Music folders plus Needle storage',
    page: FilesPage(),
  ),
  _Entry(
    card: 'Personalize',
    icon: Icons.palette_rounded,
    title: 'Appearance',
    subtitle: 'Theme plus AMOLED, tap a phone to apply',
    page: AppearancePage(),
  ),
  _Entry(
    card: 'Personalize',
    icon: Icons.phone_android_rounded,
    title: 'App',
    subtitle: 'Battery, notifications, system',
    page: AppPage(),
  ),
  _Entry(
    card: 'Care',
    icon: Icons.bolt_rounded,
    title: 'Shortcuts',
    subtitle: 'One-tap actions',
    page: ShortcutsPage(),
  ),
  _Entry(
    card: 'Care',
    icon: Icons.cleaning_services_rounded,
    title: 'Cache',
    subtitle: 'Sizes plus clearing, nothing owned lost',
    page: CachePage(),
  ),
  _Entry(
    card: 'Care',
    icon: Icons.backup_rounded,
    title: 'Backup',
    subtitle: 'Playlists out and back in',
    page: BackupPage(),
  ),
  _Entry(
    card: 'Care',
    icon: Icons.volunteer_activism_rounded,
    title: 'Donate',
    subtitle: 'Keep Arch independent',
    page: DonatePage(),
  ),
  _Entry(
    card: 'Care',
    icon: Icons.receipt_long_rounded,
    title: 'Logs',
    subtitle: 'What the app has been doing',
    page: LogScreen(),
  ),
  _Entry(
    card: 'Care',
    icon: Icons.info_outline_rounded,
    title: 'About',
    subtitle: 'Developer, version, updates, credit',
    page: AboutPage(),
  ),
  _Entry(
    card: 'Care',
    icon: Icons.system_update_rounded,
    title: 'Updates',
    subtitle: 'Newest build plus what changed',
    page: UpdaterPage(),
  ),
];

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'settings open');
    final scheme = Theme.of(context).colorScheme;
    final songs = ref.watch(songsProvider).value ?? [];
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? _entries
        : _entries
              .where(
                (e) =>
                    e.title.toLowerCase().contains(q) ||
                    e.subtitle.toLowerCase().contains(q),
              )
              .toList();
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 4,
        title: LiquidGlassLens(
          style:
              ArchGlass.circle(radius: 24, amoled: isAmoledScheme(context)),
          child: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(
              CupertinoIcons.chevron_left,
              color: scheme.onSurface,
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 160),
            children: [
              _ProfileHeader(trackCount: songs.length),
              const SizedBox(height: 12),
              TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search settings',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                  ),
                ),
              ),
              if (shown.isEmpty)
                SettingState.empty(
                  'Nothing matches that search.',
                )
              else
                for (final card in _cardsInOrder(shown))
                  SettingGroup(
                    title: card,
                    children: [
                      for (final e in shown.where(
                        (x) => x.card == card,
                      ))
                        SettingRow(
                          icon: e.icon,
                          title: e.title,
                          subtitle: e.subtitle,
                          push: e.page,
                        ),
                    ],
                  ),
            ],
          ),
          const NowPlayingDock(),
        ],
      ),
    );
  }
}

List<String> _cardsInOrder(List<_Entry> shown) {
  const order = [
    'System',
    'Needle',
    'Personalize',
    'Care',
  ];
  return [
    for (final c in order)
      if (shown.any((e) => e.card == c)) c,
  ];
}

class _ProfileHeader extends ConsumerWidget {
  final int trackCount;

  const _ProfileHeader({required this.trackCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final pic = ref.watch(profilePicProvider);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
      },
      child: Row(
        children: [
          ClipOval(
            child: SizedBox(
              width: 52,
              height: 52,
              child: pic != null && File(pic).existsSync()
                  ? Image.file(File(pic), fit: BoxFit.cover)
                  : Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.person_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Settings',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '$trackCount tracks in your library',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
