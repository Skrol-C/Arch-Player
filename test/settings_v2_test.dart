import 'package:arch_player/core/app_prefs.dart';
import 'package:arch_player/features/settings/changelog_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('changelog parsing', () {
    test('parses bundled-shape json', () {
      final entries = parseChangelog({
        'generatedAt': '2026-10-27T00:00:00Z',
        'commits': [
          {
            'hash': 'abcdef1234567890',
            'message': 'fix: tame echo',
            'author': 'Skrol-C',
            'date': '2026-10-27',
          },
        ],
      });
      expect(entries, hasLength(1));
      expect(entries.first.short, 'abcdef1');
      expect(
        entries.first.avatarUrl,
        'https://github.com/Skrol-C.png',
      );
    });

    test('malformed payload yields empty, never throws', () {
      expect(parseChangelog(null), isEmpty);
      expect(parseChangelog({'commits': 'nope'}), isEmpty);
      expect(parseChangelog({'commits': [42]}), isEmpty);
    });

    test('stamp reads generatedAt', () {
      expect(
        changelogStamp({'generatedAt': 'x'}),
        'x',
      );
      expect(changelogStamp(null), isEmpty);
    });
  });

  group('theme mode parsing', () {
    test('round-trips known modes, unknowns fall back to system', () {
      expect(appThemeModeOf('amoled'), AppThemeMode.amoled);
      expect(appThemeModeOf('dark'), AppThemeMode.dark);
      expect(appThemeModeOf('light'), AppThemeMode.light);
      expect(appThemeModeOf('nope'), AppThemeMode.system);
      expect(appThemeModeOf(null), AppThemeMode.system);
      expect(
        appThemeModeName(AppThemeMode.amoled),
        'amoled',
      );
    });
  });
}
