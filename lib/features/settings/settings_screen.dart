import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../library/library_providers.dart';

/// Minimal settings: folders entry, version. Needle teasers live here later.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(songsProvider).value ?? [];
    return ListView(
      padding: const EdgeInsets.only(bottom: 140),
      children: [
        const SizedBox(height: 56),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Settings', style: Theme.of(context).textTheme.headlineLarge),
        ),
        ListTile(
          title: const Text('Music folders'),
          subtitle: Text('${songs.length} songs in library'),
          trailing: const Text('Manage them from Library › Folders'),
        ),
        const _BatteryExemptionTile(),
        FutureBuilder(
          future: PackageInfo.fromPlatform(),
          builder: (context, snap) => ListTile(
            title: const Text('Version'),
            subtitle: Text(snap.data == null
                ? '…'
                : '${snap.data!.version} — Needle coming soon'),
          ),
        ),
      ],
    );
  }
}

/// Honor/Xiaomi-style killers murder background audio without this.
/// One system tap, asked once, never nagging.
class _BatteryExemptionTile extends StatefulWidget {
  const _BatteryExemptionTile();

  @override
  State<_BatteryExemptionTile> createState() => _BatteryExemptionTileState();
}

class _BatteryExemptionTileState extends State<_BatteryExemptionTile> {
  bool? _ignored;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (!mounted) return;
    setState(() => _ignored = status.isGranted);
  }

  Future<void> _ask() async {
    await Permission.ignoreBatteryOptimizations.request();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ignored = _ignored;
    return ListTile(
      title: const Text('Allow background playback'),
      subtitle: Text(ignored == null
          ? 'Checking…'
          : ignored
              ? 'Battery unrestricted — Arch survives the night'
              : 'Lets music keep playing with the screen off'),
      trailing: ignored == true
          ? const Icon(Icons.check_circle, color: Colors.green)
          : FilledButton.tonal(onPressed: _ask, child: const Text('Allow')),
      onTap: ignored == true ? null : _ask,
    );
  }
}
