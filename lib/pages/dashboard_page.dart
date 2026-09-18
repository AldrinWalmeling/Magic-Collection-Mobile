import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/app_database.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/currency_service.dart';
import '../services/price_reference.dart';
import '../services/price_update_service.dart';
import '../services/mana_repair_service.dart';
import '../services/rarity_repair_service.dart';
import '../theme/app_theme.dart';
import 'card_detail_sheet.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<String, Object?> _stats = {};
  List<Map<String, Object?>> _byRarity = [];
  List<Map<String, Object?>> _topCards = [];
  int _deckCount = 0;
  String _currency = 'BRL';
  String _mode = PriceReference.original;
  bool _loading = true;
  bool _repairingRarities = false;

  static Color _rarityColor(String rarity) {
    switch (_normalizeRarity(rarity)) {
      case 'common':
        return const Color(0xFF9AA0A6);
      case 'uncommon':
        return const Color(0xFFC7D3E0);
      case 'rare':
        return AppTheme.gold;
      case 'mythic':
        return const Color(0xFFFF7A45);
      default:
        return AppTheme.textMuted;
    }
  }

  static String _normalizeRarity(String rarity) {
    final value = rarity.trim().toLowerCase();
    switch (value) {
      case 'common':
      case 'comum':
        return 'common';
      case 'uncommon':
      case 'incomum':
        return 'uncommon';
      case 'rare':
      case 'rara':
        return 'rare';
      case 'mythic':
      case 'mythic rare':
      case 'mythic_rare':
      case 'mítica':
      case 'mitica':
      case 'mítica rara':
      case 'mitica rara':
        return 'mythic';
      default:
        return value;
    }
  }

  static String _rarityLabel(String rarity) {
    switch (_normalizeRarity(rarity)) {
      case 'common':
        return AppLocale.t('rar_common');
      case 'uncommon':
        return AppLocale.t('rar_uncommon');
      case 'rare':
        return AppLocale.t('rar_rare');
      case 'mythic':
        return AppLocale.t('rar_mythic');
      default:
        return rarity.trim().isEmpty ? '?' : rarity;
    }
  }

  @override
  void initState() {
    super.initState();
    _currency = CurrencyService.instance.currency.value;
    _load();
    AppEvents.collectionChanged.addListener(_onExternalChange);
    AppLocale.current.addListener(_onExternalChange);
    AppEvents.topVisible.addListener(_onBarsChanged);
    AppEvents.activeProfile.addListener(_onExternalChange);
    CurrencyService.instance.currency.addListener(_onCurrency);
    PriceUpdateService.instance.addListener(_onPriceUpdateChanged);
  }

  void _onCurrency() {
    if (mounted) {
      setState(() => _currency = CurrencyService.instance.currency.value);
    }
  }

  @override
  void dispose() {
    AppEvents.collectionChanged.removeListener(_onExternalChange);
    AppLocale.current.removeListener(_onExternalChange);
    AppEvents.topVisible.removeListener(_onBarsChanged);
    AppEvents.activeProfile.removeListener(_onExternalChange);
    CurrencyService.instance.currency.removeListener(_onCurrency);
    PriceUpdateService.instance.removeListener(_onPriceUpdateChanged);
    super.dispose();
  }

  void _onPriceUpdateChanged() {
    if (mounted) setState(() {});
  }

  void _onExternalChange() {
    if (mounted) _load();
  }

  void _onBarsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);

    final db = AppDatabase.instance.db;
    final stats = await AppDatabase.instance.collectionStats();

    final rarity = await db.rawQuery('''
      SELECT
        CASE LOWER(TRIM(COALESCE(rarity, '')))
          WHEN 'common' THEN 'common'
          WHEN 'comum' THEN 'common'
          WHEN 'uncommon' THEN 'uncommon'
          WHEN 'incomum' THEN 'uncommon'
          WHEN 'rare' THEN 'rare'
          WHEN 'rara' THEN 'rare'
          WHEN 'mythic' THEN 'mythic'
          WHEN 'mythic rare' THEN 'mythic'
          WHEN 'mythic_rare' THEN 'mythic'
          WHEN 'mítica' THEN 'mythic'
          WHEN 'mitica' THEN 'mythic'
          ELSE 'desconhecida'
        END AS rarity,
        SUM(quantity) AS n
      FROM cards
      WHERE quantity > 0
      GROUP BY
        CASE LOWER(TRIM(COALESCE(rarity, '')))
          WHEN 'common' THEN 'common'
          WHEN 'comum' THEN 'common'
          WHEN 'uncommon' THEN 'uncommon'
          WHEN 'incomum' THEN 'uncommon'
          WHEN 'rare' THEN 'rare'
          WHEN 'rara' THEN 'rare'
          WHEN 'mythic' THEN 'mythic'
          WHEN 'mythic rare' THEN 'mythic'
          WHEN 'mythic_rare' THEN 'mythic'
          WHEN 'mítica' THEN 'mythic'
          WHEN 'mitica' THEN 'mythic'
          ELSE 'desconhecida'
        END
      ORDER BY n DESC
    ''');

    final decks = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM decks',
    );
    final deckCount = (decks.first['n'] as num?)?.toInt() ?? 0;

    final top = await db.query(
      'cards',
      columns: [
        'id',
        'name',
        'printed_name',
        'lang',
        'set_name',
        'set_code',
        'collector_number',
        'price_usd',
        'price_usd_foil',
        'price_ref_usd',
        'preferred_finish',
        'quantity',
        'image_url',
      ],
      where:
          'quantity > 0 AND COALESCE(price_usd, price_ref_usd, 0) > 0',
      orderBy: 'COALESCE(price_usd, price_ref_usd, 0) DESC',
      limit: 5,
    );

    _mode = await PriceReference.getMode();

    if (mounted) {
      setState(() {
        _stats = stats;
        _byRarity = rarity;
        _topCards = top;
        _deckCount = deckCount;
        _loading = false;
      });
    }

    // Atualiza preços em segundo plano. A tela não espera as requests.
    unawaited(_refreshPricesInBackground());
    // Repara raridades vazias ("desconhecida"), comum após importar
    // backup. Roda em segundo plano e recarrega se consertou algo.
    unawaited(_repairMissingRarities());

    final today = DateTime.now().toIso8601String().substring(0, 10);
    await AppDatabase.instance
        .createSnapshot(today, CurrencyService.instance.usdBrl);
  }

  Future<void> _refreshPricesInBackground() async {
    final updated = await PriceUpdateService.instance.refreshCollectionPrices();
    if (updated <= 0 || !mounted) return;
    await _load();
  }

  Future<void> _repairMissingRarities() async {
    if (_repairingRarities) return;
    _repairingRarities = true;

    try {
      final results = await Future.wait([
        RarityRepairService.repairMissingRarities(),
        ManaRepairService.repairMissingCardData(),
      ]);
      final fixed = results.fold<int>(0, (s, v) => s + v);
      if (fixed > 0 && mounted) {
        // Recarrega uma vez com os dados corrigidos (a próxima
        // passagem não acha mais nada vazio, então não há loop).
        await _load();
      }
    } finally {
      _repairingRarities = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalCards = (_stats['total_cards'] as num?)?.toInt() ?? 0;
    final unique = (_stats['unique_cards'] as num?)?.toInt() ?? 0;
    final sets = (_stats['total_sets'] as num?)?.toInt() ?? 0;
    final usd = (_stats['value_usd'] as num?)?.toDouble() ?? 0;
    final converted = CurrencyService.instance.convertUsd(usd, _currency);
    final fmt =
        NumberFormat.currency(symbol: CurrencyService.symbols[_currency]!);

    return Scaffold(
      appBar: AppEvents.topVisible.value
          ? AppBar(
              title: Text(AppLocale.t('nav_dashboard')),
              actions: [
                if (PriceUpdateService.instance.state == PriceUpdateState.updating)
                  Tooltip(
                    message: PriceUpdateService.instance.total > 0
                        ? 'Atualizando preços · ${PriceUpdateService.instance.processed}/${PriceUpdateService.instance.total}'
                        : 'Atualizando preços',
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Icon(
                        Icons.sync,
                        color: AppTheme.gold,
                      ),
                    ),
                  ),
                if (PriceUpdateService.instance.state == PriceUpdateState.paused)
                  Tooltip(
                    message: 'Scryfall limitou as requisições. Continuando em ${PriceUpdateService.instance.pausedSeconds}s',
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Icon(
                        Icons.pause_circle_outline,
                        color: AppTheme.gold,
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: AppLocale.t('common_focus'),
                  onPressed: AppEvents.toggleNav,
                ),
              ],
            )
          : null,
      body: SafeArea(
        top: !AppEvents.topVisible.value,
        bottom: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        _kpi(
                          AppLocale.t('dash_cards'),
                          '$totalCards',
                          Icons.style,
                        ),
                        const SizedBox(width: 12),
                        _kpi(
                          AppLocale.t('dash_unique'),
                          '$unique',
                          Icons.auto_awesome_mosaic,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _kpi(
                          AppLocale.t('dash_sets'),
                          '$sets',
                          Icons.collections_bookmark,
                        ),
                        const SizedBox(width: 12),
                        _kpi(
                          'Decks',
                          '$_deckCount',
                          Icons.layers,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  AppLocale.t('dash_networth'),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: SegmentedButton<String>(
                                style: SegmentedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  textStyle:
                                      const TextStyle(fontSize: 12),
                                ),
                                segments: [
                                  for (final c
                                      in CurrencyService.currencies)
                                    ButtonSegment(
                                        value: c, label: Text(c)),
                                ],
                                selected: {_currency},
                                showSelectedIcon: false,
                                onSelectionChanged: (s) =>
                                    CurrencyService.instance
                                        .setCurrency(s.first),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${fmt.format(converted)} • ${usd.toStringAsFixed(2)} USD',
                              style: const TextStyle(
                                color: AppTheme.gold,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '${AppLocale.t('dash_mode')}: ${PriceReference.labels[_mode]}',
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (totalCards == 0)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.style_outlined,
                                color: AppTheme.textFaint,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  AppLocale.t('dash_empty_hint'),
                                  style: const TextStyle(
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      AppLocale.t('dash_byrarity'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final r in _byRarity)
                      _bar(
                        (r['rarity'] ?? '?').toString(),
                        (r['n'] as num?)?.toInt() ?? 0,
                        totalCards,
                      ),
                    if (_topCards.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        AppLocale.t('dash_top'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Card(
                        child: Column(
                          children: [
                            for (var i = 0; i < _topCards.length; i++)
                              _topTile(_topCards[i], i + 1),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _kpi(String label, String value, IconData icon) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppTheme.gold),
              const SizedBox(height: 8),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bar(String rarity, int value, int total) {
    final pct = total == 0 ? 0.0 : value / total;
    final color = _rarityColor(rarity);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(child: Text(_rarityLabel(rarity))),
              Text(
                '$value • ${(pct * 100).toStringAsFixed(0)}%',
                style: const TextStyle(color: AppTheme.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: pct,
            backgroundColor: AppTheme.border,
            color: color,
          ),
        ],
      ),
    );
  }

  Widget _topTile(Map<String, Object?> c, int pos) {
    final foil =
        ((c['preferred_finish'] ?? '').toString().toLowerCase().contains('foil'));
    final usd = (c['price_usd'] as num?)?.toDouble();
    final usdFoil = (c['price_usd_foil'] as num?)?.toDouble();
    final ref = (c['price_ref_usd'] as num?)?.toDouble();
    final price = (foil ? (usdFoil ?? usd) : usd) ?? ref ?? 0;
    final qty = (c['quantity'] as num?)?.toInt() ?? 0;
    final url = (c['image_url'] ?? '').toString();
    final printed = (c['printed_name'] ?? '').toString().trim();
    final name = printed.isNotEmpty
        ? printed
        : (c['name'] ?? '').toString();
    final set = (c['set_name'] ?? '').toString();
    final cn = (c['collector_number'] ?? '').toString();
    final lang = (c['lang'] ?? '').toString().toUpperCase();
    final desc = [
      if (set.isNotEmpty) set,
      if (cn.isNotEmpty) '#$cn',
      if (lang.isNotEmpty) lang,
    ].join(' • ');

    return ListTile(
      dense: true,
      leading: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: url.isEmpty
                ? Container(
                    width: 40,
                    height: 56,
                    color: AppTheme.goldSoft,
                    child: const Icon(Icons.style,
                        color: AppTheme.gold, size: 20),
                  )
                : CachedNetworkImage(
                    imageUrl: url,
                    width: 40,
                    height: 56,
                    fit: BoxFit.cover,
                    memCacheWidth: 120,
                    placeholder: (_, __) => Container(
                      width: 40,
                      height: 56,
                      color: AppTheme.goldSoft,
                    ),
                    errorWidget: (_, __, ___) => Container(
                      width: 40,
                      height: 56,
                      color: AppTheme.goldSoft,
                      child: const Icon(Icons.broken_image,
                          color: AppTheme.gold, size: 18),
                    ),
                  ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: const BoxDecoration(
                color: AppTheme.gold,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(6),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(
                '$pos',
                style: const TextStyle(
                  color: Color(0xFF14161D),
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        desc,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppTheme.textMuted,
          fontSize: 12,
        ),
      ),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Text(
          '$qty× • ${CurrencyService.instance.formatUsd(price, _currency)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: const TextStyle(
            color: AppTheme.gold,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
      onTap: () async {
        // A lista top traz colunas resumidas; o detalhe precisa da
        // linha completa (texto, custo, P/T...) — busca pelo id.
        var full = c;
        final id = (c['id'] as num?)?.toInt();
        if (id != null) {
          final rows = await AppDatabase.instance.db.query('cards',
              where: 'id = ?', whereArgs: [id], limit: 1);
          if (rows.isNotEmpty) full = rows.first;
        }
        if (!mounted) return;
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => CardDetailSheet(card: full),
        ).then((_) => _load());
      },
    );
  }
}
