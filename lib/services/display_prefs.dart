import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferências de exibição das cartas no modo grade da Coleção:
/// mostrar ou não o nome e a linha de edição/preço abaixo da arte.
/// ValueNotifiers para a grade reagir na hora ao trocar nos Ajustes.
class DisplayPrefs {
  static const _nameKey = 'grid_show_name';
  static const _setKey = 'grid_show_set';
  static const _priceKey = 'grid_show_price';
  static final ValueNotifier<bool> showCardName = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> showCardSet = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> showCardPrice = ValueNotifier<bool>(true);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      showCardName.value = prefs.getBool(_nameKey) ?? true;
      showCardSet.value = prefs.getBool(_setKey) ?? true;
      showCardPrice.value = prefs.getBool(_priceKey) ?? true;
    } catch (_) {}
  }

  static Future<void> setShowCardName(bool v) async {
    showCardName.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_nameKey, v);
    } catch (_) {}
  }

  static Future<void> setShowCardSet(bool v) async {
    showCardSet.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_setKey, v);
    } catch (_) {}
  }

  static Future<void> setShowCardPrice(bool v) async {
    showCardPrice.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_priceKey, v);
    } catch (_) {}
  }
}
