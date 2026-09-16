import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferências da mesa Jogar: "sempre ocultar nomes das fichas" e
/// "virar a carta de verdade (90º)". ValueNotifiers para a mesa reagir
/// na hora ao trocar nos Ajustes.
class PlayPrefs {
  static const _hideKey = 'play_hide_names';
  static const _rotateKey = 'play_rotate_tapped';
  static final ValueNotifier<bool> hideTokenNames = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> rotateTapped = ValueNotifier<bool>(true);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      hideTokenNames.value = prefs.getBool(_hideKey) ?? false;
      rotateTapped.value = prefs.getBool(_rotateKey) ?? true;
    } catch (_) {}
  }

  static Future<void> setHideTokenNames(bool v) async {
    hideTokenNames.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_hideKey, v);
    } catch (_) {}
  }

  static Future<void> setRotateTapped(bool v) async {
    rotateTapped.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_rotateKey, v);
    } catch (_) {}
  }
}
