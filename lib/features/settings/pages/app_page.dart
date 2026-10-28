import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/log.dart';
import '../widgets/setting_bits.dart';

/// App: system-facing grants and identity. Battery exemption keeps
/// background audio alive on aggressive OEMs; notifications own the
/// playback controls. Both re-check on return, never naggy.
class AppPage extends ConsumerWidget {
  const AppPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ArchLog.i('nav', 'app settings open');
    return Scaffold(
      appBar: AppBar(title: const Text('App')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: const [
          SettingGroup(
            title: 'System',
            children: [_BatteryRow(), _NotifRow()],
          ),
        ],
      ),
    );
  }
}

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
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          exempt == true
              ? Icons.battery_full_rounded
              : Icons.battery_alert_rounded,
          color: const Color(0xFFFC3C44),
        ),
      ),
      title: const Text(
        'Background playback',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        exempt == null
            ? 'Checking…'
            : exempt
            ? 'Unrestricted, survives the background'
            : 'Restricted, tap to allow background play',
        maxLines: 2,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: scheme.onSurfaceVariant,
      ),
      onTap: () async {
        try {
          final before =
              await Permission.ignoreBatteryOptimizations.status;
          await Permission.ignoreBatteryOptimizations.request();
          await _check();
          final after =
              await Permission.ignoreBatteryOptimizations.status;
          ArchLog.i(
            'settings',
            'battery exemption: was=${before.isGranted} now=${after.isGranted}',
          );
          if (!after.isGranted && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'System screen did not open, allow it manually',
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
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          granted == true
              ? Icons.notifications_active_rounded
              : Icons.notifications_off_rounded,
          color: const Color(0xFFFC3C44),
        ),
      ),
      title: const Text(
        'Playback notifications',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        granted == null
            ? 'Checking…'
            : granted
            ? 'On, controls appear while playing'
            : 'Off, tap to enable in settings',
        maxLines: 2,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: scheme.onSurfaceVariant,
      ),
      onTap: () async {
        if (granted != true) await openAppSettings();
        await _check();
      },
    );
  }
}
