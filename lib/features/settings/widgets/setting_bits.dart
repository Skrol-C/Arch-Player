import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../setting_icons.dart';

/// Shared settings chrome: group card, nav row, toggle row, and the
/// loading/error/empty/data states every settings page must render.
/// Content lives in plain Material cards (glass is for floating nav
/// and controls only, never content).
class SettingGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingGroup({
    super.key,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = scheme.brightness == Brightness.dark
        ? scheme.surfaceContainerHighest
        : paperRaised;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Material(
          color: card,
          borderRadius: BorderRadius.circular(20),
          child: Column(children: children),
        ),
      ],
    );
  }
}

/// One tappable row. [push] opens the destination; pure display rows
/// pass no callback and render without a chevron.
class SettingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? push;
  final VoidCallback? onTap;
  final Widget? trailing;

  const SettingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.push,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actionable = push != null || onTap != null;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.brightness == Brightness.dark
              ? scheme.surface
              : paper,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(settingIconFor(icon), color: archPink),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
      trailing:
          trailing ??
          (actionable
              ? Icon(
                  CupertinoIcons.forward,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                )
              : null),
      onTap: actionable
          ? () {
              if (onTap != null) {
                onTap!();
              } else if (push != null) {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => push!));
              }
            }
          : null,
    );
  }
}

/// Loading / error / empty placeholders so no settings page ever
/// renders nothing. [retry] re-runs the failed load when given.
class SettingState extends StatelessWidget {
  final String message;
  final IconData icon;
  final VoidCallback? retry;

  const SettingState._(this.message, this.icon, this.retry);

  factory SettingState.loading([String message = 'Loading…']) =>
      SettingState._(message, Icons.hourglass_empty_rounded, null);

  factory SettingState.error(String message, {VoidCallback? retry}) =>
      SettingState._(message, Icons.error_outline_rounded, retry);

  factory SettingState.empty(String message) =>
      SettingState._(message, Icons.inbox_rounded, null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (retry != null) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: retry,
              style: FilledButton.styleFrom(backgroundColor: archPink),
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }
}
