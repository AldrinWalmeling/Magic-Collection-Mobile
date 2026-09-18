// Estatísticas calculadas das CARTAS REAIS do deck (Fase A).
// Tudo sai das colunas locais (`cmc`, `type_line`, `colors`,
// `color_identity`); nada mockado, nenhuma heurística inventada.
// Sem `ramp detection`: fontes de mana = terrenos (+ identidade).
import 'dart:convert';

import 'card_types.dart';

class DeckTypeCount {
  const DeckTypeCount({
    this.lands = 0,
    this.creatures = 0,
    this.planeswalkers = 0,
    this.instants = 0,
    this.sorceries = 0,
    this.artifacts = 0,
    this.enchantments = 0,
    this.other = 0,
  });

  final int lands;
  final int creatures;
  final int planeswalkers;
  final int instants;
  final int sorceries;
  final int artifacts;
  final int enchantments;
  final int other;

  int get total =>
      lands +
      creatures +
      planeswalkers +
      instants +
      sorceries +
      artifacts +
      enchantments +
      other;
}

class DeckStats {
  const DeckStats({
    required this.totalCards,
    required this.curve,
    required this.avgMv,
    required this.mvCount,
    required this.types,
    required this.colors,
    required this.landCount,
    required this.basicLands,
    required this.multiColorLands,
    required this.colorlessLands,
    required this.manaSources,
    required this.sourcesByColor,
    required this.totalValue,
  });

  /// Cópias totais no deck.
  final int totalCards;

  /// Curva de mana (só não-terrenos): índice 0..5, 6 = 6+.
  final Map<int, int> curve;

  /// Mana value médio (só não-terrenos com cmc conhecido).
  final double avgMv;

  /// Cópias com cmc conhecido (base da média).
  final int mvCount;

  final DeckTypeCount types;

  /// Cartas por cor (identidade; multicolorida conta em cada).
  final Map<String, int> colors;

  /// Terrenos (cópias).
  final int landCount;

  /// Básicas / multicoloridas (identidade ≥2 cores) / incolores
  /// (identidade vazia, não produzem mana diretamente).
  final int basicLands;
  final int multiColorLands;
  final int colorlessLands;

  /// Fontes de mana = terrenos (cópias).
  final int manaSources;

  /// Fontes por cor (identidade dos terrenos).
  final Map<String, int> sourcesByColor;

  final double totalValue;

  static const empty = DeckStats(
    totalCards: 0,
    curve: {},
    avgMv: 0,
    mvCount: 0,
    types: DeckTypeCount(),
    colors: {},
    landCount: 0,
    basicLands: 0,
    multiColorLands: 0,
    colorlessLands: 0,
    manaSources: 0,
    sourcesByColor: {},
    totalValue: 0,
  );
}

class DeckStatsService {
  static const colorOrder = ['W', 'U', 'B', 'R', 'G'];

  static List<String> stringList(Object? raw) {
    if (raw == null) return [];
    if (raw is List) return [for (final e in raw) e.toString()];
    return [];
  }

  /// Aceita JSON-encoded também (colunas colors/color_identity).
  static List<String> colorList(Object? raw) {
    if (raw is List) return [for (final e in raw) e.toString()];
    if (raw is String && raw.trim().isNotEmpty) {
      final t = raw.trim();
      if (t.startsWith('[')) {
        try {
          final d = jsonDecode(t);
          if (d is List) return [for (final e in d) e.toString()];
        } catch (_) {}
      } else if (t.length <= 5) {
        return t.split('');
      }
    }
    return [];
  }

  /// Valor de mana de uma carta, tolerante a dados incompletos:
  /// 1. `cmc` numérico (caso normal, vindo do Scryfall);
  /// 2. `cmc` como String numérica (coluna REAL lida como TEXT em
  ///    bancos antigos ou linhas importadas sem normalização);
  /// 3. derivado de `mana_cost` ("{2}{R}" -> 3) quando `cmc` é nulo
  ///    (DFCs, enriquecimento falho, imports antigos).
  /// Retorna null só quando não há dado nenhum.
  static double? manaValue(Object? cmcRaw, Object? manaCostRaw) {
    if (cmcRaw is num) return cmcRaw.toDouble();
    if (cmcRaw is String) {
      final v = double.tryParse(cmcRaw.trim());
      if (v != null) return v;
    }
    if (manaCostRaw is String && manaCostRaw.trim().isNotEmpty) {
      return manaValueFromCost(manaCostRaw);
    }
    return null;
  }

