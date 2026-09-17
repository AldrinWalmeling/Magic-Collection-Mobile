import 'package:sqflite/sqflite.dart';

import 'scryfall_service.dart';

/// Disponibilidade Deck x Collection — LÓGICA CENTRAL (Fase A).
///
/// REGRA FUNDAMENTAL: deck e coleção são coisas diferentes. O deck só
/// CONSULTA a coleção; nunca escreve nela. Mesma lógica alimenta: deck
/// pessoal, comunidade, cópia, importação, notificações e faltantes.
///
/// Casamento por `oracle_id` (conceito), com fallback para nome
/// normalizado — impressão/idioma diferentes NÃO geram falso negativo.

enum AvailStatus { ok, partial, missing }

class CardAvailability {
  const CardAvailability({required this.need, required this.owned});

  /// Cópias exigidas pelo deck.
  final int need;

  /// Cópias possuídas na collection (qualquer impressão/idioma).
  final int owned;

  int get missing => (need - owned).clamp(0, need);

  AvailStatus get status =>
      owned >= need ? AvailStatus.ok : owned > 0 ? AvailStatus.partial : AvailStatus.missing;
}

class DeckAvailability {
  const DeckAvailability({
    required this.byCardId,
    required this.totalNeed,
    required this.totalOwned,
    required this.missingDistinct,
    required this.distinctTotal,
    required this.ownedValue,
    required this.missingValue,
    required this.pricedCount,
    required this.unpricedCount,
  });

  /// Disponibilidade por id da linha `cards` (chave do item no deck).
  final Map<int, CardAvailability> byCardId;

  /// Cópias totais exigidas / possuídas (possuídas limitadas ao need).
  final int totalNeed;
  final int totalOwned;

  int get totalMissing => totalNeed - totalOwned;

  /// Cartas distintas faltantes / distintas totais.
  final int missingDistinct;
  final int distinctTotal;

  /// Valor (USD) das cópias possuídas vs faltantes.
  final double ownedValue;
  final double missingValue;

  /// Cartas distintas com/sem preço disponível.
  final int pricedCount;
  final int unpricedCount;

  double get completeness =>
      totalNeed == 0 ? 1.0 : totalOwned / totalNeed;

  CardAvailability forCard(int cardId) =>
      byCardId[cardId] ?? const CardAvailability(need: 0, owned: 0);

  static const empty = DeckAvailability(
    byCardId: {},
    totalNeed: 0,
    totalOwned: 0,
    missingDistinct: 0,
    distinctTotal: 0,
    ownedValue: 0,
    missingValue: 0,
    pricedCount: 0,
    unpricedCount: 0,
  );
}

class DeckAvailabilityService {
  /// Índice da coleção: oracle_id -> cópias (só quantity>0).
  static Future<Map<String, int>> ownedByOracle(Database db) async {
    final out = <String, int>{};
    try {
      final rows = await db.rawQuery('''
        SELECT oracle_id AS o, COALESCE(SUM(quantity),0) AS n
        FROM cards
        WHERE quantity > 0 AND oracle_id IS NOT NULL AND oracle_id <> ''
        GROUP BY oracle_id''');
      for (final r in rows) {
        out[(r['o'] ?? '').toString()] =
            (r['n'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return out;
  }

  /// Índice da coleção: nome normalizado -> cópias (fallback sem oracle).
  static Future<Map<String, int>> ownedByName(Database db) async {
    final out = <String, int>{};
    try {
      final rows = await db.rawQuery('''
        SELECT name AS n, printed_name AS p, COALESCE(SUM(quantity),0) AS q
        FROM cards
        WHERE quantity > 0
        GROUP BY name, printed_name''');
      for (final r in rows) {
        final q = (r['q'] as num?)?.toInt() ?? 0;
        for (final key in [
          ScryfallService.normalize((r['n'] ?? '').toString()),
          ScryfallService.normalize((r['p'] ?? '').toString()),
        ]) {
          if (key.isEmpty) continue;
          out[key] = (out[key] ?? 0) + q;
        }
      }
    } catch (_) {}
    return out;
  }

  /// Calcula disponibilidade dos [items] (linhas `cards.* + deck_qty`).
  /// Preço por cópia: `price_usd ?? price_ref_usd` (padrão do app).
  static DeckAvailability compute(
    List<Map<String, Object?>> items,
    Map<String, int> byOracle,
    Map<String, int> byName,
  ) {
    final byCardId = <int, CardAvailability>{};
    var totalNeed = 0;
    var totalOwned = 0;
    var missingDistinct = 0;
    var ownedValue = 0.0;
    var missingValue = 0.0;
    var pricedCount = 0;
    var unpricedCount = 0;

    for (final c in items) {
      final id = (c['id'] as num?)?.toInt() ?? -1;
      final need = (c['deck_qty'] as num?)?.toInt() ?? 0;
      if (id < 0 || need <= 0) continue;
      final oracle = (c['oracle_id'] ?? '').toString();
      var owned = 0;
      if (oracle.isNotEmpty && byOracle.containsKey(oracle)) {
        owned = byOracle[oracle]!;
      } else {
        final n1 =
            ScryfallService.normalize((c['name'] ?? '').toString());
        final n2 =
            ScryfallService.normalize((c['printed_name'] ?? '').toString());
        owned = byName[n1] ?? (n2.isNotEmpty ? (byName[n2] ?? 0) : 0);
      }
      final a = CardAvailability(need: need, owned: owned);
      byCardId[id] = a;
      totalNeed += need;
      totalOwned += owned.clamp(0, need);
      if (a.status != AvailStatus.ok) missingDistinct++;
      final unit = ((c['price_usd'] as num?)?.toDouble() ??
          (c['price_ref_usd'] as num?)?.toDouble() ??
          0);
      if (unit > 0) {
        pricedCount++;
        ownedValue += owned.clamp(0, need) * unit;
        missingValue += a.missing * unit;
      } else {
        unpricedCount++;
      }
    }
    return DeckAvailability(
      byCardId: byCardId,
      totalNeed: totalNeed,
      totalOwned: totalOwned,
      missingDistinct: missingDistinct,
      distinctTotal: byCardId.length,
      ownedValue: ownedValue,
      missingValue: missingValue,
      pricedCount: pricedCount,
      unpricedCount: unpricedCount,
    );
  }

  /// Atalho: lê os itens do deck + índice da coleção e calcula tudo.
  static Future<DeckAvailability> forDeck(Database db, int deckId) async {
    List<Map<String, Object?>> items = [];
    try {
      items = await db.rawQuery('''
        SELECT c.*, dc.quantity AS deck_qty
        FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
        WHERE dc.deck_id = ?''', [deckId]);
    } catch (_) {}
    final results = await Future.wait([
      ownedByOracle(db),
      ownedByName(db),
    ]);
    return compute(items, results[0], results[1]);
  }
}
