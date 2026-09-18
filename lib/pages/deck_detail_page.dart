import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/app_database.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/currency_service.dart';
import '../services/deck_availability.dart';
import '../services/deck_list_format.dart';
import '../services/deck_stats.dart';
import '../services/card_types.dart';
import '../services/export_service.dart';
import '../services/scryfall_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/deck_view.dart';
import '../widgets/mana_curve_chart.dart';
import '../widgets/mtg_symbols.dart';
import 'card_detail_sheet.dart';
import 'community_publish.dart';

// Editor do deck — espelha pages/decks_page.py + services/decks_database.py.
// Adicionar tem DOIS modos (alternador):
//  - "Coleção" (padrão): busca no banco local, funciona offline.
//  - "Scryfall": autocomplete + busca online (carta entra no catálogo
//    com quantity=0 se for só-do-deck, igual ao desktop).
// Formato, comandante, stats, exportar TXT, importar lista colada.

class DeckDetailPage extends StatefulWidget {
  final int deckId;
  final String deckName;
  const DeckDetailPage(
      {super.key, required this.deckId, required this.deckName});

  @override
  State<DeckDetailPage> createState() => _DeckDetailPageState();
}

class _DeckDetailPageState extends State<DeckDetailPage> {
  List<Map<String, Object?>> _items = [];
  final _query = TextEditingController();
  Timer? _debounce;

  // modo de adição: 'collection' | 'scryfall'
  String _addMode = 'collection';
  String _scryLang = 'all'; // filtro de idioma dos printings
  List<Map<String, Object?>> _localResults = [];
  List<String> _suggestions = [];
  List<Map<String, dynamic>> _scryResults = [];
  bool _scryLoading = false;
  String? _scryError;
  bool _adding = false;
  int _scryReq = 0;

  String _format = 'livre';
  int? _commanderId;
  int? _previewCardId;
  bool _importing = false;
  String _importStatus = '';

  // Filtros da lista de cartas do deck, espelhando os da Coleção.
  final _typeFilter = TextEditingController();
  List<String> _allSets = [];
  String _rarity = 'all';
  String _setName = 'all';
  String _color = 'all';
  String _abilityFilter = 'all';
  String _order = 'name ASC';
  bool _favoritesOnly = false;
  bool _showFilters = false;
  // Validação do formato (sininho) + modo de exibição.
  List<String> _problems = [];
  bool _deckViewGrid = false;
  int _gridCols = 2;
  // Disponibilidade Deck x Collection + estatísticas (Fase A).
  // Recalculados a cada _reload: o estado flui dos dados, sem timers.
  DeckAvailability _avail = DeckAvailability.empty;
  DeckStats _deckStats = DeckStats.empty;
  // Rolagem única da página (padrão do Social): cabeçalho, stats,
  // filtros e cartas rolam juntos — sem topo fixo nem snap.
  final _cardsScroll = ScrollController();
  // Cabeçalho recolhível (persistido): menos poluição, mais grade.
  static const _headerKey = 'deck_header_expanded';
  bool _headerExpanded = true;

  // Estado local da ExpansionTile de estatísticas. Quando ambos os blocos
  // estão fechados, o topo deixa de usar um scroll view limitado e volta a
  // ocupar somente a altura real do conteúdo.
  bool _statsExpanded = false;

