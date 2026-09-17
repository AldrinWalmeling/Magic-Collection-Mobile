// Estatísticas calculadas das CARTAS REAIS do deck (Fase A).
// Tudo sai das colunas locais (`cmc`, `type_line`, `colors`,
// `color_identity`); nada mockado, nenhuma heurística inventada.
// Sem `ramp detection`: fontes de mana = terrenos (+ identidade).
import 'dart:convert';

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

    for (final c in items) {
      final qty = (c['deck_qty'] as num?)?.toInt() ?? 0;
      if (qty <= 0) continue;
      totalCards += qty;
      final tl = ((c['type_line'] ?? '') as String).toLowerCase();
      final isLand = tl.contains('land');
      final cmc = (c['cmc'] as num?)?.toDouble();

      if (isLand) {
        lands += qty;
      } else {
        if (tl.contains('creature')) {
          creatures += qty;
        } else if (tl.contains('planeswalker')) {
          planeswalkers += qty;
        } else if (tl.contains('instant')) {
          instants += qty;
        } else if (tl.contains('sorcery')) {
          sorceries += qty;
        } else if (tl.contains('artifact')) {
          artifacts += qty;
        } else if (tl.contains('enchantment')) {
          enchantments += qty;
        } else {
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
      manaSources: lands,
      sourcesByColor: sourcesByColor,
      totalValue: totalValue,
    );
  }
}
