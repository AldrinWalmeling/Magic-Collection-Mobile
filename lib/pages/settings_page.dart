import 'package:flutter/material.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/display_prefs.dart';
import '../services/play_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/currency_service.dart';
import '../services/price_reference.dart';

// Espelha pages/settings_page.py:
// moeda (BRL/USD/EUR/TIX), modo de preço (Original x Imprint),
// cotação atual, sobre.

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _currency = 'BRL';
  String _mode = PriceReference.original;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _currency = CurrencyService.instance.currency.value;
        _mode = prefs.getString('pricing_mode') ?? PriceReference.original;
      });
    }
  }

  Future<void> _setCurrency(String? v) async {
    if (v == null) return;
    await CurrencyService.instance.setCurrency(v);
    if (mounted) setState(() => _currency = v);
  }

  Future<void> _setMode(String? v) async {
    if (v == null) return;
    await PriceReference.setMode(v);
    setState(() => _mode = v);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLang>(
        valueListenable: AppLocale.current,
        builder: (_, lang, __) => ValueListenableBuilder<bool>(
            valueListenable: AppEvents.topVisible,
            builder: (_, top, ___) => Scaffold(
                  appBar: top
                      ? AppBar(
                          title: Text(AppLocale.t('settings_title')),
                          actions: [
                            IconButton(
                              icon: const Icon(Icons.fullscreen),
                              tooltip: AppLocale.t('common_focus'),
                              onPressed: AppEvents.toggleNav,
                            ),
                          ],
                        )
                      : null,
                  body: SafeArea(
                    top: !top,
                    bottom: false,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(AppLocale.t('settings_language'),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                Text(AppLocale.t('settings_language_sub'),
                                    style: const TextStyle(color: Colors.grey)),
                                DropdownButton<AppLang>(
                                  value: lang,
                                  isExpanded: true,
                                  items: AppLang.values
                                      .map((l) => DropdownMenuItem(
                                          value: l,
                                          child: Text(
                                              AppLocale.languageNames[l]!)))
                                      .toList(),
                                  onChanged: (v) {
                                    if (v != null) AppLocale.set(v);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(AppLocale.t('settings_table'),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                ValueListenableBuilder<bool>(
                                  valueListenable: PlayPrefs.hideTokenNames,
                                  builder: (_, hide, __) => SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    secondary: const Icon(Icons.title_outlined,
                                        color: Colors.grey),
                                    title: Text(
                                        AppLocale.t('settings_hide_names')),
                                    subtitle: Text(
                                        AppLocale.t('settings_hide_names_sub')),
                                    value: hide,
                                    onChanged: PlayPrefs.setHideTokenNames,
                                  ),
                                ),
                                ValueListenableBuilder<bool>(
                                  valueListenable: PlayPrefs.rotateTapped,
                                  builder: (_, rotate, __) => SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    secondary: const Icon(Icons.rotate_right,
                                        color: Colors.grey),
                                    title: Text(AppLocale.t('settings_rotate')),
                                    subtitle: Text(
                                        AppLocale.t('settings_rotate_sub')),
                                    value: rotate,
                                    onChanged: PlayPrefs.setRotateTapped,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(AppLocale.t('settings_display'),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                Text(AppLocale.t('settings_display_sub'),
                                    style: const TextStyle(color: Colors.grey)),
                                ValueListenableBuilder<bool>(
                                  valueListenable: DisplayPrefs.showCardName,
                                  builder: (_, show, __) => SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    secondary: const Icon(Icons.title_outlined,
                                        color: Colors.grey),
                                    title: Text(AppLocale.t(
                                        'settings_show_name')),
                                    subtitle: Text(AppLocale.t(
                                        'settings_show_name_sub')),
                                    value: show,
                                    onChanged: DisplayPrefs.setShowCardName,
                                  ),
                                ),
                                ValueListenableBuilder<bool>(
                                  valueListenable: DisplayPrefs.showCardSet,
                                  builder: (_, show, __) => SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    secondary: const Icon(
                                        Icons.library_books_outlined,
                                        color: Colors.grey),
                                    title: Text(AppLocale.t(
                                        'settings_show_set')),
                                    subtitle: Text(AppLocale.t(
                                        'settings_show_set_sub')),
                                    value: show,
                                    onChanged: DisplayPrefs.setShowCardSet,
                                  ),
                                ),
                                ValueListenableBuilder<bool>(
                                  valueListenable: DisplayPrefs.showCardPrice,
                                  builder: (_, show, __) => SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    secondary: const Icon(
                                        Icons.attach_money_outlined,
                                        color: Colors.grey),
                                    title: Text(AppLocale.t(
                                        'settings_show_price')),
                                    subtitle: Text(AppLocale.t(
                                        'settings_show_price_sub')),
                                    value: show,
                                    onChanged: DisplayPrefs.setShowCardPrice,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(AppLocale.t('settings_currency'),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                DropdownButton<String>(
                                  value: _currency,
                                  isExpanded: true,
                                  items: CurrencyService.currencies
                                      .map((c) => DropdownMenuItem(
                                          value: c,
                                          child: Text(
                                              '$c (${CurrencyService.symbols[c]})')))
                                      .toList(),
                                  onChanged: _setCurrency,
                                ),
                                const SizedBox(height: 12),
                                Text(AppLocale.t('settings_pricing'),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                Text(AppLocale.t('settings_pricing_hint'),
                                    style: const TextStyle(color: Colors.grey)),
                                DropdownButton<String>(
                                  value: _mode,
                                  isExpanded: true,
                                  items: PriceReference.labels.entries
                                      .map((e) => DropdownMenuItem(
                                          value: e.key, child: Text(e.value)))
                                      .toList(),
                                  onChanged: _setMode,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.currency_exchange,
                                color: Color(0xFFD4A84B)),
                            title: Text(AppLocale.t('settings_update_quote')),
                            subtitle: Text(
                                'USD/BRL: ${CurrencyService.instance.usdBrl?.toStringAsFixed(4) ?? '—'}'),
                            onTap: () async {
                              await CurrencyService.instance
                                  .refresh(force: true);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(AppLocale.t(
                                            'settings_quote_updated'))));
                                setState(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                )));
  }
}
