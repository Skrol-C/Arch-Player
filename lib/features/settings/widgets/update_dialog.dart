import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/glass.dart';
import '../../../core/log.dart';
import '../../../core/theme.dart';
import '../apk_installer.dart';
import '../changelog_store.dart';
import '../update_service.dart';
import 'commit_row.dart';

/// Glassy update prompt, Mornye grammar: logo, version jump, what is
/// new, then Download or Later. Breaking releases and exhausted
/// skips remove Later — the button row says exactly what happens.
Future<void> showUpdateDialog(
  BuildContext context, {
  required UpdateInfo info,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    showDragHandle: false,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.88,
    ),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: LiquidGlassLens(
        style:
            ArchGlass.sheet(radius: 28, amoled: isAmoledScheme(context)),
        child: _UpdateSheet(info: info),
      ),
    ),
  );
}

class _UpdateSheet extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateSheet({required this.info});

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  bool _busy = false;
  double? _progress;
  String? _error;
  List<ChangelogEntry>? _commits;

  @override
  void initState() {
    super.initState();
    loadChangelog().then((entries) {
      if (mounted) setState(() => _commits = entries.take(8).toList());
    });
  }

  Future<void> _download() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    HapticFeedback.mediumImpact();
    try {
      var status = await Permission.requestInstallPackages.status;
      if (!status.isGranted) {
        status = await Permission.requestInstallPackages.request();
      }
      if (!status.isGranted) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'Allow installs to update from the APK.';
        });
        return;
      }
      if (widget.info.apkUrl.isEmpty) {
        final uri = Uri.tryParse(widget.info.pageUrl);
        if (uri != null && mounted) {
          Navigator.of(context).pop();
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        return;
      }
      final apk = await ApkInstaller.download(
        widget.info.apkUrl,
        filename: 'arch-player-${widget.info.version}.apk',
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
      );
      if (!mounted) return;
      if (apk == null) {
        setState(() {
          _busy = false;
          _error = 'Download failed. Check the connection and retry.';
        });
        return;
      }
      setState(() => _progress = null);
      final handedOff = await ApkInstaller.install(apk);
      if (!mounted) return;
      if (handedOff) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _busy = false;
        _error = 'Could not open the installer. Try again.';
      });
    } catch (e) {
      ArchLog.w('updater', 'download failed: $e');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Download failed. Check the connection and retry.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = widget.info;
    final remaining = updateMaxSkips - info.skips;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/icon/app_logo.png',
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 48,
                      height: 48,
                      color: archPink.withValues(alpha: 0.14),
                      alignment: Alignment.center,
                      child: const Text(
                        'A',
                        style: TextStyle(
                          color: archPink,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Update available',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'v${info.current} to v${info.version}',
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
            if (info.breaking) ...[
              const SizedBox(height: 12),
              Text(
                'This one changes the format. It installs now, no skipping.',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ] else if (info.forced) ...[
              const SizedBox(height: 12),
              Text(
                'Skipped five times. This one installs now.',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                info.notes,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (_commits != null)
              for (final e in _commits!) CommitRow(entry: e),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: archPink, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            if (_busy) ...[
              LinearProgressIndicator(
                value: _progress,
                color: archPink,
                backgroundColor:
                    scheme.onSurface.withValues(alpha: 0.08),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _download,
                    style: FilledButton.styleFrom(
                      backgroundColor: archPink,
                    ),
                    child: Text(
                      _busy ? 'Downloading…' : 'Download',
                    ),
                  ),
                ),
                if (!info.forced) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            HapticFeedback.selectionClick();
                            await recordUpdateSkip(info.version);
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                            ArchLog.i('updater',
                                'later (${remaining - 1} skips left for v${info.version})');
                          },
                    child: Text(
                      remaining > 0 ? 'Later ($remaining left)' : 'Later',
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
