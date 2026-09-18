// Classificação canônica de tipos de carta (Fase A++).
//
// PROBLEMA REAL: `ScryfallService.flatten()` grava `printed_type_line`
// (ex. PT "Criatura — Elfo") na coluna `type_line`, descartando o inglês.
// Todo o app casava substring em inglês ("creature", "land"...), então
// cartas PT/ES caíam em "other" e sumiam da curva/composição.
// Não existia nenhum dicionário de tipos — este é o ponto único de
// verdade, usado por stats, agrupamentos, terrenos básicos e validação
// de comandante. Cobre EN + PT + ES (idiomas do app).

/// Categorias de composição (chaves estáveis p/ UI e ordenação).
class CardCategory {
  static const commander = 'commander';
  static const creatures = 'creatures';
  static const planeswalkers = 'planeswalkers';
  static const artifacts = 'artifacts';
  static const enchantments = 'enchantments';
  static const instants = 'instants';
  static const sorceries = 'sorceries';
  static const lands = 'lands';
  static const other = 'other';

  /// Ordem de exibição dos grupos.
  static const order = [
    commander,
    creatures,
    planeswalkers,
    artifacts,
    enchantments,
    instants,
    sorceries,
    lands,
    other,
  ];
}

class CardTypes {
  CardTypes._();

  /// Minúsculas, sem acento (ver [_flat]).
  static const _creature = {'creature', 'criatura'};
  static const _planeswalker = {'planeswalker', 'planinauta'};
  static const _artifact = {'artifact', 'artefato', 'artefacto'};
  static const _enchantment = {
    'enchantment',
    'encantamento',
    'encantamiento'
  };
  // 'instant' casa EN + PT 'instantânea' + ES 'instantáneo'.
  static const _instant = {'instant'};
  static const _sorcery = {'sorcery', 'feitico', 'conjuro'};
  static const _land = {'land', 'terreno', 'tierra'};
  // flat() remove acentos: 'básico'/'básica' viram 'basico'/'basica'.
  static const _basic = {'basic', 'basico'};
  static const _legendary = {'legendary', 'lendari', 'legendario'};

  /// Nomes de básicos por idioma (EN/PT/ES, com/sem acento).
  static const _basicNames = {
    'forest',
    'floresta',
    'bosque',
    'island',
    'ilha',
    'isla',
    'mountain',
    'montanha',
    'montana',
    'plains',
    'planicie',
    'llanura',
    'swamp',
    'pantano',
    'wastes',
    'ermos',
    'yermos',
  };

  static const _accents = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ã': 'a',
    'é': 'e',
    'ê': 'e',
    'í': 'i',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
  };

  /// Lowercase + sem acento p/ casar "Planície"/"básica" etc.
  static String flat(Object? raw) {
    final s = (raw ?? '').toString().toLowerCase();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      buf.write(_accents[ch] ?? ch);
    }
    return buf.toString();
  }

  static bool _has(String flatLine, Set<String> needles) {
    for (final n in needles) {
      if (flatLine.contains(n)) return true;
    }
    return false;
  }

  static bool isLand(Object? typeLine) =>
      _has(flat(typeLine), _land);

  static bool isBasicLand(Object? typeLine, Object? name) {
    final tl = flat(typeLine);
    if (_has(tl, _basic) && _has(tl, _land)) return true;
    return _basicNames.contains(flat(name));
  }

  static bool isLegendary(Object? typeLine) =>
      _has(flat(typeLine), _legendary);

  /// Categoria de composição. Mesma precedência histórica do app
  /// (criatura > planinauta > instant > feitiço > artefato >
  /// encantamento), agora multilíngue. Terreno sai separado.
  static String category(Object? typeLine) {
    final tl = flat(typeLine);
    if (_has(tl, _land)) return CardCategory.lands;
    if (_has(tl, _creature)) return CardCategory.creatures;
    if (_has(tl, _planeswalker)) return CardCategory.planeswalkers;
    if (_has(tl, _instant)) return CardCategory.instants;
    if (_has(tl, _sorcery)) return CardCategory.sorceries;
    if (_has(tl, _artifact)) return CardCategory.artifacts;
    if (_has(tl, _enchantment)) return CardCategory.enchantments;
    return CardCategory.other;
  }

  /// Quantas cores distintas na identidade (p/ multicoloridas).
  static int identityColorCount(Object? colorIdentity) {
    final set = <String>{};
    final raw = colorIdentity;
    if (raw is Iterable) {
      for (final e in raw) {
        final up = e.toString().trim().toUpperCase();
        if ('WUBRG'.contains(up) && up.length == 1) set.add(up);
      }
    } else if (raw is String) {
      for (final ch in raw.toUpperCase().split('')) {
        if ('WUBRG'.contains(ch)) set.add(ch);
      }
    }
    return set.length;
  }
}
