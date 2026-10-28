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

Finder _groove() => find.byType(LiquidGlassLens).first;

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
      await t.drag(_groove(), const Offset(100, 0));
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

      await t.drag(_groove(), const Offset(-100, 0));
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

      await t.tap(_groove());
      await t.pumpAndSettle();

      // Groove center = exactly half the 180s track.
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

      await t.drag(_groove(), const Offset(0, 120));
      await t.pumpAndSettle();

      expect(dismissed, isTrue);
      expect(sought, isNull);
    });

    testWidgets('thumb swells while the finger is down', (t) async {
      await t.pumpWidget(_wrap(onSeek: (_) {}, onDismiss: () {}));
      await t.pumpAndSettle();

      AnimatedScale scaleOf() =>
          t.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scaleOf().scale, 1.0);

      final gesture = await t.startGesture(t.getCenter(_groove()));
      await gesture.moveBy(const Offset(30, 0));
      await t.pump();
      expect(scaleOf().scale, 1.5);

      await gesture.up();
      await t.pumpAndSettle();
      expect(scaleOf().scale, 1.0);
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
