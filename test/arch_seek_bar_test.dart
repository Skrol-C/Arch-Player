import 'package:arch_player/features/player/arch_seek_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

Widget _wrap({
  required ValueChanged<double> onSeek,
  required VoidCallback onDismiss,
  double positionMs = 60000,
  double totalMs = 180000,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ArchSeekBar(
        positionMs: positionMs,
        totalMs: totalMs,
        onSeek: onSeek,
        onDismiss: onDismiss,
      ),
    ),
  );
}

Finder _track() => find.byKey(const Key('arch_seek_track'));

void main() {
  group('ArchSeekBar', () {
    testWidgets('horizontal drag right seeks forward along the bar', (
      t,
    ) async {
      double? sought;
      var dismissed = false;
      await t.pumpWidget(
        _wrap(onSeek: (ms) => sought = ms, onDismiss: () => dismissed = true),
      );
      await t.pumpAndSettle();

      // Touch lands mid-bar (50% = 90s), then travels right.
      await t.drag(_track(), const Offset(100, 0));
      await t.pumpAndSettle();

      expect(sought, isNotNull);
      expect(sought!, greaterThan(90000));
      expect(sought!, lessThanOrEqualTo(180000));
      expect(dismissed, isFalse);
    });

    testWidgets('horizontal drag left seeks backward along the bar', (
      t,
    ) async {
      double? sought;
      await t.pumpWidget(
        _wrap(onSeek: (ms) => sought = ms, onDismiss: () {}),
      );
      await t.pumpAndSettle();

      await t.drag(_track(), const Offset(-100, 0));
      await t.pumpAndSettle();

      expect(sought, isNotNull);
      expect(sought!, lessThan(90000));
      expect(sought!, greaterThanOrEqualTo(0));
    });

    testWidgets('tap jumps to the tapped point', (t) async {
      double? sought;
      await t.pumpWidget(
        _wrap(onSeek: (ms) => sought = ms, onDismiss: () {}),
      );
      await t.pumpAndSettle();

      await t.tap(_track());
      await t.pumpAndSettle();

      // Track center = exactly half the 180s track.
      expect(sought, isNotNull);
      expect(sought!, closeTo(90000, 1));
    });

    testWidgets('vertical drag dismisses instead of seeking', (t) async {
      double? sought;
      var dismissed = false;
      await t.pumpWidget(
        _wrap(onSeek: (ms) => sought = ms, onDismiss: () => dismissed = true),
      );
      await t.pumpAndSettle();

      await t.drag(_track(), const Offset(0, 120));
      await t.pumpAndSettle();

      expect(dismissed, isTrue);
      expect(sought, isNull);
    });

    testWidgets('only the thumb is glass, and only while dragging', (
      t,
    ) async {
      await t.pumpWidget(_wrap(onSeek: (_) {}, onDismiss: () {}));
      await t.pumpAndSettle();

      // One lens total: the drag-only thumb. The line itself is plain.
      expect(find.byType(LiquidGlassLens), findsOneWidget);

      AnimatedOpacity fadeOf() => t.widget<AnimatedOpacity>(
        find.byKey(const Key('arch_seek_thumb_fade')),
      );
      AnimatedScale scaleOf() => t.widget<AnimatedScale>(
        find.byKey(const Key('arch_seek_thumb_scale')),
      );
      expect(fadeOf().opacity, 0);
      expect(scaleOf().scale, 0.5);

      final gesture = await t.startGesture(t.getCenter(_track()));
      await gesture.moveBy(const Offset(30, 0));
      await t.pump();
      expect(fadeOf().opacity, 1);
      expect(scaleOf().scale, 1.0);

      await gesture.up();
      await t.pumpAndSettle();
      expect(fadeOf().opacity, 0);
      expect(scaleOf().scale, 0.5);
    });

    testWidgets('renders position fill and remaining time', (t) async {
      await t.pumpWidget(_wrap(onSeek: (_) {}, onDismiss: () {}));
      await t.pumpAndSettle();

      // 60s in, 120s left of a 180s track.
      expect(find.text('1:00'), findsOneWidget);
      expect(find.text('-2:00'), findsOneWidget);
    });
  });
}
