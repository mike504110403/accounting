import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 由 main() 啟動時注入的 SharedPreferences（測試可 override）。
final sharedPrefsProvider = Provider<SharedPreferences?>((ref) => null);

const _kThemeModeKey = 'themeMode';

/// 白天／夜晚／跟隨系統。設定頁切換，持久化到 SharedPreferences。
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final saved = ref.read(sharedPrefsProvider)?.getString(_kThemeModeKey);
    return ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(sharedPrefsProvider)?.setString(_kThemeModeKey, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

String themeModeLabel(ThemeMode m) => switch (m) {
      ThemeMode.light => '白天',
      ThemeMode.dark => '夜晚',
      ThemeMode.system => '跟隨系統',
    };
