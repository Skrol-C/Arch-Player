import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'log_screen.dart';
import 'needle_teaser.dart';

/// Settings hub: Apple-grouped white cards. Full map — working rows act,
/// future rows open designed teaser panels. Nothing dead, nothing shouty.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'settings open');
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 72, 20, 160),
      children: const [
        FocalEntrance(
          child: Text('Settings', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
        ),
        SizedBox(height: 16),
        _Group(title: 'Library', children: [
          _Row(
            icon: Icons.folder_rounded,
            title: 'Music folders',
            subtitle: 'Counts, toggles and adding live in Library',
            route: _SoonRoute(label: 'Folder management lives in Library › Folders'),
          ),
          _Row(
            icon: Icons.refresh_rounded,
            title: 'Rescan library',
            subtitle: 'Pick up new and removed files',
            route: _SoonRoute(label: 'Rescan arrives with the library engine'),
          ),
          _Row(
            icon: Icons.image_rounded,
            title: 'Artwork cache',
            subtitle: 'Sizes and clearing live here when art lands',
            route: _SoonRoute(label: 'Art cache controls arrive with artwork'),
          ),
        ]),
        _Group(title: 'Metadata', children: [
          _Row(
            icon: Icons.hub_rounded,
            title: 'Providers',
            subtitle: 'MusicBrainz · Deezer · Last.fm status',
            route: _SoonRoute(label: 'Provider status arrives with enrichment'),
          ),
        ]),
        _Group(title: 'Downloads', children: [
          _Row(
            icon: Icons.download_rounded,
            title: 'Needle',
            subtitle: 'Quality, queue, storage — the one-stop shop',
            push: NeedleTeaser(),
          ),
        ]),
        _Group(title: 'Playback', children: [
          _Row(
            icon: Icons.bedtime_rounded,
            title: 'Background playback',
            subtitle: 'Exemption, crossfade and gapless on arrival',
            route: _SoonRoute(label: 'Playback controls arrive with the engine'),
          ),
        ]),
        _Group(title: 'Diagnostics', children: [
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
            route: _SoonRoute(label: 'Arch Player v2 · Needle coming soon'),
          ),
        ]),
      ],
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
          child: Text(title.toUpperCase(),
              style: const TextStyle(
                  color: inkDim, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6)),
        ),
        Container(
          decoration: BoxDecoration(
            color: paperRaised,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? push;
  final _SoonRoute? route;

  const _Row({required this.icon, required this.title, required this.subtitle, this.push, this.route});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: paper, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: archPink),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, maxLines: 2, style: const TextStyle(color: inkDim, fontSize: 13)),
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
              'This arrives with its engine slice. Nothing here is a dead end — it just isn\u2019t built yet.',
              style: TextStyle(color: inkDim, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