  Future<void> _loadHeader() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(_headerKey);
      if (!mounted || v == null) return;
      setState(() => _headerExpanded = v);
    } catch (_) {}
  }

  Future<void> _toggleHeader() async {
    setState(() => _headerExpanded = !_headerExpanded);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_headerKey, _headerExpanded);
    } catch (_) {}
  }

  /// Regras por formato (espelha services/deck_formats.py).
  static const _deckRules = {
    'livre': {'min': 0, 'max': -1, 'copies': -1, 'commander': false},
    'standard': {'min': 60, 'max': -1, 'copies': 4, 'commander': false},
    'pioneer': {'min': 60, 'max': -1, 'copies': 4, 'commander': false},
    'modern': {'min': 60, 'max': -1, 'copies': 4, 'commander': false},
    'legacy': {'min': 60, 'max': -1, 'copies': 4, 'commander': false},
    'vintage': {'min': 60, 'max': -1, 'copies': 4, 'commander': false},
    'pauper': {'min': 60, 'max': -1, 'copies': 4, 'commander': false},
    'commander': {'min': 100, 'max': 100, 'copies': 1, 'commander': true},
    'brawl': {'min': 60, 'max': 60, 'copies': 1, 'commander': true},
  };

  static const _formats = {
    'livre': 'fmt_livre',
    'standard': 'fmt_standard',
    'pioneer': 'Pioneer',
    'modern': 'Modern',
    'legacy': 'Legacy',
    'vintage': 'Vintage',
    'pauper': 'Pauper',
    'commander': 'Commander',
    'brawl': 'Brawl',
  };

  static const _rarityKeys = ['all', 'common', 'uncommon', 'rare', 'mythic'];

  static const _colorKeys = [
    'all',
    'W',
    'U',
    'B',
    'R',
    'G',
    'multi',
    'colorless',
  ];

  static const _orderLabels = <String, String>{
    'name ASC': 'Nome (A–Z)',
    'name DESC': 'Nome (Z–A)',
    'price_usd DESC': 'Valor (maior → menor)',
    'price_usd ASC': 'Valor (menor → maior)',
    'set_name ASC': 'Edição (A–Z)',
    'quantity DESC': 'Quantidade (maior → menor)',
    'quantity ASC': 'Quantidade (menor → maior)',
  };

  static const _abilityLabels = <String, String>{
    'all': 'Todas',
    'flying': 'Voar',
    'lifelink': 'Lifelink',
    'deathtouch': 'Toque mortífero',
    'first_strike': 'First strike',
    'double_strike': 'Double strike',
    'haste': 'Ímpeto',
    'hexproof': 'Resistência à magia (Hexproof)',
    'indestructible': 'Indestrutível',
    'menace': 'Ameaçar',
    'reach': 'Alcance',
    'trample': 'Atropelar',
    'vigilance': 'Vigilância',
    'ward': 'Ward',
    'flash': 'Flash',
    'defender': 'Defensor',
    'sacrifice': 'Sacrificar',
    'graveyard_return': 'Retornar do cemitério',
    'exile': 'Exilar',
    'destroy': 'Destruir',
    'discard': 'Descartar',
    'draw': 'Comprar carta',
    'counter': 'Anular / Counter',
    'create_token': 'Criar ficha',
    'mill': 'Milling',
    'scry': 'Scry',
    'gain_life': 'Ganhar vida',
    'lose_life': 'Perder vida',
  };

  static const _cp1252Bytes = <int, int>{
    0x20AC: 0x80,
    0x201A: 0x82,
    0x0192: 0x83,
    0x201E: 0x84,
    0x2026: 0x85,
    0x2020: 0x86,
    0x2021: 0x87,
    0x02C6: 0x88,
    0x2030: 0x89,
    0x0160: 0x8A,
    0x2039: 0x8B,
    0x0152: 0x8C,
    0x017D: 0x8E,
    0x2018: 0x91,
    0x2019: 0x92,
    0x201C: 0x93,
    0x201D: 0x94,
    0x2022: 0x95,
    0x2013: 0x96,
    0x2014: 0x97,
    0x02DC: 0x98,
    0x2122: 0x99,
    0x0161: 0x9A,
    0x203A: 0x9B,
    0x0153: 0x9C,
    0x017E: 0x9E,
    0x0178: 0x9F,
  };

  static int? _mojibakeByte(int rune) =>
      _cp1252Bytes[rune] ?? (rune <= 0xFF ? rune : null);

  static String _repairMojibake(String value) {
    var current = value;

    // Corrige cadeias UTF-8 interpretadas como Windows-1252/Latin-1.
    // Fazemos algumas passagens porque alguns dados podem ter sido
    // codificados duas vezes antes de chegar ao banco.
    for (var pass = 0; pass < 4; pass++) {
      final runes = current.runes.toList();
      final out = StringBuffer();
      var changed = false;

      for (var i = 0; i < runes.length;) {
        final first = runes[i];

        int? decodedLength;
        List<int>? bytes;

        if ((first == 0xC2 || first == 0xC3) && i + 1 < runes.length) {
          final second = _mojibakeByte(runes[i + 1]);
          if (second != null) {
            bytes = [first, second];
            decodedLength = 2;
          }
        } else if (first == 0xE2 && i + 2 < runes.length) {
          final second = _mojibakeByte(runes[i + 1]);
          final third = _mojibakeByte(runes[i + 2]);
          if (second != null && third != null) {
            bytes = [first, second, third];
            decodedLength = 3;
          }
        } else if (first == 0xF0 && i + 3 < runes.length) {
          final second = _mojibakeByte(runes[i + 1]);
          final third = _mojibakeByte(runes[i + 2]);
          final fourth = _mojibakeByte(runes[i + 3]);
          if (second != null && third != null && fourth != null) {
            bytes = [first, second, third, fourth];
            decodedLength = 4;
          }
        }

        if (bytes != null && decodedLength != null) {
          try {
            out.write(utf8.decode(bytes));
            i += decodedLength;
            changed = true;
            continue;
          } catch (_) {
            // Sequência legítima/ambígua: preserva os caracteres originais.
          }
        }

        out.write(String.fromCharCode(first));
        i++;
      }

      final next = out.toString();
      if (!changed || next == current) break;
      current = next;
    }

    return current;
  }

  static Object? _sanitizeValue(Object? value) {
    // Preserva a estrutura/tipo original retornado pelo banco/API.
    // Strings JSON (como card_faces/card_printings) continuam Strings;
    // o parser específico de habilidades é que as decodifica quando necessário.
    if (value is String) return _repairMojibake(value);

    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(
          key.toString(),
          _sanitizeValue(item),
        ),
      );
    }

    if (value is Iterable) {
      return value.map(_sanitizeValue).toList(growable: false);
    }

    return value;
  }

  static Map<String, Object?> _sanitizeDbCard(
    Map<String, Object?> card,
  ) {
    final sanitized = _sanitizeValue(card);
    if (sanitized is Map) {
      return sanitized.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return Map<String, Object?>.of(card);
  }

  static Map<String, dynamic> _sanitizeApiCard(
    Map<String, dynamic> card,
  ) {
    final sanitized = _sanitizeValue(card);
    if (sanitized is Map) {
      return sanitized.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return Map<String, dynamic>.of(card);
  }

  static String _abilityRaw(Map<String, Object?> card) {
    final parts = <String>[];

    void collect(Object? value) {
      if (value == null) return;

      if (value is String) {
        final repaired = _repairMojibake(value).trim().toLowerCase();

        if ((repaired.startsWith('[') || repaired.startsWith('{'))) {
          try {
            final decoded = jsonDecode(repaired);
            collect(decoded);
            return;
          } catch (_) {}
        }

        if (repaired.isNotEmpty) parts.add(repaired);
        return;
      }

      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase();
          if (key == 'oracle_text' ||
              key == 'printed_text' ||
              key == 'keywords' ||
              key == 'type_line' ||
              key == 'printed_type_line') {
            collect(entry.value);
          } else if (key == 'card_faces' ||
              key == 'faces' ||
              key == 'card_printings') {
            collect(entry.value);
          }
        }
        return;
      }

      if (value is Iterable) {
        for (final item in value) {
          collect(item);
        }
        return;
      }

      collect(value.toString());
    }

    collect(card['oracle_text']);
    collect(card['printed_text']);
    collect(card['keywords']);
    collect(card['type_line']);
    collect(card['printed_type_line']);
    collect(card['card_faces']);
    collect(card['faces']);
    collect(card['card_printings']);

    return parts.join(' ');
  }

  static bool _containsAny(String raw, List<String> terms) =>
      terms.any(raw.contains);

  static bool _matchesAbility(Map<String, Object?> card, String ability) {
    if (ability == 'all') return true;
    final raw = _abilityRaw(card);

    switch (ability) {
      case 'flying':
        return _containsAny(raw, [
          'flying', 'voar', 'voa', 'voadora', 'vuela', 'volar', 'vol',
          'volare', 'fliegend', 'fliegen', 'volare', '飛行', '비행',
          'летает', 'полет', '飞行', '飛行',
        ]);
      case 'lifelink':
        return _containsAny(raw, [
          'lifelink', 'vínculo com a vida', 'vinculo com a vida',
          'vínculo con la vida', 'vinculo con la vida', 'lien de vie',
          'lebensverknüpfung', 'lebensverknupfung', 'legame vitale',
          'vínculo vital', '絆魂', '생명연결', 'связь с жизнью', '系命', '繫命',
        ]);
      case 'deathtouch':
        return _containsAny(raw, [
          'deathtouch', 'toque mortífero', 'toque mortal', 'contact mortel',
          'todesberührung', 'todesberuhrung', 'tocco letale', 'toque letal',
          '接死', '치명타', 'смертельное касание', '死触', '死觸',
        ]);
      case 'first_strike':
        return _containsAny(raw, [
          'first strike', 'initiative', 'iniciativa', 'daña primero',
          'dano primero', 'dança primeiro', 'erstschlag', 'attacco improvviso',
          '先制攻撃', '선제공격', 'первый удар', '先攻', '先手攻撃',
        ]);
      case 'double_strike':
        return _containsAny(raw, [
          'double strike', 'golpe duplo', 'golpe doble', 'double initiative',
          'doppio attacco', 'erst- und doppelschlag', 'double strike',
          '二段攻撃', '이단 공격', 'двойной удар', '二重先制',
        ]);
      case 'haste':
        return _containsAny(raw, [
          'haste', 'ímpeto', 'impeto', 'prisa', 'rapidité', 'eile',
          'rapidità', 'rapidez', '速攻', '신속', 'ускорение', '敏捷',
        ]);
      case 'hexproof':
        return _containsAny(raw, [
          'hexproof', 'resistência à magia', 'resistencia a magia',
          'antimalefício', 'antimaleficio', 'antimaleficio', 'défense talismanique',
          'verhexungsfluchsicherheit', 'antimalocchio', '呪禁', '방호',
          'порчеустойчивость', '辟邪', '辟邪',
        ]);
      case 'indestructible':
        return _containsAny(raw, [
          'indestructible', 'indestrutível', 'indestructivel', 'indestructible',
          'indestructible', 'unzerstörbar', 'indistruttibile', '破壊不能',
          '무적', 'неразрушимый', '不灭', '不滅',
        ]);
      case 'menace':
        return _containsAny(raw, [
          'menace', 'ameaçar', 'ameaçador', 'amenaza', 'menace', 'bedrohlich',
          'minacciare', 'menace', '威迫', '위협', 'угроза', '威慑', '威懾',
        ]);
      case 'reach':
        return _containsAny(raw, [
          'reach', 'alcance', 'alcanzar', 'portée', 'reichweite', 'portata',
          'alcance', '到達', '대공', 'достижимость', '延到',
        ]);
      case 'trample':
        return _containsAny(raw, [
          'trample', 'atropelar', 'atropelo', 'arrollar', 'piétinement',
          'überrennen', 'travolgere', 'atropellare', '践踏', '돌진',
          'пробивное', '践踏',
        ]);
      case 'vigilance':
        return _containsAny(raw, [
          'vigilance', 'vigilância', 'vigilancia', 'vigilanz', 'vigilanza',
          'vigilancia', '警戒', '경계', 'бдительность', '警戒',
        ]);
      case 'ward':
        return _containsAny(raw, [
          'ward', 'salvaguarda', 'resguardo', 'proteção', 'proteccion',
          'ward', 'schutz', 'tutela', '護法', '방호', 'оберег', '护幕', '護幕',
        ]);
      case 'flash':
        return _containsAny(raw, [
          'flash', 'lampejo', 'destello', 'éclair', 'aufblitzen', 'lampo',
          'flash', '瞬速', '섬광', 'вспышка', '闪现', '閃現',
        ]);
      case 'defender':
        return _containsAny(raw, [
          'defender', 'defensor', 'defensora', 'defensive', 'défenseur',
          'verteidiger', 'difensore', '守備', '방어', 'защитник', '防御者',
        ]);
      case 'sacrifice':
        return _containsAny(raw, [
          'sacrifice', 'sacrificar', 'sacrifica', 'sacrifice', 'opfern',
          'sacrificare', 'sacrificar', '生け贄', '희생', 'жертва', '牺牲', '犧牲',
        ]);
      case 'graveyard_return':
        return _containsAny(raw, [
          'graveyard', 'cemitério', 'cemiterio', 'cementerio', 'cimetière',
          'friedhof', 'cimitero', '墓地', '무덤', 'кладбище', '墓地',
        ]) &&
            _containsAny(raw, [
              'return', 'retornar', 'voltar', 'devolver', 'regresar', 'retourner',
              'zurück', 'zuruck', 'ritorn', 'volver', '戻す', '돌아', 'вернуть',
              '返回', '回墓',
            ]);
      case 'exile':
        return _containsAny(raw, [
          'exile', 'exilar', 'exilia', 'exiliar', 'desterrar', 'exiler',
          'ins exil', 'ins exil', 'esiliare', '추방', '追放', 'изгнать',
          '放逐', '放逐',
        ]);
      case 'destroy':
        return _containsAny(raw, [
          'destroy', 'destruir', 'destruye', 'détruire', 'zerstören',
          'zerstoren', 'distruggere', 'destruír', '破壊', '파괴', 'уничтожить',
          '摧毁', '摧毀',
        ]);
      case 'discard':
        return _containsAny(raw, [
          'discard', 'descartar', 'descarta', 'défausser', 'abwerfen',
          'scartare', 'descartar', '捨て', '버리', 'сбросить', '弃牌', '棄牌',
        ]);
      case 'draw':
        return _containsAny(raw, [
          'draw a card', 'draw cards', 'draw ', 'comprar uma carta',
          'compre uma carta', 'comprar cartas', 'robar una carta',
          'robar cartas', 'piocher une carte', 'piocher des cartes',
          'eine karte ziehen', 'pesca una carta', 'pesca carte',
          '카드를 뽑', 'カードを引', 'взять карту', '抽一张牌', '抽一張牌',
        ]);
      case 'counter':
        return _containsAny(raw, [
          'counter target', 'counter spell', 'counter that',
          'anular alvo', 'anule a mágica', 'anular a mágica',
          'neutralizar a mágica', 'neutralize a mágica',
          'contrarrestar', 'contrarresta',
          'contrecarrer', 'neutralisieren', 'neutralisiere',
          'neutralizzare', '打ち消す', '打消す', '무효화',
          'контрить', 'отменить заклинание', '反击', '反擊',
        ]);
      case 'create_token':
        return (_containsAny(raw, [
              'create a ',
              'create one ',
              'criar uma ',
              'criar um ',
              'crie uma ',
              'crear una ',
              'crear un ',
              'créer un ',
              'erschaffe',
              'crea una ',
              'crea un ',
              'token',
              'ficha',
              'ficha',
              'jeton',
              'spielstein',
              'pedina',
              'トークン',
              '토큰',
              'жетон',
              '衍生物',
            ]) &&
            _containsAny(raw, [
              'token', 'ficha', 'jeton', 'spielstein', 'pedina',
              'トークン', '토큰', 'жетон', '衍生物',
            ]));
      case 'mill':
        return _containsAny(raw, [
          'mill', 'milling', 'moer cartas', 'moa cartas',
          'moa a biblioteca', 'moler cartas', 'meule les cartes',
          'mühle', 'macinare', 'macina carte',
          'ライブラリーの上から', 'ライブラリーを切削',
          '덱에서 밀', '덱을 밀', 'карты с верха библиотеки',
          '磨掉', '磨牌',
        ]);
      case 'scry':
        return _containsAny(raw, [
          'scry', 'adivinhar', 'vidência', 'scry', 'mirar', 'espiar',
          '占術', '점술', 'предсказание', '占卜',
        ]);
      case 'gain_life':
        return _containsAny(raw, [
          'gain life', 'gained life', 'gain 1 life', 'gain 2 life',
          'gain 3 life', 'gain 4 life', 'gain 5 life',
          'ganha vida', 'ganhar vida', 'ganhe vida',
          'ganha pontos de vida', 'ganhar pontos de vida',
          'ganhe pontos de vida', 'ganar vida', 'ganar vidas',
          'gagner des points de vie', 'lebenspunkte erhalten',
          'lebenspunkte gewinn', 'guadagnare punti vita',
          'ライフを得', '생명점을 얻', 'получить жизнь',
          'получите жизнь', '获得生命', '獲得生命',
        ]);
      case 'lose_life':
        return _containsAny(raw, [
          'lose life', 'perde vida', 'perder vida', 'perca vida',
          'perder vidas', 'perder puntos de vida', 'perdre des points de vie',
          'lebenspunkte verlieren', 'perdere punti vita',
          'ライフを失', '생명점을 잃', 'потерять жизнь', '失去生命',
        ]);
      default:
        return false;
    }
  }

  static String _sortName(Map<String, Object?> card) =>
      _repairMojibake(
        (card['name'] ?? card['printed_name'] ?? '').toString(),
      ).trim().toLowerCase();

  static double _cardPrice(Map<String, Object?> card) {
    final values = [
      card['price_usd'],
      card['price_ref_usd'],
      card['value_usd'],
      card['price'],
    ];
    for (final value in values) {
      final parsed = double.tryParse(value?.toString() ?? '');
      if (parsed != null && parsed.isFinite) return parsed;
    }
    return 0;
  }

  static String rarityLabel(String key) => switch (key) {
        'common' => AppLocale.t('rar_common'),
        'uncommon' => AppLocale.t('rar_uncommon'),
        'rare' => AppLocale.t('rar_rare'),
        'mythic' => AppLocale.t('rar_mythic'),
        _ => AppLocale.t('rar_all'),
      };

  static String colorLabel(String key) => switch (key) {
        'W' => AppLocale.t('col_white'),
        'U' => AppLocale.t('col_blue'),
        'B' => AppLocale.t('col_black'),
        'R' => AppLocale.t('col_red'),
        'G' => AppLocale.t('col_green'),
        'multi' => AppLocale.t('col_multi'),
        'colorless' => AppLocale.t('col_colorless'),
        _ => AppLocale.t('rar_all'),
      };

  bool _matchesDeckFilters(Map<String, Object?> card) {
    if (_rarity != 'all' &&
        ((card['rarity'] ?? '').toString().toLowerCase() != _rarity)) {
      return false;
    }

    if (_setName != 'all' && (card['set_name'] ?? '').toString() != _setName) {
      return false;
    }

    if (_typeFilter.text.trim().isNotEmpty) {
      final needle = _typeFilter.text.trim().toLowerCase();
      final typeLine = (card['type_line'] ?? '').toString().toLowerCase();
      if (!typeLine.contains(needle)) return false;
    }

    if (_color != 'all') {
      final rawColors = card['colors'];
      final colors = <String>[];
      if (rawColors is List) {
        colors.addAll(rawColors.map((e) => e.toString()));
      } else {
        try {
          final decoded = jsonDecode(rawColors?.toString() ?? '[]');
          if (decoded is List) colors.addAll(decoded.map((e) => e.toString()));
        } catch (_) {}
      }
      if (_color == 'colorless') {
        if (colors.isNotEmpty) return false;
      } else if (_color == 'multi') {
        if (colors.length < 2) return false;
      } else if (!colors.contains(_color)) {
        return false;
      }
    }

    if (!_matchesAbility(card, _abilityFilter)) return false;

    if (_favoritesOnly) {
      final favorite = card['favorite'];
      final ok = favorite == true ||
          favorite == 1 ||
          favorite == '1' ||
          favorite == 'true';
      if (!ok) return false;
    }

    return true;
  }

  List<Map<String, Object?>> get _visibleItems {
    final visible = _items.where(_matchesDeckFilters).toList();
    visible.sort((a, b) {
      final byName = _sortName(a).compareTo(_sortName(b));
      final bySet = _repairMojibake(
        (a['set_name'] ?? '').toString(),
      )
          .toLowerCase()
          .compareTo(
            _repairMojibake((b['set_name'] ?? '').toString()).toLowerCase(),
          );

      final aq = (a['deck_quantity'] as num?)?.toInt() ??
          (a['quantity'] as num?)?.toInt() ??
          0;
      final bq = (b['deck_quantity'] as num?)?.toInt() ??
          (b['quantity'] as num?)?.toInt() ??
          0;
      final byQty = aq.compareTo(bq);
      final byPrice = _cardPrice(a).compareTo(_cardPrice(b));

      switch (_order) {
        case 'name DESC':
          return byName == 0 ? bySet : -byName;
        case 'price_usd DESC':
          return byPrice == 0 ? byName : -byPrice;
        case 'price_usd ASC':
          return byPrice == 0 ? byName : byPrice;
        case 'set_name ASC':
          return bySet == 0 ? byName : bySet;
        case 'quantity DESC':
          return byQty == 0 ? byName : -byQty;
        case 'quantity ASC':
          return byQty == 0 ? byName : byQty;
        case 'name ASC':
        default:
          return byName == 0 ? bySet : byName;
      }
    });
    return List<Map<String, Object?>>.unmodifiable(visible);
  }

  bool get _hasActiveDeckFilters =>
      _rarity != 'all' ||
      _setName != 'all' ||
      _color != 'all' ||
      _favoritesOnly ||
      _abilityFilter != 'all' ||
      _typeFilter.text.trim().isNotEmpty;

  Future<void> _loadSets() async {
    try {
      final sets = await AppDatabase.instance.distinctSets();
      if (mounted) setState(() => _allSets = sets);
    } catch (_) {}
  }

  void _clearDeckFilters() {
    setState(() {
      _rarity = 'all';
      _setName = 'all';
      _color = 'all';
      _abilityFilter = 'all';
      _order = 'name ASC';
      _favoritesOnly = false;
      _typeFilter.clear();
    });
  }

  Widget _deckFiltersPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _rarity,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: AppLocale.t('cl_rarity')),
                  items: _rarityKeys
                      .map((k) => DropdownMenuItem(
                            value: k,
                            child: Text(rarityLabel(k), overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _rarity = v ?? 'all'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _colorKeys.contains(_color) ? _color : 'all',
                  isExpanded: true,
                  decoration: InputDecoration(labelText: AppLocale.t('cl_color')),
                  items: _colorKeys
                      .map((k) => DropdownMenuItem(
                            value: k,
                            child: Text(colorLabel(k), overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _color = v ?? 'all'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _allSets.contains(_setName) ? _setName : 'all',
                  isExpanded: true,
                  decoration: InputDecoration(labelText: AppLocale.t('cl_set')),
                  items: [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text(
                        AppLocale.t('cl_all'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final s in _allSets)
                      DropdownMenuItem(
                        value: s,
                        child: Text(s, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _setName = v ?? 'all'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue:
                      _orderLabels.containsKey(_order) ? _order : 'name ASC',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Ordenar por',
                  ),
                  items: _orderLabels.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(
                            e.value,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _order = v ?? 'name ASC'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _typeFilter,
                  decoration:
                      InputDecoration(labelText: AppLocale.t('cl_type_ex')),
                  onSubmitted: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _abilityLabels.containsKey(_abilityFilter)
                      ? _abilityFilter
                      : 'all',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Habilidades'),
                  items: _abilityLabels.entries
                      .map((e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value, overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _abilityFilter = v ?? 'all'),
                ),
              ),
            ],
          ),
          Row(
            children: [
              FilterChip(
                label: Text(AppLocale.t('cl_fav')),
                selected: _favoritesOnly,
                onSelected: (v) => setState(() => _favoritesOnly = v),
              ),
              const Spacer(),
              if (_hasActiveDeckFilters)
                TextButton(
                  onPressed: _clearDeckFilters,
                  child: Text(AppLocale.t('cl_clear')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String formatLabel(String key) {
    final v = _formats[key] ?? key;
    // Nomes próprios de formato ficam iguais; os demais traduzem.
    if (v.startsWith('fmt_')) return AppLocale.t(v);
    return v;
  }

  @override
  void initState() {
    super.initState();
    _reload();
    _loadHeader();
    _loadSets();
    _query.addListener(_onQueryChanged);
    AppLocale.current.addListener(_onLocale);
    AppEvents.topVisible.addListener(_onBars);
  }

  @override
  void dispose() {
    _query.dispose();
    _typeFilter.dispose();
    _cardsScroll.dispose();
    _debounce?.cancel();
    AppLocale.current.removeListener(_onLocale);
    AppEvents.topVisible.removeListener(_onBars);
    super.dispose();
  }

  void _onLocale() {
    if (mounted) {
      setState(() {});
      // Mensagens de validação guardadas precisam retraduzir.
      _computeProblems();
    }
  }

  void _onBars() {
    if (mounted) {
      setState(() {});
    }
  }

  static void _laterDispose(TextEditingController c) {
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        c.dispose();
      } catch (_) {}
    });
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final q = _query.text.trim();
      if (q.length < 2) {
        setState(() {
          _localResults = [];
          _suggestions = [];
          _scryResults = [];
          _scryError = null;
        });
        return;
      }
      if (_addMode == 'collection') {
        _searchLocal(q);
      } else {
        _fetchSuggestions(q);
        if (q.length >= 3) _searchScryfall(silent: true);
      }
    });
  }

  Future<void> _reload() async {
    final db = AppDatabase.instance.db;
    final deck = await db.query('decks',
        where: 'id = ?', whereArgs: [widget.deckId], limit: 1);
    final rows = await db.rawQuery('''
      SELECT c.*, dc.quantity AS deck_qty
      FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
      WHERE dc.deck_id = ? ORDER BY c.name''', [widget.deckId]);
    // Disponibilidade + stats derivam dos mesmos dados (fluxo único).
    final idx = await Future.wait([
      DeckAvailabilityService.ownedByOracle(db),
      DeckAvailabilityService.ownedByName(db),
    ]);
    final avail =
        DeckAvailabilityService.compute(rows, idx[0], idx[1]);
    final stats = DeckStatsService.compute(rows);
    if (!mounted) return;
    setState(() {
      _items = rows.map(_sanitizeDbCard).toList(growable: true);
      _avail = avail;
      _deckStats = stats;
      if (deck.isNotEmpty) {
        _format = (deck.first['format'] ?? 'livre').toString();
        _commanderId = deck.first['commander_card_id'] as int?;
        _previewCardId = deck.first['preview_card_id'] as int?;
      }
    });
    await _computeProblems();
  }

  static bool _isBasicLand(Map<String, Object?> c) {
    // Multilíngue via CardTypes (type_line impresso pode ser PT/ES).
    return CardTypes.isBasicLand(
        c['type_line'], (c['name'] ?? '').toString());
  }

  static List<String> _stringList(Object? raw) {
    if (raw == null) return [];
    if (raw is List) {
      return [for (final e in raw) e.toString()];
    }
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is List) {
        return [for (final e in decoded) e.toString()];
      }
    } catch (_) {}
    return [];
  }

  /// Valida o deck contra o formato: tamanho, cópias, comandante
  /// (lendário?), identidade de cor e pauper. Alimenta o sininho.
  Future<void> _computeProblems() async {
    final rules = _deckRules[_format] ?? _deckRules['livre']!;
    final probs = <String>[];
    final min = rules['min'] as int;
    final max = rules['max'] as int;
    final copies = rules['copies'] as int;
    final needsCommander = rules['commander'] as bool;
    final total = _totalCards;

    if (total < min) {
      probs.add(AppLocale.t('dd_v_need')
          .replaceAll('{a}', '${min - total}')
          .replaceAll('{b}', '$min'));
    }
    if (max >= 0 && total > max) {
      probs.add(AppLocale.t('dd_v_over')
          .replaceAll('{t}', '$total')
          .replaceAll('{m}', '$max'));
    }
    if (copies > 0) {
      for (final c in _items) {
        final q = ((c['deck_qty'] as num?)?.toInt() ?? 0);
        if (q > copies && !_isBasicLand(c)) {
          probs.add(AppLocale.t('dd_v_copies')
              .replaceAll('{n}', '${c['name']}')
              .replaceAll('{q}', '$q')
              .replaceAll('{c}', '$copies'));
        }
      }
    }

    Map<String, Object?>? commander;
    if (needsCommander) {
      if (_commanderId == null) {
        probs.add(AppLocale.t('dd_v_commander'));
      } else {
        final rows = await AppDatabase.instance.db.query('cards',
            where: 'id = ?', whereArgs: [_commanderId], limit: 1);
        if (rows.isEmpty) {
          probs.add(AppLocale.t('dd_v_commander_nf'));
        } else {
          commander = rows.first;
          if (!CardTypes.isLegendary(commander['type_line'])) {
            probs.add(AppLocale.t('dd_v_commander_leg')
                .replaceAll('{n}', '${commander['name']}'));
          }
        }
      }
    } else if (_commanderId != null) {
      final rows = await AppDatabase.instance.db
          .query('cards', where: 'id = ?', whereArgs: [_commanderId], limit: 1);
      if (rows.isNotEmpty) commander = rows.first;
    }

    // Identidade de cor: carta com cor fora do comandante.
    if (commander != null) {
      final identity = _stringList(commander['color_identity']).toSet();
      for (final c in _items) {
        if (_isBasicLand(c)) continue;
        final colors = _stringList(c['colors']);
        final out = colors.where((col) => !identity.contains(col)).toList();
        if (out.isNotEmpty) {
          probs.add(AppLocale.t('dd_v_identity')
              .replaceAll('{n}', '${c['name']}')
              .replaceAll('{o}', out.join(', ')));
        }
      }
    }

    // Pauper: só comuns.
    if (_format == 'pauper') {
      for (final c in _items) {
        final r = ((c['rarity'] ?? '') as String).toLowerCase();
        if (r.isNotEmpty && r != 'common') {
          probs.add(
              AppLocale.t('dd_v_pauper').replaceAll('{n}', '${c['name']}'));
        }
      }
    }

    if (mounted) setState(() => _problems = probs);
  }

  int get _totalCards =>
      _items.fold(0, (s, c) => s + (((c['deck_qty'] as num?)?.toInt() ?? 0)));

  double get _totalValue => _items.fold(
      0.0,
      (s, c) =>
          s +
          (((c['deck_qty'] as num?)?.toInt() ?? 0) *
              (((c['price_usd'] as num?)?.toDouble() ??
                  (c['price_ref_usd'] as num?)?.toDouble() ??
                  0))));

  // ============ modo COLEÇÃO ============

  Future<void> _searchLocal(String q) async {
    final rows = await AppDatabase.instance.searchCatalog(query: q);
    if (mounted) setState(() => _localResults = rows.map(_sanitizeDbCard).toList(growable: true));
  }

  Future<void> _addExisting(int cardId) async {
    final db = AppDatabase.instance.db;
    final existing = await db.query('deck_cards',
        where: 'deck_id = ? AND card_id = ?',
        whereArgs: [widget.deckId, cardId]);
    final cur = existing.isEmpty
        ? 0
        : ((existing.first['quantity'] as num?)?.toInt() ?? 0);
    final next = cur + 1;
    if (existing.isEmpty) {
      await db.insert('deck_cards',
          {'deck_id': widget.deckId, 'card_id': cardId, 'quantity': next});
    } else {
      await db.update('deck_cards', {'quantity': next},
          where: 'deck_id = ? AND card_id = ?',
          whereArgs: [widget.deckId, cardId]);
    }
    if (mounted) {
      AppToast.show(context, AppLocale.t('dd_added'));
    }
    await _reload();
  }

  // ============ modo SCRYFALL ============

  Future<void> _fetchSuggestions(String q) async {
    try {
      final s = await ScryfallService.instance.autocomplete(q);
      if (mounted) setState(() => _suggestions = s.take(5).toList());
    } catch (_) {
      if (mounted) setState(() => _suggestions = []);
    }
  }

  Future<void> _searchScryfall({bool silent = false}) async {
    final q = _query.text.trim();
    if (q.length < 2) return;
    final req = ++_scryReq;
    setState(() {
      _scryLoading = true;
      _scryError = null;
      if (!silent) _scryResults = [];
    });
    try {
      final results = await ScryfallService.instance.search(q, lang: _scryLang);
      if (!mounted || req != _scryReq) return;
      setState(() => _scryResults = results.take(20).map(_sanitizeApiCard).toList(growable: true));
      if (results.isEmpty && !silent) {
        final langLabel = ScryfallService.languageLabels[_scryLang] ?? '';
        setState(() => _scryError = _scryLang == 'all'
            ? AppLocale.t('dd_nothing').replaceAll('{q}', q)
            : AppLocale.t('dd_nothing_lang')
                .replaceAll('{l}', langLabel)
                .replaceAll('{q}', q));
      }
    } catch (e) {
      if (!mounted || req != _scryReq) return;
      setState(() =>
          _scryError = AppLocale.t('dd_fail_net').replaceAll('{e}', '$e'));
    } finally {
      if (mounted && req == _scryReq) {
        setState(() => _scryLoading = false);
      }
    }
  }

  /// Idioma fixo = estrito: sem cair para inglês escondido.
  /// [deckId] permite importar para outro deck (novo); o padrão é este.
  /// A coleção nunca é alterada aqui (Fase A §1/§45-fluxo F).
  Future<int?> _resolveAndAdd(String name, {int qty = 1, int? deckId}) async {
    Map<String, dynamic>? data;
    if (_scryLang != 'all') {
      data =
          await ScryfallService.instance.getCardByName(name, lang: _scryLang);
    } else {
      data = await ScryfallService.instance.getCardByName(name, lang: 'pt');
      data ??= await ScryfallService.instance.getCardByName(name, lang: 'en');
    }
    if (data == null) return null;
    return _addScryfallData(data, qty: qty, deckId: deckId);
  }

  Future<int> _addScryfallData(Map<String, dynamic> data,
      {int qty = 1, int? deckId}) async {
    final flat = ScryfallService.flatten(data);
    final db = AppDatabase.instance.db;
    final target = deckId ?? widget.deckId;
    // Preserva a quantidade da coleção: nunca zera carta que já tem.
    final scryfallId = flat['scryfall_id']?.toString();
    int cardId;
    if (scryfallId != null) {
      final found = await db.query('cards',
          columns: ['id'],
          where: 'scryfall_id = ?',
          whereArgs: [scryfallId],
          limit: 1);
      if (found.isNotEmpty) {
        cardId = found.first['id'] as int;
        final upd = Map<String, Object?>.of(flat)..remove('quantity');
        await db.update('cards', upd, where: 'id = ?', whereArgs: [cardId]);
      } else {
        flat['quantity'] = 0; // só-de-deck: catálogo com 0
        cardId = await db.insert('cards', flat);
      }
    } else {
      flat['quantity'] = 0;
      cardId = await db.insert('cards', flat);
    }
    final existing = await db.query('deck_cards',
        where: 'deck_id = ? AND card_id = ?', whereArgs: [target, cardId]);
    final cur = existing.isEmpty
        ? 0
        : ((existing.first['quantity'] as num?)?.toInt() ?? 0);
    // Sem trava pela coleção (Fase A §1): deck pode exigir mais do que
    // se possui; a disponibilidade informa a diferença.
    final next = cur + qty;
    if (existing.isEmpty) {
      await db.insert('deck_cards',
          {'deck_id': target, 'card_id': cardId, 'quantity': next});
    } else {
      await db.update('deck_cards', {'quantity': next},
          where: 'deck_id = ? AND card_id = ?', whereArgs: [target, cardId]);
    }
    return cardId;
  }

  Future<void> _addFromScryfallFlow(String name) async {
    final q = name.trim();
    if (q.isEmpty) return;
    setState(() {
      _adding = true;
      _suggestions = [];
    });
    try {
      final id = await _resolveAndAdd(q);
      if (!mounted) return;
      if (id == null) {
        AppToast.show(context, AppLocale.t('dd_notfound').replaceAll('{q}', q));
      } else {
        _query.clear();
        AppToast.show(context, AppLocale.t('dd_added'));
      }
      await _reload();
    } catch (e) {
      if (mounted) {
        AppToast.show(
            context, AppLocale.t('dd_fail_net').replaceAll('{e}', '$e'));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  // ============ formato / comandante ============

  Future<void> _setFormat(String? v) async {
    if (v == null) return;
    await AppDatabase.instance.db.update('decks', {'format': v},
        where: 'id = ?', whereArgs: [widget.deckId]);
    setState(() => _format = v);
  }

  Future<void> _setCommander(int? cardId) async {
    await AppDatabase.instance.db.update('decks', {'commander_card_id': cardId},
        where: 'id = ?', whereArgs: [widget.deckId]);
    setState(() => _commanderId = cardId);
    if (mounted && cardId != null) {
      AppToast.show(context, AppLocale.t('dd_commander_set'));
    }
  }

  Future<void> _setPreview(int? cardId) async {
    await AppDatabase.instance.db.update('decks', {'preview_card_id': cardId},
        where: 'id = ?', whereArgs: [widget.deckId]);
    setState(() => _previewCardId = cardId);
    if (mounted) {
      AppToast.show(
          context,
          cardId == null
              ? AppLocale.t('dd_cover_auto')
              : AppLocale.t('dd_cover_set'));
    }
  }

  Future<void> _setQty(int cardId, int qty) async {
    final db = AppDatabase.instance.db;
    if (qty <= 0) {
      var name = 'esta carta';
      for (final card in _items) {
        if (card['id'] == cardId) {
          name = (card['name'] ?? name).toString();
          break;
        }
      }
      final remove = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(AppLocale.t('dd_remove_last')),
          content: Text(AppLocale.t('dd_remove_q').replaceAll('{n}', name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(AppLocale.t('common_cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppLocale.t('token_remove'))),
          ],
        ),
      );
      if (remove != true) return;
      await db.delete('deck_cards',
          where: 'deck_id = ? AND card_id = ?',
          whereArgs: [widget.deckId, cardId]);
      if (_commanderId == cardId) await _setCommander(null);
    } else {
      // Sem trava pela coleção (Fase A §1).
      await db.update('deck_cards', {'quantity': qty},
          where: 'deck_id = ? AND card_id = ?',
          whereArgs: [widget.deckId, cardId]);
    }
    await _reload();
  }

  // ============ import / export ============

  // ============ import / export (Fase A §36-45) ============
  // Parsers moram em DeckListFormat (central, testável).

  Future<void> _importDialog() async {
    final c = TextEditingController();
    var mode = 'append';
    final picked = await showDialog<Map<String, Object>>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (dlgCtx, setD) => AlertDialog(
          title: Text(AppLocale.t('imp_title')),
          // Rolável: com teclado aberto a altura encolhe e estourava.
          scrollable: true,
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(AppLocale.t('imp_mode_sub'),
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12)),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  segments: [
                    ButtonSegment(
                        value: 'append',
                        label: Text(AppLocale.t('imp_mode_append'),
                            style: const TextStyle(fontSize: 12))),
                    ButtonSegment(
                        value: 'replace',
                        label: Text(AppLocale.t('imp_mode_replace'),
                            style: const TextStyle(fontSize: 12))),
                    ButtonSegment(
                        value: 'new',
                        label: Text(AppLocale.t('imp_mode_new'),
                            style: const TextStyle(fontSize: 12))),
                  ],
                  selected: {mode},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setD(() => mode = s.first),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: c,
                  maxLines: 6,
                  minLines: 4,
                  decoration: const InputDecoration(
                    hintText:
                        'Commander\n1 Aang\n\nDeck\n4 Lightning Bolt\n1 Sol Ring',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: c,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    hintText:
                        'Commander\n1 Aang\n\nDeck\n4 Lightning Bolt\n1 Sol Ring',
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: Text(AppLocale.t('imp_from_file')),
                    onPressed: () async {
                      try {
                        final file = await FilePicker.pickFile(
                          type: FileType.custom,
                          allowedExtensions: ['txt', 'json'],
                        );
                        final path = file?.path;
                        if (path == null || path.isEmpty) return;
                        final content =
                            await File(path).readAsString();
                        setD(() {
                          c.text = content;
                          c.selection = TextSelection.collapsed(
                              offset: c.text.length);
                        });
                      } catch (e) {
                        if (dlgCtx.mounted) {
                          ScaffoldMessenger.of(dlgCtx).showSnackBar(
                              SnackBar(content: Text('$e')));
                        }
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocale.t('common_cancel'))),
            ElevatedButton(
              onPressed: () =>
                  Navigator.pop(context, {'text': c.text, 'mode': mode}),
              child: Text(AppLocale.t('dd_import')),
            ),
          ],
        ),
      ),
    );
    if (picked == null) {
      _laterDispose(c);
      return;
    }
    final text = (picked['text'] ?? '').toString();
    final importMode = (picked['mode'] ?? 'append').toString();
    _laterDispose(c);
    if (text.trim().isEmpty) {
      if (mounted) AppToast.show(context, AppLocale.t('imp_empty'));
      return;
    }
    // JSON fiel primeiro; senão, texto tolerante.
    var parsed = DeckListFormat.parseDeckJson(text);
    parsed ??= DeckListFormat.parseDeckText(text);
    final entries =
        (parsed['entries'] as List).cast<Map<String, Object?>>();
    var commanderName = parsed['commander']?.toString();
    if (entries.isEmpty) {
      if (mounted) AppToast.show(context, AppLocale.t('imp_empty'));
      return;
    }
    int targetId = widget.deckId;
    if (importMode == 'new') {
      final name = await _askDeckName();
      if (name == null || !mounted) return;
      targetId = await AppDatabase.instance.db
          .insert('decks', {'name': name.trim(), 'format': _format});
    } else if (importMode == 'replace') {
      final db = AppDatabase.instance.db;
      await db.delete('deck_cards', where: 'deck_id = ?', whereArgs: [targetId]);
      await db.update('decks', {'commander_card_id': null},
          where: 'id = ?', whereArgs: [targetId]);
      if (targetId == widget.deckId && mounted) {
        setState(() => _commanderId = null);
      }
    }
    setState(() {
      _importing = true;
      _importStatus = AppLocale.t('dd_starting');
    });
    var ok = 0;
    final unidentified = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final line = (e['name'] ?? '').toString();
      final qty = (e['qty'] as num?)?.toInt() ?? 1;
      if (mounted) {
        setState(() => _importStatus = '${i + 1}/${entries.length}: $line');
      }
      try {
        final id =
            await _resolveAndAdd(line, qty: qty, deckId: targetId);
        if (id == null) {
          unidentified.add(line);
        } else {
          ok++;
        }
      } catch (_) {
        unidentified.add(line);
      }
    }
    // Comandante (se reconhecido entre as adicionadas).
    if (commanderName != null && commanderName.trim().isNotEmpty) {
      try {
        final db = AppDatabase.instance.db;
        final rows = await db.query('cards',
            columns: ['id'],
            where: 'name = ? OR printed_name = ?',
            whereArgs: [commanderName.trim(), commanderName.trim()],
            limit: 1);
        if (rows.isNotEmpty && mounted) {
          final cid = rows.first['id'] as int;
          if (targetId == widget.deckId) {
            await _setCommander(cid);
          } else {
            await db.update('decks', {'commander_card_id': cid},
                where: 'id = ?', whereArgs: [targetId]);
          }
        }
      } catch (_) {}
    }
    // Disponibilidade imediata (Fase A §37) sobre o deck destino.
    DeckAvailability avail = DeckAvailability.empty;
    try {
      avail = await DeckAvailabilityService.forDeck(
          AppDatabase.instance.db, targetId);
    } catch (_) {}
    if (targetId == widget.deckId) {
      await _reload();
    }
    if (mounted) {
      setState(() {
        _importing = false;
        _importStatus = '';
      });
      await _importReport(
          ok: ok,
          unidentified: unidentified,
          avail: avail,
          targetId: targetId);
    }
  }

  Future<String?> _askDeckName() async {
    final c = TextEditingController(
        text: '${widget.deckName} (importado)');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(AppLocale.t('imp_mode_new')),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: Text(AppLocale.t('common_save'))),
        ],
      ),
    );
    _laterDispose(c);
    if (name == null || name.trim().isEmpty) return null;
    return name.trim();
  }

  /// Relatório da importação (Fase A §38): identificadas, não
  /// reconhecidas e faltantes — sem confundir as duas coisas.
  Future<void> _importReport(
      {required int ok,
      required List<String> unidentified,
      required DeckAvailability avail,
      required int targetId}) async {
    final missing = avail.totalMissing;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('dd_imported')
            .replaceAll('{ok}', '$ok')
            .replaceAll('{fail}', '${unidentified.length}')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  AppLocale.t('av_summary')
                      .replaceAll('{o}', '${avail.totalOwned}')
                      .replaceAll('{t}', '${avail.totalNeed}'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (missing > 0) ...[
                const SizedBox(height: 4),
                Text(
                    AppLocale.t('imp_avail')
                        .replaceAll('{n}', '$missing'),
                    style: const TextStyle(color: Colors.orange)),
              ],
              if (unidentified.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                    AppLocale.t('imp_unidentified')
                        .replaceAll('{n}', '${unidentified.length}'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                for (final u in unidentified.take(12))
                  Text('• $u',
                      style:
                          const TextStyle(color: AppTheme.textMuted)),
              ],
            ],
          ),
        ),
        actions: [
          if (missing > 0)
            TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  if (targetId == widget.deckId) {
                    _missingSheet();
                  }
                },
                child: Text(AppLocale.t('av_missing_btn'))),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _exportDeckById(targetId, json: false);
              },
              child: const Text('TXT')),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _exportDeckById(targetId, json: true);
              },
              child: const Text('JSON')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocale.t('common_apply'))),
        ],
      ),
    );
  }

  /// Exporta qualquer deck por id (relatório de import pode mirar
  /// num deck novo, não só no aberto).
  Future<void> _exportDeckById(int deckId, {bool json = false}) async {
    try {
      final db = AppDatabase.instance.db;
      final deck = await db.query('decks',
          where: 'id = ?', whereArgs: [deckId], limit: 1);
      if (deck.isEmpty) return;
      final name = (deck.first['name'] ?? 'deck').toString();
      final format = (deck.first['format'] ?? 'livre').toString();
      final commanderId =
          deck.first['commander_card_id'] as int?;
      final items = await db.rawQuery('''
        SELECT c.*, dc.quantity AS deck_qty
        FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
        WHERE dc.deck_id = ? ORDER BY c.name''', [deckId]);
      var commanderName = '';
      for (final c in items) {
        if ((c['id'] as int?) == commanderId) {
          commanderName = (c['name'] ?? '').toString();
        }
      }
      if (json) {
        await ExportService.exportDeckJson(
          name,
          format: format,
          commanderCardId: commanderId,
          commanderName: commanderName,
          cards: items,
        );
      } else {
        await ExportService.exportDeckTxt(name, items);
      }
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    }
  }

  Future<void> _export() async {
    await ExportService.exportDeckTxt(widget.deckName, _items);
  }

  Future<void> _exportJson() async {
    var commanderName = '';
    for (final c in _items) {
      if ((c['id'] as int?) == _commanderId) {
        commanderName = (c['name'] ?? '').toString();
      }
    }
    await ExportService.exportDeckJson(
      widget.deckName,
      format: _format,
      commanderCardId: _commanderId,
      commanderName: commanderName,
      cards: _items,
    );
  }

  void _toggleDeckFilters() {
    setState(() => _showFilters = !_showFilters);
  }

  void _switchMode(String mode) {
    setState(() {
      _addMode = mode;
      _localResults = [];
      _suggestions = [];
      _scryResults = [];
      _scryError = null;
    });
    final q = _query.text.trim();
    if (q.length >= 2) {
      if (mode == 'collection') {
        _searchLocal(q);
      } else {
        _fetchSuggestions(q);
      }
    }
  }

  // ============ UI ============

  /// Sininho: lista os alertas do formato (ou deck válido).
  Future<void> _showProblems() async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  _problems.isEmpty
                      ? AppLocale.t('dd_valid')
                      : AppLocale.t('dd_alerts')
                          .replaceAll('{n}', '${_problems.length}'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: AppTheme.gold)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (_problems.isEmpty)
                      ListTile(
                        leading:
                            const Icon(Icons.check_circle, color: Colors.green),
                        title: Text(AppLocale.t('dd_allok')),
                      ),
                    for (final p in _problems)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.warning_amber,
                            color: Colors.orange),
                        title: Text(p),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCollection = _addMode == 'collection';
    final top = AppEvents.topVisible.value;
    final visibleItems = _visibleItems;
    return Scaffold(
      // Rota empilhada: com a top escondida mostra o voltar flutuante.
      floatingActionButton: top
          ? null
          : FloatingActionButton.small(
              heroTag: 'deck_bars',
              onPressed: AppEvents.showBars,
              tooltip: AppLocale.t('nav_show'),
              child: const Icon(Icons.fullscreen_exit),
            ),
      appBar: top
          ? AppBar(
              title: Text(widget.deckName),
              actions: [
                IconButton(
                    icon: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                            _problems.isEmpty
                                ? Icons.notifications_outlined
                                : Icons.notifications_active,
                            color: _problems.isEmpty
                                ? AppTheme.text
                                : AppTheme.gold),
                        if (_problems.isNotEmpty)
                          Positioned(
                            right: -6,
                            top: -6,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                              child: Text('${_problems.length}',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                      ],
                    ),
                    tooltip: AppLocale.t('dd_validate'),
                    onPressed: _showProblems),
                IconButton(
                    icon: const Icon(Icons.upload),
                    tooltip: AppLocale.t('dd_import_tip'),
                    onPressed: _importing ? null : _importDialog),
                PopupMenuButton<String>(
                  tooltip: 'Ordenar',
                  icon: const Icon(Icons.sort),
                  onSelected: (v) {
                    setState(() => _order = v);
                  },
                  itemBuilder: (_) => _orderLabels.entries
                      .map(
                        (e) => PopupMenuItem<String>(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                ),
                PopupMenuButton<String>(
                  tooltip: AppLocale.t('dd_export'),
                  icon: const Icon(Icons.share),
                  enabled: _items.isNotEmpty,
                  onSelected: (v) {
                    if (v == 'json') {
                      _exportJson();
                    } else {
                      _export();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'txt',
                        child: Text(AppLocale.t('dd_export'))),
                    PopupMenuItem(
                        value: 'json',
                        child: Text(AppLocale.t('dd_export_json'))),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: AppLocale.t('com_publish'),
                  onPressed: _items.isEmpty
                      ? null
                      : () => CommunityPublish.show(
                          context, widget.deckId),
                ),
              ],
            )
          : null,
      body: SafeArea(
        top: !AppEvents.topVisible.value,
        bottom: false,
        child: ListView(
          controller: _cardsScroll,
          children: [
                _headerCard(),
                if (_importing)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _importStatus,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                _statsSection(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                AppLocale.t('dd_count')
                                    .replaceAll('{u}', '${_items.length}')
                                    .replaceAll('{t}', '$_totalCards'),
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ),
                            if (_hasActiveDeckFilters) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${visibleItems.length} filtradas',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppTheme.gold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _toggleDeckFilters,
                        icon: Icon(
                          _showFilters
                              ? Icons.filter_list_off
                              : Icons.filter_list,
                          color: _hasActiveDeckFilters
                              ? AppTheme.gold
                              : AppTheme.textMuted,
                        ),
                        label: Text(
                          _hasActiveDeckFilters ? 'Filtros ativos' : 'Filtros',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _hasActiveDeckFilters
                                ? AppTheme.gold
                                : AppTheme.textMuted,
                          ),
                        ),
                      ),
                      if (_deckViewGrid) ...[
                        GridColumnsToggle(
                          columns: _gridCols,
                          onChanged: (v) {
                            setState(() => _gridCols = v);
                          },
                        ),
                        const SizedBox(width: 4),
                      ],
                      IconButton(
                        icon: Icon(
                          _deckViewGrid
                              ? Icons.view_list
                              : Icons.grid_view,
                        ),
                        tooltip: _deckViewGrid
                            ? AppLocale.t('dd_view_list')
                            : AppLocale.t('dd_view_grid'),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        onPressed: () {
                          setState(() => _deckViewGrid = !_deckViewGrid);
                        },
                      ),
                    ],
                  ),
                ),
                if (_showFilters) _deckFiltersPanel(),

            // ---- alternador da fonte de adição ----
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                            value: 'collection',
                            icon: const Icon(Icons.style),
                            label: Text(AppLocale.t('dd_collection'))),
                        const ButtonSegment(
                            value: 'scryfall',
                            icon: Icon(Icons.travel_explore),
                            label: Text('Scryfall')),
                      ],
                      selected: {_addMode},
                      onSelectionChanged: (s) => _switchMode(s.first),
                    ),
                  ),
                  if (!isCollection) ...[
                    const SizedBox(width: 4),
                    DropdownButton<String>(
                      value: _scryLang,
                      dropdownColor: AppTheme.panel,
                      underline: const SizedBox.shrink(),
                      icon: const Icon(Icons.language,
                          color: AppTheme.gold, size: 18),
                      style:
                          const TextStyle(color: AppTheme.gold, fontSize: 13),
                      items: ScryfallService.languageLabels.entries
                          .map((e) => DropdownMenuItem(
                              value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _scryLang = v;
                          // Limpa na hora: nada de resultado velho.
                          _scryResults = [];
                          _scryError = null;
                          _suggestions = [];
                        });
                        if (_query.text.trim().length >= 2) {
                          _searchScryfall();
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (v) {
                  if (isCollection) {
                    _searchLocal(v.trim());
                  } else {
                    _searchScryfall();
                  }
                },
                decoration: InputDecoration(
                  hintText: isCollection
                      ? AppLocale.t('dd_search_local')
                      : AppLocale.t('dd_search_scry'),
                  prefixIcon: _adding
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : Icon(isCollection ? Icons.style : Icons.travel_explore),
                  suffixIcon: !isCollection
                      ? IconButton(
                          icon: const Icon(Icons.search, color: AppTheme.gold),
                          onPressed: _searchScryfall,
                        )
                      : null,
                ),
              ),
            ),
            if (isCollection && _localResults.isNotEmpty)
              SizedBox(height: 240, child: _localAddList()),
            if (!isCollection && _suggestions.isNotEmpty)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final s in _suggestions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                            label: Text(s),
                            onPressed: () => _addFromScryfallFlow(s)),
                      ),
                  ],
                ),
              ),
            if (!isCollection && _scryLoading)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text(AppLocale.t('dd_searching'),
                        style: const TextStyle(color: AppTheme.textMuted)),
                  ],
                ),
              ),
            if (!isCollection && _scryError != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(_scryError!,
                    style: const TextStyle(color: Colors.orange)),
              ),
            if (!isCollection && _scryResults.isNotEmpty)
              SizedBox(height: 280, child: _scryAddList()),
            visibleItems.isEmpty
                ? SizedBox(
                    height: 200,
                    child: Center(
                        child: Text(
                            _items.isEmpty
                                ? AppLocale.t('dd_empty')
                                : 'Nenhuma carta encontrada com os filtros atuais.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppTheme.textMuted))))
                : _deckViewGrid
                      ? _groupedGridView(visibleItems, nested: true)
                      : _groupedListView(visibleItems, nested: true),
          ],
        ),
      ),
    );
  }

  /// Grupo de composição da carta (comandante primeiro).
  String _groupKeyOf(Map<String, Object?> c) {
    if (_commanderId != null && (c['id'] as int?) == _commanderId) {
      return CardCategory.commander;
    }
    return CardTypes.category(c['type_line']);
  }

  Map<String, List<Map<String, Object?>>> _groupItems(
      List<Map<String, Object?>> items) {
    final groups = <String, List<Map<String, Object?>>>{};
    for (final c in items) {
      groups.putIfAbsent(_groupKeyOf(c), () => []).add(c);
    }
    return groups;
  }

  int _groupQty(List<Map<String, Object?>> items) =>
      items.fold<int>(
          0, (s, c) => s + (((c['deck_qty'] as num?)?.toInt() ?? 0)));

  /// Linha da carta no modo lista (mesmo conteúdo de antes).
  Widget _deckListTile(Map<String, Object?> c) {
    final q = (c['deck_qty'] as num?)?.toInt() ?? 1;
    final isCommander = _commanderId == (c['id'] as int);
    final isCover = _previewCardId == (c['id'] as int);
    final thumbUrl = (c['image_url'] ?? '').toString();
    return ListTile(
      leading: thumbUrl.isEmpty
          ? (isCommander
              ? const Icon(Icons.shield, color: AppTheme.gold)
              : null)
          : Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CachedNetworkImage(
                    imageUrl: thumbUrl,
                    width: 32,
                    height: 44,
                    fit: BoxFit.cover,
                    memCacheWidth: 100,
                    errorWidget: (_, __, ___) =>
                        const Icon(Icons.broken_image),
                  ),
                ),
                if (isCommander)
                  const Positioned(
                    right: 0,
                    bottom: 0,
                    child: Icon(Icons.shield,
                        size: 14, color: AppTheme.gold),
                  ),
              ],
            ),
      title: Text((c['name'] ?? '').toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontWeight: isCommander
                  ? FontWeight.bold
                  : FontWeight.normal)),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
                '${c['type_line'] ?? ''} • ${CurrencyService.instance.formatUsd(((c['price_usd'] ?? c['price_ref_usd']) as num?)?.toDouble() ?? 0)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          _availBadge(c),
        ],
      ),
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => CardDetailSheet(card: c),
      ).then((_) => _reload()),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => _setQty(c['id'] as int, q - 1)),
          Text('$q',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.gold),
              onPressed: () => _setQty(c['id'] as int, q + 1)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'commander') {
                _setCommander(c['id'] as int);
              } else if (v == 'uncommander') {
                _setCommander(null);
              } else if (v == 'cover') {
                _setPreview(c['id'] as int);
              } else if (v == 'uncover') {
                _setPreview(null);
              } else if (v == 'remove') {
                _setQty(c['id'] as int, 0);
              }
            },
            itemBuilder: (_) => [
              if (!isCommander)
                PopupMenuItem(
                    value: 'commander',
                    child: Text(AppLocale.t('dd_set_commander'))),
              if (isCommander)
                PopupMenuItem(
                    value: 'uncommander',
                    child: Text(AppLocale.t('dd_uncommander'))),
              if (!isCover)
                PopupMenuItem(
                    value: 'cover',
                    child: Text(AppLocale.t('dd_cover'))),
              if (isCover)
                PopupMenuItem(
                    value: 'uncover',
                    child: Text(AppLocale.t('dd_uncover'))),
              PopupMenuItem(
                  value: 'remove',
                  child: Text(AppLocale.t('dd_remove_from'))),
            ],
          ),
        ],
      ),
    );
  }

  /// Lista agrupada por composição (mesmo padrão da Comunidade).
  /// Aninhada na rolagem única da página: sem controller próprio.
  Widget _groupedListView(List<Map<String, Object?>> items,
      {bool nested = false}) {
    final groups = _groupItems(items);
    return ListView(
      controller: nested ? null : _cardsScroll,
      shrinkWrap: nested,
      physics: nested ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 12),
      children: [
        for (final g in CardCategory.order)
          if (groups[g] != null && groups[g]!.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: DeckGroupHeader(
                  title: deckGroupTitle(g),
                  count: _groupQty(groups[g]!)),
            ),
            for (final c in groups[g]!) _deckListTile(c),
          ],
      ],
    );
  }

  /// Grade agrupada por composição. 2 colunas = tile completo
  /// (steppers); 3 colunas = tile compacto (toque abre detalhes).
  /// Aninhada na rolagem única da página: sem controller próprio.
  Widget _groupedGridView(List<Map<String, Object?>> items,
      {bool nested = false}) {
    final groups = _groupItems(items);
    return ListView(
      controller: nested ? null : _cardsScroll,
      shrinkWrap: nested,
      physics: nested ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, 12 + MediaQuery.of(context).padding.bottom),
      children: [
        for (final g in CardCategory.order)
          if (groups[g] != null && groups[g]!.isNotEmpty) ...[
            DeckGroupHeader(
                title: deckGroupTitle(g),
                count: _groupQty(groups[g]!)),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 8),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _gridCols,
                childAspectRatio: _gridCols == 2 ? 0.69 : 63 / 96,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: groups[g]!.length,
              itemBuilder: (_, i) => _gridCols == 2
                  ? _deckGridTile(groups[g]![i])
                  : _compactGridTile(groups[g]![i]),
            ),
          ],
      ],
    );
  }

  /// Tile compacto p/ grade de 3 colunas: imagem, nome, qtd.
  /// Toque abre a ficha (de onde dá para ajustar a quantidade).
  Widget _compactGridTile(Map<String, Object?> c) {
    final q = (c['deck_qty'] as num?)?.toInt() ?? 1;
    final av = _avail.forCard((c['id'] as int?) ?? -1);
    Widget? badge;
    if (av.need > 0 && av.status != AvailStatus.ok) {
      badge = Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('−${av.missing}',
            style: const TextStyle(
                color: Colors.orange,
                fontSize: 11,
                fontWeight: FontWeight.bold)),
      );
    }
    return CardGridTile(
      imageUrl: (c['image_url'] ?? '').toString(),
      name: (c['name'] ?? '').toString(),
      qtyText: '${q}x',
      badge: badge,
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => CardDetailSheet(card: c),
      ).then((_) => _reload()),
    );
  }

  /// Tile do deck em grade: arte inteira + qtd do deck.
  /// Toque abre os detalhes; +/- respeitam a coleção.
  Widget _deckGridTile(Map<String, Object?> c) {
    final url = c['image_url'] as String?;
    final q = (c['deck_qty'] as num?)?.toInt() ?? 1;
    final isCommander = _commanderId == (c['id'] as int);
    final isCover = _previewCardId == (c['id'] as int);
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: isCommander ? AppTheme.gold : AppTheme.border,
            width: isCommander ? 2 : 1),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (url == null || url.isEmpty)
            const ColoredBox(
                color: AppTheme.panel,
                child: Icon(Icons.style, size: 40, color: AppTheme.textFaint))
          else
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: 400,
              errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
                stops: [0.48, 1],
              ),
            ),
          ),
          // Só a área da arte abre os detalhes. A faixa inferior fica livre
          // para nome, quantidade e os botões +/- sem toques acidentais.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: 80,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => CardDetailSheet(card: c),
              ).then((_) => _reload()),
              onLongPressStart: (details) =>
                  _showGridCardMenuAt(c, details.globalPosition),
            ),
          ),
          if (isCommander)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.shield, size: 14, color: AppTheme.gold),
                  const SizedBox(width: 3),
                  Text(AppLocale.t('dd_commander_badge'),
                      style: const TextStyle(
                          color: AppTheme.gold,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ]),
              ),
            ),
          Positioned(
            top: 0,
            right: 0,
            child: PopupMenuButton<String>(              tooltip: AppLocale.t('dd_card_options'),
              icon: const Icon(Icons.more_vert, color: Colors.white),
              color: AppTheme.panel,
              onSelected: (v) {
                if (v == 'commander') {
                  _setCommander(c['id'] as int);
                } else if (v == 'uncommander') {
                  _setCommander(null);
                } else if (v == 'cover') {
                  _setPreview(c['id'] as int);
                } else if (v == 'uncover') {
                  _setPreview(null);
                } else if (v == 'remove') {
                  _setQty(c['id'] as int, 0);
                }
              },
              itemBuilder: (_) => [
                if (!isCommander)
                  PopupMenuItem(
                      value: 'commander',
                      child: Text(AppLocale.t('dd_set_commander'))),
                if (isCommander)
                  PopupMenuItem(
                      value: 'uncommander',
                      child: Text(AppLocale.t('dd_uncommander'))),
                if (!isCover)
                  PopupMenuItem(
                      value: 'cover', child: Text(AppLocale.t('dd_cover'))),
                if (isCover)
                  PopupMenuItem(
                      value: 'uncover', child: Text(AppLocale.t('dd_uncover'))),
                PopupMenuItem(
                    value: 'remove',
                    child: Text(AppLocale.t('dd_remove_from'))),
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 6,
            bottom: 6,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((c['name'] ?? '').toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.05,
                        fontWeight:
                            isCommander ? FontWeight.bold : FontWeight.w600)),
                const SizedBox(height: 5),
                Row(children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: isCommander ? AppTheme.gold : Colors.black54,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${q}×',
                        style: TextStyle(
                            color: isCommander
                                ? const Color(0xFF14161D)
                                : Colors.white,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _availBadge(c),
                  ),
                  const Spacer(),
                  _gridQtyButton(
                      Icons.remove, () => _setQty(c['id'] as int, q - 1)),
                  const SizedBox(width: 4),
                  _gridQtyButton(
                      Icons.add, () => _setQty(c['id'] as int, q + 1),
                      accent: true),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<String>> _gridCardMenuItems(
          {required bool isCommander, required bool isCover}) =>
      [
        if (!isCommander)
          PopupMenuItem(
              value: 'commander', child: Text(AppLocale.t('dd_set_commander'))),
        if (isCommander)
          PopupMenuItem(
              value: 'uncommander', child: Text(AppLocale.t('dd_uncommander'))),
        if (!isCover)
          PopupMenuItem(value: 'cover', child: Text(AppLocale.t('dd_cover'))),
        if (isCover)
          PopupMenuItem(
              value: 'uncover', child: Text(AppLocale.t('dd_uncover'))),
        PopupMenuItem(
            value: 'remove', child: Text(AppLocale.t('dd_remove_from'))),
      ];

  void _onGridCardMenu(String value, Map<String, Object?> card) {
    final id = card['id'] as int;
    if (value == 'commander') {
      _setCommander(id);
    } else if (value == 'uncommander') {
      _setCommander(null);
    } else if (value == 'cover') {
      _setPreview(id);
    } else if (value == 'uncover') {
      _setPreview(null);
    } else if (value == 'remove') {
      _setQty(id, 0);
    }
  }

  Future<void> _showGridCardMenuAt(
      Map<String, Object?> card, Offset globalPosition) async {
    final isCommander = _commanderId == (card['id'] as int);
    final isCover = _previewCardId == (card['id'] as int);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      overlay.size.width - globalPosition.dx,
      overlay.size.height - globalPosition.dy,
    );
    final value = await showMenu<String>(
      context: context,
      position: position,
      color: AppTheme.panel,
      items: _gridCardMenuItems(isCommander: isCommander, isCover: isCover),
    );
    if (value != null) _onGridCardMenu(value, card);
  }

  Widget _gridQtyButton(IconData icon, VoidCallback onTap,
      {bool accent = false}) {
    return Material(
      color: accent ? AppTheme.gold : Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon,
              size: 17, color: accent ? const Color(0xFF14161D) : Colors.white),
        ),
      ),
    );
  }

  /// Resultados do catálogo local com botão + (modo Coleção).
  Widget _localAddList() {
    return Container(
      // A busca é auxiliar: em telas baixas ela não pode empurrar a lista
      // principal do deck para fora da tela.
      constraints: const BoxConstraints(maxHeight: 120),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _localResults.length,
        itemBuilder: (_, i) {
          final c = _localResults[i];
          return ListTile(
            dense: true,
            title: Text((c['name'] ?? '').toString()),
            subtitle: Text(
                '${c['set_name'] ?? ''} • ${AppLocale.t('dd_qty')}: ${c['quantity'] ?? 0}',
                style: const TextStyle(color: AppTheme.textMuted)),
            trailing: IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.gold),
              onPressed: () => _addExisting(c['id'] as int),
            ),
          );
        },
      ),
    );
  }

  /// Resultados do Scryfall com botão + (modo Scryfall).
  Widget _scryAddList() {
    return Container(
      // Mantém resultados acessíveis por rolagem sem estourar o layout.
      constraints: const BoxConstraints(maxHeight: 120),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _scryResults.length,
        itemBuilder: (_, i) {
          final data = _scryResults[i];
          final name = (data['name'] ?? '?').toString();
          final printed = (data['printed_name'] ?? '').toString();
          final lang = ((data['lang'] ?? '?') as String).toUpperCase();
          return ListTile(
            dense: true,
            title: Text(printed.isNotEmpty ? printed : name),
            subtitle: Text(
                '${data['set_name'] ?? ''} • #${data['collector_number'] ?? '—'} • $lang',
                style: const TextStyle(color: AppTheme.textMuted)),
            trailing: IconButton(
              icon: const Icon(Icons.add_circle, color: AppTheme.gold),
              onPressed: () async {
                setState(() => _adding = true);
                try {
                  await _addScryfallData(data);
                  _query.clear();
                  if (mounted) {
                    AppToast.show(context, AppLocale.t('dd_added'));
                  }
                  await _reload();
                } catch (e) {
                  if (mounted) {
                    AppToast.show(context,
                        AppLocale.t('dd_error').replaceAll('{e}', '$e'));
                  }
                } finally {
                  if (mounted) {
                    setState(() => _adding = false);
                  }
                }
              },
            ),
          );
        },
      ),
    );
  }

  /// Cabeçalho recolhível (Fase A §21): fechado mostra só o essencial
  /// (cartas • valor • disponibilidade); aberto, resumo completo.
  Widget _headerCard() {
    final a = _avail;
    final Color availColor;
    final String availText;
    if (a.totalNeed == 0) {
      availColor = AppTheme.textMuted;
      availText = '0';
    } else if (a.totalMissing == 0) {
      availColor = Colors.green;
      availText = '${a.totalOwned}/${a.totalNeed}';
    } else if (a.totalOwned > 0) {
      availColor = Colors.orange;
      availText = '${a.totalOwned}/${a.totalNeed}';
    } else {
      availColor = Colors.redAccent;
      availText = '0/${a.totalNeed}';
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            InkWell(
              onTap: _toggleHeader,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                          '$_totalCards • ${CurrencyService.instance.formatUsd(_totalValue)} • $availText',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: availColor)),
                    ),
                    Icon(
                        _headerExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 20,
                        color: AppTheme.textMuted),
                  ],
                ),
              ),
            ),
            if (_headerExpanded) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  _stat('$_totalCards', AppLocale.t('dd_cards')),
                  _stat(
                      CurrencyService.instance.formatUsd(_totalValue),
                      CurrencyService.instance.currency.value),
                  _stat('${_items.length}', AppLocale.t('dd_unique')),
                ],
              ),
              const SizedBox(height: 8),
              _commanderColorsRow(),
              const SizedBox(height: 8),
              _availabilityBar(),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _formats.containsKey(_format) ? _format : 'livre',
                decoration:
                    InputDecoration(labelText: AppLocale.t('dd_format')),
                items: _formats.entries
                    .map((e) => DropdownMenuItem(
                        value: e.key, child: Text(formatLabel(e.key))))
                    .toList(),
                onChanged: _setFormat,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.gold)),
          Text(label, style: const TextStyle(color: AppTheme.textMuted)),
        ],
      ),
    );
  }

  /// Linha comandante + cores + MV médio (Fase A).
  Widget _commanderColorsRow() {
    Map<String, Object?>? commander;
    for (final c in _items) {
      if ((c['id'] as int?) == _commanderId) commander = c;
    }
    final colors = [
      for (final col in DeckStatsService.colorOrder)
        if ((_deckStats.colors[col] ?? 0) > 0) col
    ];
    if (commander == null && colors.isEmpty && _deckStats.mvCount == 0) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        if (commander != null)
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.shield, size: 14, color: AppTheme.gold),
                const SizedBox(width: 4),
                Flexible(
                  child: Text((commander['name'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),
        if (colors.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var k = 0; k < colors.length; k++) ...[
                if (k > 0) const SizedBox(width: 3),
                MtgPip(colors[k], size: 16),
              ],
            ],
          ),
        if (_deckStats.mvCount > 0) ...[
          const SizedBox(width: 8),
          Text(
              'MV ${_deckStats.avgMv.toStringAsFixed(2)}',
              style:
                  const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ],
      ],
    );
  }

  /// Barra de disponibilidade Deck x Collection (Fase A).
  Widget _availabilityBar() {
    final a = _avail;
    final ok = a.totalOwned;
    final missing = a.totalMissing;
    final total = a.totalNeed;
    final complete = total > 0 && missing == 0;
    final empty = total == 0;
    final label = empty
        ? AppLocale.t('dd_empty')
        : complete
            ? AppLocale.t('av_complete')
            : AppLocale.t('av_summary')
                .replaceAll('{o}', '$ok')
                .replaceAll('{t}', '$total');
    return InkWell(
      onTap: (!empty && !complete) ? _missingSheet : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                    empty
                        ? Icons.inbox_outlined
                        : complete
                            ? Icons.check_circle
                            : (ok > 0
                                ? Icons.warning_amber
                                : Icons.cancel_outlined),
                    size: 16,
                    color: empty
                        ? AppTheme.textMuted
                        : complete
                            ? Colors.green
                            : (ok > 0 ? Colors.orange : Colors.redAccent)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                if (!empty && !complete)
                  Text(AppLocale.t('av_missing_btn'),
                      style: const TextStyle(
                          color: AppTheme.gold, fontSize: 12)),
              ],
            ),
            if (!empty) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 8,
                  child: Row(
                    children: [
                      if (ok > 0)
                        Expanded(
                            flex: ok,
                            child: const ColoredBox(color: Colors.green)),
                      if (missing > 0)
                        Expanded(
                            flex: missing,
                            child: ColoredBox(
                                color: ok > 0
                                    ? Colors.orange
                                    : Colors.redAccent)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Seção de estatísticas (curva, tipos, mana) — ExpansionTile.
  Widget _statsSection() {
    final s = _deckStats;
    if (s.totalCards == 0) return const SizedBox.shrink();
    Widget barRow(String label, int value, int max, Color color) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 11)),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 10,
                  child: Row(
                    children: [
                      if (value > 0 && max > 0)
                        Expanded(
                            flex: value,
                            child: ColoredBox(color: color)),
                      if (max - value > 0)
                        Expanded(
                            flex: max - value,
                            child: ColoredBox(
                                color: Colors.white.withValues(alpha: 0.08))),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 32,
              child: Text('$value',
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
      );
    }

    final t = s.types;
    final typeRows = [
      (AppLocale.t('cat_creatures'), t.creatures),
      (AppLocale.t('cat_instants'), t.instants),
      (AppLocale.t('cat_sorceries'), t.sorceries),
      (AppLocale.t('cat_artifacts'), t.artifacts),
      (AppLocale.t('cat_enchantments'), t.enchantments),
      (AppLocale.t('cat_planeswalkers'), t.planeswalkers),
      (AppLocale.t('cat_lands'), t.lands),
      (AppLocale.t('cat_other'), t.other),
    ];
    final typeMax =
        [...typeRows.map((e) => e.$2)].fold<int>(1, (m, v) => v > m ? v : m);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      // Corta o conteúdo nos cantos: aberto, o fundo da expansão não
      // vaza em quadrado por cima do arredondado.
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        dense: true,
        onExpansionChanged: (open) {
          if (mounted) {
            setState(() => _statsExpanded = open);
          }
        },
        // Cabeçalho e corpo com o mesmo raio do Card (sem quina).
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        title: Text(AppLocale.t('stats_title'),
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Text(
            'MV ${s.avgMv.toStringAsFixed(2)} • ${AppLocale.t('stats_lands')}: ${s.landCount} • ${AppLocale.t('stats_sources')}: ${s.manaSources}',
            style:
                const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        children: [
          // Sem teto/rolo interno: o topo da página já rola por fora
          // (Flexible) — aqui o conteúdo abre inteiro, sem corte e sem
          // brilho de overscroll aninhado.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ManaCurveChart(curve: s.curve),
                const SizedBox(height: 8),
                Text(AppLocale.t('stats_types'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                for (final r in typeRows)
                  barRow(r.$1, r.$2, typeMax, Colors.lightBlue),
                const SizedBox(height: 8),
                Text(AppLocale.t('stats_mana'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                Text(AppLocale.t('stats_cards_sources'),
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 11)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    for (final col in DeckStatsService.colorOrder)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MtgPip(col, size: 16),
                          const SizedBox(width: 3),
                          Text('${s.colors[col] ?? 0}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold)),
                          Text(
                              ' / ${s.sourcesByColor[col] ?? 0}',
                              style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 12)),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(AppLocale.t('stats_lands_title'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _landStat(
                        AppLocale.t('stats_lands_total'), s.landCount),
                    _landStat(AppLocale.t('stats_lands_basic'),
                        s.basicLands),
                    _landStat(AppLocale.t('stats_lands_nonbasic'),
                        s.landCount - s.basicLands),
                    _landStat(AppLocale.t('stats_lands_multi'),
                        s.multiColorLands),
                    _landStat(
                        AppLocale.t('stats_lands_colorless'),
                        s.colorlessLands),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _landStat(String label, int value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value',
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 12)),
      ],
    );
  }

  /// Selo de disponibilidade por carta (lista/grade).
  Widget _availBadge(Map<String, Object?> c) {
    final id = (c['id'] as num?)?.toInt() ?? -1;
    final a = _avail.forCard(id);
    if (a.need <= 0) return const SizedBox.shrink();
    final Widget icon;
    final String text;
    final Color color;
    if (a.status == AvailStatus.ok) {
      icon = const Icon(Icons.check_circle, size: 14, color: Colors.green);
      text = '';
      color = Colors.green;
    } else if (a.status == AvailStatus.partial) {
      icon = const Icon(Icons.warning_amber, size: 14, color: Colors.orange);
      text = '−${a.missing}';
      color = Colors.orange;
    } else {
      icon =
          const Icon(Icons.cancel_outlined, size: 14, color: Colors.redAccent);
      text = '−${a.missing}';
      color = Colors.redAccent;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        if (text.isNotEmpty) ...[
          const SizedBox(width: 2),
          Text(text,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ],
    );
  }

  /// Faltantes: tabela + exportar (Fase A §15/§42-43).
  Future<void> _missingSheet() async {
    final a = _avail;
    final rows = [
      for (final c in _items)
        if ((_avail.forCard((c['id'] as num?)?.toInt() ?? -1).missing) > 0)
          MapEntry(c, _avail.forCard((c['id'] as num?)?.toInt() ?? -1))
    ];
    if (rows.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  AppLocale.t('av_missing_title')
                      .replaceAll('{n}', '${a.totalMissing}'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                  AppLocale.t('av_missing_value').replaceAll(
                      '{v}',
                      CurrencyService.instance
                          .formatUsd(a.missingValue)),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 12)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (_, k) {
                    final c = rows[k].key;
                    final av = rows[k].value;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text((c['name'] ?? '').toString(),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                          AppLocale.t('av_row')
                              .replaceAll('{need}', '${av.need}')
                              .replaceAll('{owned}', '${av.owned}')
                              .replaceAll('{missing}', '${av.missing}'),
                          style: const TextStyle(fontSize: 11)),
                      trailing: Text('−${av.missing}',
                          style: const TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.bold)),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.share, size: 16),
                      label: Text(AppLocale.t('av_export_txt')),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _exportMissingTxt();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon:
                          const Icon(Icons.table_chart, size: 16),
                      label: Text(AppLocale.t('av_export_csv')),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _exportMissingCsv();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportMissingTxt() async {
    final buf = StringBuffer();
    for (final c in _items) {
      final av = _avail.forCard((c['id'] as num?)?.toInt() ?? -1);
      if (av.missing > 0) {
        buf.writeln('${av.missing}x ${c['name'] ?? ''}');
      }
    }
    await ExportService.exportMissingTxt(widget.deckName, buf.toString());
  }

  Future<void> _exportMissingCsv() async {
    final rows = <List<String>>[
      ['name', 'need', 'owned', 'missing'],
      for (final c in _items)
        if (_avail
                .forCard((c['id'] as num?)?.toInt() ?? -1)
                .missing >
            0)
          [
            (c['name'] ?? '').toString(),
            '${_avail.forCard((c['id'] as num?)?.toInt() ?? -1).need}',
            '${_avail.forCard((c['id'] as num?)?.toInt() ?? -1).owned}',
            '${_avail.forCard((c['id'] as num?)?.toInt() ?? -1).missing}',
          ],
    ];
    await ExportService.exportMissingCsv(widget.deckName, rows);
  }
}
