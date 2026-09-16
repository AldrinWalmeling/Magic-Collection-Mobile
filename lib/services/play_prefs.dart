import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferências da mesa Jogar: "sempre ocultar nomes das fichas" e
/// "virar a carta de verdade (90º)". ValueNotifiers para a mesa reagir
/// na hora ao trocar nos Ajustes.
class PlayPrefs {
  static const _hideKey = 'play_hide_names';
  static const _rotateKey = 'play_rotate_tapped';
  static const _stackKey = 'play_stack_visible';
  static final ValueNotifier<bool> hideTokenNames = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> rotateTapped = ValueNotifier<bool>(true);
  // Quantas cartas aparecem na pilha (1 = só a frente, 5 = frente + 4).
  static const stackMin = 1;
  static const stackMax = 100;
  static final ValueNotifier<int> stackVisible = ValueNotifier<int>(3);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      hideTokenNames.value = prefs.getBool(_hideKey) ?? false;
      rotateTapped.value = prefs.getBool(_rotateKey) ?? true;
      stackVisible.value = (prefs.getInt(_stackKey) ?? 3)
          .clamp(stackMin, stackMax);
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

  static Future<void> setStackVisible(int v) async {
    final fixed = v.clamp(stackMin, stackMax);
    stackVisible.value = fixed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_stackKey, fixed);
    } catch (_) {}
  }
}