  /// Soma os símbolos de `mana_cost`: genérico vale o número, cada
  /// símbolo colorido/híbrido/firéxio/neve vale 1, {X}/{Y}/{Z} valem 0,
  /// duplo ({2/W}) vale 2, meio ({½}) vale 0.5. Lados de split ("//")
  /// somam (igual ao cmc total do Scryfall).
  static double manaValueFromCost(String cost) {
    var total = 0.0;
    for (final m in RegExp(r'\{([^}]*)\}').allMatches(cost)) {
      final s = m.group(1)!.trim().toUpperCase();
      if (s.isEmpty) continue;
      if (s == 'X' || s == 'Y' || s == 'Z') continue;
      if (s == 'S') {
        total += 1;
        continue;
      }
      if (s == '1/2' || s == '½') {
        total += 0.5;
        continue;
      }
      final generic = int.tryParse(s);
      if (generic != null) {
        total += generic;
        continue;
      }
      if (s.contains('/')) {
        // Híbrido ({W/U}) e firéxio ({W/P}) valem 1 no total;
        // duplo ({2/W}) vale o numeral.
        var num = 1;
        for (final p in s.split('/')) {
          final n = int.tryParse(p);
          if (n != null) num = n;
        }
        total += num;
        continue;
      }
      total += 1;
    }
    return total.clamp(0, 100).toDouble();
  }

  static DeckStats compute(List<Map<String, Object?>> items) {
    final curve = {for (var i = 0; i <= 6; i++) i: 0};
    var mvSum = 0.0;
    var mvCount = 0;
    var lands = 0;
    var creatures = 0;
    var planeswalkers = 0;
    var instants = 0;
    var sorceries = 0;
    var artifacts = 0;
    var enchantments = 0;
    var other = 0;
    final colors = {for (final c in colorOrder) c: 0};
    final sourcesByColor = {for (final c in colorOrder) c: 0};
    var totalCards = 0;
    var totalValue = 0.0;
    var basicLands = 0;
    var multiColorLands = 0;
    var colorlessLands = 0;

    for (final c in items) {
      final qty = (c['deck_qty'] as num?)?.toInt() ?? 0;
      if (qty <= 0) continue;
      totalCards += qty;
      final typeLine = (c['type_line'] ?? '').toString();
      final isLand = CardTypes.isLand(typeLine);
      final cmc = manaValue(c['cmc'], c['mana_cost']);

      if (isLand) {
        lands += qty;
        if (CardTypes.isBasicLand(
            typeLine, (c['name'] ?? '').toString())) {
          basicLands += qty;
        }
        final nColors =
            CardTypes.identityColorCount(c['color_identity']);
        if (nColors >= 2) {
          multiColorLands += qty;
        } else if (nColors == 0) {
          colorlessLands += qty;
        }
      } else {
        switch (CardTypes.category(typeLine)) {
          case CardCategory.creatures:
            creatures += qty;
            break;
          case CardCategory.planeswalkers:
            planeswalkers += qty;
            break;
          case CardCategory.instants:
            instants += qty;
            break;
          case CardCategory.sorceries:
            sorceries += qty;
            break;
          case CardCategory.artifacts:
            artifacts += qty;
            break;
          case CardCategory.enchantments:
            enchantments += qty;
            break;
          default:
            other += qty;
        }
        if (cmc != null) {
          final bucket = cmc.floor().clamp(0, 6);
          curve[bucket] = (curve[bucket] ?? 0) + qty;
          mvSum += cmc * qty;
          mvCount += qty;
        }
      }

      for (final col in colorList(c['color_identity'])) {
        final up = col.trim().toUpperCase();
        if (colors.containsKey(up)) {
          colors[up] = colors[up]! + qty;
          if (isLand) sourcesByColor[up] = sourcesByColor[up]! + qty;
        }
      }

      final unit = ((c['price_usd'] as num?)?.toDouble() ??
          (c['price_ref_usd'] as num?)?.toDouble() ??
          0);
      totalValue += unit * qty;
    }

    return DeckStats(
      totalCards: totalCards,
      curve: curve,
      avgMv: mvCount == 0 ? 0 : mvSum / mvCount,
      mvCount: mvCount,
      types: DeckTypeCount(
        lands: lands,
        creatures: creatures,
        planeswalkers: planeswalkers,
        instants: instants,
        sorceries: sorceries,
        artifacts: artifacts,
        enchantments: enchantments,
        other: other,
      ),
      colors: colors,
      landCount: lands,
      basicLands: basicLands,
      multiColorLands: multiColorLands,
      colorlessLands: colorlessLands,
      manaSources: lands,
      sourcesByColor: sourcesByColor,
      totalValue: totalValue,
    );
  }
}
