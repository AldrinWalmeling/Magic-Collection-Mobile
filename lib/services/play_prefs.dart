import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferências da mesa Jogar: "sempre ocultar nomes das fichas" e
/// "virar a carta de verdade (90º)". ValueNotifiers para a mesa reagir
/// na hora ao trocar nos Ajustes.
class PlayPrefs {
  static const _hideKey = 'play_hide_names';
  static const _rotateKey = 'play_rotate_tapped';
  static const _stackKey = 'play_stack_visible';
  static const _tableFormatKey = 'play_table_format';
  static const _keywordPosKey = 'play_keyword_pos';
  static final ValueNotifier<bool> hideTokenNames = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> rotateTapped = ValueNotifier<bool>(true);
  // Quantas cartas aparecem na pilha (1 = só a frente, 5 = frente + 4).
  static const stackMin = 1;
  static const stackMax = 5;
  static final ValueNotifier<int> stackVisible = ValueNotifier<int>(3);
  // Formato da mesa LAN/Online: 'arena' (mesa única) ou 'legacy'
  // (cartões empilhados verticais, comportamento antigo).
  static final ValueNotifier<String> tableFormat =
      ValueNotifier<String>('arena');
  // Habilidades na mini da mesa: 'below' (faixa sob o nome) ou
  // 'center' (pílula no centro, como a descrição).
  static final ValueNotifier<String> keywordPos =
      ValueNotifier<String>('below');

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      hideTokenNames.value = prefs.getBool(_hideKey) ?? false;
      rotateTapped.value = prefs.getBool(_rotateKey) ?? true;
      stackVisible.value = (prefs.getInt(_stackKey) ?? 3)
          .clamp(stackMin, stackMax);
      final fmt = prefs.getString(_tableFormatKey) ?? 'arena';
      tableFormat.value = fmt == 'legacy' ? 'legacy' : 'arena';
      final kwp = prefs.getString(_keywordPosKey) ?? 'below';
      keywordPos.value = kwp == 'center' ? 'center' : 'below';
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

  static Future<void> setTableFormat(String v) async {
    final fixed = v == 'legacy' ? 'legacy' : 'arena';
    tableFormat.value = fixed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tableFormatKey, fixed);
    } catch (_) {}
  }

  static Future<void> setKeywordPos(String v) async {
    final fixed = v == 'center' ? 'center' : 'below';
    keywordPos.value = fixed;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keywordPosKey, fixed);
    } catch (_) {}
  }
}
