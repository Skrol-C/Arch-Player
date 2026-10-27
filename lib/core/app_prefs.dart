import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide theme choice. `amoled` is a separate dark theme (pure
/// #000 surfaces), not a brightness flag — it hot-swaps like the
/// rest via [appThemeModeProvider].
enum AppThemeMode { system, light, dark, amoled }

AppThemeMode appThemeModeOf(String? raw) => switch (raw) {
  'light' => AppThemeMode.light,
  'dark' => AppThemeMode.dark,
  'amoled' => AppThemeMode.amoled,
  _ => AppThemeMode.system,
};

String appThemeModeName(AppThemeMode m) => m.name;

final appThemeModeProvider =
    NotifierProvider<AppThemeModeNotifier, AppThemeMode>(
      AppThemeModeNotifier.new,
    );

class AppThemeModeNotifier extends Notifier<AppThemeMode> {
  static const _key = 'arch.themeMode';

  @override
  AppThemeMode build() {
    _sync();
    return AppThemeMode.system;
  }

  Future<void> _sync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = appThemeModeOf(prefs.getString(_key));
    } catch (_) {}
  }

  Future<void> set(AppThemeMode m) async {
    state = m;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key,
        appThemeModeName(m),
      );
    } catch (_) {}
  }
}
