import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import '../shell/dock.dart';

/// Search bar with three stops, driven by the page's scroll:
/// `open` (full editable field, only at the top of a page), `peek`
/// (slim tappable row after a downward swipe mid-list) and `hidden`
/// (retracted while diving into a list).
///
/// The field and the slim row share one spring driver: height,
/// opacity and a small upward travel all read from the same value, so
/// the swap reads as one object changing size rather than two widgets
/// trading places. Tapping the slim row rides the page back to the
/// top; arriving there expands it and takes focus.
class LibraryCollapsingSearch extends ConsumerStatefulWidget {
  final String hint;
  final ValueChanged<String> onChanged;

  const LibraryCollapsingSearch({
    super.key,
    required this.hint,
    required this.onChanged,
  });

  @override
  ConsumerState<LibraryCollapsingSearch> createState() =>
      _LibraryCollapsingSearchState();
}

class _LibraryCollapsingSearchState
    extends ConsumerState<LibraryCollapsingSearch>
    with SingleTickerProviderStateMixin {
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 240,
    damping: 25,
  );

  /// Full field height (Material SearchBar) and the slim row that
  /// replaces it mid-list. The peek stop is a driver position, not a
  /// separate layout: the clip does the work.
  static const double _fullHeight = 56;
  static const double _peekHeight = 38;
  static const double _peekAt = _peekHeight / _fullHeight;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.stateChange,
    value: 1,
  );

  final FocusNode _focus = FocusNode();
  SearchStage? _target;
  bool _focusPending = false;

  @override
  void dispose() {
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  static double _stopFor(SearchStage stage) => switch (stage) {
    SearchStage.hidden => 0.0,
    SearchStage.peek => _peekAt,
    SearchStage.open => 1.0,
  };

  void _settle(double target) {
    if (Motion.reduced(context)) {
      _c.value = target;
      return;
    }
    if (!_c.isAnimating && (_c.value - target).abs() < 0.002) return;
    _c.animateWith(
      SpringSimulation(_spring, _c.value, target, _c.velocity.clamp(-1.5, 1.5)),
    );
  }

  /// Tap the slim row: ride the page home. Arriving at the top is what
  /// promotes peek to open, so focus is only taken once that lands -
  /// the caret never appears in a half-clipped field.
  void _peekTapped() {
    HapticFeedback.selectionClick();
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    _focusPending = true;
    scrollable.position.animateTo(
      0,
      duration: Motion.reduced(context) ? Duration.zero : Motion.overlay,
      curve: Motion.arrival,
    );
  }

  @override
  Widget build(BuildContext context) {
    final stage = ref.watch(searchStageProvider);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Typing owns the field: never yank it out from under the caret.
    final want = keyboard ? SearchStage.open : stage;
    if (want != _target) {
      _target = want;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _settle(_stopFor(want));
      });
    }
    if (want == SearchStage.open && _focusPending) {
      _focusPending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focus.hasFocus) _focus.requestFocus();
      });
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final v = _c.value.clamp(0.0, 1.0);
        // Field owns 1.0 down to _peekAt, slim row owns the rest.
        final fieldT = ((v - _peekAt) / (1 - _peekAt)).clamp(0.0, 1.0);
        final peekT = (v / _peekAt).clamp(0.0, 1.0) * (1 - fieldT);
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: v,
            child: SizedBox(
              height: _fullHeight,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: fieldT < 0.98,
                      child: Opacity(
                        opacity: fieldT,
                        child: Transform.translate(
                          offset: Offset(0, -10 * (1 - fieldT)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: LibrarySearchField(
                              hint: widget.hint,
                              onChanged: widget.onChanged,
                              focusNode: _focus,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: _peekHeight,
                    child: IgnorePointer(
                      ignoring: fieldT >= 0.5,
                      child: Opacity(
                        opacity: peekT,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _peekTapped,
                            child: Container(
                              height: _peekHeight,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(
                                  _peekHeight / 2,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    CupertinoIcons.search,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      widget.hint,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    CupertinoIcons.arrow_up,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    size: 14,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Library search field: 300ms debounce so fast typing doesn't
/// re-filter the world on every keystroke (SpotiFLAC pattern).
class LibrarySearchField extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;

  const LibrarySearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.focusNode,
  });

  @override
  State<LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends State<LibrarySearchField> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SearchBar(
      hintText: widget.hint,
      focusNode: widget.focusNode,
      backgroundColor: WidgetStatePropertyAll(
          Theme.of(context).colorScheme.surfaceContainerHighest),
      elevation: const WidgetStatePropertyAll(0),
      onChanged: (q) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), () {
          if (mounted) widget.onChanged(q);
        });
      },
    );
  }
}

/// Bottom-sheet sort picker: one row, check mark, house frost card.
/// Replaces inline filter-chip rows on library pages.
Future<T?> showLibrarySort<T>({
  required BuildContext context,
  required T current,
  required List<({String label, T value})> options,
}) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    elevation: 0,
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            for (final o in options)
              ListTile(
                title: Text(
                  o.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: current == o.value
                    ? const Icon(
                        CupertinoIcons.check_mark_circled_solid,
                        color: archPink,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(o.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// Sort row: current choice + chevron, opens the picker sheet.
class LibrarySortRow extends StatelessWidget {
  final String current;
  final VoidCallback onTap;
  const LibrarySortRow({super.key, required this.current, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            Text(
              'Sort: $current',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              CupertinoIcons.chevron_up_chevron_down,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }
}
