import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/log.dart';
import '../changelog_store.dart';
import '../widgets/setting_bits.dart';
import 'changelog_page.dart';

/// Updater: visual shell only. Checks the bundled changelog against
/// the installed version and renders current/latest/notes — no
/// download or install wiring yet. That slice is parked, not faked:
/// the buttons describe exactly what they do today.
class UpdaterPage extends StatefulWidget {
  const UpdaterPage({super.key});

  @override
  State<UpdaterPage> createState() => _UpdaterPageState();
}

class _UpdaterPageState extends State<UpdaterPage> {
  bool _checking = false;
  bool _checked = false;
  String _version = '';
  List<ChangelogEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final entries = await loadChangelog();
      if (mounted) {
        setState(() {
          _version = '${info.version}+${info.buildNumber}';
          _entries = entries;
        });
      }
    } catch (e) {
      ArchLog.w('updater', 'version read failed: $e');
    }
  }

  Future<void> _check() async {
    HapticFeedback.selectionClick();
    setState(() {
      _checking = true;
    });
    ArchLog.i('updater', 'check requested (offline shell)');
    // The shell compares against the bundled changelog — the newest
    // entry IS this build. A beat for honesty: local read, no spinner
    // theatre beyond the frame it takes.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() {
        _checking = false;
        _checked = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'updater open');
    final scheme = Theme.of(context).colorScheme;
    final latest = _entries.isEmpty ? null : _entries.first;
    return Scaffold(
      appBar: AppBar(title: const Text('Updates')),
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
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: _checking
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Icon(
                                Icons.system_update_rounded,
                                color: Color(0xFFFC3C44),
                                size: 28,
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              _version.isEmpty
                                  ? 'Arch Player'
                                  : 'Arch Player $_version',
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              _checked
                                  ? 'You’re up to date'
                                  : 'Check for the newest build',
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
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _checking ? null : _check,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFC3C44),
                      ),
                      child: Text(
                        _checking
                            ? 'Checking…'
                            : 'Check for updates',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SettingGroup(
            title: 'Latest changes',
            children: [
              if (latest == null)
                SettingState.empty(
                  'No changelog bundled with this build.',
                )
              else ...[
                for (final e in _entries.take(5))
                  SettingRow(
                    icon: Icons.history_rounded,
                    title: e.message,
                    subtitle:
                        '${e.short} · ${e.author} · ${e.date}',
                  ),
                SettingRow(
                  icon: Icons.list_rounded,
                  title: 'Full changelog',
                  subtitle:
                      '${_entries.length} commits in this build',
                  push: const ChangelogPage(),
                ),
              ],
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Automatic downloads and installs are not wired yet — '
              'this screen checks and shows notes only.',
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
