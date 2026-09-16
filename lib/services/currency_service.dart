import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Espelha services/currency_service.py:
// - CURRENCIES BRL/USD/EUR/TIX, API AwesomeAPI, TTL 1h,
//   refresh em background sem travar a UI, QSettings -> SharedPreferences.

class CurrencyService {
  CurrencyService._();
  static final CurrencyService instance = CurrencyService._();

  static const currencies = ['BRL', 'USD', 'EUR', 'TIX'];
  static const symbols = {'BRL': 'R\$', 'USD': '\$', 'EUR': '€', 'TIX': 'TIX '};
  static const _api =
      'https://economia.awesomeapi.com.br/json/last/USD-BRL,EUR-BRL';
  static const _ttl = Duration(hours: 1);

  double? usdBrl;
  double? eurBrl;
  Timer? _timer;

  /// Moeda selecionada nos Ajustes (fonte única: Ajustes e Painel
  /// usam e alteram o mesmo valor).
  final ValueNotifier<String> currency = ValueNotifier<String>('BRL');

  Future<void> loadCurrency() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final c = prefs.getString('currency');
      if (c != null && currencies.contains(c)) currency.value = c;
    } catch (_) {}
  }

  Future<void> setCurrency(String v) async {
    if (!currencies.contains(v)) return;
    currency.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('currency', v);
    } catch (_) {}
  }

  /// Moeda padrão de cada idioma do app (PT -> BRL, demais -> USD).
  static String currencyForLanguage(String langCode) {
    switch (langCode) {
      case 'pt':
        return 'BRL';
      default:
        return 'USD';
    }
  }

  /// Segue o idioma do app, EXCETO se o usuário já escolheu uma moeda
  /// manualmente no dropdown (escolha explícita sempre vence).
  Future<void> applyLanguageDefault([String? langCode]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('currency')) return;
      await setCurrency(currencyForLanguage(langCode ?? 'en'));
    } catch (_) {}
  }

  Future<void> startBackgroundRefresh() async {
    await refresh(force: true);
    _timer?.cancel();
    // Atualiza a cada hora, como RATES_TTL do desktop.
    _timer = Timer.periodic(_ttl, (_) => refresh());
  }

  Future<void> refresh({bool force = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt('rates_timestamp') ?? 0;
      final age =
          DateTime.now().millisecondsSinceEpoch - last;
      if (!force &&
          age < _ttl.inMilliseconds &&
          prefs.containsKey('usd_brl')) {
        usdBrl = prefs.getDouble('usd_brl');
        eurBrl = prefs.getDouble('eur_brl');
        return;
      }
      final res =
          await http
              .get(Uri.parse(_api), headers: {
                'User-Agent': 'MagicCollection/1.0 (Android)',
                'Accept': 'application/json',
              })
              .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      usdBrl =
          double.tryParse((body['USDBRL']?['bid'] ?? '').toString());
      eurBrl =
          double.tryParse((body['EURBRL']?['bid'] ?? '').toString());
      if (usdBrl != null) await prefs.setDouble('usd_brl', usdBrl!);
      if (eurBrl != null) await prefs.setDouble('eur_brl', eurBrl!);
      await prefs.setInt(
          'rates_timestamp', DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // Offline: mantém última cotação em memória (desktop faz o mesmo).
    }
  }

  /// Converte USD -> moeda destino (desktop: convert_usd_to_currency).
  double convertUsd(double usd, String currency) {
    switch (currency) {
      case 'BRL':
        return usd * (usdBrl ?? 0);
      case 'EUR':
        if (usdBrl == null ||
            eurBrl == null ||
            eurBrl == 0) return 0;
        return usd * usdBrl! / eurBrl!;
      case 'TIX':
      case 'USD':
      default:
        return usd;
    }
  }

  /// Formata um valor em USD na moeda selecionada (BRL por padrão).
  /// Ex.: BRL -> "R$ 12.34" | USD -> "12.34 USD" | EUR -> "€ 12.34".
  /// Sem cotação carregada, BRL/EUR caem para 0.00 (não inventa valor).
  String formatUsd(double usd, [String? currencyCode]) {
    final c = currencyCode ?? currency.value;
    final fixed = convertUsd(usd, c).toStringAsFixed(2);
    switch (c) {
      case 'BRL':
        return 'R\$ $fixed';
      case 'EUR':
        return '€ $fixed';
      case 'TIX':
        return '$fixed TIX';
      default:
        return '$fixed USD';
    }
  }

  void dispose() => _timer?.cancel();
}
