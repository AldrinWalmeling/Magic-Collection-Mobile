import 'package:flutter_test/flutter_test.dart';
import 'package:magic_collection/services/card_types.dart';
import 'package:magic_collection/services/deck_stats.dart';

// Custo de mana tolerante a dados incompletos (cmc nulo/texto,
// mana_cost como fallback). Sem rede, sem banco.

void main() {
  group('manaValueFromCost', () {
    test('genérico + colorido', () {
      expect(DeckStatsService.manaValueFromCost('{2}{R}'), 3);
    });
    test('X vale 0', () {
      expect(DeckStatsService.manaValueFromCost('{X}{R}'), 1);
    });
    test('híbrido vale 1', () {
      expect(DeckStatsService.manaValueFromCost('{W/U}'), 1);
    });
    test('duplo vale 2', () {
      expect(DeckStatsService.manaValueFromCost('{2/W}'), 2);
    });
    test('neve vale 1', () {
      expect(DeckStatsService.manaValueFromCost('{S}{S}'), 2);
    });
    test('split soma os lados', () {
      expect(
          DeckStatsService.manaValueFromCost('{1}{R} // {3}{G}'), 6);
    });
    test('vazio e meio', () {
      expect(DeckStatsService.manaValueFromCost(''), 0);
      expect(DeckStatsService.manaValueFromCost('{½}'), 0.5);
    });
  });

  group('manaValue', () {
    test('numérico direto', () {
      expect(DeckStatsService.manaValue(2, '{2}'), 2);
      expect(DeckStatsService.manaValue(3, null), 3);
    });
    test('string numérica', () {
      expect(DeckStatsService.manaValue('3.0', null), 3);
    });
    test('fallback para mana_cost', () {
      expect(DeckStatsService.manaValue(null, '{2}{R}'), 3);
    });
    test('sem dado nenhum', () {
      expect(DeckStatsService.manaValue(null, null), isNull);
      expect(DeckStatsService.manaValue(null, ''), isNull);
    });
  });

  group('compute com dados incompletos', () {
    test('cmc nulo + mana_cost conta na curva e na média', () {
      final s = DeckStatsService.compute([
        {
          'deck_qty': 4,
          'cmc': null,
          'mana_cost': '{1}{R}',
          'type_line': 'Creature',
          'color_identity': ['R'],
        },
        {
          'deck_qty': 2,
          'cmc': '3.0',
          'mana_cost': '{3}',
          'type_line': 'Sorcery',
          'color_identity': [],
        },
      ]);
      expect(s.totalCards, 6);
      expect(s.mvCount, 6);
      expect(s.avgMv, closeTo((4 * 2 + 2 * 3) / 6, 0.001));
      expect(s.curve[2], 4);
      expect(s.curve[3], 2);
    });

    test('sem cmc e sem custo: excluída da média, não da contagem', () {
      final s = DeckStatsService.compute([
        {
          'deck_qty': 1,
          'cmc': null,
          'mana_cost': null,
          'type_line': 'Creature',
          'color_identity': [],
        },
      ]);
      expect(s.totalCards, 1);
      expect(s.mvCount, 0);
      expect(s.avgMv, 0);
      expect(s.types.creatures, 1);
    });
  });

  group('CardTypes multilíngue', () {
    test('criatura EN/PT/ES', () {
      expect(CardTypes.category('Creature — Elf'), 'creatures');
      expect(CardTypes.category('Criatura — Elfo'), 'creatures');
      expect(CardTypes.category('Criatura — Elfo'), 'creatures');
    });
    test('tipos PT/ES', () {
      expect(CardTypes.category('Terreno Básico — Floresta'), 'lands');
      expect(CardTypes.category('Tierra Básica — Bosque'), 'lands');
      expect(CardTypes.category('Encantamento'), 'enchantments');
      expect(CardTypes.category('Encantamiento'), 'enchantments');
      expect(CardTypes.category('Artefacto'), 'artifacts');
      expect(CardTypes.category('Feitiço'), 'sorceries');
      expect(CardTypes.category('Conjuro'), 'sorceries');
      expect(CardTypes.category('Mágica Instantânea'), 'instants');
      expect(CardTypes.category('Planinauta'), 'planeswalkers');
    });
    test('básica por tipo ou nome', () {
      expect(CardTypes.isBasicLand('Basic Land — Forest', 'Forest'),
          isTrue);
      expect(CardTypes.isBasicLand('Terreno Básico — Ilha', 'Ilha'),
          isTrue);
      expect(CardTypes.isBasicLand('Land', 'Bosque'), isTrue);
      expect(CardTypes.isBasicLand('Land — Gate', 'Portão'), isFalse);
    });
    test('lendária PT/ES', () {
      expect(CardTypes.isLegendary('Criatura Lendária'), isTrue);
      expect(CardTypes.isLegendary('Legendary Creature'), isTrue);
    });
    test('compute conta PT como criatura (não other)', () {      final s = DeckStatsService.compute([
        {
          'deck_qty': 3,
          'cmc': 2,
          'mana_cost': '{2}',
          'type_line': 'Criatura — Elfo',
          'color_identity': ['G'],
        },
        {
          'deck_qty': 36,
          'cmc': null,
          'mana_cost': null,
          'type_line': 'Terreno Básico — Floresta',
          'color_identity': ['G'],
        },
      ]);
      expect(s.types.creatures, 3);
      expect(s.types.other, 0);
      expect(s.landCount, 36);
      expect(s.basicLands, 36);
      expect(s.sourcesByColor['G'], 36);
    });
    test('terrenos multi e incolores', () {
      expect(CardTypes.identityColorCount(['W', 'U']), 2);
      expect(CardTypes.identityColorCount('["R"]'), 1);
      expect(CardTypes.identityColorCount([]), 0);
      expect(CardTypes.identityColorCount(null), 0);
      final s = DeckStatsService.compute([
        {
          'deck_qty': 4,
          'cmc': 0,
          'mana_cost': null,
          'type_line': 'Land',
          'color_identity': ['W', 'U'],
        },
        {
          'deck_qty': 2,
          'cmc': 0,
          'mana_cost': null,
          'type_line': 'Land',
          'color_identity': [],
        },
      ]);
      expect(s.landCount, 6);
      expect(s.basicLands, 0);
      expect(s.multiColorLands, 4);
      expect(s.colorlessLands, 2);
    });
  });
}
