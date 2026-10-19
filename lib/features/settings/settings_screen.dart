import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/glass.dart';
import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../needle/download_page.dart';
import '../needle/extensions_page.dart';
import '../needle/repo_page.dart';
import '../shell/dock.dart';
import 'log_screen.dart';
import 'needle_teaser.dart';

/// Settings hub: Apple-grouped white cards. Full map - working rows act,
/// future rows open designed teaser panels. Nothing dead, nothing shouty.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'settings open');
    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        backgroundColor: paper,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 4,
        title: LiquidGlassLens(
          style: ArchGlass.circle(radius: 24),
          child: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon:
                const Icon(CupertinoIcons.chevron_left, color: ink),
          ),
        ),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 160),
      children: [
        FocalEntrance(
          child: Text(
            'Settings',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(height: 16),
        _Group(
          title: 'Library',
          children: [
            _Row(
              icon: Icons.folder_rounded,
              title: 'Music folders',
              subtitle: 'Counts, toggles and adding live in Library',
              route: _SoonRoute(
                label: 'Folder management lives in Library > Folders',
              ),
            ),
            _Row(
              icon: Icons.refresh_rounded,
              title: 'Rescan library',
              subtitle: 'Pick up new and removed files',
              route: _SoonRoute(
                label: 'Rescan arrives with the library engine',
              ),
            ),
            _Row(
              icon: Icons.image_rounded,
              title: 'Artwork cache',
              subtitle: 'Sizes and clearing live here when art lands',
              route: _SoonRoute(
                label: 'Art cache controls arrive with artwork',
              ),
            ),
          ],
        ),
        _Group(
          title: 'Metadata',
          children: [
            _Row(
              icon: Icons.hub_rounded,
              title: 'Providers',
              subtitle: 'MusicBrainz - Deezer - Last.fm status',
              route: _SoonRoute(
                label: 'Provider status arrives with enrichment',
              ),
            ),
          ],
        ),
        _Group(
          title: 'Downloads',
          children: [
            _Row(
              icon: Icons.extension_rounded,
              title: 'Extensions',
              subtitle: 'Providers plug in here - sandboxed',
              push: ExtensionsPage(),
            ),
            _Row(
              icon: Icons.store_rounded,
              title: 'Repositories',
              subtitle: 'Community default preloaded',
              push: RepoPage(),
            ),
            _Row(
              icon: Icons.tune_rounded,
              title: 'Download prefs',
              subtitle: 'Quality tier and storage folder',
              push: DownloadPage(),
            ),
            _Row(
              icon: Icons.download_rounded,
              title: 'Needle',
              subtitle: 'Quality, queue, storage - the one-stop shop',
              push: NeedleTeaser(),
            ),
          ],
        ),
        _Group(title: 'Playback', children: [_BatteryRow(), _NotifRow()]),
        _Group(
          title: 'Diagnostics',
          children: [
            _Row(
              icon: Icons.receipt_long_rounded,
              title: 'View log',
              subtitle: 'What the app has been doing',
              push: LogScreen(),
            ),
            _Row(
              icon: Icons.info_outline_rounded,
              title: 'About',
              subtitle: 'Version and the Arch promise',
              route: _SoonRoute(label: 'Arch Player v2 - Needle coming soon'),
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

class _Group extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Group({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: inkDim,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Material(
          // Material owns the group background (not a DecoratedBox) so
          // each ListTile's ink splash has a canvas and never hides.
          color: paperRaised,
          borderRadius: BorderRadius.circular(20),
          child: Column(children: children),
        ),
      ],
    );
  }
}

/// Battery exemption: Honor-class killers murder background audio
/// without it. One tap opens the system screen; status re-checks on
/// return. Never naggy - one row, honest copy.
class _BatteryRow extends StatefulWidget {
  const _BatteryRow();

  @override
  State<_BatteryRow> createState() => _BatteryRowState();
}

class _BatteryRowState extends State<_BatteryRow> {
  bool? _exempt;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final s = await Permission.ignoreBatteryOptimizations.status;
    if (mounted) setState(() => _exempt = s.isGranted);
  }

  @override
  Widget build(BuildContext context) {
    final exempt = _exempt;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: paper,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          exempt == true
              ? Icons.battery_full_rounded
              : Icons.battery_alert_rounded,
          color: archPink,
        ),
      ),
      title: const Text(
        'Background playback',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        exempt == null
            ? 'Checking...'
            : exempt
            ? 'Unrestricted - survives the background'
            : 'Restricted - tap to allow background play',
        maxLines: 2,
        style: const TextStyle(color: inkDim, fontSize: 13),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: inkDim),
      onTap: () async {
        HapticFeedback.selectionClick();
        // Honor-class devices often lack the standard intent: the call
        // returns silently with nothing shown. Log the outcome and
        // fall back to the app's system page, which always exists.
        try {
          final before = await Permission.ignoreBatteryOptimizations.status;
          await Permission.ignoreBatteryOptimizations.request();
          await _check();
          final after = await Permission.ignoreBatteryOptimizations.status;
          ArchLog.i(
            'settings',
            'battery exemption: was=${before.isGranted} now=${after.isGranted}',
          );
          if (!after.isGranted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'System screen did not open - allow it manually',
                ),
                action: SnackBarAction(
                  label: 'Settings',
                  onPressed: () => openAppSettings(),
                ),
              ),
            );
          }
        } catch (e) {
          ArchLog.w('settings', 'battery exemption failed: $e');
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Could not open system screen'),
              action: SnackBarAction(
                label: 'Settings',
                onPressed: () => openAppSettings(),
              ),
            ),
          );
        }
      },
    );
  }
}

class _NotifRow extends StatefulWidget {
  const _NotifRow();

  @override
  State<_NotifRow> createState() => _NotifRowState();
}

class _NotifRowState extends State<_NotifRow> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final s = await Permission.notification.status;
    if (mounted) setState(() => _granted = s.isGranted);
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: paper,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          granted == true
              ? Icons.notifications_active_rounded
              : Icons.notifications_off_rounded,
          color: archPink,
        ),
      ),
      title: const Text(
        'Playback notifications',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        granted == null
            ? 'Checking...'
            : granted
            ? 'On - controls appear while playing'
            : 'Off - tap to enable in settings',
        maxLines: 2,
        style: const TextStyle(color: inkDim, fontSize: 13),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: inkDim),
      onTap: () async {
        HapticFeedback.selectionClick();
        if (granted != true) await openAppSettings();
        await _check();
      },
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? push;
  final _SoonRoute? route;

  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.push,
    this.route,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: paper,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: archPink),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        style: const TextStyle(color: inkDim, fontSize: 13),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: inkDim),
      onTap: () {
        final target = push ?? route?.page;
        if (target == null) return;
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => target));
      },
    );
  }
}

/// A designed teaser panel: calm title, quiet copy, never a dead end.
class _SoonRoute {
  final String label;
  const _SoonRoute({required this.label});

  Widget get page => _SoonPage(label: label);
}

class _SoonPage extends StatelessWidget {
  final String label;
  const _SoonPage({required this.label});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Soon')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'This arrives with its engine slice. Nothing here is a dead end - it just isn\u2019t built yet.',
              style: TextStyle(color: inkDim, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
