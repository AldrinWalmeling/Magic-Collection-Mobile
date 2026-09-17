import 'package:flutter_test/flutter_test.dart';
import 'package:magic_collection/services/deck_availability.dart';
import 'package:magic_collection/services/deck_list_format.dart';
import 'package:magic_collection/services/deck_stats.dart';

// FASE 4 — Validação dos fluxos críticos (sem rede, sem banco).
// Deck ≠ Collection; disponibilidade; parser; stats.

Map<String, Object?> card({
  required int id,
  required String name,
  required int deckQty,
  String oracle = '',
  double? cmc,
  String type = '',
  List<String> colors = const [],
  List<String> identity = const [],
  double price = 0,
}) {
  return {
    'id': id,
    'name': name,
    'printed_name': name,
    'oracle_id': oracle,
    'deck_qty': deckQty,
    'cmc': cmc,
    'type_line': type,
    'colors': colors,
    'color_identity': identity,
    'price_usd': price,
  };
}

void main() {
  group('Disponibilidade (§1-§2, fluxos B/C)', () {
    // Collection: 2 Aang (outra impressão!), 4 Bolt, 0 Ring.
    final byOracle = {'o-aang': 2, 'o-bolt': 4};
    final byName = <String, int>{};

    test('Aang: deck 4, coleção 2 → faltam 2 (parcial)', () {
      final items = [
        card(id: 11, name: 'Aang', deckQty: 4, oracle: 'o-aang'),
      ];
      final a = DeckAvailabilityService.compute(items, byOracle, byName);
      expect(a.forCard(11).need, 4);
      expect(a.forCard(11).owned, 2);
      expect(a.forCard(11).missing, 2);
      expect(a.forCard(11).status, AvailStatus.partial);
    });

    test('Bolt: 4/4 → completo', () {
      final items = [
        card(id: 12, name: 'Lightning Bolt', deckQty: 4, oracle: 'o-bolt'),
      ];
      final a = DeckAvailabilityService.compute(items, byOracle, byName);
      expect(a.forCard(12).status, AvailStatus.ok);
      expect(a.forCard(12).missing, 0);
    });

    test('Ring: 1/0 → faltam 1 (ausente)', () {
      final items = [
        card(id: 13, name: 'Sol Ring', deckQty: 1, oracle: 'o-ring'),
      ];
      final a = DeckAvailabilityService.compute(items, byOracle, byName);
      expect(a.forCard(13).status, AvailStatus.missing);
      expect(a.forCard(13).missing, 1);
    });

    test('Totais: 9 pedidas, 6 possuídas, 3 faltando, 2 distintas faltando',
        () {
      final items = [
        card(id: 11, name: 'Aang', deckQty: 4, oracle: 'o-aang'),
        card(id: 12, name: 'Lightning Bolt', deckQty: 4, oracle: 'o-bolt'),
        card(id: 13, name: 'Sol Ring', deckQty: 1, oracle: 'o-ring'),
      ];
      final a = DeckAvailabilityService.compute(items, byOracle, byName);
      expect(a.totalNeed, 9);
      expect(a.totalOwned, 6);
      expect(a.totalMissing, 3);
      expect(a.missingDistinct, 2);
      expect(a.distinctTotal, 3);
    });

    test('Impressão diferente não gera falso negativo (mesmo oracle)', () {
      // Deck usa impressão id=21 (PT), coleção tem impressão id=99 (EN).
      final items = [
        card(id: 21, name: 'Aang', deckQty: 2, oracle: 'o-aang'),
      ];
      final a = DeckAvailabilityService.compute(items, byOracle, byName);
      expect(a.forCard(21).owned, 2);
      expect(a.forCard(21).status, AvailStatus.ok);
    });

    test('Sem oracle: fallback por nome normalizado', () {
      final items = [
        card(id: 31, name: 'Floresta', deckQty: 3, oracle: ''),
      ];
      final names = {'floresta': 10};
      final a = DeckAvailabilityService.compute(items, {}, names);
      expect(a.forCard(31).owned, 10);
      expect(a.forCard(31).status, AvailStatus.ok);
    });

    test('Valores possui/falta (fluxo D: sem preço não quebra)', () {
      final items = [
        card(id: 11, name: 'Aang', deckQty: 4, oracle: 'o-aang', price: 5),
        card(id: 13, name: 'Sol Ring', deckQty: 1, oracle: 'o-ring'),
      ];
      final a = DeckAvailabilityService.compute(items, byOracle, byName);
      expect(a.ownedValue, 10); // 2 possuídas x 5
      expect(a.missingValue, 10); // 2 faltantes x 5
      expect(a.pricedCount, 1);
      expect(a.unpricedCount, 1);
    });
  });

  group('Parser de decklist (§39)', () {
    test('Arena: Commander/Deck/Sideboard + 4x + [SET]', () {
      const txt = '''Commander
1 Aang

Deck
4 Lightning Bolt [M10]
2 Counterspell
Sol Ring x1

Sideboard
3 Pyroblast''';
      final p = DeckListFormat.parseDeckText(txt);
      final entries = (p['entries'] as List).cast<Map<String, Object?>>();
      expect(p['commander'], 'Aang');
      expect(entries.length, 3); // sideboard fora
      expect(entries[0]['name'], 'Lightning Bolt');
      expect(entries[0]['qty'], 4);
      expect(entries[0]['set'], 'M10');
      expect(entries[1]['qty'], 2);
      expect(entries[2]['name'], 'Sol Ring');
      expect(entries[2]['qty'], 1);
    });

    test('Comentários e linhas vazias ignorados', () {
      const txt = '# comment\n// outro\n\n4 Bolt';
      final p = DeckListFormat.parseDeckText(txt);
      final entries = (p['entries'] as List).cast<Map<String, Object?>>();
      expect(entries.length, 1);
      expect(entries[0]['name'], 'Bolt');
    });

    test('JSON fiel .mcdeck.json', () {
      const js =
          '{"format":"magic_collection_deck","version":1,"commander":{"name":"Aang"},"cards":[{"name":"Aang","quantity":4},{"name":"Xyz Abc","quantity":2}]}';
      final p = DeckListFormat.parseDeckJson(js)!;
      final entries = (p['entries'] as List).cast<Map<String, Object?>>();
      expect(p['commander'], 'Aang');
      expect(entries.length, 2);
      expect(entries[0]['qty'], 4);
    });

    test('JSON inválido retorna null', () {
      expect(DeckListFormat.parseDeckJson('não é json'), isNull);
      expect(DeckListFormat.parseDeckJson('{"sem":[]}'), isNull);
    });
  });

  group('Stats (§9-§11)', () {
    test('Curva, média (sem terrenos), tipos e fontes', () {
      final items = [
        card(
            id: 1,
            name: 'Bolt',
            deckQty: 6,
            cmc: 1,
            type: 'Instant',
            colors: ['R'],
            identity: ['R']),
        card(
            id: 2,
            name: 'Dragon',
            deckQty: 2,
            cmc: 5,
            type: 'Creature — Dragon',
            colors: ['R'],
            identity: ['R']),
        card(
            id: 3,
            name: 'Mountain',
            deckQty: 10,
            type: 'Basic Land — Mountain',
            identity: ['R']),
        card(
            id: 4,
            name: 'Ring',
            deckQty: 1,
            cmc: 1,
            type: 'Artifact',
            identity: []),
      ];
      final s = DeckStatsService.compute(items);
      expect(s.totalCards, 19);
      expect(s.curve[1], 7);
      expect(s.curve[5], 2);
      expect(s.curve[0], 0);
      // Média só não-terrenos: (6*1 + 2*5 + 1*1)/9 = 17/9.
      expect(s.avgMv, closeTo(17 / 9, 0.001));
      expect(s.mvCount, 9);
      expect(s.types.instants, 6);
      expect(s.types.creatures, 2);
      expect(s.types.artifacts, 1);
      expect(s.types.lands, 10);
      expect(s.landCount, 10);
      expect(s.manaSources, 10);
      expect(s.sourcesByColor['R'], 10);
      expect(s.colors['R'], 18); // 6+2 mágicas + 10 terrenos
    });
  });
}
