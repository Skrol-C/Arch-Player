import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import '../settings/widgets/arch_switch.dart';
import 'extension.dart';

/// Manifest-driven settings form: string, boolean, select rows
/// generated from the extension's own `settings` array. Values
/// persist per extension id; the engine reads them when it calls
/// extension code. No hand-built provider UIs, ever.
class ExtensionSettingsPage extends ConsumerWidget {
  final ExtensionManifest manifest;
  const ExtensionSettingsPage({super.key, required this.manifest});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(manifest.displayName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          if (manifest.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(manifest.description,
                  style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5)),
            ),
          for (final s in manifest.settings)
            _SettingRow(manifestId: manifest.name, setting: s),
        ],
      ),
    );
  }
}

class _SettingRow extends ConsumerStatefulWidget {
  final String manifestId;
  final ExtensionSetting setting;
  const _SettingRow({required this.manifestId, required this.setting});

  @override
  ConsumerState<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends ConsumerState<_SettingRow> {
  String? _value;
  bool _loaded = false;

  String get _prefsKey => 'arch.ext.${widget.manifestId}.${widget.setting.key}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _value = prefs.getString(_prefsKey) ?? widget.setting.def ?? '';
      _loaded = true;
    });
  }

  Future<void> _save(String v) async {
    setState(() => _value = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, v);
    ArchLog.i('needle', 'setting ${widget.manifestId}.${widget.setting.key}');
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.setting;
    if (!_loaded) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Loading...'),
      );
    }
    switch (s.type) {
      case 'boolean':
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s.label,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: s.description.isEmpty
              ? null
              : Text(s.description,
                  style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13)),
          trailing: ArchSwitch(
            value: _value == 'true',
            onChanged: (on) {
              HapticFeedback.selectionClick();
              _save(on ? 'true' : 'false');
            },
          ),
        );
      case 'select':
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s.label,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              _value!.isEmpty ? s.options.first : _value!,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13)),
          trailing: Icon(Icons.chevron_right_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          onTap: () async {
            HapticFeedback.selectionClick();
            final picked = await showDialog<String>(
              context: context,
              builder: (context) => SimpleDialog(
                title: Text(s.label),
                children: [
                  for (final o in s.options)
                    SimpleDialogOption(
                      onPressed: () =>
                          Navigator.of(context).pop(o),
                      child: Text(o,
                          style: TextStyle(
                              color: o == _value
                                  ? archPink
                                  : Theme.of(context).colorScheme.onSurface,
                              fontWeight: o == _value
                                  ? FontWeight.w700
                                  : FontWeight.w400)),
                    ),
                ],
              ),
            );
            if (picked != null) _save(picked);
          },
        );
      default:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(s.label,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              _value!.isEmpty
                  ? (s.description.isEmpty
                      ? 'Tap to set'
                      : s.description)
                  : _value!,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13)),
          trailing: Icon(Icons.chevron_right_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          onTap: () async {
            HapticFeedback.selectionClick();
            final controller = TextEditingController(text: _value);
            final v = await showDialog<String>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(s.label),
                content: TextField(
                  controller: controller,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: s.description.isEmpty
                        ? null
                        : s.description,
                  ),
                  onSubmitted: (t) =>
                      Navigator.of(context).pop(t),
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pop(controller.text),
                    child: const Text('Save',
                        style: TextStyle(color: archPink)),
                  ),
                ],
              ),
            );
            controller.dispose();
            if (v != null) _save(v.trim());
          },
        );
    }
  }
}
