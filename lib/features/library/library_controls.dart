import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

/// Widened Play / Shuffle pill used on index pages (Albums, artist
/// hub). Disabled state greys the label instead of hiding the pill.
class LibraryActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const LibraryActionPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: paperRaised,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: enabled ? archPink : inkDim, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: enabled ? archPink : inkDim,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The WA0010 / WA0013 top-right capsule: one quick action and a
/// `...` menu in a single pill. The menu anchors to the exact half
/// that was tapped, which is what lets the popover land correctly.
class LibraryCornerCluster extends StatelessWidget {
  final IconData leftIcon;
  final Color leftColor;
  final VoidCallback onLeft;
  final void Function(BuildContext buttonContext) onMenu;

  const LibraryCornerCluster({
    super.key,
    required this.leftIcon,
    required this.leftColor,
    required this.onLeft,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: paperRaised,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              onLeft();
            },
            child: SizedBox(
              width: 48,
              height: 44,
              child: Icon(leftIcon, color: leftColor, size: 20),
            ),
          ),
          Container(width: 1, height: 18, color: ink.withValues(alpha: 0.08)),
          Builder(
            builder: (buttonContext) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                onMenu(buttonContext);
              },
              child: const SizedBox(
                width: 48,
                height: 44,
                child: Icon(CupertinoIcons.ellipsis, color: ink, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
