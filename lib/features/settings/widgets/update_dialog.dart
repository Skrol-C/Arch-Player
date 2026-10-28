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

/// Update prompt: a centered glass dialog, Mornye grammar. Transparent
/// dialog, max 320 wide, the menu lens as its surface, scale-in
/// 0.96 to 1.0 over a dimmed barrier. Title, then content, then
/// full-width buttons: Download first, Later only when skipping is
/// still allowed. Forced updates lock the barrier too. No logo,
/// no grab handle — dialogs do not have them.
Future<void> showUpdateDialog(
  BuildContext context, {
  required UpdateInfo info,
}) {
  final amoled = isAmoledScheme(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: !info.forced,
    barrierLabel: 'Update available',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, _) => SafeArea(
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: LiquidGlassLens(
            style: ArchGlass.menu(radius: 28, amoled: amoled),
            child: _UpdateBody(info: info),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: curved.drive(Tween<double>(begin: 0.94, end: 1.0)),
          child: child,
        ),
      );
    },
  );
}

class _UpdateBody extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateBody({required this.info});

  @override
  State<_UpdateBody> createState() => _UpdateBodyState();
}

class _UpdateBodyState extends State<_UpdateBody> {
  bool _busy = false;
  double? _progress;
  String? _error;
  List<ChangelogEntry>? _commits;

  @override
  void initState() {
    super.initState();
    loadChangelog().then((entries) {
      if (mounted) setState(() => _commits = entries.take(3).toList());
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Update available',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 19,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'v${info.current} to v${info.version}',
            style: const TextStyle(
              color: archPink,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (info.breaking) ...[
            const SizedBox(height: 10),
            Text(
              'This one changes the format. It installs now, no skipping.',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ] else if (info.forced) ...[
            const SizedBox(height: 10),
            Text(
              'Skipped five times. This one installs now.',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
          if (info.notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              info.notes,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
          if (_commits != null && _commits!.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final e in _commits!) CommitRow(entry: e),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: archPink, fontSize: 13),
            ),
          ],
          const SizedBox(height: 16),
          if (_busy) ...[
            LinearProgressIndicator(
              value: _progress,
              color: archPink,
              backgroundColor:
                  scheme.onSurface.withValues(alpha: 0.08),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _download,
              style: FilledButton.styleFrom(
                backgroundColor: archPink,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              child: Text(
                _busy ? 'Downloading…' : 'Download',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (!info.forced) ...[
            const SizedBox(height: 4),
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
                          'later (${remaining - 1} left) for v${info.version}');
                    },
              child: Text(
                remaining > 0 ? 'Later ($remaining left)' : 'Later',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
