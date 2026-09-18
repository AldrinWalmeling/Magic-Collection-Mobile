import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../firebase_options.dart';
import '../data/app_database.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/online_friends.dart';
import '../services/play_prefs.dart';
import '../services/lan_match.dart';
import '../services/lan_presence.dart';
import '../services/online_match.dart';
import '../services/scryfall_service.dart';
import '../theme/app_theme.dart';
import '../theme/table_backgrounds.dart';
import '../widgets/app_toast.dart';
import '../widgets/marquee.dart';
import '../widgets/mtg_symbols.dart';
import 'ocr_scan_page.dart';

// Aba JOGAR — mesa local + mesa em rede Wi-Fi (sem internet).
// - Formatos (Livre/Padrão/Commander...), 2–6 jogadores, veneno,
//   rodadas e jogador ativo ("passar turno").
// - Fichas com dono, P/T editável, marcadores, virar/desvirar.
// - Efeitos: bônus globais ("todas +1/+1") ou numa ficha,
//   permanentes ou até o fim do turno (expiram ao passar turno).
// - Rede: Hospedar (mostra o IP) / Entrar (digita o IP do anfitrião).
//   O host é a fonte da verdade e retransmite o estado.
//
// ONLINE pela internet + login Gmail exigem servidor (ex. Firebase)
// — fora desta fase. O modelo já está em JSON pronto p/ plugar.

class _MatchPlayer {
  static const poisonLethal = 10;
  static const commanderLethal = 21;
  String name;
  int life;
  int poison;
  // Dano de comandante por NOME do comandante (21+ do mesmo = morte).
  Map<String, int> commander;
  // Contadores extras do jogador (Energia, Experiência...): nome -> qtd.
  Map<String, int> counters;
  // UID Firebase da sessão dona (online). '' = local/LAN/legado.
  // Identidade real; [name] é só exibição.
  String uid;
  // Tema da mesa deste jogador (chave de _tableStyles, '' = global).
  String theme;
  // Fundo da mesa deste jogador (id de tableBackgrounds, '' = sólido).
  String bg;
  _MatchPlayer(
      {required this.name,
      required this.life,
      this.poison = 0,
      Map<String, int>? commander,
      Map<String, int>? counters,
      this.uid = '',
      this.theme = '',
      this.bg = ''})
      : commander = commander ?? {},
        counters = counters ?? {};

  /// Maior dano de um único comandante (o que vale p/ a morte).
  int get commanderMax {
    var m = 0;
    for (final v in commander.values) {
      if (v > m) m = v;
    }
    return m;
  }

  bool get commanderDead => commanderMax >= commanderLethal;
  bool get poisonDead => poison >= poisonLethal;
  bool get alive => life > 0 && !poisonDead && !commanderDead;

  /// Causa da morte para o anúncio (life/poison/commander).
  String get deathCause {
    if (commanderDead) return 'commander';
    if (poisonDead) return 'poison';
    return 'life';
  }

  /// Nome do comandante que matou (maior dano >= 21), '' se nenhum.
  String get killerCommander {
    var best = '';
    var bestV = commanderLethal;
    commander.forEach((k, v) {
      if (v >= bestV) {
        bestV = v;
        best = k;
      }
    });
    return best;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'life': life,
        'poison': poison,
        'commander': Map<String, int>.from(commander),
        'counters': Map<String, int>.from(counters),
        'uid': uid,
        'theme': theme,
        'bg': bg,
      };

  static Map<String, int> _intMapFrom(Object? raw) {
    final out = <String, int>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final key = k.toString().trim();
        if (key.isEmpty) return;
        out[key] = (v as num?)?.toInt() ?? 0;
      });
    }
    return out;
  }

  static _MatchPlayer fromJson(Map<String, dynamic> m) => _MatchPlayer(
        name: (m['name'] ?? '?').toString(),
        life: (m['life'] as num?)?.toInt() ?? 20,
        poison: (m['poison'] as num?)?.toInt() ?? 0,
        commander: _intMapFrom(m['commander']),
        counters: _intMapFrom(m['counters']),
        uid: (m['uid'] ?? '').toString(),
        theme: (m['theme'] ?? '').toString(),
        bg: (m['bg'] ?? '').toString(),
      );
}

/// Marcador personalizado (Escudo, Atordoamento, Ponto...): marcação
/// pura, não mexe no P/T. Pode ser permanente ou até o fim do turno.
class _Mark {
  String label;
  int count;
  bool untilEOT;
  _Mark({required this.label, this.count = 1, this.untilEOT = false});

  Map<String, dynamic> toJson() =>
      {'label': label, 'count': count, 'untilEOT': untilEOT};

  static _Mark fromJson(Map<String, dynamic> m) => _Mark(
        label: (m['label'] ?? '').toString(),
        count: (m['count'] as num?)?.toInt() ?? 0,
        untilEOT: (m['untilEOT'] as bool?) ?? false,
      );
}

class _Token {
  int id;
  String name;
  int power;
  int toughness;
  // Marcadores +1/+1 (entram no P/T efetivo).
  int counters;
  // Marcadores -1/-1 (reduzem o P/T; anulam +1/+1 em pares, regra 122.3).
  int minus;
  // Marcadores de lealdade (planinautas) e carga (artefatos): NÃO mexem
  // no P/T, só aparecem como selos na carta.
  int loyalty;
  int charge;
  // Marcadores personalizados (marcação pura).
  List<_Mark> marks;
  // 'token' (ficha) ou 'card' (carta real colocada na mesa).
  String kind;
  String setCode;
  bool tapped;
  String owner;
  // UID Firebase da sessão dona (online). '' = local/LAN/legado.
  // Referência principal; [owner] é só exibição e nunca é
  // reescrito por troca de perfil.
  String ownerUid;
  String description;
  String art;
  // Carta personalizada: custo de mana (texto, ex. "{2}{G}" ou "X"),
  // linha de tipo (ex. "Criatura — Elfo") e habilidades por chave
  // (ex. 'flying', 'lifelink'). ''/vazio = ficha simples.
  String cost;
  String type;
  List<String> keywords;
  // Pode ser nulo após hot reload em fichas já existentes na memória.
  bool? hideName;
  _Token({
    required this.id,
    required this.name,
    this.power = 1,
    this.toughness = 1,
    this.counters = 0,
    this.minus = 0,
    this.loyalty = 0,
    this.charge = 0,
    List<_Mark>? marks,
    this.kind = 'token',
    this.setCode = '',
    this.tapped = false,
    this.owner = '',
    this.ownerUid = '',
    this.description = '',
    this.art = '',
    this.cost = '',
    this.type = '',
    List<String>? keywords,
    this.hideName = false,
  })  : marks = marks ?? [],
        keywords = keywords ?? [];

  /// Ficha utilitária (Tesouro, Pista...) tem habilidade ativada.
  bool get isUtility => power == 0 && toughness == 0;

  static String marksKey(List<_Mark> marks) {
    final sorted = marks.toList()..sort((a, b) => a.label.compareTo(b.label));
    return sorted
        .map((m) => '${m.label}:${m.count}:${m.untilEOT ? 1 : 0}')
        .join(',');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'power': power,
        'toughness': toughness,
        'counters': counters,
        'minus': minus,
        'loyalty': loyalty,
        'charge': charge,
        'marks': [for (final m in marks) m.toJson()],
        'kind': kind,
        'setCode': setCode,
        'tapped': tapped,
        'owner': owner,
        'ownerUid': ownerUid,
        'description': description,
        'art': art,
        'cost': cost,
        'type': type,
        'keywords': [...keywords],
        'hideName': hideName == true,
      };

  /// Habilidades de carta personalizada (chaves canônicas em inglês;
  /// o rótulo localizado sai de `ab_<chave>` no AppLocale).
  static const abilityKeys = [
    'flying',
    'vigilance',
    'lifelink',
    'deathtouch',
    'haste',
    'trample',
    'menace',
    'reach',
    'first_strike',
    'double_strike',
    'hexproof',
    'indestructible',
  ];

  static List<String> _keywordsFrom(Object? raw) {
    if (raw is! List) return [];
    return [
      for (final e in raw)
        if (e.toString().trim().isNotEmpty &&
            abilityKeys.contains(e.toString().trim()))
          e.toString().trim()
    ];
  }

  static List<_Mark> _marksFrom(Object? raw) {
    if (raw is! List) return [];
    return [
      for (final e in raw)
        if (e is Map) _Mark.fromJson(Map<String, dynamic>.from(e))
    ];
  }

  static _Token fromJson(Map<String, dynamic> m) => _Token(
        id: (m['id'] as num?)?.toInt() ?? 0,
        name: (m['name'] ?? '?').toString(),
        power: (m['power'] as num?)?.toInt() ?? 1,
        toughness: (m['toughness'] as num?)?.toInt() ?? 1,
        counters: (m['counters'] as num?)?.toInt() ?? 0,
        minus: (m['minus'] as num?)?.toInt() ?? 0,
        loyalty: (m['loyalty'] as num?)?.toInt() ?? 0,
        charge: (m['charge'] as num?)?.toInt() ?? 0,
        marks: _marksFrom(m['marks']),
        kind: (m['kind'] ?? 'token').toString(),
        setCode: (m['setCode'] ?? '').toString(),
        tapped: (m['tapped'] as bool?) ?? false,
        owner: (m['owner'] ?? '').toString(),
        ownerUid: (m['ownerUid'] ?? '').toString(),
        description: (m['description'] ?? '').toString(),
        art: (m['art'] ?? '').toString(),
        cost: (m['cost'] ?? '').toString(),
        type: (m['type'] ?? '').toString(),
        keywords: _keywordsFrom(m['keywords']),
        hideName: (m['hideName'] as bool?) ?? false,
      );
}

/// Efeito: bônus de P/T global (targetId -1 = todas) ou numa ficha,
/// permanente ou até o fim do turno.
class _TokenEffect {
  int id;
  String label;
  int power;
  int toughness;
  int targetId;
  bool untilEOT;
  _TokenEffect({
    required this.id,
    required this.label,
    this.power = 0,
    this.toughness = 0,
    this.targetId = -1,
    this.untilEOT = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'power': power,
        'toughness': toughness,
        'targetId': targetId,
        'untilEOT': untilEOT,
      };

  static _TokenEffect fromJson(Map<String, dynamic> m) => _TokenEffect(
        id: (m['id'] as num?)?.toInt() ?? 0,
        label: (m['label'] ?? '').toString(),
        power: (m['power'] as num?)?.toInt() ?? 0,
        toughness: (m['toughness'] as num?)?.toInt() ?? 0,
        targetId: (m['targetId'] as num?)?.toInt() ?? -1,
        untilEOT: (m['untilEOT'] as bool?) ?? false,
      );
}

/// Marcador separado: quase uma carta — tem nome, contador e um
/// "dentro" (fichas vinculadas). [memberIds] vazio = GLOBAL (vale para
/// a mesa toda); com ids, afeta SÓ aquelas fichas. Sincroniza como
/// efeito (estado + ações marker_*).
/// [kind]: 'custom' (contador próprio, só informativo), 'plus'
/// (carimba +1/+1 nas fichas de dentro) ou 'minus' (−1/−1).
class _Marker {
  static const kinds = ['custom', 'plus', 'minus'];
  int id;
  String label;
  int count;
  List<int> memberIds;
  String kind;
  _Marker({
    required this.id,
    required this.label,
    this.count = 0,
    List<int>? memberIds,
    String? kind,
  })  : memberIds = memberIds ?? [],
        kind = kinds.contains(kind) ? kind! : 'custom';

  bool get isGlobal => memberIds.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'count': count,
        'memberIds': [...memberIds],
        'kind': kind,
      };

  static _Marker fromJson(Map<String, dynamic> m) => _Marker(
        id: (m['id'] as num?)?.toInt() ?? 0,
        label: (m['label'] ?? '').toString(),
        count: (m['count'] as num?)?.toInt() ?? 0,
        memberIds: [
          for (final e in (m['memberIds'] as List? ?? const []))
            (e as num?)?.toInt() ?? -1
        ]..removeWhere((v) => v < 0),
        kind: (m['kind'] ?? 'custom').toString(),
      );
}

/// Ações que o auxiliar consegue resolver sem tentar ser um motor completo
/// de regras. Fichas fora desta lista continuam podendo ser viradas/editadas.
enum _UtilityAction { none, treasure, food, clue, blood, map, powerstone }

enum _PlayMode { local, lan, online }

class _MatchSnapshot {
  final Map<String, dynamic> state;
  final String label;
  _MatchSnapshot(this.state, this.label);
}

class _TableStyle {
  final String name;
  final Color background;
  final Color panel;
  final Color accent;
  const _TableStyle(this.name, this.background, this.panel, this.accent);
}

/// Pilha visual: fichas só se juntam quando seu estado de jogo é o mesmo.
/// Uma ficha 1/1 com marcador, virada ou recebendo efeito diferente nunca
/// some dentro da pilha de uma 5/5, por exemplo.
class _TokenStack {
  final List<_Token> tokens;
  _TokenStack(this.tokens);
  _Token get lead => tokens.first;
  int get count => tokens.length;
}

/// Uma sessão Online independente: seu próprio OnlineMatch (sua própria
/// conexão, UID, listeners e identidade). O slot 'a' usa o app Firebase
/// padrão; o slot 'b' usa um app secundário — ou seja, outro UID
/// anônimo no mesmo aparelho. A mesa (_players/_tokens/...) continua
/// única e compartilhada: as sessões só transportam estado e ações.
class _NetSession {
  final String slot;
  OnlineMatch? net;
  String profileId = '';
  String displayName = '';
  String roomCode = '';
  bool hosting = false;
  bool joining = false;
  bool started = false;
  bool allowLateJoin = true;
  int maxPlayers = 6;
  String? hostId;
  Map<String, Map<String, dynamic>> players = {};
  StreamSubscription<OnlineRoomInfo>? roomSub;
  StreamSubscription<Map<String, dynamic>>? actionSub;

  _NetSession(this.slot);

  bool get inRoom => net?.isInRoom ?? false;
  String? get myUid => net?.myUid;

  Map<String, dynamic> toJson() => {
        'slot': slot,
        'code': roomCode,
        'hosting': hosting,
        'name': displayName,
        'profileId': profileId,
      };
}

class PlayPage extends StatefulWidget {
  const PlayPage({super.key});

  @override
  State<PlayPage> createState() => _PlayPageState();
}

class _PlayPageState extends State<PlayPage> with WidgetsBindingObserver {
  static const _formats = {
    'livre': ('fmt_livre', 20),
    'standard': ('fmt_standard', 20),
    'commander1v1': ('su_cmd_1v1', 40),
    'commander': ('su_cmd_multi', 40),
    'custom': ('su_fmt_custom', 20),
  };

  static String _formatLabel(String key) {
    final v = _formats[key];
    if (v == null) return key;
    final label = v.$1;
    return label.startsWith('fmt_') || label.startsWith('su_')
        ? AppLocale.t(label)
        : label;
  }

  bool _inMatch = false;
  _PlayMode _playMode = _PlayMode.local;
  bool _focusMode = false;
  String _tableTheme = 'midnight';
  // Fundo da MINHA mesa no LAN/Online (id do registry; '' = sólido).
  // No local cada jogador tem o seu (_playerBgs).
  String _myTableBg = '';
  String _format = 'livre';
  int _playerCount = 2;
  int _startLife = 20;
  List<TextEditingController> _nameCtrls = [];
  // Lado de cada jogador no multi local (true = topo, false = base).
  // Padrão: P1 e P2 embaixo, resto em cima (3p = 2+1, 4p = 2+2).
  List<bool> _playerSides = [];
  // Tema e fundo por jogador no setup ('' = global / sólido).
  List<String> _playerThemes = [];
  List<String> _playerBgs = [];
  List<Map<String, Object?>> _friends = [];

  List<_MatchPlayer> _players = [];
  List<_Token> _tokens = [];
  List<_TokenEffect> _effects = [];
  // Marcadores separados da mesa (globais ou por ficha).
  List<_Marker> _markers = [];
  // Pool de mana por jogador: nome -> {W,U,B,R,G,C} -> qtd.
  // (mana "extra" p/ Tesouros e boca-livre; esvazia no reset.)
  Map<String, Map<String, int>> _mana = {};
  int _round = 1;
  int _active = 0;
  int _tokenSeq = 1;
  int _effectSeq = 1;
  int _markerSeq = 1;
  final _rand = Random();
  // Nome "eu" neste aparelho (p/ "você morreu/venceu" e mana própria).
  String _myName = '';
  // Mortes já anunciadas (não repete até reviver).
  final Set<String> _deadAnnounced = {};
  // Fichas: lista ou grade? grade com 2 ou 3 colunas?
  bool _tokensList = false;
  int _tokensCols = 2;
  // Oponente selecionado na mesa deles (3+ jogadores).
  int _oppSel = 0;
  // Jogador exibido no detalhe da Arena (índice em _players).
  int _arenaSel = 0;
  final List<_MatchSnapshot> _history = [];
  List<String> _activity = [];
  static const _savedMatchKey = 'play_match_v1';

  static const _manaColors = ['W', 'U', 'B', 'R', 'G', 'C'];
  static String _manaName(String color) => AppLocale.t('su_mana_$color');
  static const _manaDots = {
    'W': Color(0xFFE8DCC0),
    'U': Color(0xFF2196F3),
    'B': Color(0xFF616161),
    'R': Color(0xFFF44336),
    'G': Color(0xFF4CAF50),
    'C': Color(0xFFB0BEC5),
  };

  /// Número sempre legível: preto nos pontos claros (W e C), branco
  /// nos escuros. Branco sobre creme/cinza-claro some na tela.
  static bool _manaDarkText(String color) => color == 'W' || color == 'C';
  static const _tableStyles = {
    'midnight': _TableStyle(
        'su_th_midnight', AppTheme.bg, Color(0xFF20242D), Color(0xFFD4AF37)),
    'forest': _TableStyle('su_th_forest', Color(0xFF10231C), Color(0xFF1B3529),
        Color(0xFF76B985)),
    'arcane': _TableStyle('su_th_arcane', Color(0xFF20152D), Color(0xFF332348),
        Color(0xFFC994FF)),
    'ember': _TableStyle(
        'su_th_ember', Color(0xFF2B1817), Color(0xFF402523), Color(0xFFFF9A62)),
    'ocean': _TableStyle('su_th_ocean', Color(0xFF0B1D29), Color(0xFF14324A),
        Color(0xFF4FC3F7)),
    'blood': _TableStyle('su_th_blood', Color(0xFF230F14), Color(0xFF3A151C),
        Color(0xFFFF5252)),
  };
  _TableStyle get _tableStyle =>
      _tableStyles[_tableTheme] ?? _tableStyles['midnight']!;

  // ===== AJUSTE FINO DA MESA (tamanhos em px — mexa aqui) =====
  // Duelo 1x1 local (duas metades, uma de ponta-cabeça).
  static const double _duelNameH = 30; // linha nome + botão add
  static const double _duelLifeH = 72; // painel de vida (era 96: agora sobra
  static const double _duelLifeHCompact = 54; // p/ a vida na paisagem apertada
  static const double _duelCompactH = 240; // zona menor que isso encolhe tudo
  // Cartas na mesa: altura segue o espaço livre até o teto; largura =
  // altura × _tokenAspect (proporção da carta).
  static const double _tokenAspect = 0.72;
  static const double _tokenMaxH = 210; // teto duelo/local
  static const double _tokenMaxW = 150;
  static const double _tokenMinH = 44; // abaixo disso some em vez de estourar
  // Arena (online/LAN): a faixa aproveita o resto da zona até o teto.
  static const double _arenaStripMaxH = 180; // era 132
  static const double _arenaCompactH = 180; // abaixo disso rola compacto

  /// Amostra das 3 cores do tema (fundo, painel, destaque) num círculo
  /// só — cabe no slot de avatar dos chips (3 bolinhas estouravam).
  static Widget _themeSwatch(_TableStyle s, {double r = 8}) {
    return Container(
      width: r * 2,
      height: r * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(
          colors: [s.background, s.panel, s.accent, s.background],
        ),
        border: Border.all(color: Colors.black54),
      ),
    );
  }

  /// Miniatura do fundo atual (ou ícone) para os botões de escolha.
  Widget _bgThumb(String id, {double w = 28, double h = 20}) {
    TableBackground? found;
    for (final b in tableBackgrounds) {
      if (b.id == id) {
        found = b;
        break;
      }
    }
    if (found == null) {
      return const Icon(Icons.image_outlined,
          size: 18, color: AppTheme.textMuted);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.asset(found.asset,
          width: w,
          height: h,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
              size: 18, color: AppTheme.textMuted)),
    );
  }

  /// Sheet visual de fundos: grade com prévia de como fica a mesa.
  /// Primeiro item = sem imagem. Devolve o id escolhido ou null.
  Future<void> _bgPickerSheet(
      {required String current,
      required ValueChanged<String> onPick}) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppLocale.t('su_bg'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 8),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 2.2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: tableBackgrounds.length + 1,
                  itemBuilder: (_, k) {
                    if (k == 0) {
                      final sel = current.isEmpty;
                      return GestureDetector(
                        onTap: () => Navigator.pop(ctx, ''),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: sel
                                    ? AppTheme.gold
                                    : AppTheme.border,
                                width: sel ? 2 : 1),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.hide_image_outlined,
                                  size: 20,
                                  color: sel
                                      ? AppTheme.gold
                                      : AppTheme.textMuted),
                              const SizedBox(height: 2),
                              Text(AppLocale.t('su_bg_none'),
                                  style:
                                      const TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                      );
                    }
                    final b = tableBackgrounds[k - 1];
                    final sel = current == b.id;
                    return GestureDetector(
                      onTap: () => Navigator.pop(ctx, b.id),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color:
                                  sel ? AppTheme.gold : AppTheme.border,
                              width: sel ? 2 : 1),
                          image: DecorationImage(
                              image: AssetImage(b.asset),
                              fit: BoxFit.cover),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.transparent,
                                Color(0xB3000000),
                              ],
                              stops: [0.0, 0.45, 1.0],
                            ),
                          ),
                          alignment: Alignment.bottomLeft,
                          padding: const EdgeInsets.all(6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(b.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        shadows: [
                                          Shadow(
                                              color: Colors.black,
                                              blurRadius: 4)
                                        ])),
                              ),
                              if (sel)
                                const Icon(Icons.check_circle,
                                    size: 16, color: AppTheme.gold),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (pick != null) onPick(pick);
  }

  /// Tema da mesa de um jogador (o dele; '' = global). Vale no local,
  /// e no online mostra o tema QUE O OPONENTE escolheu (vem no estado).
  _TableStyle _styleFor(_MatchPlayer p) =>
      _tableStyles[p.theme] ?? _tableStyle;

  /// Fundo de mesa de um jogador (id do registry; null = sólido).
  TableBackground? _bgFor(_MatchPlayer p) {
    final id = p.bg.trim();
    if (id.isEmpty) return null;
    for (final b in tableBackgrounds) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Moldura de zona com o tema + fundo do jogador: imagem de fundo
  /// (se escolhida) com vinheta suave nos cantos — degrade escuro só
  /// nas bordas para a imagem não ficar chapada e o texto continuar
  /// legível. Sem imagem, painel sólido do tema. Borda de turno igual.
  Widget _zoneFrame({
    required _MatchPlayer p,
    required bool isActive,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(6),
  }) {
    final st = _styleFor(p);
    final bg = _bgFor(p);
    final side = BorderSide(
        color: isActive ? st.accent : AppTheme.border,
        width: isActive ? 2 : 1);
    if (bg == null) {
      return Card(
        margin: EdgeInsets.zero,
        color: st.panel,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), side: side),
        child: Padding(padding: padding, child: child),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: side),
      child: Stack(
        children: [
          // Fundo + vinheta SÓ no fundo: o degrade escurece as bordas
          // da imagem e nunca o conteúdo (textos/cartas) por cima.
          // Se o asset falhar (APK sem o arquivo, id antigo), cai para
          // o painel sólido em vez de quebrar a zona.
          Positioned.fill(
            child: Container(
              color: st.panel,
              child: Image.asset(
                bg.asset,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Container(color: st.panel),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 0.75,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    Color(0x8C000000),
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }

  // ---- rede local ----
  LanHost? _host;
  LanGuest? _guest;
  String _hostIp = '';
  String _lanHostName = '';
  List<String> _hostIps = [];
  int _hostIpIdx = 0;
  int _peers = 0;

  /// Banner de reconexão dispensado ("lan:IP" / "on:CODIGO"). Some até
  /// que uma NOVA queda aconteça (chave diferente) — sem boolean travado.
  String _dismissedReconnect = '';
  bool _hosting = false;
  bool _joining = false;
  final _joinIp = TextEditingController();
  // Jogadores fake (só teste sem 2º celular): entram como gente normal,
  // mas o ✕ aparece mesmo sem ninguém conectado.
  final Set<String> _fakePlayers = {};

  // ---- sessões online (multi) ----
  // Mapa por slot ('a' = app Firebase padrão, 'b' = app secundário com
  // UID próprio). Uma sessão NUNCA é destruída por troca de perfil.
  final Map<String, _NetSession> _sessions = {};

  String _profileName = '';
  String _profileId = '';
  final _joinCodeCtrl = TextEditingController();
  // Último estado remoto aplicado (evita reaplicar o eco entre sessões).
  String _lastRemoteStateJson = '';

  _NetSession _session(String slot) =>
      _sessions.putIfAbsent(slot, () => _NetSession(slot));

  /// Sessões "vivas" (em sala, entrando ou com identidade). Shells
  /// vazios pós-saída não aparecem na UI nem contam no limite.
  List<_NetSession> get _activeSessions => [
        for (final s in _sessions.values)
          if (s.inRoom || s.joining || s.displayName.isNotEmpty) s
      ];

  /// Sessão com autoridade (host) — no máximo uma por vez.
  _NetSession? get _hostSession {
    for (final s in _sessions.values) {
      if (s.hosting && s.inRoom) return s;
    }
    return null;
  }

  /// Primeira sessão conectada (para leitura de sala/jogadores).
  _NetSession? get _firstInRoom {
    for (final s in _sessions.values) {
      if (s.inRoom) return s;
    }
    return null;
  }

  /// Nomes controlados neste aparelho (todas as sessões). O turno passa
  /// se o jogador da vez for qualquer um deles.
  Set<String> get _localOnlineNames => {
        for (final s in _sessions.values)
          if (s.inRoom && s.displayName.trim().isNotEmpty)
            s.displayName.trim().toLowerCase(),
        if (_myName.trim().isNotEmpty) _myName.trim().toLowerCase(),
      };

  /// UIDs controlados neste aparelho (sessões em sala). Referência
  /// principal de identidade — nome é só exibição.
  Set<String> get _localUids => {
        for (final s in _sessions.values)
          if (s.inRoom && (s.myUid ?? '').isNotEmpty) s.myUid!,
      };

  /// Mapa uid -> nome de exibição (sala do host, senão a primeira).
  Map<String, String> get _uidNames {
    final s = _hostSession ?? _firstInRoom;
    if (s == null) return {};
    return {
      for (final e in s.players.entries)
        e.key: (e.value['name'] ?? '').toString()
    };
  }

  /// UID do jogador com este nome de exibição ('' se desconhecido).
  String _uidOfName(String name) {
    final key = name.trim().toLowerCase();
    if (key.isEmpty) return '';
    for (final entry in _uidNames.entries) {
      if (entry.value.trim().toLowerCase() == key) return entry.key;
    }
    return '';
  }

  /// Este jogador (uid+nome) é controlado neste aparelho?
  bool _isLocalIdentity(String uid, String name) {
    if (uid.isNotEmpty && _localUids.contains(uid)) return true;
    final n = name.trim().toLowerCase();
    return n.isNotEmpty && _localOnlineNames.contains(n);
  }

  /// Identidade estável para comparar dono de ficha com jogador.
  /// UID manda quando os dois lados têm; sem UID (local/LAN/legado
  /// ou saves antigos) compara por nome — nunca perde ficha existente.
  static bool _sameIdentity(_Token t, _MatchPlayer p) {
    if (t.ownerUid.isNotEmpty && p.uid.isNotEmpty) {
      return t.ownerUid == p.uid;
    }
    return t.owner.trim().toLowerCase() == p.name.trim().toLowerCase();
  }

  /// Este nome de jogador é meu (sessão ou perfil da mesa)?
  bool _isMinePlayer(String name) {
    final n = name.trim();
    if (n.isEmpty) return false;
    if (_isOnline) {
      final uid = _uidOfName(n);
      if (uid.isNotEmpty) return _localUids.contains(uid);
      return _localOnlineNames.contains(n.toLowerCase());
    }
    return n == _myName.trim();
  }

  bool get _isGuest => _guest != null || _isOnlineGuest;
  bool get _isHost => _host != null;
  bool get _isOnline => _playMode == _PlayMode.online;
  bool get _isOnlineHost => _hostSession != null;
  bool get _isOnlineGuest =>
      _isOnline && _hostSession == null && _firstInRoom != null;
  bool get _canRecoverLan =>
      _inMatch && _playMode == _PlayMode.lan && !_isHost && !_isGuest;
  bool get _amLanHost => _lanHostName.isNotEmpty && _lanHostName == _myName;

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  /// Perfil trocou sem restart: atualiza nome/id exibidos e os amigos.
  /// Em partida (inclusive online), não mexe em nada: cada sessão mantém
  /// a identidade com que entrou (o banner mostra se divergir).
  void _onProfileChanged() {
    if (!mounted) return;
    // Presença (nome/sala dos amigos) acompanha o perfil novo.
    _loadProfileIdentity().then((_) => _refreshPresenceRoom());
    if (_inMatch) {
      AppToast.show(context, AppLocale.t('prof_match_kept'));
      return;
    }
    _loadFriends();
    if (mounted) setState(() {});
  }

  /// Sessões com divergência entre identidade e perfil atual.
  /// Não desconecta nada sozinho — só informa.
  List<_NetSession> get _mismatchedSessions {
    final p = _profileName.trim().toLowerCase();
    return [
      for (final s in _sessions.values)
        if (s.inRoom &&
            s.displayName.trim().isNotEmpty &&
            (p.isEmpty || s.displayName.trim().toLowerCase() != p))
          s
    ];
  }

  bool get _sessionMismatch =>
      _mismatchedSessions.isNotEmpty &&
      (_sessions.values.any((s) => s.inRoom) || (_inMatch && _isOnline));

  /// Avisos "sala conectada como A, perfil atual B" (um por sessão).
  List<Widget> _sessionMismatchBanners() {
    if (!_sessionMismatch) return const [];
    final p = _profileName.trim();
    return [
      for (final s in _mismatchedSessions)
        Card(
          color: AppTheme.sidebar,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppTheme.gold),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.switch_account,
                    size: 16, color: AppTheme.gold),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      AppLocale.t('on_session_mismatch')
                          .replaceAll('{s}', s.displayName.trim())
                          .replaceAll('{p}', p.isEmpty ? '?' : p),
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetNameCtrls();
    _loadFriends();
    _loadArtCache();
    _restoreSavedMatch();
    _loadProfileIdentity();
    PlayPrefs.hideTokenNames.addListener(_onPrefsChanged);
    PlayPrefs.rotateTapped.addListener(_onPrefsChanged);
    PlayPrefs.stackVisible.addListener(_onPrefsChanged);
    PlayPrefs.keywordPos.addListener(_onPrefsChanged);
    PlayPrefs.tableFormat.addListener(_onPrefsChanged);
    AppLocale.current.addListener(_onPrefsChanged);
    AppEvents.topVisible.addListener(_onPrefsChanged);
    AppEvents.activeProfile.addListener(_onProfileChanged);
    AppEvents.authStopping.addListener(_onAuthStopping);
    LanPresence.ensureStarted();
    LanPresence.instance.onInvite = _onLanInvite;

    // Recupera as sessões salvas (cada uma no seu slot/UID).
    _restoreSessions();
    _initPresence();
  }

  final _friendsApi = OnlineFriends();
  String _fbUid = '';
  String _lastPresenceKey = '';
  // Amigos + presença para "Salas dos amigos" (entrar com 1 toque).
  List<OnlineFriend> _fbRoomFriends = [];
  StreamSubscription? _fbRoomFrSub;
  final Map<String, Map<String, dynamic>> _fbRoomPresence = {};
  final Map<String, StreamSubscription> _fbRoomPresSubs = {};
  // Stream cacheado: recriar a cada build recancelava a escuta e a
  // caixa piscava / perdia eventos. Como o onValue do Firebase é
  // single-subscription, converte para broadcast UMA vez na criação:
  // remounts (troca de Card, rebuilds do leave) reescutam sem o
  // "Stream has already been listened to".
  Stream<List<RoomInvite>>? _inviteStream;
  // UID vigiado pelo _inviteStream (troca com re-login/novo anônimo).
  String _inviteUid = '';

  Future<void> _initPresence() async {
    try {
      final uid = await _friendsApi.myUid;
      if (!mounted) return;
      setState(() => _fbUid = uid);
      _watchInvites(uid);
      _refreshPresenceRoom();
      _fbRoomFrSub?.cancel();
      _fbRoomFrSub = _friendsApi.watchFriends(uid).listen((friends) {
        if (!mounted) return;
        setState(() => _fbRoomFriends = friends);
        _syncRoomPresenceSubs();
      }, onError: (_) {});
    } catch (_) {}
  }

  /// Sessão caindo: derruba escutas de amigos/presença/salas do UID
  /// velho ANTES do signOut completar.
  void _onAuthStopping() {
    _fbRoomFrSub?.cancel();
    _fbRoomFrSub = null;
    for (final s in _fbRoomPresSubs.values) {
      s.cancel();
    }
    _fbRoomPresSubs.clear();
    for (final s in _sessions.values) {
      s.roomSub?.cancel();
      s.actionSub?.cancel();
      s.roomSub = null;
      s.actionSub = null;
    }
  }
  /// (Re)assina os convites de sala: troca de UID, volta do 2º plano
  /// (o socket do Firebase pode cochilar) ou toque no atualizar.
  /// Recriar o stream força um `onValue` imediato — o convite aparece
  /// sozinho, sem precisar "mexer na tela".
  void _watchInvites(String uid, {bool force = false}) {
    if (uid.isEmpty) return;
    if (!force && uid == _inviteUid && _inviteStream != null) return;
    _inviteUid = uid;
    _inviteStream = _friendsApi.watchRoomInvites(uid).asBroadcastStream();
    if (mounted) setState(() {});
  }

  void _syncRoomPresenceSubs() {
    final want = {for (final f in _fbRoomFriends) f.uid};
    for (final uid in _fbRoomPresSubs.keys.toList()) {
      if (!want.contains(uid)) {
        _fbRoomPresSubs.remove(uid)?.cancel();
        _fbRoomPresence.remove(uid);
      }
    }
    for (final uid in want) {
      if (uid.isEmpty || _fbRoomPresSubs.containsKey(uid)) continue;
      _fbRoomPresSubs[uid] = _friendsApi.watchPresence(uid).listen((p) {
        if (!mounted) return;
        setState(() => _fbRoomPresence[uid] = p);
      }, onError: (_) {});
    }
  }

  /// Presença (Disponível/Jogando) da identidade padrão. Só escreve
  /// quando sala ou nome mudam — sem spam no banco.
  void _refreshPresenceRoom() {
    final room = _firstInRoom?.roomCode ?? '';
    final name =
        _profileName.trim().isNotEmpty ? _profileName.trim() : _myName.trim();
    if (name.isEmpty) return;
    final key = '$room|$name';
    if (key == _lastPresenceKey) return;
    _lastPresenceKey = key;
    _friendsApi.setPresence(name: name, room: room.isEmpty ? null : room);
  }

  Future<void> _loadProfileIdentity() async {
    try {
      final name = (await AppDatabase.instance.activeProfileName()).trim();
      final id = await _currentProfileId();
      if (!mounted) return;
      setState(() {
        if (name.isNotEmpty) _profileName = name;
        _profileId = id;
      });
    } catch (_) {
      // Sem identidade: banners de divergência ficam ocultos.
    }
  }

  /// Id do perfil ativo (registro global) — identifica "este perfil"
  /// independente do nome de exibição.
  Future<String> _currentProfileId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getString('active_db_path') ?? '';
      if (active.isEmpty) return '';
      final rows = await AppDatabase.instance.mainDb().then((mdb) => mdb.query(
          'profiles',
          columns: ['id'],
          where: 'database_path = ?',
          whereArgs: [active],
          limit: 1));
      if (rows.isNotEmpty) return (rows.first['id'] ?? '').toString();
    } catch (_) {}
    return '';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_focusMode) AppEvents.navVisible.value = true;
    AppEvents.playFocusActive.value = false;

    PlayPrefs.hideTokenNames.removeListener(_onPrefsChanged);
    PlayPrefs.rotateTapped.removeListener(_onPrefsChanged);
    PlayPrefs.stackVisible.removeListener(_onPrefsChanged);
    PlayPrefs.keywordPos.removeListener(_onPrefsChanged);
    PlayPrefs.tableFormat.removeListener(_onPrefsChanged);
    AppLocale.current.removeListener(_onPrefsChanged);
    AppEvents.topVisible.removeListener(_onPrefsChanged);
    AppEvents.activeProfile.removeListener(_onProfileChanged);
    AppEvents.authStopping.removeListener(_onAuthStopping);

    if (LanPresence.instance.onInvite == _onLanInvite) {
      LanPresence.instance.onInvite = null;
    }

    _fbRoomFrSub?.cancel();
    for (final s in _fbRoomPresSubs.values) {
      s.cancel();
    }
    _fbRoomPresSubs.clear();

    for (final s in _sessions.values) {
      s.roomSub?.cancel();
      s.actionSub?.cancel();
      // Melhor esforço: marca offline na sala antes de soltar os streams.
      try {
        s.net?.setConnected(false);
      } catch (_) {}
      try {
        s.net?.dispose();
      } catch (_) {}
    }
    _sessions.clear();

    for (final c in _nameCtrls) {
      c.dispose();
    }

    _joinIp.dispose();
    _joinCodeCtrl.dispose();
    _host?.stop();
    _guest?.disconnect();

    super.dispose();
  }

  /// Descarta controllers de sheets/diálogos SÓ após a animação de saída
  /// (~350ms). O `showModalBottomSheet`/`showDialog` entrega o resultado
  /// no `pop`, mas o TextField continua montado durante a saída —
  /// descartar na hora quebra com "controller used after dispose".
  static void _laterDispose(TextEditingController c) {
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        c.dispose();
      } catch (_) {}
    });
  }

  void _resetNameCtrls() {
    // Preserva o que já foi digitado/escolhido nos índices mantidos —
    // trocar a contagem não apaga mais nomes, lados, temas e fundos.
    final oldNames = [for (final c in _nameCtrls) c.text];
    final oldSides = List<bool>.of(_playerSides);
    final oldThemes = List<String>.of(_playerThemes);
    final oldBgs = List<String>.of(_playerBgs);
    for (final c in _nameCtrls) {
      c.dispose();
    }
    _nameCtrls = List.generate(_playerCount, (i) {
      final kept = i < oldNames.length ? oldNames[i].trim() : '';
      return TextEditingController(
          text: kept.isNotEmpty
              ? kept
              : (i == 0
                  ? AppLocale.t('su_you')
                  : '${AppLocale.t('su_player')} ${i + 1}'));
    });
    _playerSides = List.generate(_playerCount,
        (i) => i < oldSides.length ? oldSides[i] : i >= 2);
    _playerThemes = List.generate(
        _playerCount, (i) => i < oldThemes.length ? oldThemes[i] : '');
    _playerBgs = List.generate(
        _playerCount, (i) => i < oldBgs.length ? oldBgs[i] : '');
  }

  Future<void> _loadFriends() async {
    try {
      final rows =
          await AppDatabase.instance.db.query('friends', orderBy: 'name ASC');
      if (mounted) setState(() => _friends = rows);
    } catch (_) {}
  }

  void _setFormat(String? v) {
    if (v == null) return;
    setState(() {
      _format = v;
      _startLife = _formats[v]!.$2;
      if (v == 'commander1v1') {
        _playerCount = 2;
        _resetNameCtrls();
      }
    });
  }

  /// Save da partida separado por perfil (cada um tem sua mesa salva).
  Future<String> _saveKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getString('active_db_path') ?? 'default';
      return '${_savedMatchKey}_$active';
    } catch (_) {
      return _savedMatchKey;
    }
  }

  /// App foi para 2º plano (home/outro app): garante a partida salva
  /// NA HORA — se o SO matar o processo, a volta restaura tudo
  /// (aba + mesa) em vez de "resetar". Vale por 7 dias.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _persistMatch();
    } else if (state == AppLifecycleState.resumed) {
      // Volta do 2º plano: garante socket vivo e reassina convites —
      // sem isso o convite só aparecia mexendo na tela. O UID pode
      // ter mudado (re-login), então reconfere antes.
      try {
        OnlineMatch.defaultDatabase().goOnline();
      } catch (_) {}
      _friendsApi.myUid.then((uid) {
        if (!mounted) return;
        if (uid.isNotEmpty && uid != _fbUid) {
          setState(() => _fbUid = uid);
        }
        if (_fbUid.isNotEmpty) _watchInvites(_fbUid, force: true);
      }).catchError((_) {});
    }
  }

  Future<void> _restoreSavedMatch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(await _saveKey());
      if (raw == null || raw.isEmpty) return;
      final saved = Map<String, dynamic>.from(jsonDecode(raw));
      if (!mounted || saved['players'] is! List) return;
      // Tempo limite: save com mais de 7 dias é descartado (mesa velha).
      final when = DateTime.tryParse((saved['savedAt'] ?? '').toString());
      if (when != null &&
          DateTime.now().difference(when) > const Duration(days: 7)) {
        await _clearSavedMatch();
        return;
      }
      _applyState(saved);
      setState(() => _myName = (saved['myName'] ?? '').toString());
      if (mounted) {
        AppToast.show(context, 'Partida anterior restaurada.');
      }
    } catch (_) {
      // Um estado antigo/corrompido não deve impedir abrir o aplicativo.
    }
  }

  Future<void> _persistMatch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _saveKey();
      if (!_inMatch || _players.isEmpty) {
        await prefs.remove(key);
        return;
      }
      await prefs.setString(
          key,
          jsonEncode({
            ..._matchToJson(),
            'myName': _myName,
            'activity': _activity,
            'savedAt': DateTime.now().toIso8601String(),
          }));
    } catch (_) {}
  }

  Future<void> _clearSavedMatch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(await _saveKey());
    } catch (_) {}
  }

  Map<String, dynamic> _stateCopy() =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(_matchToJson())));

  void _recordHistory(String label) {
    if (!_inMatch) return;
    _history.add(_MatchSnapshot(_stateCopy(), label));
    if (_history.length > 30) _history.removeAt(0);
    _activity = [label, ..._activity].take(20).toList();
  }

  void _undo() {
    if (_isGuest) {
      _send({'action': 'undo'});
      return;
    }
    if (_history.isEmpty) {
      AppToast.show(context, 'Nada para desfazer.');
      return;
    }
    final previous = _history.removeLast();
    _applyState(previous.state);
    _activity = ['Desfez: ${previous.label}', ..._activity].take(20).toList();
    _broadcast();
    AppToast.show(context, 'Desfeito: ${previous.label}');
  }

  Future<void> _showHistory() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(AppLocale.t('su_history'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 8),
            if (_activity.isEmpty)
              Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(AppLocale.t('su_no_history')))
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _activity.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.history, size: 18),
                    title: Text(_activity[i]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  // ================= ESTADO / REDE =================

  /// Código da sala principal (host, senão a primeira) — compat.
  String get _primaryRoomCode =>
      _hostSession?.roomCode ?? _firstInRoom?.roomCode ?? '';

  Map<String, dynamic> _matchToJson() => {
        'playMode': _playMode.name,
        'lanHostName': _lanHostName,
        'lanHostIp': _joinIp.text.trim(),
        'onlineRoom': _primaryRoomCode,
        'tableTheme': _tableTheme,
        'format': _format,
        'startLife': _startLife,
        'round': _round,
        'active': _active,
        'players': [for (final p in _players) p.toJson()],
        'tokens': [for (final t in _tokens) t.toJson()],
        'effects': [for (final e in _effects) e.toJson()],
        'markers': [for (final mk in _markers) mk.toJson()],
        'mana': {
          for (final entry in _mana.entries)
            entry.key: Map<String, int>.from(entry.value)
        },
        'activity': _activity,
      };

  void _applyState(Map<String, dynamic> m) {
    List<T> list<T>(Object? raw, T Function(Map<String, dynamic>) f) {
      if (raw is! List) return [];
      return [
        for (final e in raw)
          if (e is Map) f(Map<String, dynamic>.from(e))
      ];
    }

    final wasInMatch = _inMatch;
    setState(() {
      final savedMode = (m['playMode'] ?? '').toString();

      _playMode = switch (savedMode) {
        'lan' => _PlayMode.lan,
        'online' => _PlayMode.online,
        _ => _PlayMode.local,
      };

      _lanHostName = (m['lanHostName'] ?? '').toString();
      final savedIp = (m['lanHostIp'] ?? '').toString().trim();
      if (savedIp.isNotEmpty) _joinIp.text = savedIp;
      final savedRoom = (m['onlineRoom'] ?? '').toString().trim();
      if (savedRoom.isNotEmpty) {
        if (_joinCodeCtrl.text.trim().isEmpty) {
          _joinCodeCtrl.text = savedRoom.toUpperCase();
        }
      }
      _tableTheme = _tableStyles.containsKey(m['tableTheme'])
          ? m['tableTheme'].toString()
          : 'midnight';
      _format = (m['format'] ?? 'livre').toString();
      _startLife = (m['startLife'] as num?)?.toInt() ?? 20;
      _round = (m['round'] as num?)?.toInt() ?? 1;
      _active = (m['active'] as num?)?.toInt() ?? 0;
      _players = list(m['players'], _MatchPlayer.fromJson);
      _tokens = list(m['tokens'], _Token.fromJson);
      _effects = list(m['effects'], _TokenEffect.fromJson);
      _markers = list(m['markers'], _Marker.fromJson);
      _activity = [
        for (final e in (m['activity'] as List? ?? const [])) e.toString()
      ];
      _mana = {};
      final mm = m['mana'];
      if (mm is Map) {
        mm.forEach((k, v) {
          if (v is Map) {
            final inner = <String, int>{};
            v.forEach((ck, cv) {
              inner[ck.toString()] = (cv as num?)?.toInt() ?? 0;
            });
            _mana[k.toString()] = inner;
          }
        });
      }
      _inMatch = _players.isNotEmpty;
      var maxT = 0;
      for (final t in _tokens) {
        if (t.id >= maxT) maxT = t.id + 1;
      }
      _tokenSeq = maxT == 0 ? 1 : maxT;
      var maxE = 0;
      for (final e in _effects) {
        if (e.id >= maxE) maxE = e.id + 1;
      }
      _effectSeq = maxE == 0 ? 1 : maxE;
      var maxM = 0;
      for (final mk in _markers) {
        if (mk.id >= maxM) maxM = mk.id + 1;
      }
      _markerSeq = maxM == 0 ? 1 : maxM;
    });
    if (wasInMatch) {
      _checkDeaths();
    } else {
      // Sincronização inicial: marca mortos atuais sem anunciar.
      _deadAnnounced.clear();
      _winsAnnounced.clear();
      for (final p in _players) {
        if (!p.alive) _deadAnnounced.add(p.name);
      }
    }
  }

  /// Slots de sessão (até 6, como a sala). 'a' usa o app Firebase
  /// padrão; os demais usam apps secundários, cada um com seu próprio
  /// UID anônimo — ou seja, jogadores independentes no mesmo aparelho.
  static const _sessionSlots = ['a', 'b', 'c', 'd', 'e', 'f'];
  static const _extraAppNames = {
    'b': 'secondary',
    'c': 'tertiary',
    'd': 'quaternary',
    'e': 'quinary',
    'f': 'senary',
  };
  static const int _maxSessions = 6;

  /// Próximo slot livre para uma nova sessão (ou '' se lotou).
  String _freeSlot() {
    for (final slot in _sessionSlots) {
      final s = _sessions[slot];
      if (s == null || (!s.inRoom && !s.joining)) return slot;
    }
    return '';
  }

  /// Cria o transporte da sessão (app padrão no slot 'a', app
  /// secundário com UID próprio nos demais slots).
  Future<OnlineMatch> _netFor(_NetSession s) async {
    if (s.net != null) return s.net!;
    if (s.slot == 'a') {
      s.net = OnlineMatch();
      return s.net!;
    }
    final appName = _extraAppNames[s.slot] ?? 'secondary_${s.slot}';
    FirebaseApp app;
    try {
      app = Firebase.app(appName);
    } catch (_) {
      app = await Firebase.initializeApp(
        name: appName,
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    s.net = OnlineMatch(
      auth: FirebaseAuth.instanceFor(app: app),
      database: FirebaseDatabase.instanceFor(
          app: app, databaseURL: OnlineMatch.databaseUrl),
    );
    return s.net!;
  }

  void _listenSession(_NetSession s) {
    if (s.net == null) return;
    s.roomSub?.cancel();
    s.actionSub?.cancel();

    s.roomSub = s.net!.roomStream.listen((room) {
      _onSessionRoom(s, room);
    });
    s.actionSub = s.net!.actionStream.listen((action) {
      _onSessionAction(s, action);
    });
  }

  void _onSessionRoom(_NetSession s, OnlineRoomInfo room) {
    if (!mounted) return;

    final players = <String, Map<String, dynamic>>{};
    room.players.forEach((uid, v) {
      if (v is Map) {
        players[uid] = Map<String, dynamic>.from(
            v.map((k, val) => MapEntry(k.toString(), val)));
      }
    });
    setState(() {
      s.roomCode = room.roomId;
      s.hostId = room.hostId;
      s.started = room.isStarted;
      s.allowLateJoin = room.allowLateJoin;
      s.maxPlayers = room.maxPlayers.clamp(2, 12);
      s.players = players;
      // _peers agrega: host local tem autoridade no contador.
      final ref = _hostSession ?? _firstInRoom;
      _peers =
          ref == null || ref.players.isEmpty ? _peers : ref.players.length - 1;
    });

    final state = room.state;
    // O host ignora o eco do próprio publish; guests aplicam com
    // dedupe (duas sessões na mesma sala recebem o mesmo estado).
    if (!s.hosting &&
        state != null &&
        state['players'] is List &&
        (room.isStarted || _inMatch)) {
      _applyRemoteState(state);
    }

    // Host incorpora quem entrou tarde (join-in-progress): vira jogador
    // da mesa com vida cheia e republica. Vale até o limite da sala.
    if (s.hosting && s.inRoom && room.isStarted && _inMatch && _isOnline) {
      _absorbLateJoiners(s, room);
    }

    // Host realinha o visual (tema/fundo/uid) da mesa com o cadastro da
    // sala: quem trocou o visual pelo nó, ou entrou antes da mesa, passa
    // a exibir certo para TODOS (era comum só o bg do host aparecer).
    if (s.hosting && s.inRoom && _inMatch && _isOnline) {
      _syncRosterVisuals(s);
    }

    if (room.isStarted && !_inMatch && _playMode == _PlayMode.online) {
      // Guest entra quando o host começa (o state já foi aplicado).
      if (mounted && _players.isNotEmpty) {
        setState(() => _inMatch = true);
      }
    }

    final myUid = s.myUid ?? '§none§';
    if (!room.players.containsKey(myUid) &&
        s.inRoom &&
        _playMode == _PlayMode.online) {
      // Esta sessão foi removida pelo host (as outras continuam).
      _onSessionKicked(s);
    }
  }

  /// Entrada tardia no host: jogadores da sala que ainda não estão na
  /// mesa entram com vida cheia (respeita o máximo de 6). Fakes e quem
  /// já está não duplicam.
  void _absorbLateJoiners(_NetSession s, OnlineRoomInfo room) {
    if (_players.length >= OnlineMatch.defaultMaxPlayers) return;
    var added = false;
    for (final e in _sortedOnlinePlayers(s)) {
      if (_players.length >= OnlineMatch.defaultMaxPlayers) break;
      final name = (e.value['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final known = _players.any((p) =>
          (p.uid.isNotEmpty && p.uid == e.key) ||
          p.name.trim().toLowerCase() == name.toLowerCase());
      if (known) continue;
      _players.add(_MatchPlayer(
        name: name,
        life: _startLife,
        uid: e.key,
        theme: (e.value['theme'] ?? '').toString(),
        bg: (e.value['bg'] ?? '').toString(),
      ));
      _activity = ['$name entrou na partida', ..._activity].take(20).toList();
      added = true;
      if (mounted) {
        AppToast.show(context, '$name entrou na partida');
      }
    }
    if (added) {
      _active = _active.clamp(0, _players.length - 1);
      _broadcast();
    }
  }

  /// Aplica estado remoto ignorando repetição (eco entre sessões).
  void _applyRemoteState(Map<String, dynamic> state) {
    try {
      final j = jsonEncode(state);
      if (j == _lastRemoteStateJson) return;
      _lastRemoteStateJson = j;
    } catch (_) {}
    _applyState(state);
  }

  /// Realinha tema/fundo/uid de cada jogador da mesa com o nó
  /// players/<uid> da sala (fonte do visual no join). Só republica se
  /// algo realmente mudou — sem loop com o próprio publish.
  void _syncRosterVisuals(_NetSession s) {
    var changed = false;
    for (final p in _players) {
      Map<String, dynamic>? node;
      if (p.uid.isNotEmpty && s.players[p.uid] != null) {
        node = s.players[p.uid];
      } else {
        final key = p.name.trim().toLowerCase();
        if (key.isEmpty) continue;
        for (final e in s.players.entries) {
          if ((e.value['name'] ?? '').toString().trim().toLowerCase() ==
              key) {
            node = e.value;
            if (p.uid.isEmpty) {
              p.uid = e.key;
              changed = true;
            }
            break;
          }
        }
      }
      if (node == null) continue;
      final theme = (node['theme'] ?? '').toString();
      final bg = (node['bg'] ?? '').toString();
      final okTheme = theme.isEmpty || _tableStyles.containsKey(theme);
      final okBg = bg.isEmpty || tableBackgrounds.any((b) => b.id == bg);
      if (okTheme && p.theme != theme) {
        p.theme = theme;
        changed = true;
      }
      if (okBg && p.bg != bg) {
        p.bg = bg;
        changed = true;
      }
    }
    if (changed) {
      if (mounted) setState(() {});
      _broadcast();
    }
  }

  Future<void> _onSessionKicked(_NetSession s) async {
    await _teardownSession(s);
    if (!mounted) return;
    // Sem mais sessões e sem partida local válida: limpa a mesa.
    if (_firstInRoom == null && _inMatch && _isOnline) {
      setState(() => _inMatch = false);
      await _clearSavedMatch();
    }
    if (mounted) {
      AppToast.show(context, AppLocale.t('on_kicked'));
    }
  }

  void _onSessionAction(_NetSession s, Map<String, dynamic> action) {
    // Só a sessão com autoridade resolve ações.
    if (!s.hosting || !s.inRoom) return;

    final actionId = action['actionId']?.toString();
    final kind = action['action']?.toString() ?? '?';
    final fromUid = action['fromUid']?.toString() ?? '';
    if (actionId == null || actionId.isEmpty) {
      debugPrint('[Net] host ignora ação sem id ($kind)');
      return;
    }
    final myUid = s.myUid ?? '';
    if (fromUid.isNotEmpty && fromUid == myUid) {
      return; // eco próprio
    }
    debugPrint('[Net] host aplica $kind de $fromUid');
    _applyAction(action);

    s.net?.consumeAction(actionId);
  }

  void _broadcast() {
    _persistMatch();

    final state = _matchToJson();

    // LAN
    _host?.broadcast(state);

    // ONLINE: publica pela sessão com autoridade. O host ignora o
    // próprio eco (s.hosting) e guests duplicados caem no dedupe.
    if (_isOnline) {
      final host = _hostSession;
      if (host != null && host.net != null) {
        _publishOnlineState(host, state);
      }
    }

    // Presença LAN
    LanPresence.instance.setTable(
      open: _host != null,
      players: _players.length,
    );
  }

  Future<void> _publishOnlineState(
      _NetSession s, Map<String, dynamic> state) async {
    if (!_isOnline || !s.hosting || !s.inRoom || s.net == null) return;

    try {
      await s.net!.publishState(state);
    } catch (_) {
      // A UI continua usando o estado local mesmo se houver
      // uma falha momentânea de rede.
    }
  }

  void _send(Map<String, dynamic> action) {
    // LAN guest: direto no socket.
    if (_guest != null) {
      _guest?.send({'type': 'action', 'from': _myName, ...action});
      return;
    }

    // ONLINE guest: roteia pela sessão do jogador atuante.
    if (_isOnline) {
      _sendOnlineRouted(action);
    }
  }

  /// Dono da ficha com este id (para rotear a ação à sessão dele).
  String? _ownerOfToken(int? id) {
    if (id == null || id < 0) return null;
    for (final t in _tokens) {
      if (t.id == id) return t.owner;
    }
    return null;
  }

  /// Descobre de qual jogador é a ação pelo conteúdo do payload.
  String? _actionPlayer(Map<String, dynamic> action) {
    final kind = action['action']?.toString();
    switch (kind) {
      case 'life':
      case 'poison':
      case 'commander':
      case 'counter':
        final i = (action['player'] as num?)?.toInt();
        if (i != null && i >= 0 && i < _players.length) {
          return _players[i].name;
        }
        return null;
      case 'token_add':
        final tok = action['token'];
        if (tok is Map) return (tok['owner'] ?? '').toString();
        return null;
      case 'token_tap':
      case 'token_counter':
      case 'token_minus':
      case 'token_remove':
      case 'activate_utility':
        return _ownerOfToken((action['id'] as num?)?.toInt());
      case 'token_set':
        return _ownerOfToken((action['id'] as num?)?.toInt());
      case 'mana_add':
        return (action['player'] ?? '').toString();
      case 'visual':
        // Visual da mesa de um jogador: roteia pela sessão dele.
        return (action['player'] ?? '').toString();
      case 'effect_add':
        final eff = action['effect'];
        if (eff is Map) {
          final target = (eff['targetId'] as num?)?.toInt() ?? -1;
          return _ownerOfToken(target);
        }
        return null;
      case 'effect_remove':
        for (final e in _effects) {
          if (e.id == (action['id'] as num?)?.toInt()) {
            return _ownerOfToken(e.targetId);
          }
        }
        return null;
      case 'marker_add':
      case 'marker_set':
      case 'marker_remove':
        // Marcador é da mesa: roteia pela sessão do dono declarado.
        return (action['player'] ?? '').toString();
      case 'next_turn':
        if (_players.isEmpty) return null;
        return _players[_active.clamp(0, _players.length - 1)].name;
      case 'undo':
      case 'reset':
      case 'announce':
        return _myName;
      default:
        return null;
    }
  }

  /// Sessões guest em sala (para roteamento), na ordem dos slots.
  List<_NetSession> _guestSessions() => [
        for (final s in _sessions.values)
          if (s.inRoom && !s.hosting) s
      ];

  /// Escolhe por qual sessão a ação de guest sai: a do jogador atuante;
  /// se não houver, a primeira guest; se não houver, a primeira em sala.
  _NetSession? _routeSession(Map<String, dynamic> action) {
    final player = _actionPlayer(action)?.trim().toLowerCase();
    if (player != null && player.isNotEmpty) {
      for (final s in _sessions.values) {
        if (s.inRoom &&
            !s.hosting &&
            s.displayName.trim().toLowerCase() == player) {
          return s;
        }
      }
    }
    final guests = _guestSessions();
    if (guests.isNotEmpty) return guests.first;
    return _firstInRoom;
  }

  Future<void> _sendOnlineAction(
      _NetSession s, Map<String, dynamic> action) async {
    if (s.net == null || !s.inRoom) {
      if (mounted) {
        AppToast.show(context, AppLocale.t('on_fail_offline'));
      }
      return;
    }
    try {
      debugPrint(
          '[Net] envia ${action['action']} via ${s.slot} (${s.roomCode})');
      await s.net!.sendAction({...action, 'from': s.displayName});
    } catch (e) {
      debugPrint('[Net] FALHA ao enviar ${action['action']}: $e');
      if (mounted) {
        AppToast.show(
            context, AppLocale.t('on_fail').replaceAll('{e}', '$e'));
      }
    }
  }

  void _sendOnlineRouted(Map<String, dynamic> action) {
    final target = _routeSession(action);
    if (target == null) {
      if (mounted) {
        AppToast.show(context, AppLocale.t('on_fail_offline'));
      }
      return;
    }
    _sendOnlineAction(target, action);
  }

  Future<void> _startHosting() async {
    final host = LanHost();
    try {
      final ip = await host.start();
      final ips = await LanMatch.allIps();
      host.onMessage = _onGuestMessage;
      host.onPeers = (n) {
        if (mounted) setState(() => _peers = n);
      };
      setState(() {
        _host = host;
        _hostIps = ips.isEmpty ? [ip] : ips;
        _hostIpIdx = _hostIps.indexOf(ip);
        if (_hostIpIdx < 0) _hostIpIdx = 0;
        _hostIp = _hostIps[_hostIpIdx];
        _hosting = true;
        _peers = 0;
      });
      final hostName = (await AppDatabase.instance.activeProfileName()).trim();
      if (!mounted) return;
      setState(() {
        _myName = hostName.isEmpty ? AppLocale.t('su_host_name') : hostName;
        _lanHostName = _myName;
        _players = [
          _MatchPlayer(
              name: _myName,
              life: _startLife,
              theme: _tableTheme,
              bg: _myTableBg)
        ];
        _tokens = [];
        _effects = [];
        _markers = [];
        _mana.clear();
        _activity = ['Mesa criada por $_myName'];
        _history.clear();
        _round = 1;
        _active = 0;
        _inMatch = true;
      });
      _broadcast();
      if (mounted) {
        AppToast.show(context, 'Mesa aberta. Aguardando jogadores em $_hostIp');
      }
    } catch (e) {
      await host.stop();
      if (mounted) {
        AppToast.show(context, 'Falha ao hospedar: $e');
      }
    }
  }

  /// Expulsa jogador da mesa (só host): desconecta o aparelho,
  /// remove o jogador e solta as fichas dele na mesa.
  Future<void> _kickPlayer(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(AppLocale.t('su_remove_title').replaceAll('{n}', name)),
        content: Text(AppLocale.t('su_remove_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(AppLocale.t('token_remove'))),
        ],
      ),
    );
    if (ok != true) return;
    _host?.kick(name);
    final host = _hostSession;
    if (host != null && !_fakePlayers.contains(name)) {
      // Online: remove o UID da sala (fakes saem só do estado local).
      // Nunca remove o próprio UID do host.
      final uid = _onlineUidOf(host, name);
      if (uid != null && uid != host.myUid) {
        try {
          await host.net!.kick(uid);
        } catch (e) {
          if (mounted) {
            AppToast.show(
                context, AppLocale.t('on_fail').replaceAll('{e}', '$e'));
          }
          return;
        }
      }
    }
    setState(() {
      _fakePlayers.remove(name);
      _players.removeWhere((p) => p.name == name);
      for (final t in _tokens) {
        if (t.owner == name) {
          t.owner = '';
          t.ownerUid = '';
        }
      }
      if (_players.isEmpty) {
        _inMatch = false;
      } else {
        _active = _active.clamp(0, _players.length - 1);
      }
    });
    _broadcast();
  }

  Future<void> _stopHosting() async {
    await _host?.stop();
    setState(() {
      _host = null;
      _hosting = false;
      _hostIp = '';
      _peers = 0;
    });
    LanPresence.instance.setTable(open: false);
  }

  void _onGuestMessage(Map<String, dynamic> msg) {
    if (msg['type'] == 'hello') {
      final name = (msg['name'] ?? AppLocale.t('su_guest')).toString().trim();
      if (name.isEmpty) return;
      final theme = (msg['theme'] ?? '').toString();
      final bg = (msg['bg'] ?? '').toString();
      final exists = _players.any((p) => p.name == name);
      if (!exists && _players.length < 6) {
        _recordHistory('$name entrou na mesa');
        setState(() => _players.add(_MatchPlayer(
              name: name,
              life: _startLife,
              theme: _tableStyles.containsKey(theme) ? theme : '',
              bg: tableBackgrounds.any((b) => b.id == bg) ? bg : '',
            )));
        AppToast.show(context, '$name entrou na mesa');
      } else if (exists) {
        // Reconexão: atualiza o visual (tema/fundo) que ele mandou —
        // senão o bg dos outros nunca aparece para ninguém.
        setState(() {
          for (final p in _players) {
            if (p.name != name) continue;
            if (_tableStyles.containsKey(theme)) p.theme = theme;
            if (bg.isEmpty || tableBackgrounds.any((b) => b.id == bg)) {
              p.bg = bg;
            }
          }
        });
      } else if (!exists) {
        AppToast.show(context, 'A mesa já está cheia (máximo de 6).');
      }
      _broadcast();
      return;
    }
    if (msg['type'] == 'action') {
      // Online: passar turno só vale de quem é o turno.
      if (msg['action'] == 'next_turn' && _peers > 0) {
        final from = (msg['from'] ?? '').toString();
        final activeName = _players.isEmpty
            ? ''
            : _players[_active.clamp(0, _players.length - 1)].name;
        if (from.isNotEmpty && from != activeName) {
          return; // ignora: não é a vez dele
        }
      }
      _applyAction(msg);
    }
  }

  /// Aplica ação vinda do guest (host retransmite depois).
  void _applyAction(Map<String, dynamic> a) {
    final kind = a['action']?.toString() ?? '';
    if (kind == 'undo') {
      _undo();
      return;
    }
    if (kind != 'announce' && kind.isNotEmpty) {
      _recordHistory(_actionLabel(kind, a));
    }
    int idx(int? v, int max) => (v ?? -1) >= 0 && (v ?? -1) < max ? v! : -1;
    switch (kind) {
      case 'life':
        final i = idx((a['player'] as num?)?.toInt(), _players.length);
        if (i >= 0) {
          setState(
              () => _players[i].life += (a['delta'] as num?)?.toInt() ?? 0);
        }
        break;
      case 'poison':
        final i = idx((a['player'] as num?)?.toInt(), _players.length);
        if (i >= 0) {
          setState(() => _players[i].poison =
              (_players[i].poison + ((a['delta'] as num?)?.toInt() ?? 0))
                  .clamp(0, 99));
        }
        break;
      case 'commander':
        final i = idx((a['player'] as num?)?.toInt(), _players.length);
        final src = (a['from'] ?? '?').toString().trim();
        if (i >= 0 && src.isNotEmpty) {
          setState(() {
            final cur = _players[i].commander[src] ?? 0;
            _players[i].commander[src] =
                (cur + ((a['delta'] as num?)?.toInt() ?? 0)).clamp(0, 99);
          });
        }
        break;
      case 'counter':
        final i = idx((a['player'] as num?)?.toInt(), _players.length);
        final key = (a['key'] ?? '').toString().trim();
        if (i >= 0 && key.isNotEmpty) {
          setState(() {
            _players[i].counters[key] =
                ((_players[i].counters[key] ?? 0) +
                        ((a['delta'] as num?)?.toInt() ?? 0))
                    .clamp(-99, 99);
          });
        }
        break;
      case 'token_add':
        final m = a['token'];
        if (m is Map) {
          final t = _Token.fromJson(Map<String, dynamic>.from(m));
          t.id = _tokenSeq++;
          // Dono pela identidade: UID do nome na sala (online) ou ''.
          // Nunca herdado do perfil ativo — trocar de perfil não muda dono.
          if (_isOnline) {
            t.ownerUid = _uidOfName(t.owner);
          }
          // Herança no host também: guest pode ter estado desatualizado;
          // se veio sem arte, usa a arte já escolhida para esse nome
          // (vale para os dois players).
          if (t.art.isEmpty) {
            final known = _artForName(t.name);
            if (known.isNotEmpty) t.art = known;
          }
          setState(() => _tokens.add(t));
        }
        break;
      case 'token_remove':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        setState(() => _tokens.removeWhere((t) => t.id == id));
        break;
      case 'token_tap':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        setState(() {
          for (final t in _tokens) {
            if (t.id == id) t.tapped = (a['tapped'] as bool?) ?? !t.tapped;
          }
        });
        break;
      case 'token_counter':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        final d = (a['delta'] as num?)?.toInt() ?? 0;
        setState(() {
          for (final t in _tokens) {
            if (t.id == id) {
              t.counters = (t.counters + d).clamp(0, 99);
              _cancelOpposing(t);
            }
          }
        });
        break;
      case 'token_minus':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        final d = (a['delta'] as num?)?.toInt() ?? 0;
        setState(() {
          for (final t in _tokens) {
            if (t.id == id) {
              t.minus = (t.minus + d).clamp(0, 99);
              _cancelOpposing(t);
            }
          }
        });
        break;
      case 'token_set':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        setState(() {
          for (final t in _tokens) {
            if (t.id == id) {
              if (a['name'] != null) {
                t.name = a['name'].toString();
              }
              if (a['power'] != null) {
                t.power = (a['power'] as num).toInt();
              }
              if (a['toughness'] != null) {
                t.toughness = (a['toughness'] as num).toInt();
              }
              if (a['owner'] != null) {
                t.owner = a['owner'].toString();
                // Dono mudou: recalcula o UID (online) em vez de herdar.
                if (_isOnline) {
                  t.ownerUid = _uidOfName(t.owner);
                }
              }
              if (a['description'] != null) {
                t.description = a['description'].toString();
              }
              if (a['art'] != null) {
                t.art = a['art'].toString();
              }
              if (a['loyalty'] != null) {
                t.loyalty = ((a['loyalty'] as num).toInt()).clamp(0, 99);
              }
              if (a['charge'] != null) {
                t.charge = ((a['charge'] as num).toInt()).clamp(0, 99);
              }
              if (a['minus'] != null) {
                t.minus = ((a['minus'] as num).toInt()).clamp(0, 99);
                _cancelOpposing(t);
              }
              if (a['marks'] is List) {
                t.marks = _Token._marksFrom(a['marks']);
              }
              if (a['cost'] != null) {
                t.cost = a['cost'].toString();
              }
              if (a['type'] != null) {
                t.type = a['type'].toString();
              }
              if (a['keywords'] is List) {
                t.keywords = _Token._keywordsFrom(a['keywords']);
              }
              if (a['hideName'] != null) {
                t.hideName = (a['hideName'] as bool?) ?? false;
              }
            }
          }
        });
        break;
      case 'effect_add':
        final m = a['effect'];
        if (m is Map) {
          final e = _TokenEffect.fromJson(Map<String, dynamic>.from(m));
          e.id = _effectSeq++;
          setState(() => _effects.add(e));
        }
        break;
      case 'effect_remove':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        setState(() => _effects.removeWhere((e) => e.id == id));
        break;
      case 'marker_add':
        final m = a['marker'];
        if (m is Map) {
          final mk = _Marker.fromJson(Map<String, dynamic>.from(m));
          mk.id = _markerSeq++;
          // Membros que não existem mais (ficha removida) caem fora.
          mk.memberIds =
              mk.memberIds.where((id) => _tokens.any((t) => t.id == id)).toList();
          setState(() => _markers.add(mk));
        }
        break;
      case 'marker_set':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        setState(() {
          for (final mk in _markers) {
            if (mk.id != id) continue;
            if (a['label'] != null) {
              final label = a['label'].toString().trim();
              if (label.isNotEmpty) mk.label = label;
            }
            if (a['count'] != null) {
              mk.count = ((a['count'] as num).toInt()).clamp(-99, 99);
            }
            if (a['memberIds'] is List) {
              mk.memberIds = [
                for (final e in (a['memberIds'] as List))
                  (e as num?)?.toInt() ?? -1
              ]
                  .where((mid) =>
                      mid >= 0 && _tokens.any((t) => t.id == mid))
                  .toList();
            }
          }
          // Faxina geral: sem ficha, sem vínculo.
          for (final mk in _markers) {
            mk.memberIds =
                mk.memberIds.where((mid) => _tokens.any((t) => t.id == mid)).toList();
          }
        });
        break;
      case 'marker_remove':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        setState(() => _markers.removeWhere((mk) => mk.id == id));
        break;
      case 'mana_add':
        _addManaRaw((a['player'] ?? '').toString(),
            (a['color'] ?? 'C').toString(), (a['delta'] as num?)?.toInt() ?? 0);
        setState(() {});
        break;
      case 'mana_clear':
        setState(() => _mana.clear());
        break;
      case 'visual':
        // Troca o visual (tema/fundo) da mesa de UM jogador. O alvo é o
        // remetente: online resolve pelo fromUid, LAN pelo nome (from).
        // Valores fora do catálogo são ignorados — nunca quebram a mesa.
        final theme = (a['theme'] ?? '').toString();
        final bg = (a['bg'] ?? '').toString();
        if (!_tableStyles.containsKey(theme) && theme.isNotEmpty) break;
        if (bg.isNotEmpty &&
            !tableBackgrounds.any((b) => b.id == bg)) break;
        final fromUid = (a['fromUid'] ?? '').toString();
        final fromName = (a['from'] ?? a['player'] ?? '').toString();
        _MatchPlayer? target;
        for (final p in _players) {
          if (fromUid.isNotEmpty && p.uid.isNotEmpty && p.uid == fromUid) {
            target = p;
            break;
          }
        }
        target ??= (() {
          final key = fromName.trim().toLowerCase();
          if (key.isEmpty) return null;
          for (final p in _players) {
            if (p.name.trim().toLowerCase() == key) return p;
          }
          return null;
        })();
        final resolved = target;
        if (resolved != null) {
          setState(() {
            resolved.theme = theme;
            resolved.bg = bg;
          });
        }
        break;
      case 'activate_utility':
        final id = (a['id'] as num?)?.toInt() ?? -1;
        _Token? found;
        for (final t in _tokens) {
          if (t.id == id) found = t;
        }
        if (found != null) {
          _resolveUtility(found, color: a['color']?.toString());
        }
        break;
      case 'next_turn':
        _doNextTurn(broadcast: false);
        break;
      case 'announce':
        final text = (a['text'] ?? '').toString();
        if (text.isNotEmpty) {
          if (mounted) AppToast.show(context, text);
          _host?.flash(text);
        }
        break;
      case 'reset':
        _doReset(broadcast: false);
        break;
    }
    // Mortes causadas pelo guest também anunciam (antes só a autoridade
    // local checava: veneno/comandante do oponente passavam batidos).
    _checkDeaths();
    _broadcast();
  }

  String _actionLabel(String kind, Map<String, dynamic> action) {
    final delta = (action['delta'] as num?)?.toInt() ?? 0;
    switch (kind) {
      case 'life':
        return 'Vida ${delta >= 0 ? '+' : ''}$delta';
      case 'poison':
        return 'Veneno ${delta >= 0 ? '+' : ''}$delta';
      case 'commander':
        return 'Dano de comandante ${delta >= 0 ? '+' : ''}$delta';
      case 'counter':
        return 'Marcador de jogador';
      case 'token_add':
        return 'Adicionou ficha';
      case 'token_remove':
        return 'Removeu ficha';
      case 'token_tap':
        return 'Virou/desvirou ficha';
      case 'token_counter':
        return 'Alterou marcador';
      case 'mana_add':
        return 'Alterou mana';
      case 'activate_utility':
        return 'Resolveu ficha';
      case 'next_turn':
        return 'Passou o turno';
      case 'marker_add':
        return 'Criou marcador';
      case 'marker_set':
        return 'Ajustou marcador';
      case 'marker_remove':
        return 'Removeu marcador';
      case 'visual':
        return 'Trocou o visual da mesa';
      case 'reset':
        return 'Reiniciou marcadores';
      default:
        return 'Alterou a mesa';
    }
  }

  /// Reabre a mesa como host SEM apagar a partida atual.
  /// Usado quando o app reiniciou ou a rede caiu: os guests reconectam
  /// pelo mesmo IP e o hello com nome já existente não duplica jogador.
  Future<void> _rehostMatch() async {
    final host = LanHost();
    setState(() => _joining = true);
    try {
      final ip = await host.start();
      final ips = await LanMatch.allIps();
      host.onMessage = _onGuestMessage;
      host.onPeers = (n) {
        if (mounted) setState(() => _peers = n);
      };
      if (!mounted) return;
      setState(() {
        _host = host;
        _hostIps = ips.isEmpty ? [ip] : ips;
        _hostIpIdx = _hostIps.indexOf(ip);
        if (_hostIpIdx < 0) _hostIpIdx = 0;
        _hostIp = _hostIps[_hostIpIdx];
        _hosting = true;
        _peers = 0;
        _joining = false;
        _playMode = _PlayMode.lan;
        if (_myName.trim().isNotEmpty) _lanHostName = _myName.trim();
        _inMatch = _players.isNotEmpty;
      });
      _broadcast();
      if (mounted) {
        AppToast.show(
            context, 'Mesa reaberta em $_hostIp. Peça p/ reconectarem.');
      }
    } catch (e) {
      await host.stop();
      if (mounted) {
        setState(() => _joining = false);
        AppToast.show(context, 'Falha ao reabrir mesa: $e');
      }
    }
  }

  /// Banner quando a rede caiu mas a partida salva existe:
  /// host reabre, guest reconecta com o IP salvo. Vale pros dois lados.
  /// O ✕ dispensa (só volta numa NOVA queda, com outro IP).
  Widget _reconnectBanner() {
    final savedIp = _joinIp.text.trim();
    if (savedIp.isNotEmpty &&
        _dismissedReconnect == 'lan:$savedIp') {
      return const SizedBox.shrink();
    }
    final amHost = _amLanHost ||
        (_lanHostName.isEmpty && _hostIps.isNotEmpty) ||
        (_myName.trim().isNotEmpty &&
            _players.isNotEmpty &&
            _players.first.name == _myName.trim());
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Card(
        color: const Color(0xFF2A2118),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.gold),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.wifi_off, color: AppTheme.gold, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      AppLocale.t('lan_lost'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: MaterialLocalizations.of(context)
                        .closeButtonTooltip,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                    onPressed: () => setState(() =>
                        _dismissedReconnect = 'lan:$savedIp'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                amHost
                    ? 'Você é o anfitrião. Reabra a mesa e peça para o outro reconectar.'
                    : savedIp.isEmpty
                        ? 'Digite o IP do anfitrião para reconectar.'
                        : 'Toque para reconectar em $savedIp.',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (amHost)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _joining ? null : _rehostMatch,
                        icon: const Icon(Icons.router, size: 16),
                        label: Text(AppLocale.t('lan_reopen')),
                      ),
                    )
                  else
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _joining ? null : _joinMatch,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: Text(AppLocale.t('lan_reconnect')),
                      ),
                    ),
                  const SizedBox(width: 8),
                  if (!amHost)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _editReconnectIp(),
                        icon: const Icon(Icons.edit, size: 16),
                        label: Text(AppLocale.t('lan_change_ip')),
                      ),
                    )
                  else
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _editReconnectIp(joinAfter: true),
                        icon: const Icon(Icons.login, size: 16),
                        label: Text(AppLocale.t('lan_change_ip')),
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

  /// Faixa online no topo da mesa: discreta (`● N online` + ⓘ).
  /// Detalhes (sala, identidade, perfil) ficam no painel de conexão.
  /// Quando a AppBar está visível, ela mesma mostra ponto + ⓘ —
  /// a faixa só aparece sem topbar (foco/imersão).
  /// (O antigo cartão "sala salva + Reconectar" foi removido: ele lia
  /// a sala ATIVA como se fosse perdida e aparecia até recém-criada.
  /// Órfã de verdade — app morto, mesa restaurada sem sessão — já cai
  /// no setup com o código preenchido + botão Reconectar.)
  Widget _onlineNotice() {
    final inRooms = [
      for (final s in _sessions.values)
        if (s.inRoom) s
    ];
    if (inRooms.isEmpty || !_noTopBar) {
      return const SizedBox.shrink();
    }
    final total = _onlineTotal(inRooms);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _sessionMismatch ? AppTheme.gold : Colors.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text('$total ${AppLocale.t('on_connected_n')}',
              style:
                  const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.info_outline,
                size: 18, color: AppTheme.textMuted),
            tooltip: AppLocale.t('on_conn_title'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: _connectionSheet,
          ),
        ],
      ),
    );
  }

  /// UIDs únicos conectados nas salas (para o `● N online`).
  int _onlineTotal([List<_NetSession>? rooms]) {
    final inRooms = rooms ??
        [
          for (final s in _sessions.values)
            if (s.inRoom) s
        ];
    return {
      for (final s in inRooms)
        for (final uid in s.players.keys)
          if ((s.players[uid]!['connected'] as bool?) ?? true) uid
    }.length;
  }

  int _connectedCount(_NetSession s) =>
      s.players.values.where((p) => (p['connected'] as bool?) ?? true).length;

  /// Painel de conexão (ⓘ): por sessão, sala, identidade, perfil atual,
  /// rede e jogadores — sem poluir a mesa.
  Future<void> _connectionSheet() async {
    final sessions = _activeSessions;
    if (sessions.isEmpty) return;
    final profile = _profileName.trim();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(AppLocale.t('on_conn_title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              for (var i = 0; i < sessions.length; i++) ...[
                if (i > 0) const Divider(height: 16),
                _connectionSection(sessions[i], i + 1, profile),
              ],
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectionSection(_NetSession s, int n, String profile) {
    final names = [
      for (final e in _sortedOnlinePlayers(s))
        (e.value['name'] ?? '?').toString()
    ];
    final mismatch = profile.isNotEmpty &&
        s.displayName.trim().isNotEmpty &&
        s.displayName.trim().toLowerCase() != profile.toLowerCase();
    Widget row(String label, String value, {bool gold = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: Text(label,
                  style: const TextStyle(color: AppTheme.textMuted)),
            ),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: gold ? AppTheme.gold : AppTheme.text)),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(AppLocale.t('on_session_n').replaceAll('{n}', '$n'),
              style: const TextStyle(
                  color: AppTheme.gold,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: s.roomCode));
                  AppToast.show(context,
                      AppLocale.t('prof_copied').replaceAll('{c}', s.roomCode));
                },
                child: Text('${AppLocale.t('on_conn_room')}: ${s.roomCode}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 20)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        row(AppLocale.t('on_conn_as'), s.displayName, gold: mismatch),
        row(AppLocale.t('on_conn_profile'), profile.isEmpty ? '—' : profile,
            gold: mismatch),
        row(AppLocale.t('on_conn_net'), 'Online'),
        row(
            AppLocale.t('on_conn_players'),
            names.isEmpty
                ? '—'
                : '${_connectedCount(s)} • ${names.join(', ')}'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                final go = await _confirmLeaveMatch(session: s);
                if (go != true || !mounted) return;
                _leaveSession(s);
              },
              icon: const Icon(Icons.logout, size: 16),
              label: Text(AppLocale.t('on_leave')),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editReconnectIp({bool joinAfter = false}) async {
    final ctrl = TextEditingController(text: _joinIp.text.trim());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(AppLocale.t('su_ip_title')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.text,
          decoration: InputDecoration(
            hintText: AppLocale.t('su_ip_hint'),
            prefixIcon: const Icon(Icons.wifi),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('common_save'))),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _joinIp.text = ctrl.text.trim());
      _persistMatch();
      if (joinAfter && mounted && _joinIp.text.trim().isNotEmpty) {
        await _joinMatch();
      }
    }
    _laterDispose(ctrl);
  }

  Future<void> _joinMatch() async {
    final ip = _joinIp.text.trim();
    if (ip.isEmpty) {
      AppToast.show(context, 'Digite o IP do anfitrião.');
      return;
    }
    final guest = LanGuest();
    setState(() => _joining = true);
    try {
      guest.onState = (m) {
        _applyState(m);
        // Guest também persiste: se sair sem querer, restaura offline
        // e o banner oferece reconectar.
        _persistMatch();
      };
      guest.onFlash = (text) {
        if (mounted && text.isNotEmpty) {
          AppToast.show(context, text);
        }
      };
      guest.onDisconnect = () {
        // Queda de rede NÃO apaga a partida: mantém o estado
        // e o banner de reconexão aparece (vale pros dois players).
        if (!mounted) return;
        final wasGuest = _guest != null;
        setState(() {
          _guest = null;
          _joining = false;
        });
        _persistMatch();
        if (wasGuest && mounted) {
          AppToast.show(context, 'Conexão perdida. Toque em Reconectar.');
        }
      };
      final profileName =
          (await AppDatabase.instance.activeProfileName()).trim();
      // Reusa o mesmo nome da partida para o host reconhecer
      // como jogador existente (não duplica).
      final myName = profileName.isNotEmpty
          ? profileName
          : (_myName.trim().isNotEmpty
              ? _myName.trim()
              : AppLocale.t('su_guest'));
      await guest.connect(ip, myName,
          theme: _tableTheme, bg: _myTableBg);
      setState(() {
        _guest = guest;
        _joining = false;
        _myName = myName;
        _playMode = _PlayMode.lan;
      });
      _persistMatch();
      if (mounted) {
        AppToast.show(context, 'Conectado! Aguardando a partida.');
      }
    } catch (e) {
      await guest.disconnect();
      if (mounted) {
        setState(() => _joining = false);
        AppToast.show(context, 'Falha ao entrar: $e');
      }
    }
  }

  Future<void> _leaveMatch() async {
    if (_isOnline) {
      // Encerra TODAS as sessões (host apaga a própria sala).
      for (final s in _sessions.values.toList()) {
        await _teardownSession(s, deleteIfHost: true);
      }
      _sessions.clear();

      if (mounted) {
        setState(() {
          _peers = 0;
          _inMatch = false;
        });
        // Sessões encerradas: volta a usar o nome do perfil atual.
        AppDatabase.instance.activeProfileName().then((n) {
          if (!mounted) return;
          final name = n.trim();
          if (name.isNotEmpty) setState(() => _myName = name);
        });
      }

      await _clearSavedMatch();
      await _persistSessions();
      return;
    }

    await _guest?.disconnect();

    if (mounted) {
      setState(() {
        _guest = null;
        _inMatch = false;
      });
    }

    await _clearSavedMatch();
  }

  List<MapEntry<String, Map<String, dynamic>>> _sortedOnlinePlayers(
      _NetSession s) {
    final list = s.players.entries.toList();
    list.sort((a, b) {
      final ja = (a.value['joinedAt'] as num?)?.toInt() ?? 0;
      final jb = (b.value['joinedAt'] as num?)?.toInt() ?? 0;
      return ja.compareTo(jb);
    });
    return list;
  }

  String? _onlineUidOf(_NetSession s, String playerName) {
    for (final e in s.players.entries) {
      if ((e.value['name'] ?? '').toString() == playerName) return e.key;
    }
    return null;
  }

  Map<String, dynamic> _freshOnlineState(String hostName, String code) => {
        'playMode': _PlayMode.online.name,
        'lanHostName': '',
        'lanHostIp': '',
        'onlineRoom': code,
        'tableTheme': _tableTheme,
        'format': _format,
        'startLife': _startLife,
        'round': 1,
        'active': 0,
        'players': [
          {
            'name': hostName,
            'life': _startLife,
            'poison': 0,
            'uid': '',
            'theme': _tableTheme,
            'bg': _myTableBg,
          }
        ],
        'tokens': [],
        'effects': [],
        'markers': [],
        'mana': {},
        'activity': ['Mesa criada por $hostName'],
      };

  /// Encerra só esta sessão (as outras continuam). Usado no kick, no
  /// "sair da sessão" e quando o host remove este UID. Com
  /// [deleteIfHost], o host apaga a sala junto na mesma chamada
  /// (depois do leave o roomId já se foi e não dá mais para apagar).
  Future<void> _teardownSession(_NetSession s,
      {bool deleteIfHost = false}) async {
    try {
      await s.net?.setConnected(false);
    } catch (_) {}
    try {
      await s.net?.leaveRoom(deleteIfHost: deleteIfHost && s.hosting);
    } catch (_) {}
    await s.roomSub?.cancel();
    await s.actionSub?.cancel();
    s.roomSub = null;
    s.actionSub = null;
    _sessions.remove(s.slot);
    if (!mounted) return;
    setState(() {});
    await _persistSessions();
  }

  Future<void> _persistSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'online_sessions',
          jsonEncode([
            for (final s in _sessions.values)
              if (s.inRoom) s.toJson()
          ]));
    } catch (_) {}
    _persistMatch();
    _refreshPresenceRoom();
  }

  /// Host cria a sala online (código curto). Fica na espera até começar.
  /// [slot] 'a' usa o app Firebase padrão; 'b' o secundário (outro UID).
  Future<void> _createOnlineRoom({String slot = 'a'}) async {
    if (_host != null || _guest != null || _inMatch) {
      AppToast.show(context, AppLocale.t('su_leave_first'));
      return;
    }
    if (_sessions.values.any((s) => s.inRoom)) {
      AppToast.show(context, AppLocale.t('on_one_room'));
      return;
    }
    final s = _session(slot);
    if (s.joining) return;
    setState(() => s.joining = true);
    try {
      final net = await _netFor(s);
      final hostName = (await AppDatabase.instance.activeProfileName()).trim();
      final me = hostName.isEmpty ? AppLocale.t('su_host_name') : hostName;
      final info = await net.createRoom(
        playerName: me,
        format: _format,
        startLife: _startLife,
        tableTheme: _tableTheme,
        playerTheme: _tableTheme,
        playerBg: _myTableBg,
        initialState: _freshOnlineState(me, ''),
      );
      if (!mounted) return;
      setState(() {
        _playMode = _PlayMode.online;
        s.hosting = true;
        s.started = false;
        s.displayName = me;
        s.profileId = _profileId;
        s.roomCode = info.roomId;
        _myName = me;
        _profileName = me;
        _joinCodeCtrl.text = info.roomId;
        _players = [
          _MatchPlayer(
              name: me,
              life: _startLife,
              uid: s.myUid ?? '',
              theme: _tableTheme,
              bg: _myTableBg)
        ];
        _tokens = [];
        _effects = [];
        _markers = [];
        _mana.clear();
        _round = 1;
        _active = 0;
        _activity = ['Mesa criada por $me'];
        _history.clear();
        _inMatch = false;
      });
      _listenSession(s);
      // Publica o código na sala recém-criada.
      _lastRemoteStateJson = '';
      _broadcast();
      await _persistSessions();
      if (mounted) {
        AppToast.show(
            context, AppLocale.t('on_created').replaceAll('{c}', info.roomId));
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, AppLocale.t('on_fail').replaceAll('{e}', '$e'));
      }
    } finally {
      if (mounted) setState(() => s.joining = false);
    }
  }

  /// Guest entra com o código da sala. Aguarda o host começar.
  /// Numa segunda sessão, entra com outro UID/perfil na MESMA sala.
  Future<void> _joinOnlineRoom({String? slot, String? codeOverride}) async {
    final code = (codeOverride ?? _joinCodeCtrl.text).trim().toUpperCase();
    if (code.isEmpty) {
      AppToast.show(context, AppLocale.t('on_code_hint'));
      return;
    }
    if (_host != null || _guest != null) {
      AppToast.show(context, AppLocale.t('su_leave_first'));
      return;
    }
    // Sala diferente com partida rolando ou outra sala ativa: bloqueia.
    final otherCode = _sessions.values
        .where((s) => s.inRoom)
        .map((s) => s.roomCode)
        .firstOrNull;
    if (_inMatch && (otherCode == null || otherCode != code)) {
      AppToast.show(context, AppLocale.t('su_leave_first'));
      return;
    }
    if (otherCode != null && otherCode != code) {
      AppToast.show(context, AppLocale.t('on_other_room'));
      return;
    }
    var useSlot = slot ?? '';
    if (useSlot.isEmpty) useSlot = _freeSlot();
    if (useSlot.isEmpty) {
      AppToast.show(context, AppLocale.t('on_max_sessions'));
      return;
    }
    final s = _session(useSlot);
    if (s.inRoom || s.joining) return;
    // Mesmo perfil já conectado em outra sessão? Reutiliza ela.
    final myId = await _currentProfileId();
    if (!mounted) return;
    for (final o in _sessions.values) {
      if (o != s && o.inRoom && o.profileId.isNotEmpty && o.profileId == myId) {
        AppToast.show(context, AppLocale.t('on_same_profile'));
        return;
      }
    }
    setState(() => s.joining = true);
    try {
      final net = await _netFor(s);
      final profile = (await AppDatabase.instance.activeProfileName()).trim();
      final me = profile.isEmpty ? AppLocale.t('su_guest') : profile;
      final info = await net.joinRoom(
          roomCode: code,
          playerName: me,
          playerTheme: _tableTheme,
          playerBg: _myTableBg);
      if (!mounted) return;
      setState(() {
        _playMode = _PlayMode.online;
        s.hosting = false;
        s.started = info.isStarted;
        s.displayName = me;
        s.profileId = myId;
        s.roomCode = info.roomId;
        _myName = _myName.isEmpty ? me : _myName;
        _profileName = me;
        if (!info.isStarted) _inMatch = false;
      });
      _listenSession(s);
      await _persistSessions();
      if (mounted) {
        AppToast.show(
            context, AppLocale.t('on_joined').replaceAll('{c}', info.roomId));
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, AppLocale.t('on_fail').replaceAll('{e}', '$e'));
      }
    } finally {
      if (mounted) setState(() => s.joining = false);
    }
  }

  /// Host começa: monta os jogadores da sala e publica o estado oficial.
  Future<void> _startOnlineMatch(_NetSession s) async {
    if (!s.hosting || !s.inRoom || s.net == null) return;
    final entries = _sortedOnlinePlayers(s);
    // Solo liberado: dá para praticar/testar sozinho ou começar e
    // receber gente depois (late join). Zero jogadores continua fora.
    if (entries.isEmpty) {
      AppToast.show(context, AppLocale.t('on_need2'));
      return;
    }
    try {
      await s.net!.startRoom();
    } catch (e) {
      if (mounted) {
        AppToast.show(context, AppLocale.t('on_fail').replaceAll('{e}', '$e'));
      }
      return;
    }
    if (!mounted) return;
    final myName = _myName.trim().toLowerCase();
    final meIdx = entries.indexWhere((e) =>
        _localUids.contains(e.key) ||
        (e.value['name'] ?? '').toString().trim().toLowerCase() == myName);
    setState(() {
      _players = [
        for (final e in entries)
          _MatchPlayer(
              name: (e.value['name'] ?? '?').toString(),
              life: _startLife,
              uid: e.key,
              theme: (e.value['theme'] ?? '').toString(),
              bg: (e.value['bg'] ?? '').toString())
      ];
      _tokens = [];
      _effects = [];
      _mana.clear();
      _deadAnnounced.clear();
      _winsAnnounced.clear();
      _round = 1;
      _active = 0;
      _arenaSel = meIdx >= 0 ? meIdx : 0;
      _activity = ['Partida online iniciada'];
      _history.clear();
      _inMatch = true;
    });
    _broadcast();
  }

  /// Reconecta UMA sessão à sala salva (volta ao app, caiu a rede...).
  /// Host retoma a autoridade; guest volta a receber o estado.
  Future<void> _attachSession(String slot, String rawCode) async {
    final code = rawCode.trim().toUpperCase();
    if (code.isEmpty) {
      AppToast.show(context, AppLocale.t('on_code_hint'));
      return;
    }
    final s = _session(slot);
    if (s.inRoom) return;
    setState(() => s.joining = true);
    try {
      final net = await _netFor(s);
      final info = await net.attach(code);
      if (!mounted) return;
      final amHost = info.hostId.isNotEmpty && info.hostId == net.myUid;
      // Identidade da sessão vem do nó do meu UID (não do perfil atual):
      // o nome é só exibição, a sessão é o uid.
      final node = info.players[net.myUid];
      final sessionName =
          (node is Map ? (node['name'] ?? '').toString().trim() : '');
      setState(() {
        _playMode = _PlayMode.online;
        s.hosting = amHost;
        s.started = info.isStarted;
        s.roomCode = info.roomId;
        if (sessionName.isNotEmpty) {
          s.displayName = sessionName;
          if (_myName.isEmpty) _myName = sessionName;
        }
        if (amHost && info.state != null && info.state!['players'] is List) {
          _applyState(Map<String, dynamic>.from(info.state!));
        }
      });
      _listenSession(s);
      if (amHost && mounted && _inMatch) {
        // Retoma a autoridade republicando o estado atual.
        _broadcast();
      }
      await _persistSessions();
      if (mounted && !amHost && !info.isStarted) {
        AppToast.show(
            context, AppLocale.t('on_joined').replaceAll('{c}', info.roomId));
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(
            context, AppLocale.t('on_reconnect_fail').replaceAll('{e}', '$e'));
      }
    } finally {
      if (mounted) setState(() => s.joining = false);
    }
  }

  /// Restaura as sessões salvas sem toast nem barulho (abertura do app).
  Future<void> _restoreSessions() async {
    List<dynamic> saved = [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('online_sessions') ?? '[]';
      saved = List<dynamic>.from(jsonDecode(raw));
    } catch (_) {}
    for (final e in saved) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final slot = (m['slot'] ?? 'a').toString();
      final code = (m['code'] ?? '').toString().trim();
      if (code.isEmpty || _activeSessions.length >= _maxSessions) continue;
      if (_sessions.containsKey(slot)) continue;
      final s = _session(slot);
      try {
        final net = await _netFor(s);
        final info = await net.attach(code);
        if (!mounted) return;
        final amHost = info.hostId.isNotEmpty && info.hostId == net.myUid;
        final node = info.players[net.myUid];
        final sessionName =
            (node is Map ? (node['name'] ?? '').toString().trim() : '');
        setState(() {
          s.hosting = amHost;
          s.started = info.isStarted;
          s.roomCode = info.roomId;
          s.displayName = sessionName.isNotEmpty
              ? sessionName
              : (m['name'] ?? '').toString();
          s.profileId = (m['profileId'] ?? '').toString();
          _playMode = _PlayMode.online;
          if (_myName.isEmpty && s.displayName.isNotEmpty) {
            _myName = s.displayName;
          }
          if (amHost && info.state != null && info.state!['players'] is List) {
            _applyState(Map<String, dynamic>.from(info.state!));
          }
        });
        _listenSession(s);
      } catch (_) {
        _sessions.remove(slot);
      }
    }
    if (mounted && _sessions.isNotEmpty) setState(() {});
    await _persistSessions();
  }

  /// Sai de UMA sessão (as outras continuam). Host apaga a sala junto.
  Future<void> _leaveSession(_NetSession s) async {
    await _teardownSession(s, deleteIfHost: true);    if (!mounted) return;
    if (mounted) setState(() {});
    await _persistSessions();
  }

  /// Entrar na mesa de alguém da rede sem digitar IP.
  /// Adiciona um jogador fake (só host, só teste): simula o oponente
  /// sem precisar de 2º celular. Sai com o ✕ no cartão dele.
  void _addFakePlayer() {
    if (_host == null && !_isOnlineHost) return;
    var n = 1;
    while (_players.any((p) => p.name == 'Fake $n')) {
      n++;
    }
    final name = 'Fake $n';
    _recordHistory('$name entrou na mesa (teste)');
    setState(() {
      _players.add(_MatchPlayer(name: name, life: _startLife));
      _fakePlayers.add(name);
    });
    _broadcast();
    AppToast.show(context, '$name na mesa! Toque no ✕ dele para remover.');
  }

  Future<void> _joinPeer(LanPeer peer) async {
    if (_host != null || _guest != null || _joining) {
      AppToast.show(context, AppLocale.t('su_leave_first'));
      return;
    }
    setState(() => _joinIp.text = '${peer.ip}:${peer.port}');
    _persistMatch();
    await _joinMatch();
  }

  void _invitePeer(LanPeer peer) {
    LanPresence.instance.invite(peer.ip);
    AppToast.show(context, AppLocale.t('su_sent').replaceAll('{n}', peer.name));
  }

  /// Alguém da rede me convidou: diálogo para entrar na mesa dele.
  Future<void> _onLanInvite(String fromName, String tableIp) async {
    if (!mounted) return;
    if (_host != null || _guest != null || _inMatch) {
      AppToast.show(
          context, AppLocale.t('su_busy_invite').replaceAll('{n}', fromName));
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('su_invite_title').replaceAll('{n}', fromName)),
        content:
            Text(AppLocale.t('su_invite_body').replaceAll('{n}', fromName)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('lan_reconnect'))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _joinIp.text = '$tableIp:${LanMatch.port}');
    _persistMatch();
    await _joinMatch();
  }

  /// Lista de quem está na mesma rede (beacon UDP, sem servidor).
  Widget _peersSection() {
    return ValueListenableBuilder<List<LanPeer>>(
      valueListenable: LanPresence.instance.peers,
      builder: (_, peers, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.people, size: 16, color: AppTheme.gold),
              const SizedBox(width: 6),
              Text(AppLocale.t('su_nonet').replaceAll('{n}', '${peers.length}'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ],
          ),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(AppLocale.t('su_noone'),
                  style:
                      const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            )
          else
            for (final p in peers)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor:
                      p.hasTable ? Colors.green : AppTheme.goldSoft,
                  child: Text(p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                ),
                title:
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    p.hasTable
                        ? AppLocale.t('su_table_open')
                            .replaceAll('{n}', '${p.players}')
                        : AppLocale.t('su_notable'),
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12)),
                trailing: p.hasTable
                    ? TextButton(
                        onPressed: () => _joinPeer(p),
                        child: Text(AppLocale.t('su_join')),
                      )
                    : (_hosting
                        ? TextButton(
                            onPressed: () => _invitePeer(p),
                            child: Text(AppLocale.t('su_invite_btn')),
                          )
                        : null),
              ),
        ],
      ),
    );
  }

  // ================= PARTIDA =================

  void _startMatch() {
    final names = _nameCtrls.map((c) => c.text.trim()).toList();
    for (var i = 0; i < names.length; i++) {
      if (names[i].isEmpty) names[i] = '${AppLocale.t('su_player')} ${i + 1}';
    }
    // Mesa local limpa: derruba qualquer resto de rede (host/guest/
    // sessões de outro modo). Estado obsoleto travava o turno local
    // (_canPassTurn lia _host/_peers fantasmas).
    try {
      _host?.stop();
    } catch (_) {}
    _host = null;
    _hosting = false;
    try {
      _guest?.disconnect();
    } catch (_) {}
    _guest = null;
    for (final s in _sessions.values) {
      s.roomSub?.cancel();
      s.actionSub?.cancel();
    }
    _sessions.clear();
    _peers = 0;
    setState(() {
      _myName = names.first;
      _players = [
        for (var i = 0; i < names.length; i++)
          _MatchPlayer(
            name: names[i],
            life: _startLife,
            theme: i < _playerThemes.length ? _playerThemes[i] : '',
            bg: i < _playerBgs.length ? _playerBgs[i] : '',
          ),
      ];
      _tokens = [];
      _effects = [];
      _mana.clear();
      _deadAnnounced.clear();
      _winsAnnounced.clear();
      _round = 1;
      _active = 0;
      _arenaSel = 0;
      _inMatch = true;
      _activity = ['Partida local iniciada'];
      _history.clear();
    });
    _broadcast();
  }

  void _bumpLife(int i, int delta) {
    if (_isGuest) {
      _send({'action': 'life', 'player': i, 'delta': delta});
      return;
    }
    _recordHistory('${_players[i].name}: vida ${delta >= 0 ? '+' : ''}$delta');
    setState(() => _players[i].life += delta);
    _broadcast();
    _checkDeaths();
  }

  void _bumpPoison(int i, int delta) {
    if (_isGuest) {
      _send({'action': 'poison', 'player': i, 'delta': delta});
      return;
    }
    _recordHistory(
        '${_players[i].name}: veneno ${delta >= 0 ? '+' : ''}$delta');
    setState(() {
      _players[i].poison = (_players[i].poison + delta).clamp(0, 99);
    });
    _broadcast();
    _checkDeaths();
  }

  /// Dano de comandante: [from] é o NOME do comandante/dono que bateu
  /// (21+ do mesmo = morte, regra 704.5v). Vale em qualquer formato.
  void _bumpCommander(int i, String from, int delta) {
    if (i < 0 || i >= _players.length) return;
    final src = from.trim().isEmpty ? '?' : from.trim();
    if (_isGuest) {
      _send({'action': 'commander', 'player': i, 'from': src, 'delta': delta});
      return;
    }
    _recordHistory(
        '${_players[i].name}: comandante $src ${delta >= 0 ? '+' : ''}$delta');
    setState(() {
      final cur = _players[i].commander[src] ?? 0;
      _players[i].commander[src] = (cur + delta).clamp(0, 99);
    });
    _broadcast();
    _checkDeaths();
  }

  /// Contador extra do jogador (Energia, Experiência...). [delta] soma;
  /// zerar não apaga (o ✕ no menu remove).
  void _bumpPlayerCounter(int i, String key, int delta) {
    if (i < 0 || i >= _players.length) return;
    final k = key.trim();
    if (k.isEmpty) return;
    if (_isGuest) {
      _send({'action': 'counter', 'player': i, 'key': k, 'delta': delta});
      return;
    }
    _recordHistory(
        '${_players[i].name}: $k ${delta >= 0 ? '+' : ''}$delta');
    setState(() {
      _players[i].counters[k] = ((_players[i].counters[k] ?? 0) + delta)
          .clamp(-99, 99);
    });
    _broadcast();
  }

  void _removePlayerCounter(int i, String key) {
    if (i < 0 || i >= _players.length) return;
    final k = key.trim();
    if (k.isEmpty) return;
    if (_isGuest) {
      // Sem ação própria: zera por ajuste (o host aplica via 'counter').
      final cur = _players[i].counters[k] ?? 0;
      if (cur != 0) {
        _send({'action': 'counter', 'player': i, 'key': k, 'delta': -cur});
      }
      return;
    }
    _recordHistory('${_players[i].name}: removeu $k');
    setState(() => _players[i].counters.remove(k));
    _broadcast();
  }

  /// Online: só passa o turno quem é o turno — valendo para QUALQUER
  /// identidade local (UID primeiro, nome como fallback). Offline: livre.
  bool _canPassTurn() {
    if (!_inMatch || _players.isEmpty) return false;
    final online = _isGuest || _isOnlineHost || (_isHost && _peers > 0);
    if (!online) return true;
    final active = _players[_active.clamp(0, _players.length - 1)];
    if (active.name.trim().isEmpty) return false;
    if (!_isOnline) {
      return _myName.trim().isNotEmpty && active.name.trim() == _myName.trim();
    }
    return _isLocalIdentity(active.uid, active.name);
  }

  /// Dono padrão de ficha nova: eu (não o jogador ativo).
  /// Online com multi-sessão: prefere o jogador da vez se ele for
  /// controlado aqui (útil testando dois perfis no mesmo aparelho).
  String get _defaultOwner {
    if (_isOnline && _players.isNotEmpty) {
      final active =
          _players[_active.clamp(0, _players.length - 1)].name.trim();
      if (active.isNotEmpty &&
          _localOnlineNames.contains(active.toLowerCase())) {
        return _players[_active.clamp(0, _players.length - 1)].name;
      }
    }
    final me = _myName.trim();
    if (me.isNotEmpty && _players.any((p) => p.name == me)) {
      return me;
    }
    return _players.isNotEmpty ? _players[_active].name : '';
  }

  /// Passa o turno: expira efeitos temporários, avança o ativo,
  /// desvia as fichas dele e conta a rodada.
  void _nextTurn() {
    if (!_canPassTurn()) {
      final activeName = _players.isEmpty
          ? ''
          : _players[_active.clamp(0, _players.length - 1)].name;
      AppToast.show(context, 'Aguarde a vez de $activeName');
      return;
    }
    if (_isGuest) {
      _send({'action': 'next_turn'});
      return;
    }
    _recordHistory('Passou o turno');
    _doNextTurn();
  }

  void _doNextTurn({bool broadcast = true}) {
    setState(() {
      _effects.removeWhere((e) => e.untilEOT);
      // Marcadores "até o fim do turno" expiram junto com os efeitos.
      for (final t in _tokens) {
        t.marks.removeWhere((m) => m.untilEOT);
      }
      if (_players.isEmpty) return;
      // Pula quem já morreu (vida, veneno ou comandante); se todos
      // morrerem, mantém o ciclo para não travar.
      var next = _active;
      for (var step = 0; step < _players.length; step++) {
        next = (next + 1) % _players.length;
        if (_players[next].alive) break;
      }
      _active = next;
      if (_active == 0) _round++;
      final owner = _players[_active].name;
      for (final t in _tokens) {
        if (t.owner == owner) t.tapped = false;
      }
    });
    if (broadcast) _broadcast();
  }

  void _doReset({bool broadcast = true}) {
    setState(() {
      for (final p in _players) {
        p.life = _startLife;
        p.poison = 0;
        p.commander.clear();
        p.counters.clear();
      }
      _mana.clear();
      _deadAnnounced.clear();
      _winsAnnounced.clear();
      _round = 1;
      _active = 0;
    });
    if (broadcast) _broadcast();
  }

  // ============ MORTE / VITÓRIA ============

  /// Anuncia morte (e vitória no 1v1) para os dois aparelhos.
  /// Personaliza se "eu" morri ou venci. Não repete até reviver.
  /// Com 3+, o último sobrevivente vence (uma vez por partida).
  final Set<String> _winsAnnounced = {};

  void _checkDeaths() {
    if (_players.isEmpty || !_inMatch) return;
    for (final p in _players) {
      if (!p.alive && !_deadAnnounced.contains(p.name)) {
        _deadAnnounced.add(p.name);
        _announceDeath(p);
      } else if (p.alive) {
        _deadAnnounced.remove(p.name);
      }
    }
    if (_players.length > 2) {
      final alive = _players.where((p) => p.alive).toList();
      if (alive.length == 1 &&
          _deadAnnounced.isNotEmpty &&
          !_winsAnnounced.contains(alive.first.name)) {
        _winsAnnounced.add(alive.first.name);
        _announceWinner(alive.first);
      } else if (alive.length != 1) {
        _winsAnnounced.clear();
      }
    }
  }

  void _announceWinner(_MatchPlayer winner) {
    final me = _myName.trim();
    final iWon = me.isNotEmpty && winner.name == me;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
            iWon
                ? AppLocale.t('su_won')
                : AppLocale.t('su_x_won').replaceAll('{n}', winner.name),
            textAlign: TextAlign.center),
        content: Text(AppLocale.t('su_died_msg').replaceAll('{w}', winner.name),
            textAlign: TextAlign.center),
        actions: [
          Center(
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocale.t('su_continue')),
            ),
          ),
        ],
      ),
    );
  }

  void _announceDeath(_MatchPlayer dead) {
    final others =
        _players.where((p) => p.name != dead.name && p.alive).toList();
    final me = _myName.trim();
    final iDied = me.isNotEmpty && dead.name == me;
    // Causa: vida chega a 0, veneno a 10 ou comandante a 21.
    String causeMsg;
    switch (dead.deathCause) {
      case 'poison':
        causeMsg = AppLocale.t('death_poison').replaceAll('{n}', dead.name);
        break;
      case 'commander':
        causeMsg = AppLocale.t('death_commander')
            .replaceAll('{n}', dead.name)
            .replaceAll('{c}', dead.killerCommander);
        break;
      default:
        causeMsg = AppLocale.t('su_life_msg')
            .replaceAll('{n}', dead.name)
            .replaceAll('{l}', '${dead.life}');
    }
    String title;
    String msg;
    if (_players.length == 2 && others.length == 1) {
      final winner = others.first;
      final iWon = me.isNotEmpty && winner.name == me;
      title = iDied
          ? AppLocale.t('su_died')
          : (iWon
              ? AppLocale.t('su_won')
              : AppLocale.t('su_x_won').replaceAll('{n}', winner.name));
      msg = iDied ? causeMsg : '$causeMsg\n${AppLocale.t('su_died_msg').replaceAll('{w}', winner.name)}';
    } else {
      title = iDied
          ? AppLocale.t('su_died')
          : AppLocale.t('su_x_died').replaceAll('{n}', dead.name);
      msg = causeMsg;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title, textAlign: TextAlign.center),
        content: Text(msg, textAlign: TextAlign.center),
        actions: [
          Center(
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocale.t('su_continue')),
            ),
          ),
        ],
      ),
    );
  }

  void _resetMatch() {
    if (_isGuest) {
      _send({'action': 'reset'});
      return;
    }
    _recordHistory('Reiniciou marcadores');
    _doReset();
  }

  int _bonusP(_Token t) => _effects
      .where((e) => e.targetId == -1 || e.targetId == t.id)
      .fold(0, (s, e) => s + e.power);

  int _bonusT(_Token t) => _effects
      .where((e) => e.targetId == -1 || e.targetId == t.id)
      .fold(0, (s, e) => s + e.toughness);

  int effP(_Token t) => t.power + t.counters - t.minus + _bonusP(t);
  int effT(_Token t) => t.toughness + t.counters - t.minus + _bonusT(t);

  /// Regra 122.3: +1/+1 e -1/-1 no mesmo permanente se anulam em pares.
  static void _cancelOpposing(_Token t) {
    final n = t.counters < t.minus ? t.counters : t.minus;
    if (n > 0) {
      t.counters -= n;
      t.minus -= n;
    }
  }

  // ---- fichas ----

  /// Fichas comuns prontas (criaturas + artefatos utilitários),
  /// com o texto original das utilitárias.
  static const _presets = [
    {'name': 'Soldado', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Humano', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Goblin', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Elfo', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Espírito', 'p': 1, 't': 1, 'text': 'Voar'},
    {'name': 'Servo', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Saprófita', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Rato', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Pássaro', 'p': 1, 't': 1, 'text': 'Voar'},
    {'name': 'Esqueleto', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Vampiro', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Zumbi', 'p': 2, 't': 2, 'text': ''},
    {'name': 'Lobo', 'p': 2, 't': 2, 'text': ''},
    {'name': 'Cavaleiro', 'p': 2, 't': 2, 'text': ''},
    {'name': 'Guerreiro', 'p': 2, 't': 1, 'text': ''},
    {'name': 'Besta', 'p': 3, 't': 3, 'text': ''},
    {'name': 'Anjo', 'p': 4, 't': 4, 'text': 'Voar'},
    {'name': 'Dragão', 'p': 5, 't': 5, 'text': 'Voar'},
    {'name': 'Demônio', 'p': 5, 't': 5, 'text': 'Voar'},
    {
      'name': 'Tesouro',
      'p': 0,
      't': 0,
      'text': 'Vire, sacrifique: adicione uma mana de qualquer cor.'
    },
    {'name': 'Pista', 'p': 0, 't': 0, 'text': '2, sacrifique: compre um card.'},
    {
      'name': 'Comida',
      'p': 0,
      't': 0,
      'text': '2, vire, sacrifique: você ganha 3 de vida.'
    },
    {
      'name': 'Sangue',
      'p': 0,
      't': 0,
      'text': '1, vire, descarte um card, sacrifique: compre um card.'
    },
    {
      'name': 'Mapa',
      'p': 0,
      't': 0,
      'text': '1, sacrifique: a criatura alvo que você controla explora.'
    },
    {
      'name': 'Pedra de poder',
      'p': 0,
      't': 0,
      'text':
          'Vire: adicione {C}. Essa mana não pode ser usada para conjurar uma mágica que não seja artefato.'
    },
    {
      'name': 'Ouro',
      'p': 0,
      't': 0,
      'text': 'Sacrifique: adicione uma mana de qualquer cor.'
    },
    {'name': 'Thopter', 'p': 1, 't': 1, 'text': 'Voar'},
    {'name': 'Inseto', 'p': 1, 't': 1, 'text': 'Voar'},
    {'name': 'Gato', 'p': 1, 't': 1, 'text': ''},
    {'name': 'Peixe', 'p': 2, 't': 2, 'text': ''},
    {'name': 'Urso', 'p': 2, 't': 2, 'text': ''},
    {'name': 'Rinoceronte', 'p': 4, 't': 4, 'text': ''},
  ];

  /// Seletor: presets comuns ou personalizada.
  Future<void> _tokenLauncher({String? owner, bool upsideDown = false}) async {
    final tokenOwner = owner ?? _defaultOwner;
    var quantity = 1;
    // Modelos salvos (cartas personalizadas): falhar aqui não pode
    // impedir abrir o launcher (banco antigo sem a tabela, etc.).
    var templates = <Map<String, Object?>>[];
    try {
      templates = await AppDatabase.instance.db.query('custom_templates',
          orderBy: 'updated_at DESC', limit: 20);
    } catch (_) {}
    if (!mounted) return;
    final pick = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // Teto de 72%: cheio até o topo escondia os botões de cima.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.72,
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(ctx, {'custom': true}),
                    icon: const Icon(Icons.edit),
                    label: Text(AppLocale.t('token_custom')),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(ctx, {'card': true}),
                    icon: const Icon(Icons.search),
                    label: Text(AppLocale.t('token_card')),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(ctx, {'marker': true}),
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: Text(AppLocale.t('mk_add')),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final k in _Marker.kinds)
                        ActionChip(
                          avatar: Icon(
                              k == 'plus'
                                  ? Icons.arrow_upward
                                  : k == 'minus'
                                      ? Icons.arrow_downward
                                      : Icons.bookmark,
                              size: 15),
                          label: Text(AppLocale.t('mk_quick_$k'),
                              style: const TextStyle(fontSize: 12)),
                          onPressed: () =>
                              Navigator.pop(ctx, {'markerKind': k}),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      Text(AppLocale.t('su_add_count'),
                          style: const TextStyle(color: AppTheme.textMuted)),
                      for (final value in [1, 2, 3, 5, 10])
                        ChoiceChip(
                          label: Text('×$value'),
                          selected: quantity == value,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) =>
                              setSheetState(() => quantity = value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(AppLocale.t('su_common_tokens'),
                      style: const TextStyle(color: AppTheme.textMuted)),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final pr in _presets)
                                ActionChip(
                                  label: Text(
                                      '${pr['name']} ${(pr['p'] as int) == 0 && (pr['t'] as int) == 0 ? '◆' : '${pr['p']}/${pr['t']}'}'),
                                  onPressed: () => Navigator.pop(
                                      ctx, {...pr, 'quantity': quantity}),
                                ),
                            ],
                          ),
                          if (templates.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(AppLocale.t('tpl_mine'),
                                style: const TextStyle(
                                    color: AppTheme.textMuted)),
                            const SizedBox(height: 4),
                            for (final tpl in templates)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                    (tpl['name'] ?? '?').toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                    _templateSub(tpl),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18, color: Colors.redAccent),
                                  tooltip: AppLocale.t('prof_delete'),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 36, minHeight: 36),
                                  onPressed: () async {
                                    await _deleteTemplate(
                                        (tpl['id'] as num?)?.toInt() ?? -1);
                                    setSheetState(() => templates.removeWhere(
                                        (e) => e['id'] == tpl['id']));
                                  },
                                ),
                                onTap: () => Navigator.pop(ctx, {
                                  'template': true,
                                  'name': (tpl['name'] ?? 'Ficha').toString(),
                                  'p': (tpl['power'] as num?)?.toInt() ?? 1,
                                  't': (tpl['toughness'] as num?)
                                          ?.toInt() ??
                                      1,
                                  'cost': (tpl['cost'] ?? '').toString(),
                                  'type': (tpl['type'] ?? '').toString(),
                                  'keywords':
                                      _Token._keywordsFrom(tpl['keywords']),
                                  'text': (tpl['description'] ?? '').toString(),
                                  'art': (tpl['art'] ?? '').toString(),
                                  'quantity': quantity,
                                }),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (pick == null) return;
    if (pick['custom'] == true) {
      await _tokenDialog(owner: tokenOwner, upsideDown: upsideDown);
      return;
    }
    if (pick['card'] == true) {
      await _cardSearch(owner: tokenOwner, upsideDown: upsideDown);
      return;
    }
    if (pick['marker'] == true) {
      await _markerDialog(upsideDown: upsideDown);
      return;
    }
    final markerKind = (pick['markerKind'] ?? '').toString();
    if (_Marker.kinds.contains(markerKind)) {
      await _markerDialog(kind: markerKind, upsideDown: upsideDown);
      return;
    }
    if (pick['template'] == true) {
      _createPreset(
          (pick['name'] ?? 'Ficha').toString(),
          (pick['p'] as num?)?.toInt() ?? 1,
          (pick['t'] as num?)?.toInt() ?? 1,
          tokenOwner,
          description: (pick['text'] ?? '').toString(),
          quantity: (pick['quantity'] as num?)?.toInt() ?? 1,
          art: (pick['art'] ?? '').toString(),
          cost: (pick['cost'] ?? '').toString(),
          type: (pick['type'] ?? '').toString(),
          keywords: _Token._keywordsFrom(pick['keywords']));
      return;
    }
    _createPreset(
        (pick['name'] ?? 'Ficha').toString(),
        (pick['p'] as num?)?.toInt() ?? 1,
        (pick['t'] as num?)?.toInt() ?? 1,
        tokenOwner,
        description: (pick['text'] ?? '').toString(),
        quantity: (pick['quantity'] as num?)?.toInt() ?? 1);
  }

  /// Subtítulo do modelo salvo: custo + tipo + P/T.
  String _templateSub(Map<String, Object?> tpl) {
    final bits = <String>[];
    final cost = (tpl['cost'] ?? '').toString().trim();
    if (cost.isNotEmpty) bits.add(cost);
    final type = (tpl['type'] ?? '').toString().trim();
    if (type.isNotEmpty) bits.add(type);
    bits.add(
        '${(tpl['power'] as num?)?.toInt() ?? 1}/${(tpl['toughness'] as num?)?.toInt() ?? 1}');
    return bits.join(' • ');
  }

  Future<void> _saveTemplate(Map<String, Object> tpl) async {
    try {
      await AppDatabase.instance.db.insert('custom_templates', {
        'name': tpl['name'].toString(),
        'power': tpl['power'],
        'toughness': tpl['toughness'],
        'cost': tpl['cost'].toString(),
        'type': tpl['type'].toString(),
        'keywords': jsonEncode(tpl['keywords']),
        'description': tpl['description'].toString(),
        'art': '',
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    }
  }

  Future<void> _deleteTemplate(int id) async {
    if (id < 0) return;
    try {
      await AppDatabase.instance.db
          .delete('custom_templates', where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
  }

  void _createPreset(String name, int power, int toughness, String owner,
      {String description = '',
      int quantity = 1,
      String art = '',
      String cost = '',
      String type = '',
      List<String> keywords = const []}) {
    final amount = quantity.clamp(1, 20).toInt();
    // A arte é por NOME e vale pros dois players: se já existe qualquer
    // ficha com esse nome (minha ou do oponente), herda a arte dela.
    final inheritedArt = art.isNotEmpty
        ? art
        : _artForTemplate(name, power, toughness, description);
    if (_isGuest) {
      for (var i = 0; i < amount; i++) {
        _send({
          'action': 'token_add',
          'token': {
            'id': 0,
            'name': name,
            'power': power,
            'toughness': toughness,
            'counters': 0,
            'tapped': false,
            'owner': owner,
            'description': description,
            'art': inheritedArt,
            'cost': cost,
            'type': type,
            'keywords': [...keywords],
          }
        });
      }
      return;
    }
    _recordHistory('Adicionou $amount ficha${amount == 1 ? '' : 's'} $name');
    setState(() {
      for (var i = 0; i < amount; i++) {
        final t = _Token(
            id: _tokenSeq++,
            name: name,
            power: power,
            toughness: toughness,
            owner: owner,
            description: description,
            art: inheritedArt,
            cost: cost,
            type: type,
            keywords: [...keywords]);
        _stampOwner(t);
        _tokens.add(t);
      }
    });
    _broadcast();
  }

  /// Carimba a identidade do dono na ficha nova (online): UID pelo nome.
  /// Local/LAN/legado ficam com ''. Nunca reescrito por troca de perfil.
  void _stampOwner(_Token t) {
    if (!_isOnline) {
      t.ownerUid = '';
      return;
    }
    t.ownerUid = _uidOfName(t.owner);
  }

  /// Coloca uma CARTA real na mesa (não só ficha): busca primeiro na
  /// coleção local e, se não achar, no Scryfall. Traz nome, arte, tipo
  /// e P/T quando for criatura. Depois dá para pendurar marcadores
  /// (+1/+1, lealdade, carga) nela pelo menu "Marcadores…".
  Future<void> _cardSearch({String? owner, bool upsideDown = false}) async {
    final tokenOwner = owner ?? _defaultOwner;
    final q = TextEditingController();
    List<Map<String, Object?>> local = [];
    List<Map<String, dynamic>> remote = [];
    bool searching = false;
    bool remoteDone = false;
    String? error;

    Future<List<Map<String, Object?>>> queryLocal(String term) async {
      try {
        return await AppDatabase.instance.db.query(
          'cards',
          where: 'name LIKE ? OR printed_name LIKE ?',
          whereArgs: ['%$term%', '%$term%'],
          orderBy: 'name ASC',
          limit: 20,
        );
      } catch (_) {
        return [];
      }
    }

    final pick = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          Future<void> doLocal(String term) async {
            if (term.trim().length < 2) {
              setD(() => local = []);
              return;
            }
            final r = await queryLocal(term.trim());
            if (!ctx.mounted) return;
            setD(() => local = r);
          }

          Future<void> doRemote() async {
            final term = q.text.trim();
            if (term.length < 2) return;
            setD(() {
              searching = true;
              error = null;
            });
            try {
              final r = await ScryfallService.instance.search(term);
              if (!ctx.mounted) return;
              setD(() {
                remote = r.take(12).toList();
                searching = false;
                remoteDone = true;
              });
            } catch (e) {
              if (!ctx.mounted) return;
              setD(() {
                error = _artErrorText(e);
                searching = false;
                remoteDone = true;
              });
            }
          }

          Widget localTile(Map<String, Object?> c) {
            final name = ((c['printed_name'] ?? c['name']) ?? '?').toString();
            final set = ((c['set_name'] ?? c['set_code']) ?? '').toString();
            final url = (c['image_url'] ?? '').toString();
            return ListTile(
              dense: true,
              leading: url.isEmpty
                  ? const Icon(Icons.style)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CachedNetworkImage(
                          imageUrl: url,
                          width: 32,
                          height: 44,
                          fit: BoxFit.cover,
                          memCacheWidth: 100),
                    ),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: set.isEmpty
                  ? null
                  : Text(set, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, {'src': 'local', 'row': c}),
            );
          }

          Widget remoteTile(Map<String, dynamic> d) {
            final name = ((d['printed_name'] ?? d['name']) ?? '?').toString();
            final set = (d['set_name'] ?? '').toString();
            final url = ScryfallService.extractImageUrl(d) ?? '';
            return ListTile(
              dense: true,
              leading: url.isEmpty
                  ? const Icon(Icons.style)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CachedNetworkImage(
                          imageUrl: url,
                          width: 32,
                          height: 44,
                          fit: BoxFit.cover,
                          memCacheWidth: 100),
                    ),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: set.isEmpty
                  ? null
                  : Text(set, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, {'src': 'remote', 'data': d}),
            );
          }

          return RotatedBox(
            quarterTurns: upsideDown ? 2 : 0,
            child: SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.8,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(AppLocale.t('card_title'),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: q,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onChanged: doLocal,
                        onSubmitted: (_) => doRemote(),
                        decoration: InputDecoration(
                          hintText: AppLocale.t('card_hint'),
                          prefixIcon: const Icon(Icons.search),
                          // OCR: fotografa a carta física e preenche a busca.
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.camera_alt, size: 20),
                            tooltip: AppLocale.t('ocr_title'),
                            onPressed: () async {
                              final title =
                                  await Navigator.push<String>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const OcrScanPage()),
                              );
                              if (title == null ||
                                  title.trim().isEmpty ||
                                  !ctx.mounted) {
                                return;
                              }
                              q.text = title.trim();
                              await doLocal(q.text);
                              await doRemote();
                            },
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Spacer(),
                          TextButton.icon(
                            onPressed: searching ? null : doRemote,
                            icon: const Icon(Icons.cloud_outlined, size: 16),
                            label: Text(AppLocale.t('card_remote_btn')),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: searching
                          ? const Center(child: CircularProgressIndicator())
                          : ListView(
                              padding: EdgeInsets.zero,
                              children: [
                                if (local.isNotEmpty) ...[
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(16, 4, 16, 0),
                                    child: Text(AppLocale.t('card_local'),
                                        style: const TextStyle(
                                            color: AppTheme.textMuted,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                  for (final c in local) localTile(c),
                                ],
                                if (error != null)
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(error!,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: Colors.orange)),
                                  )
                                else if (remoteDone) ...[
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(16, 4, 16, 0),
                                    child: Text(AppLocale.t('card_remote'),
                                        style: const TextStyle(
                                            color: AppTheme.textMuted,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                  if (remote.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Text(AppLocale.t('art_empty'),
                                          style: const TextStyle(
                                              color: AppTheme.textMuted)),
                                    )
                                  else
                                    for (final d in remote) remoteTile(d),
                                ] else if (local.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: Text(AppLocale.t('card_start'),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: AppTheme.textMuted)),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    _laterDispose(q);
    if (pick == null) return;
    if (pick['src'] == 'local' && pick['row'] is Map) {
      _placeCard(
          Map<String, Object?>.from(pick['row'] as Map), null, tokenOwner);
    } else if (pick['src'] == 'remote' && pick['data'] is Map) {
      _placeCard(
          null, Map<String, dynamic>.from(pick['data'] as Map), tokenOwner);
    }
  }

  int _parsePt(Object? v) => int.tryParse((v ?? '').toString()) ?? 0;

  void _placeCard(Map<String, Object?>? row, Map<String, dynamic>? data,
      String tokenOwner) {
    late final String name;
    late final String art;
    late final String desc;
    late final int power;
    late final int toughness;
    late final String setCode;
    if (row != null) {
      name = ((row['printed_name'] ?? row['name']) ?? '?').toString();
      art = (row['image_url'] ?? '').toString();
      desc = (row['type_line'] ?? '').toString();
      power = _parsePt(row['power']);
      toughness = _parsePt(row['toughness']);
      setCode = (row['set_code'] ?? '').toString();
    } else {
      name = ((data!['printed_name'] ?? data['name']) ?? '?').toString();
      art = ScryfallService.extractImageUrl(data) ?? '';
      desc =
          ((data['printed_type_line'] ?? data['type_line']) ?? '').toString();
      power = _parsePt(data['power']);
      toughness = _parsePt(data['toughness']);
      setCode = (data['set'] ?? '').toString();
    }
    final card = _Token(
      id: 0,
      name: name,
      power: power,
      toughness: toughness,
      owner: tokenOwner,
      description: desc,
      art: art,
      kind: 'card',
      setCode: setCode,
    );
    if (_isGuest) {
      _send({'action': 'token_add', 'token': card.toJson()});
      return;
    }
    _recordHistory('Colocou a carta $name na mesa');
    setState(() {
      card.id = _tokenSeq++;
      _stampOwner(card);
      _tokens.add(card);
    });
    _broadcast();
  }

  bool _sameTemplate(_Token token, String name, int power, int toughness,
          String description) =>
      token.name.trim().toLowerCase() == name.trim().toLowerCase() &&
      token.power == power &&
      token.toughness == toughness &&
      token.description.trim() == description.trim();

  String _artForTemplate(
      String name, int power, int toughness, String description) {
    for (final token in _tokens) {
      if (_sameTemplate(token, name, power, toughness, description) &&
          token.art.isNotEmpty) return token.art;
    }
    // Fallback por nome: a arte vale para os dois players mesmo que
    // P/T ou descrição sejam diferentes (ex. Soldado 1/1 e 2/2).
    return _artForName(name);
  }

  /// Arte por NOME (ignora dono, P/T e descrição): assim a arte escolhida
  /// aparece nas fichas dos dois players e nas próximas criadas.
  /// Ordem: mesa atual (memória) → salvas no aparelho (disco). O disco
  /// evita rebuscar no Scryfall o que já foi alocado uma vez.
  String _artForName(String name) {
    final key = name.trim().toLowerCase();
    if (key.isEmpty) return '';
    for (final token in _tokens) {
      if (token.name.trim().toLowerCase() == key && token.art.isNotEmpty) {
        return token.art;
      }
    }
    return _artCache[key] ?? '';
  }

  /// Cache de artes escolhidas (nome normalizado -> url), persistido.
  /// Vale entre mesas e reinícios: ficha repetida já nasce com arte.
  static const _artCacheKey = 'token_art_cache';
  static const _artCacheMax = 400;
  final Map<String, String> _artCache = {};

  Future<void> _loadArtCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_artCacheKey) ?? '';
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        final key = k.toString().trim().toLowerCase();
        final url = v.toString().trim();
        if (key.isNotEmpty && url.isNotEmpty) {
          _artCache[key] = url;
        }
      });
      while (_artCache.length > _artCacheMax) {
        _artCache.remove(_artCache.keys.first);
      }
    } catch (_) {}
  }

  /// Guarda a arte alocada (chamada ao escolher no buscador).
  Future<void> _rememberArt(String name, String url) async {
    final key = name.trim().toLowerCase();
    final clean = url.trim();
    if (key.isEmpty || clean.isEmpty) return;
    _artCache.remove(key);
    _artCache[key] = clean;
    while (_artCache.length > _artCacheMax) {
      _artCache.remove(_artCache.keys.first);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_artCacheKey, jsonEncode(_artCache));
    } catch (_) {}
  }

  Future<void> _tokenDialog(
      {_Token? existing, String? owner, bool upsideDown = false}) async {
    final nameC = TextEditingController(text: existing?.name ?? '');
    final ptC = TextEditingController(
        text: existing == null
            ? '1/1'
            : '${existing.power}/${existing.toughness}');
    final descC = TextEditingController(text: existing?.description ?? '');
    final costC = TextEditingController(text: existing?.cost ?? '');
    final typeC = TextEditingController(text: existing?.type ?? '');
    final keywords = <String>{...(existing?.keywords ?? [])};
    String selectedOwner = owner ?? existing?.owner ?? _defaultOwner;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: AlertDialog(
            title: Text(existing == null
                ? AppLocale.t('dlg_new_token')
                : AppLocale.t('dlg_edit_token')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                      controller: nameC,
                      autofocus: true,
                      decoration:
                          InputDecoration(labelText: AppLocale.t('dlg_name'))),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                            controller: ptC,
                            decoration: InputDecoration(
                                labelText: AppLocale.t('dlg_pt'))),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                            controller: costC,
                            decoration: InputDecoration(
                                labelText: AppLocale.t('dlg_cost'),
                                hintText: '{2}{G} ou X')),
                      ),
                    ],
                  ),
                  TextField(
                      controller: typeC,
                      decoration: InputDecoration(
                          labelText: AppLocale.t('dlg_type'),
                          hintText: AppLocale.t('dlg_type_hint'))),
                  const SizedBox(height: 8),
                  Text(AppLocale.t('dlg_abilities'),
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 12)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final k in _Token.abilityKeys)
                        FilterChip(
                          label: Text(AppLocale.t('ab_$k'),
                              style: const TextStyle(fontSize: 12)),
                          selected: keywords.contains(k),
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setD(() {
                            if (!keywords.remove(k)) keywords.add(k);
                          }),
                        ),
                    ],
                  ),
                  TextField(
                      controller: descC,
                      maxLines: 2,
                      decoration:
                          InputDecoration(labelText: AppLocale.t('dlg_desc'))),
                  if (_players.isNotEmpty)
                    DropdownButton<String>(
                      value: _players.any((p) => p.name == selectedOwner)
                          ? selectedOwner
                          : _players.first.name,
                      isExpanded: true,
                      items: [
                        for (final p in _players)
                          DropdownMenuItem(value: p.name, child: Text(p.name))
                      ],
                      onChanged: (v) =>
                          setD(() => selectedOwner = v ?? selectedOwner),
                    ),
                  // Salvar modelo: vale criando E editando (guarda o
                  // estado atual do formulário nos modelos).
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.bookmark_add_outlined,
                            size: 16),
                        label: Text(AppLocale.t('dlg_save_template')),
                        onPressed: () async {
                          final tpl = _readTokenForm(
                              nameC: nameC,
                              ptC: ptC,
                              descC: descC,
                              costC: costC,
                              typeC: typeC,
                              keywords: keywords,
                              powerFb: 1,
                              toughnessFb: 1);
                          if (tpl['name'].toString().isEmpty) {
                            AppToast.show(
                                context, AppLocale.t('dlg_name_needed'));
                            return;
                          }
                          await _saveTemplate(tpl);
                          if (mounted) {
                            AppToast.show(context,
                                AppLocale.t('dlg_template_saved'));
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(AppLocale.t('common_cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(AppLocale.t('common_save'))),
            ],
          ),
        ),
      ),
    );
    final form = _readTokenForm(
        nameC: nameC,
        ptC: ptC,
        descC: descC,
        costC: costC,
        typeC: typeC,
        keywords: keywords,
        powerFb: existing?.power ?? 1,
        toughnessFb: existing?.toughness ?? 1);
    final name = form['name'].toString();
    final description = form['description'].toString();
    final cost = form['cost'].toString();
    final type = form['type'].toString();
    final kws = List<String>.from(form['keywords'] as List);
    final power = form['power'] as int;
    final toughness = form['toughness'] as int;
    _laterDispose(nameC);
    _laterDispose(descC);
    _laterDispose(ptC);
    _laterDispose(costC);
    _laterDispose(typeC);
    if (ok != true || name.isEmpty) return;
    // Preserva a arte ao editar o mesmo nome; se o nome mudou,
    // herda a arte já escolhida para o novo nome (dos dois players).
    final keptArt = existing == null
        ? _artForTemplate(name, power, toughness, description)
        : (existing.name.trim().toLowerCase() == name.trim().toLowerCase() &&
                existing.art.isNotEmpty)
            ? existing.art
            : _artForTemplate(name, power, toughness, description);
    if (_isGuest) {
      if (existing == null) {
        _send({
          'action': 'token_add',
          'token': {
            'id': 0,
            'name': name,
            'power': power,
            'toughness': toughness,
            'counters': 0,
            'tapped': false,
            'owner': selectedOwner,
            'description': description,
            'art': keptArt,
            'cost': cost,
            'type': type,
            'keywords': [...kws],
          }
        });
      } else {
        _send({
          'action': 'token_set',
          'id': existing.id,
          'name': name,
          'power': power,
          'toughness': toughness,
          'owner': selectedOwner,
          'description': description,
          'art': keptArt,
          'cost': cost,
          'type': type,
          'keywords': [...kws],
        });
      }
      return;
    }
    _recordHistory(
        existing == null ? 'Criou ficha $name' : 'Editou ficha $name');
    setState(() {
      if (existing == null) {
        final t = _Token(
            id: _tokenSeq++,
            name: name,
            power: power,
            toughness: toughness,
            owner: selectedOwner,
            description: description,
            art: keptArt,
            cost: cost,
            type: type,
            keywords: [...kws]);
        _stampOwner(t);
        _tokens.add(t);
      } else {
        existing.name = name;
        existing.power = power;
        existing.toughness = toughness;
        existing.owner = selectedOwner;
        if (_isOnline) {
          existing.ownerUid = _uidOfName(selectedOwner);
        }
        existing.description = description;
        existing.cost = cost;
        existing.type = type;
        existing.keywords = [...kws];
        if (keptArt.isNotEmpty) existing.art = keptArt;
      }
    });
    _broadcast();
  }

  /// Lê nome/P/T/custo/tipo/habilidades do formulário de ficha.
  /// P/T aceita "3/4"; o resto é texto livre (custo aceita "X").
  Map<String, Object> _readTokenForm(
      {required TextEditingController nameC,
      required TextEditingController ptC,
      required TextEditingController descC,
      required TextEditingController costC,
      required TextEditingController typeC,
      required Set<String> keywords,
      required int powerFb,
      required int toughnessFb}) {
    var power = powerFb;
    var toughness = toughnessFb;
    final m =
        RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(ptC.text.trim());
    if (m != null) {
      power = int.tryParse(m.group(1)!) ?? power;
      toughness = int.tryParse(m.group(2)!) ?? toughness;
    }
    return {
      'name': nameC.text.trim(),
      'description': descC.text.trim(),
      'cost': costC.text.trim(),
      'type': typeC.text.trim(),
      'keywords': [...keywords],
      'power': power,
      'toughness': toughness,
    };
  }

  void _tokenTap(_Token t) {
    // Toque vira/desvira direto (segurar mostra as informações) — o toast
    // confirma na hora, com 10 cartas na mesa não há dúvida (host/guest).
    final msg = AppLocale.t(t.tapped ? 'tok_now_untapped' : 'tok_now_tapped')
        .replaceAll('{n}', t.name);
    if (_isGuest) {
      _send({'action': 'token_tap', 'id': t.id, 'tapped': !t.tapped});
      AppToast.show(context, msg);
      return;
    }
    _recordHistory('${t.tapped ? 'Desvirou' : 'Virou'} ${t.name}');
    setState(() => t.tapped = !t.tapped);
    AppToast.show(context, msg);
    _broadcast();
  }

  /// Ocultar/mostrar o nome vale para a PILHA inteira (todas as
  /// atreladas: mesmo nome, dono (uid+nome) e dados), não só uma cópia.
  List<_Token> _stackMates(_Token t) => _tokens
      .where((o) =>
          o.owner == t.owner &&
          o.ownerUid == t.ownerUid &&
          _sameTemplate(o, t.name, t.power, t.toughness, t.description))
      .toList();

  void _toggleTokenName(_Token t) {
    final hide = t.hideName != true;
    final mates = _stackMates(t);
    if (mates.isEmpty) return;
    if (_isGuest) {
      for (final o in mates) {
        _send({'action': 'token_set', 'id': o.id, 'hideName': hide});
      }
      return;
    }
    _recordHistory('${hide ? 'Ocultou' : 'Mostrou'} nome de ${t.name}');
    setState(() {
      for (final o in mates) {
        o.hideName = hide;
      }
    });
    _broadcast();
  }

  void _tokenCounter(_Token t, int delta) {
    if (_isGuest) {
      _send({'action': 'token_counter', 'id': t.id, 'delta': delta});
      return;
    }
    _recordHistory('${t.name}: +1/+1 ${delta >= 0 ? '+' : ''}$delta');
    setState(() {
      t.counters = (t.counters + delta).clamp(0, 99);
      _cancelOpposing(t);
    });
    _broadcast();
  }

  void _tokenMinus(_Token t, int delta) {
    if (_isGuest) {
      _send({'action': 'token_minus', 'id': t.id, 'delta': delta});
      return;
    }
    _recordHistory('${t.name}: -1/-1 ${delta >= 0 ? '+' : ''}$delta');
    setState(() {
      t.minus = (t.minus + delta).clamp(0, 99);
      _cancelOpposing(t);
    });
    _broadcast();
  }

  /// Substitui a lista de marcadores personalizados (sincroniza pros dois).
  void _setMarks(_Token t, List<_Mark> marks) {
    if (_isGuest) {
      _send({
        'action': 'token_set',
        'id': t.id,
        'marks': [for (final m in marks) m.toJson()],
      });
      return;
    }
    _recordHistory('${t.name}: marcadores atualizados');
    setState(() => t.marks = marks);
    _broadcast();
  }

  void _tokenLoyalty(_Token t, int delta) {
    final next = (t.loyalty + delta).clamp(0, 99);
    if (_isGuest) {
      _send({'action': 'token_set', 'id': t.id, 'loyalty': next});
      return;
    }
    _recordHistory('${t.name}: lealdade ${delta >= 0 ? '+' : ''}$delta');
    setState(() => t.loyalty = next);
    _broadcast();
  }

  void _tokenCharge(_Token t, int delta) {
    final next = (t.charge + delta).clamp(0, 99);
    if (_isGuest) {
      _send({'action': 'token_set', 'id': t.id, 'charge': next});
      return;
    }
    _recordHistory('${t.name}: carga ${delta >= 0 ? '+' : ''}$delta');
    setState(() => t.charge = next);
    _broadcast();
  }

  /// +1/−1 CÓPIA rápida da pilha (otimista p/ guest: some/aparece na
  /// hora e converge no eco do host). [ref] é qualquer carta da pilha.
  void _stackCopyBump(_Token ref, int delta) {
    if (delta > 0) {
      final mates = _stackMates(ref);
      final src = mates.isNotEmpty ? mates.first : ref;
      _createPreset(src.name, src.power, src.toughness, src.owner,
          description: src.description,
          quantity: delta.clamp(1, 20),
          art: src.art.isNotEmpty ? src.art : _artForName(src.name),
          cost: src.cost,
          type: src.type,
          keywords: [...src.keywords]);
      return;
    }
    final mates = _stackMates(ref);
    if (mates.isEmpty) return;
    final victim = mates.first;
    if (_isGuest) {
      setState(() => _tokens.removeWhere((e) => e.id == victim.id));
      _persistMatch();
      _send({'action': 'token_remove', 'id': victim.id});
      return;
    }
    _tokenRemove(victim);
  }

  /// +1/+1 rápido (otimista p/ guest, como as cópias).
  void _tokenCounterQuick(_Token t, int delta) {
    if (_isGuest) {
      setState(() {
        t.counters = (t.counters + delta).clamp(0, 99);
        _cancelOpposing(t);
      });
      _persistMatch();
    }
    _tokenCounter(t, delta);
  }

  void _tokenRemove(_Token t) {
    if (_isGuest) {
      _send({'action': 'token_remove', 'id': t.id});
      return;
    }
    _recordHistory('Removeu ficha ${t.name}');
    setState(() => _tokens.removeWhere((e) => e.id == t.id));
    _broadcast();
  }

  // ---- efeitos ----

  Future<void> _effectDialog() async {
    final labelC = TextEditingController(text: 'Anthem');
    var power = 1;
    var toughness = 1;
    int targetId = -1;
    var untilEOT = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(AppLocale.t('su_effect')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: labelC,
                  decoration: InputDecoration(
                      labelText: AppLocale.t('su_effect_name'))),
              Row(
                children: [
                  Text(AppLocale.t('su_power')),
                  IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => setD(() => power = power - 1)),
                  Text('$power'),
                  IconButton(
                      icon: const Icon(Icons.add_circle, color: AppTheme.gold),
                      onPressed: () => setD(() => power = power + 1)),
                  Text(AppLocale.t('su_res')),
                  IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => setD(() => toughness = toughness - 1)),
                  Text('$toughness'),
                  IconButton(
                      icon: const Icon(Icons.add_circle, color: AppTheme.gold),
                      onPressed: () => setD(() => toughness = toughness + 1)),
                ],
              ),
              DropdownButton<int>(
                value: targetId,
                isExpanded: true,
                items: [
                  DropdownMenuItem(
                      value: -1, child: Text(AppLocale.t('su_all_tokens'))),
                  for (final t in _tokens)
                    DropdownMenuItem(
                        value: t.id,
                        child: Text(
                            '${AppLocale.t('su_only')}${t.name} (${effP(t)}/${effT(t)})')),
                ],
                onChanged: (v) => setD(() => targetId = v ?? -1),
              ),
              CheckboxListTile(
                value: untilEOT,
                title: Text(AppLocale.t('su_eot'),
                    style: const TextStyle(fontSize: 14)),
                onChanged: (v) => setD(() => untilEOT = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppLocale.t('common_cancel'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(AppLocale.t('common_apply'))),
          ],
        ),
      ),
    );
    _laterDispose(labelC);
    if (ok != true) return;
    final label = labelC.text.trim().isEmpty ? 'Efeito' : labelC.text.trim();
    if (_isGuest) {
      _send({
        'action': 'effect_add',
        'effect': {
          'id': 0,
          'label': label,
          'power': power,
          'toughness': toughness,
          'targetId': targetId,
          'untilEOT': untilEOT,
        }
      });
      return;
    }
    _recordHistory('Aplicou efeito $label');
    setState(() => _effects.add(_TokenEffect(
        id: _effectSeq++,
        label: label,
        power: power,
        toughness: toughness,
        targetId: targetId,
        untilEOT: untilEOT)));
    _broadcast();
  }

  void _effectRemove(int id) {
    if (_isGuest) {
      _send({'action': 'effect_remove', 'id': id});
      return;
    }
    _recordHistory('Removeu efeito');
    setState(() => _effects.removeWhere((e) => e.id == id));
    _broadcast();
  }

  // ============ MARCADORES SEPARADOS ============

  /// Cria marcador (global ou com fichas dentro). Guest pede ao host.
  /// plus/minus já carimbam o valor inicial nas fichas de dentro.
  void _markerAdd(String label, int count, List<int> memberIds,
      {String kind = 'custom'}) {
    final clean =
        label.trim().isEmpty ? AppLocale.t('mk_title') : label.trim();
    final k = _Marker.kinds.contains(kind) ? kind : 'custom';
    final members = memberIds
        .where((id) => _tokens.any((t) => t.id == id))
        .toList();
    if (_isGuest) {
      _send({
        'action': 'marker_add',
        'player': _myName,
        'marker': {
          'id': 0,
          'label': clean,
          'count': count.clamp(-99, 99),
          'memberIds': members,
          'kind': k,
        }
      });
      if ((k == 'plus' || k == 'minus') && count != 0) {
        _markerStampIds(members, k, count);
      }
      return;
    }
    _recordHistory('Criou marcador $clean');
    final mk = _Marker(
        id: _markerSeq++,
        label: clean,
        count: count.clamp(-99, 99),
        memberIds: members,
        kind: k);
    setState(() => _markers.add(mk));
    if ((k == 'plus' || k == 'minus') && mk.count != 0) {
      _stampMembers(mk, mk.count);
    }
    _broadcast();
  }

  /// Aplica [delta] ao contador do marcador E carimba nas fichas
  /// (plus: +1/+1, minus: −1/−1). É o +/− do detalhe do marcador.
  void _markerAdjust(int id, int delta) {
    if (delta == 0) return;
    _Marker? mk;
    for (final m in _markers) {
      if (m.id == id) mk = m;
    }
    if (mk == null) return;
    final kind = mk.kind;
    final members = _markerMembers(mk).map((t) => t.id).toList();
    if (_isGuest) {
      _send({
        'action': 'marker_set',
        'player': _myName,
        'id': id,
        'count': (mk.count + delta).clamp(-99, 99),
      });
      if (kind == 'plus' || kind == 'minus') {
        _markerStampIds(members, kind, delta);
      }
      return;
    }
    _recordHistory('Ajustou marcador ${mk.label}');
    setState(() {
      mk!.count = (mk.count + delta).clamp(-99, 99);
      _stampMembers(mk, delta);
    });
    _broadcast();
  }

  /// Carimba [delta] nas fichas (host, direto no estado).
  void _stampMembers(_Marker mk, int delta) {
    for (final t in _markerMembers(mk)) {
      if (mk.kind == 'plus') {
        t.counters = (t.counters + delta).clamp(0, 99);
        _cancelOpposing(t);
      } else if (mk.kind == 'minus') {
        t.minus = (t.minus + delta).clamp(0, 99);
        _cancelOpposing(t);
      }
    }
  }

  /// Carimba [delta] nas fichas (guest: otimista + envia por ficha).
  void _markerStampIds(List<int> ids, String kind, int delta) {
    for (final id in ids) {
      _Token? found;
      for (final t in _tokens) {
        if (t.id == id) found = t;
      }
      if (found == null) continue;
      if (kind == 'plus') {
        _tokenCounterQuick(found, delta);
      } else if (kind == 'minus') {
        _tokenMinusQuick(found, delta);
      }
    }
  }

  /// −1/−1 rápido (otimista p/ guest, como o +1/+1).
  void _tokenMinusQuick(_Token t, int delta) {
    if (_isGuest) {
      setState(() {
        t.minus = (t.minus + delta).clamp(0, 99);
        _cancelOpposing(t);
      });
      _persistMatch();
    }
    _tokenMinus(t, delta);
  }

  void _markerSet(int id,
      {String? label, int? count, List<int>? memberIds}) {
    if (_isGuest) {
      _send({
        'action': 'marker_set',
        'player': _myName,
        'id': id,
        if (label != null) 'label': label,
        if (count != null) 'count': count,
        if (memberIds != null) 'memberIds': memberIds,
      });
      return;
    }
    _recordHistory('Ajustou marcador');
    setState(() {
      for (final mk in _markers) {
        if (mk.id != id) continue;
        if (label != null && label.trim().isNotEmpty) mk.label = label.trim();
        if (count != null) mk.count = count.clamp(-99, 99);
        if (memberIds != null) {
          mk.memberIds = memberIds
              .where((mid) => _tokens.any((t) => t.id == mid))
              .toList();
        }
      }
    });
    _broadcast();
  }

  void _markerRemove(int id) {
    if (_isGuest) {
      _send({'action': 'marker_remove', 'player': _myName, 'id': id});
      return;
    }
    _recordHistory('Removeu marcador');
    setState(() => _markers.removeWhere((mk) => mk.id == id));
    _broadcast();
  }

  /// Nome de exibição dos membros (pula fichas que já saíram).
  List<_Token> _markerMembers(_Marker mk) => [
        for (final id in mk.memberIds)
          for (final t in _tokens)
            if (t.id == id) t
      ];

  /// Diálogo de criação: nome + contador + escopo (global ou fichas).
  /// [tokenId] pré-vincula a ficha de origem (criado pelo menu dela).
  /// Criação de marcador com TIPO + exemplo: +1/+1 e −1/−1 carimbam
  /// nas fichas de dentro; contador global é só informativo.
  /// [kind] pré-seleciona (modelos rápidos do +); [tokenId] vincula.
  Future<void> _markerDialog(
      {int? tokenId, String? kind, bool upsideDown = false}) async {
    final labelC = TextEditingController(
        text: kind == 'plus'
            ? AppLocale.t('mk_plus_name')
            : kind == 'minus'
                ? AppLocale.t('mk_minus_name')
                : kind == 'custom'
                    ? AppLocale.t('mk_custom_name')
                    : '');
    var count = 0;
    var selKind =
        _Marker.kinds.contains(kind) ? kind! : 'custom';
    final members = <int>{
      if (tokenId != null && _tokens.any((t) => t.id == tokenId)) tokenId
    };
    var global = members.isEmpty && selKind == 'custom';
    String kindExample(String k) {
      final n = members.isEmpty
          ? '—'
          : members.length == 1
              ? (_tokens
                      .where((t) => t.id == members.first)
                      .firstOrNull
                      ?.name ??
                  '—')
              : '${members.length}';
      return switch (k) {
        'plus' => AppLocale.t('mk_plus_ex').replaceAll('{n}', n),
        'minus' => AppLocale.t('mk_minus_ex').replaceAll('{n}', n),
        _ => AppLocale.t('mk_custom_ex'),
      };
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: AlertDialog(
            title: Text(AppLocale.t('mk_new')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(AppLocale.t('mk_type'),
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final k in _Marker.kinds)
                      ChoiceChip(
                        label: Text(AppLocale.t('mk_kind_$k'),
                            style: const TextStyle(fontSize: 12)),
                        selected: selKind == k,
                        onSelected: (_) => setD(() {
                          selKind = k;
                          if (selKind == 'custom') {
                            global = members.isEmpty;
                          } else if (global) {
                            global = false;
                          }
                        }),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(kindExample(selKind),
                      style: const TextStyle(
                          color: AppTheme.gold, fontSize: 12)),
                ),
                TextField(
                    controller: labelC,
                    autofocus: true,
                    decoration: InputDecoration(
                        labelText: AppLocale.t('mk_name'),
                        hintText: AppLocale.t('mk_name_hint'))),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () =>
                            setD(() => count = (count - 1).clamp(-99, 99))),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('$count',
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                        icon: const Icon(Icons.add_circle,
                            color: AppTheme.gold),
                        onPressed: () =>
                            setD(() => count = (count + 1).clamp(-99, 99))),
                  ],
                ),
                if (selKind == 'custom')
                  CheckboxListTile(
                    value: global,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(AppLocale.t('mk_global'),
                        style: const TextStyle(fontSize: 14)),
                    subtitle: Text(AppLocale.t('mk_global_sub'),
                        style: const TextStyle(fontSize: 12)),
                    onChanged: (v) => setD(() {
                      global = v ?? true;
                      if (global) members.clear();
                    }),
                  ),
                if (selKind != 'custom' || !global) ...[
                  Text(
                      selKind == 'custom'
                          ? AppLocale.t('mk_members')
                          : AppLocale.t('mk_stamp_where'),
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 12)),
                  const SizedBox(height: 4),
                  if (_tokens.isEmpty)
                    Text(AppLocale.t('play_no_tokens'),
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 12)),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in _tokens)
                        FilterChip(
                          label: Text(t.name,
                              style: const TextStyle(fontSize: 12)),
                          selected: members.contains(t.id),
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setD(() {
                            if (!members.remove(t.id)) members.add(t.id);
                            if (selKind == 'custom') {
                              global = members.isEmpty;
                            }
                          }),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppLocale.t('common_cancel'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(AppLocale.t('common_save'))),
          ],
          ),
        ),
      ),
    );
    _laterDispose(labelC);
    if (ok != true) return;
    final useGlobal = selKind == 'custom' && global;
    _markerAdd(labelC.text, count, useGlobal ? [] : members.toList(),
        kind: selKind);
  }

  /// Detalhe do marcador: conta, membros (com atalho p/ a ficha) e excluir.
  Future<void> _markerSheet(_Marker mk, {bool upsideDown = false}) async {
    final entry = _markers
        .where((m) => m.id == mk.id)
        .firstOrNull;
    if (entry == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final cur = _markers
              .where((m) => m.id == mk.id)
              .firstOrNull;
          if (cur == null) {
            Navigator.pop(ctx);
            return const SizedBox.shrink();
          }
          final members = _markerMembers(cur);
          return RotatedBox(
            quarterTurns: upsideDown ? 2 : 0,
            child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(cur.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(
                      cur.kind == 'custom'
                          ? (cur.isGlobal
                              ? AppLocale.t('mk_global')
                              : AppLocale.t('mk_scope_n')
                                  .replaceAll('{n}', '${members.length}'))
                          : AppLocale.t('mk_kind_${cur.kind}'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 12)),
                  if (cur.kind != 'custom')
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                          cur.isGlobal
                              ? AppLocale.t('mk_global')
                              : AppLocale.t('mk_scope_n')
                                  .replaceAll('{n}', '${members.length}'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppTheme.gold, fontSize: 12)),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                          icon:
                              const Icon(Icons.remove_circle_outline, size: 30),
                          onPressed: () {
                            // plus/minus carimbam nas fichas junto.
                            if (cur.kind == 'custom') {
                              _markerSet(cur.id, count: cur.count - 1);
                            } else {
                              _markerAdjust(cur.id, -1);
                            }
                            setD(() {});
                          }),
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                            cur.kind == 'custom'
                                ? '×${cur.count}'
                                : '+${cur.count}',
                            style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold)),
                      ),
                      IconButton(
                          icon: const Icon(Icons.add_circle,
                              color: AppTheme.gold, size: 30),
                          onPressed: () {
                            if (cur.kind == 'custom') {
                              _markerSet(cur.id, count: cur.count + 1);
                            } else {
                              _markerAdjust(cur.id, 1);
                            }
                            setD(() {});
                          }),
                    ],
                  ),
                  if (!cur.isGlobal) ...[
                    const SizedBox(height: 4),
                    for (final t in members)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.style, size: 18),
                        title: Text(
                            '${t.name} ${t.power == 0 && t.toughness == 0 ? '◆' : '${effP(t)}/${effT(t)}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: cur.kind == 'plus'
                            ? Text('+${t.counters}/+${t.counters}',
                                style: const TextStyle(fontSize: 11))
                            : cur.kind == 'minus'
                                ? Text('−${t.minus}/−${t.minus}',
                                    style:
                                        const TextStyle(fontSize: 11))
                                : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.close,
                              size: 18, color: Colors.redAccent),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36),
                          onPressed: () {
                            final next = cur.memberIds
                                .where((id) => id != t.id)
                                .toList();
                            _markerSet(cur.id, memberIds: next);
                            setD(() {});
                          },
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _tokenOptions(t, upsideDown: upsideDown);
                        },
                      ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.person_add_alt, size: 16),
                          label: Text(AppLocale.t('mk_edit_members')),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _markerMembersDialog(cur,
                                upsideDown: upsideDown);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.redAccent),
                          label: Text(AppLocale.t('prof_delete')),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _markerRemove(cur.id);
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
        },
      ),
    );
  }

  /// Escolhe as fichas de dentro do marcador (multi-seleção).
  Future<void> _markerMembersDialog(_Marker mk,
      {bool upsideDown = false}) async {
    final sel = <int>{...mk.memberIds};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: AlertDialog(
            title: Text(AppLocale.t('mk_edit_members')),
            content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_tokens.isEmpty)
                  Text(AppLocale.t('play_no_tokens'),
                      style: const TextStyle(color: AppTheme.textMuted)),
                for (final t in _tokens)
                  CheckboxListTile(
                    value: sel.contains(t.id),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                        '${t.name} ${t.power == 0 && t.toughness == 0 ? '◆' : '${effP(t)}/${effT(t)}'}',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: t.owner.isEmpty
                        ? null
                        : Text(t.owner,
                            style: const TextStyle(fontSize: 11)),
                    onChanged: (v) => setD(() {
                      if (v == true) {
                        sel.add(t.id);
                      } else {
                        sel.remove(t.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppLocale.t('common_cancel'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(AppLocale.t('common_apply'))),
          ],
          ),
        ),
      ),
    );
    if (ok == true) _markerSet(mk.id, memberIds: sel.toList());
  }

  /// Botão discreto de marcadores (vai ao fim da fileira de mana):
  /// ícone apagado vazio, dourado com selo de quantidade quando há.
  /// Abre o quadro com os marcadores da mesa X.
  Widget _markerBtn({bool upsideDown = false}) {
    final n = _markers.length;
    return InkWell(
      onTap: () => _markersBoard(upsideDown: upsideDown),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.bookmark_outline,
                size: 16,
                color: n > 0 ? AppTheme.gold : AppTheme.textFaint),
            if (n > 0)
              Positioned(
                right: -5,
                top: -5,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppTheme.gold,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('$n',
                      style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.black)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Quadro dos marcadores da mesa: lista (detalhe ao tocar, ✕ exclui)
  /// + criar. Substitui a faixa fixa — não disputa tela.
  Future<void> _markersBoard({bool upsideDown = false}) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(AppLocale.t('mk_board'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                if (_markers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(AppLocale.t('mk_empty'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppTheme.textMuted)),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _markers.length,
                      itemBuilder: (_, k) {
                        final mk = _markers[k];
                        final members = _markerMembers(mk);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                              mk.kind == 'plus'
                                  ? Icons.arrow_upward
                                  : mk.kind == 'minus'
                                      ? Icons.arrow_downward
                                      : Icons.bookmark,
                              size: 18,
                              color: AppTheme.gold),
                          title: Text(
                              '${mk.label} ${mk.kind == 'custom' ? '×${mk.count}' : '+${mk.count}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontSize: 13)),
                          subtitle: Text(
                              mk.isGlobal
                                  ? AppLocale.t('mk_global')
                                  : AppLocale.t('mk_scope_n').replaceAll(
                                      '{n}', '${members.length}'),
                              style: const TextStyle(fontSize: 11)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: Colors.redAccent),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 36, minHeight: 36),
                            onPressed: () {
                              _markerRemove(mk.id);
                              setD(() {});
                            },
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _markerSheet(mk, upsideDown: upsideDown);
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(AppLocale.t('mk_new')),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _markerDialog(upsideDown: upsideDown);
                  },
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }

  // ============ MANA ============

  Map<String, int> _manaOf(String player) {
    return _mana.putIfAbsent(player, () => {for (final c in _manaColors) c: 0});
  }

  void _addManaRaw(String player, String color, int delta) {
    if (player.isEmpty) return;
    final pool = _manaOf(player);
    pool[color] = ((pool[color] ?? 0) + delta).clamp(0, 99);
  }

  void _manaAdd(String player, String color, int delta) {
    if (_isGuest) {
      _send({
        'action': 'mana_add',
        'player': player,
        'color': color,
        'delta': delta
      });
      return;
    }
    _recordHistory('$player: mana $color ${delta >= 0 ? '+' : ''}$delta');
    setState(() => _addManaRaw(player, color, delta));
    _broadcast();
  }

  /// Escolha da cor ao resolver Tesouro (pips oficiais, não bolinhas).
  Future<String?> _askManaColor({bool upsideDown = false}) async {
    return showDialog<String>(
      context: context,
      builder: (_) => RotatedBox(
        quarterTurns: upsideDown ? 2 : 0,
        child: AlertDialog(
          title: Text(AppLocale.t('su_mana_title')),
          content: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final c in _manaColors)
                InkWell(
                  onTap: () => Navigator.pop(context, c),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MtgPip(c, size: 38),
                      const SizedBox(height: 2),
                      Text(_manaName(c), style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ============ RESOLVER FICHA ============

  _UtilityAction _utilityAction(_Token t) {
    final name = t.name.toLowerCase().trim();
    if (name.contains('tesouro') ||
        name.contains('treasure') ||
        name == 'ouro' ||
        name == 'gold') {
      return _UtilityAction.treasure;
    }
    if (name.contains('comida') || name.contains('food')) {
      return _UtilityAction.food;
    }
    if (name.contains('pista') || name.contains('clue')) {
      return _UtilityAction.clue;
    }
    if (name.contains('sangue') || name.contains('blood')) {
      return _UtilityAction.blood;
    }
    if (name.contains('mapa') || name.contains('map')) {
      return _UtilityAction.map;
    }
    if (name.contains('pedra de poder') || name.contains('powerstone')) {
      return _UtilityAction.powerstone;
    }
    return _UtilityAction.none;
  }

  String _resolveLabel(_UtilityAction action) => switch (action) {
        _UtilityAction.treasure => AppLocale.t('rs_treasure'),
        _UtilityAction.food => AppLocale.t('rs_food'),
        _UtilityAction.clue => AppLocale.t('rs_clue'),
        _UtilityAction.blood => AppLocale.t('rs_blood'),
        _UtilityAction.map => AppLocale.t('rs_map'),
        _UtilityAction.powerstone => AppLocale.t('rs_powerstone'),
        _UtilityAction.none => AppLocale.t('rs_resolve'),
      };

  String _resolveExplanation(_UtilityAction action) => switch (action) {
        _UtilityAction.treasure => AppLocale.t('rsx_treasure'),
        _UtilityAction.food => AppLocale.t('rsx_food'),
        _UtilityAction.clue => AppLocale.t('rsx_clue'),
        _UtilityAction.blood => AppLocale.t('rsx_blood'),
        _UtilityAction.map => AppLocale.t('rsx_map'),
        _UtilityAction.powerstone => AppLocale.t('rsx_powerstone'),
        _UtilityAction.none => '',
      };

  Future<bool> _confirmResolution(_Token t, _UtilityAction action,
      {bool upsideDown = false}) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => RotatedBox(
            quarterTurns: upsideDown ? 2 : 0,
            child: AlertDialog(
              title: Text(_resolveLabel(action)),
              content: Text(_resolveExplanation(action)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(AppLocale.t('common_cancel'))),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(AppLocale.t('rs_resolve'))),
              ],
            ),
          ),
        ) ??
        false;
  }

  /// Ativa habilidade da ficha utilitária:
  /// aplica o resultado rastreável (vida, mana, virar ou sacrifício) e
  /// mostra os passos físicos que o jogador ainda precisa cumprir.
  Future<void> _activateToken(_Token t, {bool upsideDown = false}) async {
    final action = _utilityAction(t);
    if (action == _UtilityAction.none) return;
    if (t.tapped) {
      AppToast.show(context, 'Desvire a ficha antes de ativar.');
      return;
    }
    if (!await _confirmResolution(t, action, upsideDown: upsideDown)) return;
    String? color;
    if (action == _UtilityAction.treasure) {
      color = await _askManaColor(upsideDown: upsideDown);
      if (color == null) return;
    }
    if (_isGuest) {
      _send({'action': 'activate_utility', 'id': t.id, 'color': color});
      return;
    }
    _recordHistory('Resolveu ${t.name}');
    _resolveUtility(t, color: color);
  }

  void _resolveUtility(_Token t, {String? color}) {
    final action = _utilityAction(t);
    final owner = t.owner;
    final pIdx = _players.indexWhere((p) => p.name == owner);
    setState(() {
      if (action == _UtilityAction.treasure) {
        if (color != null) _addManaRaw(owner, color, 1);
        _tokens.removeWhere((e) => e.id == t.id);
      } else if (action == _UtilityAction.food) {
        if (pIdx >= 0) _players[pIdx].life += 3;
        _tokens.removeWhere((e) => e.id == t.id);
      } else if (action == _UtilityAction.powerstone) {
        _addManaRaw(owner, 'C', 1);
        t.tapped = true;
      } else if (action != _UtilityAction.none) {
        _tokens.removeWhere((e) => e.id == t.id);
      }
    });
    _broadcast();
    if (!mounted) return;
    final colorName = color == null ? '' : ' (+1 de mana ${_manaName(color)})';
    final msg = action == _UtilityAction.treasure
        ? 'Tesouro sacrificado$colorName'
        : action == _UtilityAction.food
            ? 'Comida sacrificada: $owner +3 de vida'
            : action == _UtilityAction.clue
                ? 'Pista sacrificada: compre um card'
                : action == _UtilityAction.blood
                    ? 'Sangue sacrificado: compre um card'
                    : action == _UtilityAction.map
                        ? 'Mapa sacrificado: explore!'
                        : action == _UtilityAction.powerstone
                            ? 'Pedra de poder virada: +1 mana incolor'
                            : 'Ficha resolvida';
    AppToast.show(context, msg);
  }

  void _roll(String label, int sides) {
    final v = _rand.nextInt(sides) + 1;
    _announce('$label: $v');
  }

  void _flipCoin() {
    _announce(_rand.nextBool() ? 'Moeda: cara' : 'Moeda: coroa');
  }

  /// Dados contextuais: rolam "como" o jogador do cartão (o resultado
  /// anunciado leva o nome dele, visível nos dois aparelhos).
  void _rollAs(String player, String label, int sides) {
    final v = _rand.nextInt(sides) + 1;
    _announce('$label ($player): $v');
  }

  void _flipAs(String player) {
    _announce('${_rand.nextBool() ? 'Moeda: cara' : 'Moeda: coroa'} ($player)');
  }

  /// Fileirinha de dados do cartão do jogador (d20, d6, moeda).
  Widget _diceRow(String player) {
    const cons = BoxConstraints(minWidth: 32, minHeight: 32);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.casino, size: 18),
          tooltip: AppLocale.t('su_dice20'),
          padding: EdgeInsets.zero,
          constraints: cons,
          onPressed: () => _rollAs(player, 'D20', 20),
        ),
        IconButton(
          icon: const Icon(Icons.filter_6, size: 18),
          tooltip: AppLocale.t('su_dice6'),
          padding: EdgeInsets.zero,
          constraints: cons,
          onPressed: () => _rollAs(player, 'D6', 6),
        ),
        IconButton(
          icon: const Icon(Icons.toll, size: 18),
          tooltip: AppLocale.t('su_coin'),
          padding: EdgeInsets.zero,
          constraints: cons,
          onPressed: () => _flipAs(player),
        ),
      ],
    );
  }

  /// Aviso visível nos DOIS aparelhos: guest pede, host mostra
  /// e repassa (flash) para todos.
  void _announce(String text) {
    if (_isGuest) {
      _send({'action': 'announce', 'text': text});
      return;
    }
    AppToast.show(context, text);
    _host?.flash(text);
  }

  // ================= UI =================

  /// Sem barra superior quando: foco da mesa OU imersão global.
  /// O corpo usa SafeArea na mesma condição (nunca atrás do status).
  bool get _noTopBar => _focusMode || !AppEvents.topVisible.value;

  @override
  Widget build(BuildContext context) {
    // Botão voltar do celular: primeiro sai do modo foco, depois pede
    // confirmação para sair da sala/mesa — nunca fecha o app de cara.
    // A página é uma aba (IndexedStack), então o "pop" aqui sairia do app.
    return PopScope(
      canPop: !_needsBackIntercept,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBackPressed();
      },
      child: Scaffold(
      appBar: _noTopBar
          ? null
          : AppBar(
              title: Row(
                children: [
                  Flexible(
                    child: Text(AppLocale.t('nav_play'),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (_isHost) ...[
                    const SizedBox(width: 8),
                    _netDot('$_peers'),
                  ],
                  if (_isGuest) ...[
                    const SizedBox(width: 8),
                    _netDot('•'),
                  ],
                  // Online (Firebase): igual ao LAN — ponto na topbar.
                  if (_isOnline && _onlineTotal() > 0) ...[
                    const SizedBox(width: 8),
                    _netDot('${_onlineTotal()}'),
                  ],
                ],
              ),
              actions: [
                // Online em sala: ⓘ abre o painel de conexão (sala,
                // identidade, perfil, jogadores) — igual à faixa.
                if (_isOnline &&
                    _sessions.values.any((s) => s.inRoom))
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    tooltip: AppLocale.t('on_conn_title'),
                    onPressed: _connectionSheet,
                  ),
                if (_inMatch)
                  IconButton(
                    icon: const Icon(Icons.palette_outlined),
                    tooltip: AppLocale.t('su_table'),
                    onPressed: _showTableThemes,
                  ),
                if (_inMatch)
                  IconButton(
                    icon: const Icon(Icons.fullscreen),
                    tooltip: AppLocale.t('play_focus'),
                    onPressed: _toggleFocusMode,
                  ),
                if (_inMatch && !_isGuest)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: AppLocale.t('su_reset_life'),
                    onPressed: _resetMatch,
                  ),
                if (_inMatch)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: AppLocale.t('su_end_match'),
                    onPressed: () async {
                      final go = await _confirmLeaveMatch();
                      if (go != true || !mounted) return;
                      await _exitMatchAndRoom();
                    },
                  ),
                // No setup, a caixa entra na imersão global; na partida,
                // o botão de foco da mesa já cobre isso (evita 2 iguais).
                if (!_inMatch)
                  IconButton(
                    icon: const Icon(Icons.fullscreen),
                    tooltip: AppLocale.t('common_focus'),
                    onPressed: AppEvents.toggleNav,
                  ),
              ],
            ),
      body: _inMatch ? _matchView() : _setupView(),
      ),
    );
  }

  /// Há algo para o voltar interceptar? Foco ativo ou partida em curso
  /// (sala online, mesa LAN ou local). Fora disso, o voltar sai do app.
  bool get _needsBackIntercept {
    if (_focusMode) return true;
    if (!_inMatch) return false;
    return true;
  }

  /// Voltar do celular: 1º sai do modo foco; 2º pede confirmação e sai
  /// da sala/mesa (sem fechar o app — a partida encerra e fica na aba).
  Future<void> _onBackPressed() async {
    if (_focusMode) {
      _toggleFocusMode();
      return;
    }
    if (!_inMatch || !mounted) return;
    final go = await _confirmLeaveMatch();
    if (go != true || !mounted) return;
    await _exitMatchAndRoom();
  }

  /// Diálogo de confirmação antes de sair da sala/mesa. Texto conforme
  /// o modo: sala online (com código), mesa LAN hospedada ou partida.
  /// [session] restringe àquela sessão (botão "Sair da sala" do painel).
  Future<bool?> _confirmLeaveMatch({_NetSession? session}) {
    var body = AppLocale.t('play_exit_match_body');
    final code = (session?.roomCode.trim().isNotEmpty ?? false)
        ? session!.roomCode.trim()
        : (_primaryRoomCode.trim().isNotEmpty
            ? _primaryRoomCode.trim()
            : _sessions.values
                .map((s) => s.roomCode.trim())
                .firstWhere((c) => c.isNotEmpty, orElse: () => ''));
    if (_isOnline || session != null) {
      body = AppLocale.t('play_exit_room_body')
          .replaceAll('{c}', code.isEmpty ? '…' : code);
    } else if (_host != null || _hosting) {
      body = AppLocale.t('play_exit_host_body');
    }
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('play_exit_title')),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('common_leave'))),
        ],
      ),
    );
  }

  /// Encerra partida e sai da sala/sessão (online derruba as sessões;
  /// LAN guest desconecta; LAN host fecha a mesa). Usado pelo ✕ e pelo
  /// voltar — sempre depois de [_confirmLeaveMatch].
  Future<void> _exitMatchAndRoom() async {
    if (_focusMode) _toggleFocusMode();
    // Online (host ou guest): derruba TODAS as sessões e apaga a sala
    // do host. LAN guest: desconecta. LAN host: fecha a mesa.
    if (_isOnline || _isGuest) {
      await _leaveMatch();
      return;
    }
    if (_host != null) {
      await _stopHosting();
    }
    if (mounted) {
      setState(() {
        _hosting = false;
        _inMatch = false;
      });
    }
    await _clearSavedMatch();
  }

  void _toggleFocusMode() {
    setState(() => _focusMode = !_focusMode);
    AppEvents.navVisible.value = !_focusMode;
    AppEvents.playFocusActive.value = _focusMode;
  }

  /// Aplica tema/fundo na mesa de UM jogador (nunca global).
  /// Local: muda direto o jogador escolhido. Online/LAN: autoridade
  /// (host) aplica e republica; guest aplica otimista e pede ao host
  /// via ação `visual` (ele valida, aplica e republica para todos).
  /// O nó da sala acompanha (lista/entrada tardia) pela sessão dona.
  Future<void> _applyPlayerVisual(int idx,
      {String? theme, String? bg}) async {
    if (idx < 0 || idx >= _players.length) return;
    final nextTheme = theme ?? _players[idx].theme;
    final nextBg = bg ?? _players[idx].bg;
    if (nextTheme.isNotEmpty && !_tableStyles.containsKey(nextTheme)) return;
    if (nextBg.isNotEmpty &&
        !tableBackgrounds.any((b) => b.id == nextBg)) return;
    final target = _players[idx];
    if (target.theme == nextTheme && target.bg == nextBg) return;
    _recordHistory('Trocou o visual da mesa (${target.name})');
    setState(() {
      target.theme = nextTheme;
      target.bg = nextBg;
      // Guarda meu fundo p/ próximas salas (só quando é a minha mesa).
      if ((_isOnline || _host != null || _guest != null) &&
          _isLocalPlayerIdx(idx)) {
        _myTableBg = nextBg;
      }
    });
    final isNet = _isOnline || _host != null || _guest != null;
    final canPublish = !isNet ||
        (!_isOnline && _host != null) ||
        (_isOnline && _hostSession != null);
    if (isNet && !canPublish) {
      _send({
        'action': 'visual',
        'player': target.name,
        'theme': nextTheme,
        'bg': nextBg,
      });
    } else {
      _broadcast();
    }
    if (_isOnline) {
      final key = target.name.trim().toLowerCase();
      for (final s in _sessions.values) {
        if (!s.inRoom || s.net == null) continue;
        if (s.displayName.trim().toLowerCase() != key) continue;
        try {
          await s.net!.updatePlayerVisual(theme: nextTheme, bg: nextBg);
        } catch (_) {}
      }
    }
  }

  /// Sheet "Visual da mesa": tema + fundo da mesa de UM jogador.
  /// Online/LAN mostra só as minhas mesas (cada um muda a sua);
  /// no local escolho qual mesa estou mudando (uma por jogador).
  /// Aplica na hora (sem fechar) para dar para ajustar tema e fundo.
  Future<void> _showTableThemes() async {
    if (_players.isEmpty) return;
    final isNet = _isOnline || _host != null || _guest != null;
    List<int> editable;
    if (!isNet) {
      editable = [for (var i = 0; i < _players.length; i++) i];
    } else if (_isOnline) {
      editable = [
        for (var i = 0; i < _players.length; i++)
          if (_isLocalPlayerIdx(i)) i
      ];
    } else {
      final me = _myName.trim().toLowerCase();
      editable = [
        for (var i = 0; i < _players.length; i++)
          if (me.isNotEmpty &&
              _players[i].name.trim().toLowerCase() == me)
            i
      ];
    }
    var sel = editable.isEmpty ? -1 : editable.first;
    if (editable.contains(_arenaSel)) sel = _arenaSel;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          if (sel < 0 || sel >= _players.length) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(AppLocale.t('play_visual_mine_only'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.textMuted)),
              ),
            );
          }
          final cur = _players[sel];
          var bgLabel = AppLocale.t('su_bg_none');
          for (final b in tableBackgrounds) {
            if (b.id == cur.bg) {
              bgLabel = b.label;
              break;
            }
          }
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              // Rolável: com 6 temas a lista passa da altura em landscape.
              child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(AppLocale.t('su_table'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      if (isNet)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                              AppLocale.t('play_visual_mine_only'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppTheme.textMuted, fontSize: 12)),
                        ),
                      if (editable.length > 1) ...[
                        const SizedBox(height: 10),
                        Text(AppLocale.t('play_visual_pick'),
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final i in editable)
                              ChoiceChip(
                                label: Text(_players[i].name),
                                selected: sel == i,
                                onSelected: (_) => setD(() => sel = i),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _themeSwatch(_tableStyle),
                        title:
                            Text(AppLocale.t('play_visual_default')),
                        trailing: cur.theme.isEmpty
                            ? Icon(Icons.check,
                                color: _tableStyle.accent)
                            : null,
                        onTap: () async {
                          await _applyPlayerVisual(sel, theme: '');
                          if (ctx.mounted) {
                            setD(() {});
                          }
                        },
                      ),
                      for (final entry in _tableStyles.entries)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: _themeSwatch(entry.value),
                          title: Text(AppLocale.t(entry.value.name)),
                          trailing: cur.theme == entry.key
                              ? Icon(Icons.check,
                                  color: entry.value.accent)
                              : null,
                          onTap: () async {
                            await _applyPlayerVisual(sel,
                                theme: entry.key);
                            if (ctx.mounted) {
                              setD(() {});
                            }
                          },
                        ),
                      const Divider(height: 16),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _bgThumb(cur.bg, w: 40, h: 28),
                        title: Text(AppLocale.t('su_bg')),
                        subtitle: Text(bgLabel,
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                        trailing: const Icon(Icons.chevron_right, size: 20),
                        onTap: () => _bgPickerSheet(
                          current: cur.bg,
                          onPick: (v) async {
                            await _applyPlayerVisual(sel, bg: v);
                            if (ctx.mounted) {
                              setD(() {});
                            }
                          },
                        ),
                      ),
                    ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _netDot(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.goldSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
                color: Colors.green, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(color: AppTheme.gold, fontSize: 11)),
        ],
      ),
    );
  }

  // ================= SETUP =================

  Widget _setupView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(AppLocale.t('su_how'),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              avatar: const Icon(Icons.phone_android, size: 18),
              label: Text(AppLocale.t('su_local')),
              selected: _playMode == _PlayMode.local,
              onSelected: (_) => setState(() => _playMode = _PlayMode.local),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.wifi, size: 18),
              label: Text(AppLocale.t('su_lan')),
              selected: _playMode == _PlayMode.lan,
              onSelected: (_) => setState(() => _playMode = _PlayMode.lan),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.cloud_outlined, size: 18),
              label: Text(AppLocale.t('on_title')),
              selected: _playMode == _PlayMode.online,
              onSelected: (_) => setState(() => _playMode = _PlayMode.online),
            ),
          ],
        ),
        // Formato da mesa LAN/Online: Arena (única, nova) ou Legacy.
        if (_playMode == _PlayMode.lan ||
            _playMode == _PlayMode.online) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text(AppLocale.t('fmt_title'),
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: PlayPrefs.tableFormat,
                  builder: (_, fmt, __) => SegmentedButton<String>(
                    style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(
                          value: 'arena',
                          icon: Icon(Icons.groups_outlined, size: 14),
                          label: Text('Arena',
                              style: TextStyle(fontSize: 12))),
                      ButtonSegment(
                          value: 'legacy',
                          icon: Icon(Icons.view_agenda_outlined, size: 14),
                          label: Text('Legacy',
                              style: TextStyle(fontSize: 12))),
                    ],
                    selected: {fmt},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        PlayPrefs.setTableFormat(s.first),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        // Conexão/jogadores primeiro: Online e LAN aparecem sem scroll.
        if (_playMode == _PlayMode.lan) ...[
          _networkCard(),
          const SizedBox(height: 8),
          Text(AppLocale.t('su_lan_hint'),
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ] else if (_playMode == _PlayMode.online) ...[
          _onlineCard(),
          const SizedBox(height: 8),
          Text(AppLocale.t('on_hint'),
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ] else ...[
          Text(AppLocale.t('su_who'),
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          for (var i = 0; i < _playerCount; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameCtrls[i],
                      decoration: InputDecoration(
                          labelText:
                              '${AppLocale.t('su_player')} ${i + 1}'),
                    ),
                  ),
                  // Lado na mesa (só faz diferença com 3+).
                  IconButton(
                    icon: Icon(
                        (_playerSides.length > i && _playerSides[i])
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 18),
                    color: (_playerSides.length > i && _playerSides[i])
                        ? AppTheme.gold
                        : AppTheme.textMuted,
                    tooltip:
                        '${AppLocale.t('su_side_top')}/${AppLocale.t('su_side_bottom')}',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 34, minHeight: 34),
                    onPressed: () => setState(() {
                      while (_playerSides.length <= i) {
                        _playerSides.add(_playerSides.length >= 2);
                      }
                      _playerSides[i] = !_playerSides[i];
                    }),
                  ),
                  // Tema da mesa deste jogador.
                  PopupMenuButton<String>(
                    icon: CircleAvatar(
                        radius: 10,
                        backgroundColor:
                            (_tableStyles[_playerThemes.length > i
                                        ? _playerThemes[i]
                                        : ''] ??
                                    _tableStyle)
                                .accent),
                    tooltip: AppLocale.t('su_theme'),
                    padding: EdgeInsets.zero,
                    onSelected: (v) => setState(() {
                      while (_playerThemes.length <= i) {
                        _playerThemes.add('');
                      }
                      _playerThemes[i] = v;
                    }),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                          value: '',
                          child: Text(AppLocale.t('su_table_sub'))),
                      for (final e in _tableStyles.entries)
                        PopupMenuItem(
                          value: e.key,
                          child: Row(children: [
                            _themeSwatch(e.value, r: 8),
                            const SizedBox(width: 8),
                            Text(AppLocale.t(e.value.name)),
                          ]),
                        ),
                    ],
                  ),
                  // Fundo da mesa (visual, com prévia de como fica).
                  if (tableBackgrounds.isNotEmpty)
                    InkWell(
                      onTap: () => _bgPickerSheet(
                        current: _playerBgs.length > i
                            ? _playerBgs[i]
                            : '',
                        onPick: (v) => setState(() {
                          while (_playerBgs.length <= i) {
                            _playerBgs.add('');
                          }
                          _playerBgs[i] = v;
                        }),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _bgThumb(_playerBgs.length > i
                            ? _playerBgs[i]
                            : ''),
                      ),
                    ),
                ],
              ),
            ),
          if (_friends.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(AppLocale.t('su_tap_friend'),
                style: const TextStyle(color: AppTheme.textMuted)),
            Wrap(
              spacing: 8,
              children: [
                for (final f in _friends)
                  ActionChip(
                    avatar: const Icon(Icons.person, size: 16),
                    label: Text((f['name'] ?? '?').toString()),
                    onPressed: () {
                      final prefix = '${AppLocale.t('su_player')} ';
                      final you = AppLocale.t('su_you');
                      final empty = _nameCtrls.indexWhere((c) =>
                          c.text.trim().isEmpty ||
                          c.text.startsWith(prefix) ||
                          c.text.trim() == you);
                      final target = empty == -1 ? 0 : empty;
                      setState(() => _nameCtrls[target].text =
                          (f['name'] ?? '').toString());
                    },
                  ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 12),
        // Guest esperando: só a espera (formato/vida/tema são do host).
        if (_isWaitingGuest) ...[
          _waitingCard(),
        ] else ...[
          _formatCard(),
          const SizedBox(height: 12),
          // Visual global só fora do local: no local cada jogador já
          // tem tema+fundo próprios no "Quem joga?" acima.
          if (_playMode != _PlayMode.local) ...[
            _tableThemeCard(),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 16),
        if (_playMode == _PlayMode.local)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _startMatch,
              icon: const Icon(Icons.play_arrow),
              label: Text(AppLocale.t('su_start')),
            ),
          ),
      ],
    );
  }

  /// Esperando o host começar (guest online na sala ou guest LAN
  /// conectado, sem partida e sem autoridade): tela de espera — sem
  /// formato, vida inicial ou tema (tudo é do host).
  bool get _isWaitingGuest {
    if (_inMatch) return false;
    if (_hostSession != null || _host != null || _hosting) return false;
    if (_isOnline) {
      return _sessions.values.any((s) => s.inRoom && !s.hosting);
    }
    if (_playMode == _PlayMode.lan) return _guest != null;
    return false;
  }

  /// Cartão de espera do guest (sem nada configurável).
  Widget _waitingCard() {
    final code = _firstInRoom?.roomCode.trim() ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppLocale.t('on_wait_host'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  if (code.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                          '${AppLocale.t('on_room')}: $code',
                          style: const TextStyle(
                              color: AppTheme.gold,
                              fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _formatCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLocale.t('su_format'),
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            DropdownButton<String>(
              value: _format,
              isExpanded: true,
              items: _formats.entries
                  .map((e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(AppLocale.t('su_life_of')
                          .replaceAll('{n}', _formatLabel(e.key))
                          .replaceAll('{l}', '${e.value.$2}'))))
                  .toList(),
              onChanged: _setFormat,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(AppLocale.t('su_startlife')),
                IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => setState(
                        () => _startLife = (_startLife - 1).clamp(1, 99))),
                Text('$_startLife',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                    icon: const Icon(Icons.add_circle, color: AppTheme.gold),
                    onPressed: () => setState(
                        () => _startLife = (_startLife + 1).clamp(1, 99))),
              ],
            ),
            if (_playMode == _PlayMode.local)
              Row(
                children: [
                  Text(AppLocale.t('su_players_mode')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SegmentedButton<int>(
                      style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      segments: [
                        for (var n = 1; n <= 6; n++)
                          ButtonSegment(
                              value: n,
                              label: Text('$n',
                                  style:
                                      const TextStyle(fontSize: 12))),
                      ],
                      selected: {_playerCount.clamp(1, 6)},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => setState(() {
                        _playerCount = s.first.clamp(1, 6);
                        _resetNameCtrls();
                      }),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _tableThemeCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(AppLocale.t('su_table'),
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final entry in _tableStyles.entries)
              ChoiceChip(
                selected: _tableTheme == entry.key,
                avatar: _themeSwatch(entry.value, r: 7),
                label: Text(AppLocale.t(entry.value.name)),
                onSelected: (_) => setState(() => _tableTheme = entry.key),
              ),
          ]),
          const SizedBox(height: 6),
          Text(AppLocale.t('su_table_sub'),
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ]),
      ),
    );
  }

  /// Wi-Fi/LAN compacto: ações, IP, jogadores, pares na rede.
  /// Mesma estrutura do cartão Online (título, ações, conexão,
  /// jogadores, lista auxiliar).
  Widget _networkCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi, size: 16, color: AppTheme.gold),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(AppLocale.t('su_net'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ],
            ),
            // Fundo da MINHA mesa no LAN (thumb com prévia).
            if (tableBackgrounds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Text(AppLocale.t('su_bg'),
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 12)),
                    const Spacer(),
                    InkWell(
                      onTap: () => _bgPickerSheet(
                        current: _myTableBg,
                        onPick: (v) =>
                            setState(() => _myTableBg = v),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: _bgThumb(_myTableBg, w: 40, h: 28),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _hosting ? null : _startHosting,
                    icon: const Icon(Icons.router, size: 16),
                    label: Text(AppLocale.t('su_host')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_hosting || _guest != null) ? null : _joinMatch,
                    icon: const Icon(Icons.login, size: 16),
                    label: Text(AppLocale.t('su_join')),
                  ),
                ),
              ],
            ),
            if (_hosting) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Clipboard.setData(
                            ClipboardData(text: '$_hostIp:${LanMatch.port}'));
                        AppToast.show(
                            context,
                            AppLocale.t('prof_copied').replaceAll(
                                '{c}', '$_hostIp:${LanMatch.port}'));
                      },
                      child: Text(
                          '$_hostIp:${LanMatch.port}'
                          '${_hostIps.length > 1 ? ' (${_hostIpIdx + 1}/${_hostIps.length})' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppTheme.gold,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  if (_hostIps.length > 1)
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: AppLocale.t('su_other_ip'),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: () => setState(() {
                        _hostIpIdx = (_hostIpIdx + 1) % _hostIps.length;
                        _hostIp = _hostIps[_hostIpIdx];
                      }),
                    ),
                ],
              ),
              Text(
                  '${AppLocale.t('lan_players')} • ${AppLocale.t('su_connected').replaceAll('{n}', '$_peers')}',
                  style:
                      const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
              for (final p in _players)
                _netPlayerRow(
                  online: true,
                  title:
                      '${p.name}${p.name == _myName ? ' ${AppLocale.t('on_you')}' : ''}${_fakePlayers.contains(p.name) ? ' (${AppLocale.t('lan_fake')})' : ''}',
                ),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _stopHosting,
                    icon: const Icon(Icons.close, size: 16),
                    label: Text(AppLocale.t('su_close')),
                  ),
                  const Spacer(),
                  // Discreto: simula oponente sem 2º celular.
                  TextButton.icon(
                    onPressed: _addFakePlayer,
                    icon: const Icon(Icons.person_add_alt, size: 14),
                    label: Text(AppLocale.t('su_fake'),
                        style: const TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.textFaint,
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ],
            if (_guest == null && !_hosting) ...[
              const SizedBox(height: 6),
              TextField(
                controller: _joinIp,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                  hintText: AppLocale.t('su_ip_hint'),
                  prefixIcon: const Icon(Icons.wifi),
                ),
              ),
            ],
            if (_joining)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text(AppLocale.t('su_connecting'),
                        style: const TextStyle(color: AppTheme.textMuted)),
                  ],
                ),
              ),
            _peersSection(),
          ],
        ),
      ),
    );
  }

  /// Sala online (pela internet, via Firebase). Três estados:
  /// sem sala (criar/entrar), esperando (código + jogadores) e
  /// sincronizando (transição para a mesa).
  /// Cartão Online: criar/entrar quando vazio; um bloco por sessão
  /// quando há sessões (cada uma com sala, identidade e status
  /// próprios) + "Conectar este perfil" para a segunda sessão.
  Widget _onlineCard() {
    final sessions = _activeSessions;
    final anyJoining = sessions.any((s) => s.joining);
    // "Conectar este perfil": <2 sessões, perfil atual ainda não
    // conectado e sem partida em outra sala.
    final profileConnected = sessions.any((s) =>
        s.inRoom &&
        s.profileId.isNotEmpty &&
        _profileId.isNotEmpty &&
        s.profileId == _profileId);
    final canSecond = sessions.length < _maxSessions &&
        !profileConnected &&
        !_inMatch &&
        (_host == null && _guest == null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_outlined,
                    size: 16, color: AppTheme.gold),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(AppLocale.t('on_net'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ],
            ),
            // Fundo da MINHA mesa no online (vai no roster da sala).
            if (tableBackgrounds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Text(AppLocale.t('su_bg'),
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 12)),
                    const Spacer(),
                    InkWell(
                      onTap: () => _bgPickerSheet(
                        current: _myTableBg,
                        onPick: (v) =>
                            setState(() => _myTableBg = v),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: _bgThumb(_myTableBg, w: 40, h: 28),
                      ),
                    ),
                  ],
                ),
              ),
            for (final b in _sessionMismatchBanners())
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: b,
              ),
            _roomInviteInbox(),
            _friendsRoomsSection(),
            const SizedBox(height: 6),
            if (sessions.isEmpty) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: anyJoining ? null : _createOnlineRoom,
                  icon: const Icon(Icons.cloud_outlined, size: 16),
                  label: Text(AppLocale.t('on_create')),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _joinCodeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        hintText: AppLocale.t('on_code_hint'),
                        prefixIcon: const Icon(Icons.key),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: anyJoining ? null : () => _joinOnlineRoom(),
                    icon: const Icon(Icons.login, size: 16),
                    label: Text(AppLocale.t('su_join')),
                  ),
                ],
              ),
              if (anyJoining)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Text(AppLocale.t('on_sync'),
                          style: const TextStyle(color: AppTheme.textMuted)),
                    ],
                  ),
                ),
              if (_joinCodeCtrl.text.trim().isNotEmpty && !anyJoining)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () =>
                          _attachSession('a', _joinCodeCtrl.text.trim()),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text(AppLocale.t('lan_reconnect')),
                    ),
                  ),
                ),
            ] else ...[
              for (var i = 0; i < sessions.length; i++) ...[
                if (i > 0) const Divider(),
                _sessionSection(sessions[i], i + 1),
              ],
              if (canSecond)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      // Reutiliza o código da primeira sessão se o campo
                      // estiver vazio (mesma sala, outro UID/perfil).
                      onPressed: () {
                        if (_joinCodeCtrl.text.trim().isEmpty) {
                          final code = sessions
                              .where((s) => s.inRoom)
                              .map((s) => s.roomCode)
                              .firstOrNull;
                          if (code != null && code.isNotEmpty) {
                            setState(() => _joinCodeCtrl.text = code);
                          }
                        }
                        _joinOnlineRoom();
                      },
                      icon: const Icon(Icons.person_add_alt, size: 16),
                      label: Text(AppLocale.t('on_connect_profile')),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Convites de sala recebidos (Firebase): entrar consome o convite
  /// e entra com o código; recusar só consome.
  Widget _roomInviteInbox() {
    final stream = _inviteStream;
    if (_fbUid.isEmpty || stream == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<List<RoomInvite>>(
      stream: stream,
      builder: (_, snap) {
        final invites = (snap.data ?? [])
            .where((i) => i.roomCode.trim().isNotEmpty)
            .take(3)
            .toList();
        if (invites.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(AppLocale.t('fr_invites'),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                  InkWell(
                    onTap: () =>
                        _watchInvites(_fbUid, force: true),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.refresh,
                          size: 16, color: AppTheme.textMuted),
                    ),
                  ),
                ],
              ),
            ),
            for (final inv in invites)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                          '${AppLocale.t('fr_invite_body').replaceAll('{n}', inv.fromName)} (${inv.roomCode})',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: () async {
                        await _friendsApi.consumeRoomInvite(_fbUid, inv.id);
                        if (!mounted) return;
                        setState(() => _joinCodeCtrl.text = inv.roomCode);
                        await _joinOnlineRoom();
                      },
                      child: Text(AppLocale.t('fr_enter')),
                    ),
                    TextButton(
                      onPressed: () =>
                          _friendsApi.consumeRoomInvite(_fbUid, inv.id),
                      child: Text(AppLocale.t('fr_decline'),
                          style: const TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// Salas onde os amigos estão AGORA (presença): entrar com 1 toque,
  /// sem digitar código e sem esperar convite.
  Widget _friendsRoomsSection() {
    if (_fbUid.isEmpty) return const SizedBox.shrink();
    final inRoom = <OnlineFriend, String>{};
    for (final f in _fbRoomFriends) {
      final pres = _fbRoomPresence[f.uid];
      final online = (pres?['online'] as bool?) ?? false;
      final room = (pres?['room'] ?? '').toString().trim().toUpperCase();
      if (online && room.isNotEmpty) inRoom[f] = room;
    }
    if (inRoom.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(AppLocale.t('fr_rooms'),
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        for (final e in inRoom.entries)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                      color: Colors.green, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      '${e.key.name} • ${AppLocale.t('on_room')}: ${e.value}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () async {
                    setState(() => _joinCodeCtrl.text = e.value);
                    await _joinOnlineRoom();
                  },
                  child: Text(AppLocale.t('fr_enter')),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Bloco de UMA sessão: número, identidade, sala, status e espera.
  Widget _sessionSection(_NetSession s, int n) {
    final status = !s.inRoom
        ? AppLocale.t('on_st_waiting')
        : s.started
            ? AppLocale.t('on_st_connected')
            : AppLocale.t('on_st_waiting');
    final dot =
        s.inRoom && (!s.started || _inMatch) ? Colors.green : Colors.grey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  '${AppLocale.t('on_session_n').replaceAll('{n}', '$n')} • $status',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            IconButton(
              icon: const Icon(Icons.logout, size: 16),
              tooltip: AppLocale.t('on_leave'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () async {
                final go = await _confirmLeaveMatch(session: s);
                if (go != true || !mounted) return;
                _leaveSession(s);
              },
            ),
          ],
        ),
        Text(
            '${AppLocale.t('on_as').replaceAll('{n}', s.displayName.isEmpty ? '…' : s.displayName)}'
            '${s.roomCode.isNotEmpty ? ' • ${AppLocale.t('on_room')}: ${s.roomCode}' : ''}',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        if (s.joining)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (s.inRoom && !s.started && !_inMatch)
          _onlineWaiting(s)
        else if (s.inRoom && s.started && !_inMatch)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(AppLocale.t('on_sync'),
                    style: const TextStyle(color: AppTheme.textMuted)),
              ],
            ),
          ),
      ],
    );
  }

  /// Sala de espera de UMA sessão: código, estado, jogadores,
  /// entrada tardia (host), começar/sair. Limpa, sem técnica.
  Widget _onlineWaiting(_NetSession s) {
    final entries = _sortedOnlinePlayers(s);
    final myUid = s.myUid ?? '';
    final count = entries.length;
    final full = count >= s.maxPlayers;
    final stateText = full
        ? AppLocale.t('on_st_full')
        : !s.started
            ? AppLocale.t('on_waiting')
            : s.allowLateJoin
                ? AppLocale.t('on_st_open')
                : AppLocale.t('on_st_locked');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SelectableText(
                s.roomCode,
                style: const TextStyle(
                    color: AppTheme.gold,
                    fontWeight: FontWeight.bold,
                    fontSize: 28,
                    letterSpacing: 4),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: AppLocale.t('prof_copy'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: s.roomCode));
                AppToast.show(context,
                    AppLocale.t('prof_copied').replaceAll('{c}', s.roomCode));
              },
            ),
          ],
        ),
        Text(
            '$stateText • ${AppLocale.t('on_count').replaceAll('{n}', '$count').replaceAll('{m}', '${s.maxPlayers}')}',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        const SizedBox(height: 4),
        Text(AppLocale.t('on_players'),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        for (final e in entries)
          _netPlayerRow(
            online: ((e.value['connected'] as bool?) ?? true),
            title:
                '${(e.value['name'] ?? '?')}${e.key == myUid ? ' ${AppLocale.t('on_you')}' : ''}',
            trailing: s.hosting && e.key != myUid && s.net != null
                ? IconButton(
                    icon: const Icon(Icons.close,
                        size: 16, color: Colors.redAccent),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    onPressed: () async {
                      try {
                        await s.net!.kick(e.key);
                      } catch (err) {
                        if (mounted) {
                          AppToast.show(context,
                              AppLocale.t('on_fail').replaceAll('{e}', '$err'));
                        }
                      }
                    },
                  )
                : null,
          ),
        if (!full)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(AppLocale.t('on_wait_dot'),
                style:
                    const TextStyle(color: AppTheme.textFaint, fontSize: 12)),
          ),
        if (s.hosting)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary:
                const Icon(Icons.timer_outlined, color: AppTheme.textMuted),
            title: Text(AppLocale.t('on_late'),
                style: const TextStyle(fontSize: 13)),
            subtitle: Text(AppLocale.t('on_late_sub'),
                style: const TextStyle(fontSize: 11)),
            value: s.allowLateJoin,
            onChanged: (v) => _setLateJoin(s, v),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (s.hosting)
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (s.joining || count < 1)
                      ? null
                      : () => _startOnlineMatch(s),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(AppLocale.t('on_start')),
                ),
              )
            else
              Expanded(
                child: Text(AppLocale.t('on_wait_host'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.textMuted)),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final go = await _confirmLeaveMatch(session: s);
                  if (go != true || !mounted) return;
                  _leaveSession(s);
                },
                icon: const Icon(Icons.logout, size: 16),
                label: Text(AppLocale.t('on_leave')),
              ),
            ),
          ],
        ),
        if (s.hosting)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _inviteFriendsSheet(s),
                icon: const Icon(Icons.person_add_alt, size: 16),
                label: Text(AppLocale.t('fr_invite_title')),
              ),
            ),
          ),
      ],
    );
  }

  /// Checklist de amigos para convidar à sala. Usa SEMPRE a identidade
  /// padrão (_fbUid/_friendsApi, onde moram amizades, presença e caixa
  /// de entrada) — a auth da sessão varia por slot (UIDs secundários
  /// sem amigos) e o convite se perdia.
  Future<void> _inviteFriendsSheet(_NetSession s) async {
    if (s.net == null || !s.inRoom) return;
    final api = _friendsApi;
    var myUid = _fbUid;
    if (myUid.isEmpty) {
      try {
        myUid = await api.myUid;
      } catch (_) {}
    }
    if (!mounted) return;
    final selected = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setD) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                      '${AppLocale.t('fr_invite_title')} • ${s.roomCode}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                FutureBuilder<List<OnlineFriend>>(
                  future: myUid.isEmpty
                      ? Future.value(<OnlineFriend>[])
                      : api.friendsOnce(myUid),
                  builder: (_, snap) {
                    if (!snap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final friends = snap.data!;
                    if (friends.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(AppLocale.t('fr_invite_empty'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppTheme.textMuted)),
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final f in friends)
                          CheckboxListTile(
                            dense: true,
                            title: Text(f.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(f.code,
                                style: const TextStyle(
                                    color: AppTheme.textMuted, fontSize: 12)),
                            value: selected.contains(f.uid),
                            onChanged: (v) => setD(() {
                              if (v == true) {
                                selected.add(f.uid);
                              } else {
                                selected.remove(f.uid);
                              }
                            }),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: selected.isEmpty
                                  ? null
                                  : () async {
                                      final targets = selected.toList();
                                      Navigator.pop(ctx);
                                      for (final uid in targets) {
                                        try {
                                          final fromName = s.displayName
                                                  .trim()
                                                  .isNotEmpty
                                              ? s.displayName.trim()
                                              : _profileName.trim();
                                          await api.sendRoomInvite(
                                            toUid: uid,
                                            fromName: fromName,
                                            roomCode: s.roomCode,
                                          );
                                        } catch (_) {}
                                      }
                                      if (mounted) {
                                        AppToast.show(context,
                                            AppLocale.t('fr_invite_sent'));
                                      }
                                    },
                              icon: const Icon(Icons.send, size: 16),
                              label: Text(AppLocale.t('fr_invite_send')),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _setLateJoin(_NetSession s, bool v) async {
    if (s.net == null || !s.hosting || !s.inRoom) return;
    try {
      await s.net!.setLateJoin(v);
      if (mounted) setState(() => s.allowLateJoin = v);
    } catch (e) {
      if (mounted) {
        AppToast.show(context, AppLocale.t('on_fail').replaceAll('{e}', '$e'));
      }
    }
  }

  /// Linha de jogador unificada (LAN e Online): bolinha + nome + ação.
  Widget _netPlayerRow(
      {required bool online, required String title, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: online ? Colors.green : Colors.grey,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  // ================= PARTIDA =================

  /// Zona da mesa: meu índice, minhas fichas, deles e mesa.
  /// "Eu" primeiro por UID (s reference), senão por nome (legado).
  int get _meIndex {
    for (var i = 0; i < _players.length; i++) {
      final p = _players[i];
      if (p.uid.isNotEmpty && _localUids.contains(p.uid)) return i;
    }
    final me = _myName.trim();
    if (me.isNotEmpty) {
      final i = _players.indexWhere((p) => p.name == me);
      if (i != -1) return i;
    }
    return 0;
  }

  List<int> get _otherIdx => [
        for (var i = 0; i < _players.length; i++)
          if (i != _meIndex) i
      ];
  List<_Token> get _mineTokens {
    if (_players.isEmpty) return _tokens;
    final me = _players[_meIndex.clamp(0, _players.length - 1)];
    return _tokens.where((t) => _sameIdentity(t, me)).toList();
  }

  List<_Token> get _sharedTokens {
    if (_players.isEmpty) return [];
    bool known(_Token t) {
      for (var i = 0; i < _players.length; i++) {
        if (_sameIdentity(t, _players[i])) return true;
      }
      return false;
    }

    return _tokens.where((t) => !known(t)).toList();
  }

  /// Fichas de um jogador específico (por identidade, não por nome).
  List<_Token> _tokensOf(_MatchPlayer p) {
    return _tokens.where((t) => _sameIdentity(t, p)).toList();
  }

  bool _isLocalPlayerIdx(int i) {
    if (i < 0 || i >= _players.length) return false;
    final p = _players[i];
    return _isLocalIdentity(p.uid, p.name);
  }

  /// Oponentes REMOTOS: no modo dual (2 perfis aqui), as identidades
  /// locais têm zona própria e saem desta lista.
  List<int> get _remoteIdx {
    if (!_isDualMode) return _otherIdx;
    return [
      for (final i in _otherIdx)
        if (!_isLocalPlayerIdx(i)) i
    ];
  }

  /// Sessões locais na mesma sala com partida rolando: modo dual,
  /// uma zona de mesa por identidade (A e B no mesmo aparelho).
  List<_NetSession> get _dualSessions {
    if (!_isOnline || !_inMatch) return [];
    final locals = [
      for (final s in _sessions.values)
        if (s.inRoom) s
    ];
    if (locals.length < 2) return [];
    final code = locals.first.roomCode;
    if (locals.any((s) => s.roomCode != code)) return [];
    return locals;
  }

  bool get _isDualMode => _dualSessions.length >= 2;

  /// Índice do jogador desta sessão (UID primeiro, nome depois).
  int _playerIndexOfSession(_NetSession s) {
    final uid = s.myUid ?? '';
    if (uid.isNotEmpty) {
      final i = _players.indexWhere((p) => p.uid == uid);
      if (i != -1) return i;
    }
    final key = s.displayName.trim().toLowerCase();
    if (key.isNotEmpty) {
      final i = _players.indexWhere((p) => p.name.trim().toLowerCase() == key);
      if (i != -1) return i;
    }
    return -1;
  }

  /// Zona da mesa deles: com 3+ jogadores mostra UM por vez
  /// (chips para trocar); no 1v1 mostra direto.
  int _selOppIdx() {
    if (_remoteIdx.isEmpty) return -1;
    return _remoteIdx[_oppSel.clamp(0, _remoteIdx.length - 1)];
  }

  /// Fichas do oponente selecionado.
  List<_Token> _selOppTokens() {
    final i = _selOppIdx();
    if (i < 0) return [];
    return _tokensOf(_players[i]);
  }

  List<_TokenStack> _groupTokens(Iterable<_Token> tokens) {
    final groups = <String, List<_Token>>{};
    for (final t in tokens) {
      // P/T efetivo entra na chave por causa de efeitos que miram só uma
      // ficha. Marcadores e virar também precisam permanecer visíveis.
      final key = [
        t.name.toLowerCase(),
        t.owner,
        t.ownerUid,
        t.kind,
        t.power,
        t.toughness,
        effP(t),
        effT(t),
        t.counters,
        t.minus,
        t.loyalty,
        t.charge,
        _Token.marksKey(t.marks),
        t.tapped,
        t.description,
        t.art,
        t.hideName == true,
      ].join('|');
      (groups[key] ??= []).add(t);
    }
    final out = [for (final list in groups.values) _TokenStack(list)];
    // Ordem estável por menor id (criação): virar/desvirar muda a chave
    // do grupo, mas a pilha NÃO pula de lugar na fileira.
    out.sort((a, b) {
      var minA = a.tokens.first.id;
      for (final t in a.tokens) {
        if (t.id < minA) minA = t.id;
      }
      var minB = b.tokens.first.id;
      for (final t in b.tokens) {
        if (t.id < minB) minB = t.id;
      }
      return minA.compareTo(minB);
    });
    return out;
  }

  bool get _isSharedPhoneDuel =>
      _playMode == _PlayMode.local &&
      !_isHost &&
      !_isGuest &&
      _players.length == 2;

  /// Mesa presencial: as duas pessoas ficam uma de frente para a outra.
  /// A metade superior é desenhada de ponta-cabeça para ser lida por quem
  /// está do outro lado do telefone; os dois lados usam as mesmas medidas.
  Widget _sharedPhoneDuelView() {
    // Fundo igual ao das outras telas (AppTheme.bg), bem escurinho.
    // O tema da mesa aparece nos painéis/cards/destaques, não no fundo.
    // SafeArea só sem AppBar: com AppBar ela duplicaria o respiro.
    return Container(
      color: AppTheme.bg,
      child: SafeArea(
        top: _noTopBar,
        bottom: false,
        child: Column(children: [
          Expanded(
            child: RotatedBox(
              quarterTurns: 2,
              child: _duelZone(1, upsideDown: true),
            ),
          ),
          _duelToolbar(),
          Expanded(child: _duelZone(0)),
        ]),
      ),
    );
  }

  Widget _duelToolbar() {
    final activeName = _players.isEmpty
        ? '—'
        : _players[_active.clamp(0, _players.length - 1)].name;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.sidebar,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _tableStyle.accent.withValues(alpha: 0.45)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.casino, size: 20),
            tooltip: AppLocale.t('su_dice20'),
            color: AppTheme.textMuted,
            onPressed: () => _roll('D20', 20),
          ),
          IconButton(
            icon: const Icon(Icons.toll, size: 20),
            tooltip: AppLocale.t('su_coin'),
            color: AppTheme.textMuted,
            onPressed: _flipCoin,
          ),
          Expanded(
            child: GestureDetector(
              onTap: _nextTurn,
              // A metade de cima é lida de ponta-cabeça: quando for a vez
              // do jogador de cima (índice 1), a pílula gira 180º junto.
              child: RotatedBox(
                quarterTurns: _active == 1 ? 2 : 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      _tableStyle.accent.withValues(alpha: 0.28),
                      _tableStyle.accent.withValues(alpha: 0.12),
                    ]),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _tableStyle.accent.withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.skip_next,
                          size: 18, color: _tableStyle.accent),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '$activeName • R$_round',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.undo, size: 20),
            tooltip: 'Desfazer',
            color: AppTheme.textMuted,
            onPressed: _history.isEmpty ? null : _undo,
          ),
          IconButton(
            icon: Icon(_focusMode ? Icons.fullscreen_exit : Icons.fullscreen,
                size: 20),
            tooltip: _focusMode ? 'Sair do foco' : 'Modo foco',
            color: _tableStyle.accent,
            onPressed: _toggleFocusMode,
          ),
        ],
      ),
    );
  }

  /// Duelo 1x1 local: altura ADAPTATIVA (nunca estoura).
  /// A faixa de cartas fica com todo o resto (até _tokenMaxH); a vida
  /// encolhe via FittedBox quando aperta (paisagem). Em zona minúscula
  /// (paisagem baixa: nem o fixo cabe) rola por dentro. Tamanhos no
  /// bloco "AJUSTE FINO DA MESA".
  Widget _duelZone(int playerIndex, {bool upsideDown = false}) {
    final player = _players[playerIndex];
    final tokens = _tokensOf(player);
    final stacks = _groupTokens(tokens);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      // Moldura com o tema/fundo DESTE jogador (igual online 1v1).
      child: _zoneFrame(
        p: player,
        isActive: playerIndex == _active,
        padding: EdgeInsets.zero,
        child: LayoutBuilder(builder: (_, cons) {
          final maxH = cons.maxHeight;
          final tight = maxH.isFinite && maxH < _duelCompactH;
          final lifeH = !maxH.isFinite
              ? _duelLifeH
              : (tight ? _duelLifeHCompact : _duelLifeH);
          final manaH = tight ? 26.0 : 32.0;
          final stripH = maxH.isFinite
              ? (maxH - _duelNameH - manaH - lifeH - 14.0)
                  .clamp(0.0, _tokenMaxH)
              : _tokenMaxH;
          Widget nameRow() {
            return SizedBox(
              height: _duelNameH,
              child: Row(children: [
                Expanded(
                  child: Text(
                      '${player.name} • ${tokens.length} ${AppLocale.t('play_tokens_count')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                IconButton(
                  icon: Icon(Icons.add_circle,
                      color: _tableStyle.accent, size: 20),
                  tooltip: AppLocale.t('play_add_token'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  onPressed: () => _tokenLauncher(
                      owner: player.name, upsideDown: upsideDown),
                ),
              ]),
            );
          }

          Widget strip(double h) {
            if (h < _tokenMinH) return const SizedBox.shrink();
            if (tokens.isEmpty) {
              return SizedBox(
                height: h,
                child: const Center(
                    child: Text('Sem fichas',
                        style: TextStyle(color: AppTheme.textMuted))),
              );
            }
            final w = (h * _tokenAspect).clamp(0.0, _tokenMaxW);
            return SizedBox(
              height: h,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(3, 4, 3, 10),
                itemCount: stacks.length,
                itemBuilder: (_, i) => _tokenStackMini(stacks[i],
                    w: w, h: h, upsideDown: upsideDown),
              ),
            );
          }

          Widget lifeBox() {
            // Vida encolhe proporcional (sem estourar) quando aperta.
            return SizedBox(
              height: lifeH,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: 210,
                  height: 96,
                  // Topo do duelo lê de ponta-cabeça: menu de vida acompanha.
                  child: _playerTileContent(playerIndex,
                      upsideDown: upsideDown),
                ),
              ),
            );
          }

          // Zona minúscula: nem nome+mana+vida cabem — rola por dentro
          // com faixa fixa em vez de estourar (paisagem ~90px).
          final minNeed = _duelNameH + manaH + lifeH;
          if (maxH.isFinite && maxH < minNeed) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  nameRow(),
                  strip(64),
                  _manaRow(player.name,
                      compact: true, upsideDown: upsideDown),
                  lifeBox(),
                ],
              ),
            );
          }
          // stretch: os filhos (faixa, vida) recebem a largura da zona.
          // Sem isso a largura chega infinita até o Expanded da vida.
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                nameRow(),
                Expanded(
                  child: stripH < _tokenMinH
                      ? const SizedBox.shrink()
                      : strip(stripH),
                ),
                _manaRow(player.name,
                    compact: tight, upsideDown: upsideDown),
                lifeBox(),
              ]);
        }),
      ),
    );
  }

  /// Linha da mesa: vez/rodada, desfazer, histórico e foco.
  /// Faixa da mesa (vez, desfazer, histórico, foco): igual à faixa
  /// central do modo Local — mesmo Container, pílula de turno, dados
  /// e moeda. Vale para online e LAN.
  Widget _matchToolbar() {
    final canPass = _canPassTurn();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.sidebar,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _tableStyle.accent.withValues(alpha: 0.45)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.casino, size: 20),
            tooltip: AppLocale.t('su_dice20'),
            color: AppTheme.textMuted,
            onPressed: () => _roll('D20', 20),
          ),
          IconButton(
            icon: const Icon(Icons.toll, size: 20),
            tooltip: AppLocale.t('su_coin'),
            color: AppTheme.textMuted,
            onPressed: _flipCoin,
          ),
          Expanded(
            child: GestureDetector(
              onTap: canPass ? _nextTurn : null,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    _tableStyle.accent.withValues(alpha: 0.28),
                    _tableStyle.accent.withValues(alpha: 0.12),
                  ]),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: _tableStyle.accent.withValues(alpha: 0.6)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.skip_next,
                        size: 18, color: _tableStyle.accent),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _players.isEmpty
                            ? '${AppLocale.t('play_round')} $_round'
                            : '${AppLocale.t('play_turn')}: ${_players[_active.clamp(0, _players.length - 1)].name} • R$_round',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.undo, size: 20),
            tooltip: AppLocale.t('play_undo'),
            onPressed: _history.isNotEmpty || _isGuest ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.history, size: 20),
            tooltip: AppLocale.t('play_history'),
            onPressed: _showHistory,
          ),
          IconButton(
            icon: Icon(_focusMode ? Icons.fullscreen_exit : Icons.fullscreen,
                size: 20),
            tooltip: _focusMode
                ? AppLocale.t('play_exit_focus')
                : AppLocale.t('play_focus'),
            color: _focusMode ? _tableStyle.accent : null,
            onPressed: _toggleFocusMode,
          ),
        ],
      ),
    );
  }

  /// Moldura comum da mesa (fundo + SafeArea + saída do foco).
  Widget _tableFrame(Widget content,
      {bool showFocusFab = true, Widget? actionButton}) {
    return Stack(
      children: [
        Container(
          // O fundo do tema global finalmente vale (antes era fixo).
          color: _tableStyle.background,
          child: SafeArea(
            top: _noTopBar,
            bottom: false,
            child: content,
          ),
        ),
        if (_focusMode && showFocusFab)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: 'exit_focus',
              tooltip: AppLocale.t('play_exit_focus'),
              onPressed: _toggleFocusMode,
              child: const Icon(Icons.fullscreen_exit),
            ),
          ),
        if (actionButton != null)
          // Lateral central (neutro para cima/baixo): não favorece
          // nenhum lado, diferente do canto inferior.
          Positioned(
            right: 12,
            top: 0,
            bottom: 0,
            child: Center(child: actionButton),
          ),
      ],
    );
  }

  /// Funções da faixa num sheet: vez, dados, moeda, desfazer,
  /// histórico, foco e temas. Usado no multi 3+ (sem faixa fixa).
  Future<void> _toolbarSheet() async {
    final canPass = _canPassTurn();
    final activeName = _players.isEmpty
        ? '—'
        : _players[_active.clamp(0, _players.length - 1)].name;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: canPass ? 1 : 0.45,
                child: SizedBox(
                  width: double.infinity,
                  child: GestureDetector(
                    onTap: canPass
                        ? () {
                            Navigator.pop(ctx);
                            _nextTurn();
                          }
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [
                          _tableStyle.accent.withValues(alpha: 0.28),
                          _tableStyle.accent.withValues(alpha: 0.12),
                        ]),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color:
                                _tableStyle.accent.withValues(alpha: 0.6)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.skip_next,
                              size: 18, color: _tableStyle.accent),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _players.isEmpty
                                  ? '${AppLocale.t('play_round')} $_round'
                                  : '${AppLocale.t('play_turn')}: $activeName • R$_round',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.casino, size: 22),
                      tooltip: AppLocale.t('su_dice20'),
                      onPressed: () => _roll('D20', 20),
                    ),
                    IconButton(
                      icon: const Icon(Icons.toll, size: 22),
                      tooltip: AppLocale.t('su_coin'),
                      onPressed: _flipCoin,
                    ),
                    IconButton(
                      icon: const Icon(Icons.undo, size: 22),
                      tooltip: AppLocale.t('play_undo'),
                      onPressed:
                          _history.isNotEmpty || _isGuest ? _undo : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.history, size: 22),
                      tooltip: AppLocale.t('play_history'),
                      onPressed: _showHistory,
                    ),
                    IconButton(
                      icon: Icon(
                          _focusMode
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          size: 22),
                      tooltip: _focusMode
                          ? AppLocale.t('play_exit_focus')
                          : AppLocale.t('play_focus'),
                      color: _focusMode ? _tableStyle.accent : null,
                      onPressed: () {
                        Navigator.pop(ctx);
                        _toggleFocusMode();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.palette_outlined, size: 22),
                      tooltip: AppLocale.t('su_table'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showTableThemes();
                      },
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
  /// Local multi: lados escolhidos no setup (3p = 2+1, 4p = 2+2).
  /// Os dois lados dividem a altura por igual (sem um pequeno e outro
  /// gigante); cada lado preenche a largura — centralizado, sem cantos
  /// vazios — e só rola na horizontal se passar.
  /// O lado de cima gira 180º (leitura de quem está do outro lado,
  /// como no duelo); o de baixo fica reto.
  Widget _localMultiView() {
    final top = <int>[];
    final bottom = <int>[];
    for (var i = 0; i < _players.length; i++) {
      final isTop = i < _playerSides.length ? _playerSides[i] : i >= 2;
      if (isTop) {
        top.add(i);
      } else {
        bottom.add(i);
      }
    }
    // Tudo num lado só? Usa ele sozinho (sem lado vazio).
    final sides = [
      if (top.isNotEmpty) top,
      if (bottom.isNotEmpty) bottom,
    ];
    // A Faixa virou botão flutuante (3+): solo mantém a barra.
    final floatingBar = _players.length >= 3;
    return _tableFrame(
      Column(
        children: [
          if (!floatingBar) _duelToolbar(),
          for (var s = 0; s < sides.length; s++)
            Expanded(
              child: _sideRow(sides[s],
                  rotated:
                      sides[s] == top && bottom.isNotEmpty),
            ),
        ],
      ),
      showFocusFab: !floatingBar,
      actionButton: floatingBar
          ? FloatingActionButton(
              heroTag: null,
              mini: true,
              tooltip: AppLocale.t('tb_functions'),
              onPressed: _toolbarSheet,
              child: const Icon(Icons.tune),
            )
          : null,
    );
  }

  /// Uma fileira lateral: se couber, as zonas dividem a largura
  /// igualmente (preenchendo, sem vazio nos cantos); se passar,
  /// rola na horizontal com zonas de 330px. [rotated] vira o lado
  /// inteiro para quem está em frente (e os menus das zonas junto).
  Widget _sideRow(List<int> idxs, {bool rotated = false}) {
    Widget row = LayoutBuilder(builder: (_, c) {
      const zoneW = 330.0;
      const gap = 8.0;
      const pad = 24.0;
      final needW = idxs.length * zoneW + (idxs.length - 1) * gap + pad;
      if (needW <= c.maxWidth) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var k = 0; k < idxs.length; k++) ...[
                if (k > 0) const SizedBox(width: gap),
                Expanded(
                    child: _localZoneCard(idxs[k],
                        upsideDown: rotated)),
              ],
            ],
          ),
        );
      }
      return ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        itemCount: idxs.length,
        itemBuilder: (_, k) => Container(
          width: zoneW,
          margin: const EdgeInsets.only(right: gap),
          child: _localZoneCard(idxs[k], upsideDown: rotated),
        ),
      );
    });
    return rotated ? RotatedBox(quarterTurns: 2, child: row) : row;
  }
  /// Uma mesa individual do Local multi: vida ao lado de
  /// (mana compacta + fichas + add), com o tema/fundo do jogador.
  /// Borda dourada em quem tem a vez. [upsideDown] vira todos os
  /// menus/sheets daquele lado para quem está em frente.
  Widget _localZoneCard(int i, {bool upsideDown = false}) {
    final p = _players[i];
    final mine = _tokensOf(p);
    final stacks = _groupTokens(mine);
    return _zoneFrame(
      p: p,
      isActive: i == _active,
      padding: const EdgeInsets.all(6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
              width: 132,
              child: _playerTileContent(i,
                  style: _styleFor(p), upsideDown: upsideDown)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _manaRow(p.name,
                    compact: true,
                    upsideDown: upsideDown,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('×${mine.length}',
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                        InkWell(
                          onTap: () => _tokenLauncher(
                              owner: p.name, upsideDown: upsideDown),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.add_circle,
                                color: AppTheme.gold, size: 18),
                          ),
                        ),
                      ],
                    )),
                Expanded(
                  child: LayoutBuilder(builder: (_, c) {
                    // Ocupa o que sobrar, sem piso mínimo: com pouco
                    // espaço some em vez de estourar. Minis escalam.
                    final stripH = (c.maxHeight - 4).clamp(0.0, 110.0);
                    if (stripH < 20) return const SizedBox.shrink();
                    final mw = stripH * 0.72;
                    if (stacks.isEmpty) {
                      return Center(
                          child: Text(AppLocale.t('play_no_tokens'),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11)));
                    }
                    return ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.zero,
                      itemCount: stacks.length,
                      itemBuilder: (_, k) => _tokenStackMini(stacks[k],
                          w: mw,
                          h: stripH,
                          style: _styleFor(p),
                          upsideDown: upsideDown),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Arena (LAN/Online) espelhando o duelo Local: em cima a mesa de
  /// quem está selecionado, faixa central, embaixo SEMPRE eu. No
  /// landscape as duas ficam lado a lado. Vidas lado a lado no trilho:
  /// tocar mostra em cima. Sem mesas empilhadas.
  Widget _arenaView() {
    if (_players.isEmpty) {
      return _tableFrame(
        Center(
            child: Text(AppLocale.t('play_no_tokens'),
                style: const TextStyle(color: AppTheme.textMuted))),
      );
    }
    final me = _meIndex.clamp(0, _players.length - 1);
    // Topo mostra outro jogador; sozinho, mostra eu.
    var sel = _arenaSel.clamp(0, _players.length - 1);
    if (_players.length > 1 && sel == me) {
      sel = [for (var i = 0; i < _players.length; i++) if (i != me) i].first;
    }
    final wide = MediaQuery.of(context).size.width >
        MediaQuery.of(context).size.height;
    final solo = _players.length < 2;
    final topZone = _arenaZone(sel);
    final myZone = _arenaZone(me);
    return _tableFrame(
      Column(
        children: [
          if (_canRecoverLan) _reconnectBanner(),
          if (_isOnline) _onlineNotice(),
          if (solo)
            Expanded(child: myZone)
          else if (wide)
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: topZone),
                  Expanded(child: myZone),
                ],
              ),
            )
          else
            Expanded(child: topZone),
          _duelToolbar(),
          if (!solo) _arenaRail(sel, me),
          if (!solo && !wide) Expanded(child: myZone),
          if (_sharedTokens.isNotEmpty) _sharedSection(),
          _arenaEffects(),
        ],
      ),
    );
  }

  /// Trilho de jogadores: pílula com nome + vida ao vivo por jogador.
  /// Toque seleciona (a mesa de cima mostra ele); segurar abre a vida.
  /// Borda dourada = selecionado; vida vermelha = em risco.
  Widget _arenaRail(int sel, int me) {
    return SizedBox(
      height: 70,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        itemCount: _players.length,
        itemBuilder: (_, i) {
          final p = _players[i];
          final isSel = i == sel;
          final isTurn = i == _active;
          return GestureDetector(
            onTap: () => setState(() => _arenaSel = i),
            onLongPress: () => _lifeMenu(i),
            child: Container(
              width: 104,
              margin: const EdgeInsets.only(right: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isSel ? AppTheme.goldSoft : AppTheme.sidebar,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: isSel
                        ? AppTheme.gold
                        : (isTurn
                            ? _tableStyle.accent
                            : AppTheme.border),
                    width: isSel ? 2 : 1),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                      '${p.name}${i == me ? ' • ${AppLocale.t('on_you')}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isTurn)
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                              color: _tableStyle.accent,
                              shape: BoxShape.circle),
                        ),
                      Text('${p.life}',
                          style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              color: p.life <= 5
                                  ? Colors.redAccent
                                  : AppTheme.text)),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Uma zona da Arena: nome/contador/dados/kick/add, vida compacta,
  /// mana e fichas. Sem alturas fixas além da faixa de fichas (que se
  /// ajusta ao espaço via LayoutBuilder) — nunca estoura.
  Widget _arenaZone(int idx) {
    final p = _players[idx];
    final mine = _tokensOf(p);
    final stacks = _groupTokens(mine);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: _zoneFrame(
        p: p,
        isActive: idx == _active,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        // LayoutBuilder decide o modo: altura folgada usa Column+Expanded
        // (igual a antes); altura apertada (<180, ex. giro/hot-reload com
        // 114px) usa rolagem compacta — nunca estoura (era 7px overflow).
        child: LayoutBuilder(builder: (_, cons) {
          final tight =
              cons.maxHeight.isFinite && cons.maxHeight < _arenaCompactH;
          if (tight) {
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _arenaZoneHeader(idx, p, mine.length, compact: true),
                  _arenaLifeRow(idx, compact: true),
                  _manaRow(p.name, compact: true),
                  const SizedBox(height: 2),
                  _arenaTokenStrip(stacks, p, fixedHeight: 56),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _arenaZoneHeader(idx, p, mine.length, compact: false),
              _arenaLifeRow(idx),
              _manaRow(p.name),
              Expanded(
                child: LayoutBuilder(builder: (_, c) {
                  // Faixa aproveita a altura livre (até _arenaStripMaxH);
                  // minis maiores agora que a faixa fixa saiu do layout.
                  // Sem piso mínimo: some em vez de estourar.
                  final stripH = (c.maxHeight - 4)
                      .clamp(0.0, _arenaStripMaxH);
                  if (stripH < 20) return const SizedBox.shrink();
                  if (stacks.isEmpty) {
                    return Center(
                        child: Text(AppLocale.t('play_no_tokens'),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)));
                  }
                  return _arenaTokenStrip(stacks, p, fixedHeight: stripH);
                }),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// Cabeçalho da zona (nome/contador/dados/kick/add). No modo compacto
  /// (zona apertada) os dados saem — já existem na barra central — e os
  /// botões encolhem de 34 para 28px.
  Widget _arenaZoneHeader(int idx, _MatchPlayer p, int tokenCount,
      {bool compact = false}) {
    final btnCons =
        BoxConstraints(minWidth: compact ? 28 : 34, minHeight: compact ? 28 : 34);
    final iconSize = compact ? 16.0 : 20.0;
    return Row(
      children: [
        Expanded(
          child: Text(
              '$tokenCount ${AppLocale.t('play_tokens_count')}'
              ' • ${p.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  shadows: [
                    Shadow(color: Colors.black, blurRadius: 4)
                  ])),
        ),
        if (!compact) _diceRow(p.name),
        // Host expulsa remoto direto da zona (nunca a si).
        if ((_host != null || _hostSession != null) &&
            !_isLocalPlayerIdx(idx))
          IconButton(
            icon: Icon(Icons.person_remove_outlined,
                size: iconSize, color: Colors.redAccent),
            tooltip:
                AppLocale.t('su_remove_title').replaceAll('{n}', p.name),
            padding: EdgeInsets.zero,
            constraints: btnCons,
            onPressed: () => _kickPlayer(p.name),
          ),
        IconButton(
          icon: Icon(Icons.auto_awesome, size: iconSize),
          tooltip: AppLocale.t('play_new_effect'),
          padding: EdgeInsets.zero,
          constraints: btnCons,
          onPressed: _effectDialog,
        ),
        IconButton(
          icon: Icon(Icons.add, size: compact ? 18 : 22),
          tooltip: AppLocale.t('play_add_token'),
          padding: EdgeInsets.zero,
          constraints: btnCons,
          onPressed: () => _tokenLauncher(owner: p.name),
        ),
      ],
    );
  }

  /// Faixa horizontal de fichas com altura fixa. Altura fixa (sem
  /// Expanded) permite usar dentro de rolagem no modo compacto e
  /// reutilizar no modo normal — altura 0 some em vez de estourar.
  Widget _arenaTokenStrip(
      List<_TokenStack> stacks, _MatchPlayer p, {required double fixedHeight}) {
    if (fixedHeight < 20) return const SizedBox.shrink();
    final mw = (fixedHeight * _tokenAspect).clamp(0.0, _tokenMaxW);
    if (stacks.isEmpty) {
      return SizedBox(
        height: fixedHeight,
        child: Center(
            child: Text(AppLocale.t('play_no_tokens'),
                style: const TextStyle(
                    color: Colors.white70, fontSize: 11))),
      );
    }
    return SizedBox(
      height: fixedHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: stacks.length,
        itemBuilder: (_, k) => _tokenStackMini(stacks[k],
            w: mw, h: fixedHeight, style: _styleFor(p)),
      ),
    );
  }

  /// Vida compacta da zona: zonas grandes −/+ e número, + veneno.
  /// (segurar número abre presets). Roteamento de autoridade intacto.
  Widget _arenaLifeRow(int idx, {bool compact = false}) {
    final p = _players[idx];
    return Row(
      children: [
        Expanded(child: _lifeStepper(idx, fontSize: compact ? 18 : 24)),
        _poisonStepper(idx),
        // Comandante (só quando existe): toque abre o menu completo.
        if (p.commanderMax > 0)
          InkWell(
            onTap: () => _lifeMenu(idx),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text('Cmd ${p.commanderMax}',
                  style: TextStyle(
                      color: p.commanderDead
                          ? Colors.redAccent
                          : AppTheme.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }

  /// Efeitos ativos da mesa (global, como no Legacy).
  Widget _arenaEffects() {
    if (_effects.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        children: [
          for (final e in _effects)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                label: Text(
                    '${e.label} ${e.power >= 0 ? '+' : ''}${e.power}/${e.toughness >= 0 ? '+' : ''}${e.toughness}'
                    '${e.targetId == -1 ? ' (todas)' : ''}'
                    '${e.untilEOT ? ' ⏳' : ''}',
                    style: const TextStyle(fontSize: 12)),
                deleteIcon: const Icon(Icons.close, size: 14),
                onDeleted: () => _effectRemove(e.id),
              ),
            ),
        ],
      ),
    );
  }

  Widget _matchView() {
    if (_isSharedPhoneDuel) return _sharedPhoneDuelView();
    // Local com 1, 3, 4, 5 ou 6: grade de mesas (2p fica no duelo).
    if (_playMode == _PlayMode.local) return _localMultiView();
    // LAN/Online: Arena (mesa única) ou Legacy (empilhado antigo).
    // O dual (2 perfis no mesmo aparelho, para testes) também entra na
    // Arena: os dois perfis já são jogadores distintos em _players, com
    // UIDs locais próprios — o trilho mostra os dois e cada zona opera
    // pelo dono dela. Legacy mantém o _dualMatchView antigo.
    if ((_isOnline || _playMode == _PlayMode.lan) &&
        PlayPrefs.tableFormat.value == 'arena') {
      return _arenaView();
    }
    // Dois perfis/sessões no mesmo aparelho: zonas A e B próprias.
    if (_isDualMode) return _dualMatchView();
    // Rolável: zonas dos dois lados + fileiras laterais.
    // Fundo igual ao das outras telas (bem escurinho).
    // Sem AppBar (foco ou imersão): SafeArea compacta respeita o
    // status/notch sem empurrar o conteúdo para baixo demais.
    return _tableFrame(
      SingleChildScrollView(
        child: Column(
          children: [
            _matchToolbar(),
            // Banner de reconexão quando a rede caiu mas a partida existe.
            if (_canRecoverLan) _reconnectBanner(),
            if (_isOnline) _onlineNotice(),
            // ---- MESA DELES (acima; 3+ mostra um por vez) ----
            if (_remoteIdx.isNotEmpty) ...[
              if (_remoteIdx.length > 1)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (var k = 0; k < _remoteIdx.length; k++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            avatar: const Icon(Icons.person, size: 16),
                            label: Text(_players[_remoteIdx[k]].name),
                            selected: _oppSel == k,
                            onSelected: (_) => setState(() => _oppSel = k),
                          ),
                        ),
                    ],
                  ),
                ),
              Builder(builder: (_) {
                final sel = _selOppIdx();
                if (sel < 0) {
                  return const SizedBox.shrink();
                }
                final selTokens = _selOppTokens();
                final selStacks = _groupTokens(selTokens);
                final selActive = sel == _active.clamp(0, _players.length - 1);
                return Card(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: selActive ? _tableStyle.accent : AppTheme.border,
                        width: selActive ? 2 : 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            if (selActive)
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                    color: _tableStyle.accent,
                                    shape: BoxShape.circle),
                              ),
                            Expanded(
                              child: Text(
                                  '${AppLocale.t('play_opp_tokens')} ${_players[sel].name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                            ),
                            _diceRow(_players[sel].name),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Center(child: _playerTile(sel, kickable: true)),
                        if (selTokens.isNotEmpty)
                          SizedBox(
                            height: 158,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: EdgeInsets.zero,
                              itemCount: selStacks.length,
                              itemBuilder: (_, j) =>
                                  _tokenStackMini(selStacks[j]),
                            ),
                          ),
                        _manaRow(_players[sel].name),
                      ],
                    ),
                  ),
                );
              }),
              if (_sharedTokens.isNotEmpty) _sharedSection(),
            ],
            // ---- Mesa deles vazia? mostra placeholder (layout de 2). ----
            if (_otherIdx.isEmpty && _playMode == _PlayMode.lan)
              Card(
                margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.radar,
                              size: 16, color: AppTheme.gold),
                          const SizedBox(width: 6),
                          Text(AppLocale.t('su_waiting'),
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(AppLocale.t('su_wait_hint'),
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            // ---- MINHA MESA (abaixo) ----
            // Compacta de propósito: jogador, vida, mana, fichas e
            // ações numa leitura só, sem diagnóstico de rede.
            Card(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(AppLocale.t('play_my_table'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppTheme.gold,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                        ),
                        if (_players.isNotEmpty)
                          _diceRow(
                              _players[_meIndex.clamp(0, _players.length - 1)]
                                  .name),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Center(
                      child: SizedBox(
                        width: 216,
                        height: 112,
                        child: _players.isEmpty
                            ? const SizedBox.shrink()
                            : _playerTileContent(
                                _meIndex.clamp(0, _players.length - 1)),
                      ),
                    ),
                    if (_players.isNotEmpty)
                      _manaRow(_players[_meIndex.clamp(0, _players.length - 1)]
                          .name),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${AppLocale.t('play_my_tokens')} (${_mineTokens.length})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.auto_awesome, size: 20),
                    tooltip: AppLocale.t('play_new_effect'),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    onPressed: _effectDialog,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, size: 22),
                    tooltip: AppLocale.t('play_add_token'),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    onPressed: _tokenLauncher,
                  ),
                ],
              ),
            ),
            if (_effects.isNotEmpty)
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final e in _effects)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Chip(
                          label: Text(
                              '${e.label} ${e.power >= 0 ? '+' : ''}${e.power}/${e.toughness >= 0 ? '+' : ''}${e.toughness}'
                              '${e.targetId == -1 ? ' (todas)' : ''}'
                              '${e.untilEOT ? ' ⏳' : ''}',
                              style: const TextStyle(fontSize: 12)),
                          deleteIcon: const Icon(Icons.close, size: 14),
                          onDeleted: () => _effectRemove(e.id),
                        ),
                      ),
                  ],
                ),
              ),
            // ---- minhas fichas: fileira lateral (uma linha) ----
            SizedBox(
              height: 190,
              child: Builder(builder: (_) {
                final mine = _mineTokens;
                final stacks = _groupTokens(mine);
                if (mine.isEmpty) {
                  return Center(
                      child: Text(AppLocale.t('play_no_tokens'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppTheme.textMuted)));
                }
                return ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: stacks.length,
                  itemBuilder: (_, i) =>
                      _tokenStackMini(stacks[i], w: 130, h: 182),
                );
              }),
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  /// Fichas compartilhadas (dono fora da partida, ex. kick).
  Widget _sharedSection() {
    final stacks = _groupTokens(_sharedTokens);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(AppLocale.t('play_shared'),
                style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SizedBox(
              height: 158,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemCount: stacks.length,
                itemBuilder: (_, k) => _tokenStackMini(stacks[k]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mesa dual: duas sessões/perfis no MESMO aparelho, cada um com sua
  /// zona própria (vida, mana, fichas, dados), sem rotação — quem opera
  /// é uma pessoa só testando os dois lados. Remotos vão para a seção
  /// de oponentes (já filtrada). Destaque dourado em quem tem a vez.
  Widget _dualMatchView() {
    return _tableFrame(
      SingleChildScrollView(
        child: Column(
          children: [
            _matchToolbar(),
            if (_canRecoverLan) _reconnectBanner(),
            if (_isOnline) _onlineNotice(),
            for (var n = 0; n < _dualSessions.length; n++)
              _dualZoneCard(_dualSessions[n], n + 1),
            // Remotos (se houver um 3º jogador de verdade).
            if (_remoteIdx.isNotEmpty) ...[
              if (_remoteIdx.length > 1)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (var k = 0; k < _remoteIdx.length; k++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            avatar: const Icon(Icons.person, size: 16),
                            label: Text(_players[_remoteIdx[k]].name),
                            selected: _oppSel == k,
                            onSelected: (_) => setState(() => _oppSel = k),
                          ),
                        ),
                    ],
                  ),
                ),
              Builder(builder: (_) {
                final sel = _selOppIdx();
                if (sel < 0) return const SizedBox.shrink();
                final selTokens = _selOppTokens();
                final selStacks = _groupTokens(selTokens);
                final selActive = sel == _active.clamp(0, _players.length - 1);
                return Card(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: selActive ? _tableStyle.accent : AppTheme.border,
                        width: selActive ? 2 : 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            if (selActive)
                              Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                    color: _tableStyle.accent,
                                    shape: BoxShape.circle),
                              ),
                            Expanded(
                              child: Text(
                                  '${AppLocale.t('play_opp_tokens')} ${_players[sel].name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                            ),
                            _diceRow(_players[sel].name),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Center(child: _playerTile(sel, kickable: true)),
                        if (selTokens.isNotEmpty)
                          SizedBox(
                            height: 158,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: EdgeInsets.zero,
                              itemCount: selStacks.length,
                              itemBuilder: (_, j) =>
                                  _tokenStackMini(selStacks[j]),
                            ),
                          ),
                        _manaRow(_players[sel].name),
                      ],
                    ),
                  ),
                );
              }),
            ],
            if (_sharedTokens.isNotEmpty) _sharedSection(),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  /// Zona de UMA identidade local no modo dual: nome + selo da sessão,
  /// vida, mana, fichas e dados — tudo vertical, sem girar.
  Widget _dualZoneCard(_NetSession s, int n) {
    final idx = _playerIndexOfSession(s);
    if (idx < 0 || idx >= _players.length) {
      return const SizedBox.shrink();
    }
    final p = _players[idx];
    final tokens = _tokensOf(p);
    final stacks = _groupTokens(tokens);
    final isTurn = idx == _active.clamp(0, _players.length - 1);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: isTurn ? _tableStyle.accent : AppTheme.border,
            width: isTurn ? 2 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (isTurn)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                        color: _tableStyle.accent, shape: BoxShape.circle),
                  ),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppTheme.goldSoft,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('S$n',
                            style: const TextStyle(
                                color: AppTheme.gold,
                                fontWeight: FontWeight.bold,
                                fontSize: 11)),
                      ),
                    ],
                  ),
                ),
                _diceRow(p.name),
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: AppLocale.t('play_add_token'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () => _tokenLauncher(owner: p.name),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Center(
              child: SizedBox(
                width: 216,
                height: 112,
                child: _playerTileContent(idx),
              ),
            ),
            _manaRow(p.name),
            if (tokens.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                    '${tokens.length} ${AppLocale.t('play_tokens_count')}',
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12)),
              ),
              SizedBox(
                height: 158,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.zero,
                  itemCount: stacks.length,
                  itemBuilder: (_, j) => _tokenStackMini(stacks[j]),
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(AppLocale.t('play_no_tokens_short'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  /// Linha de vida em ZONAS GRANDES de toque: a metade esquerda tira,
  /// a direita põe (toque = 1, segurar = acelera em marchas 1/5/10).
  /// O número no meio soma 1 no toque e abre presets ao segurar.
  /// Ao soltar a segurada, um aviso mostra o saldo (de X para Y).
  Widget _lifeStepper(int i,
      {bool upsideDown = false, double fontSize = 23}) {
    final p = _players[i];
    final st = _styleFor(p);
    // Vida no início da segurada (p/ o saldo ao soltar).
    var holdBase = p.life;
    void holdToast() {
      if (i < 0 || i >= _players.length) return;
      final now = _players[i].life;
      final d = now - holdBase;
      if (d == 0 || !mounted) return;
      AppToast.show(
          context,
          AppLocale.t('life_moved')
              .replaceAll('{a}', '$holdBase')
              .replaceAll('{b}', '$now'));
    }

    Widget zoneBtn(IconData icon, int sign, Alignment align) {
      return _HoldButton(
        icon: icon,
        iconSize: 26,
        minHeight: 48,
        expand: true,
        alignment: align,
        onTap: () => _bumpLife(i, sign),
        onStep: (n) => _bumpLife(
            i, n <= 6 ? sign : (n <= 12 ? sign * 5 : sign * 10)),
        onHoldStart: () {
          if (i >= 0 && i < _players.length) holdBase = _players[i].life;
        },
        onHoldEnd: holdToast,
      );
    }

    Widget number() {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _bumpLife(i, 1),
        // Segurar abre o menuzinho: presets + personalizado.
        onLongPress: () => _lifeMenu(i, upsideDown: upsideDown),
        // Caixa de clique gorda só na horizontal: as laterais têm
        // espaço de sobra. Na vertical cresce pouco para NÃO invadir
        // a fileira de veneno/comandante de baixo.
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          child: Text('${p.life}',
              style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                  color: p.life <= 5 ? Colors.redAccent : st.accent)),
        ),
      );
    }

    // Sem largura limitada (rolagem horizontal, FittedBox medindo...),
    // Expanded estoura: usa zonas fixas e deixa o pai escalar.
    return LayoutBuilder(builder: (_, cons) {
      if (!cons.maxWidth.isFinite) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 64, child: zoneBtn(Icons.remove, -1, Alignment.center)),
            number(),
            SizedBox(width: 64, child: zoneBtn(Icons.add, 1, Alignment.center)),
          ],
        );
      }
      return Row(
        // SEM stretch: em rolagem a altura é infinita e o stretch estoura
        // ("forces an infinite height"). As zonas já têm 48px de mínimo.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
              child: zoneBtn(Icons.remove, -1, Alignment.centerLeft)),
          number(),
          Expanded(child: zoneBtn(Icons.add, 1, Alignment.centerRight)),
        ],
      );
    });
  }

  /// Veneno compacto (− ☠n +) reutilizado nas duas caixas de vida.
  Widget _poisonStepper(int i) {
    final p = _players[i];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('☠ ', style: TextStyle(fontSize: 10)),
        InkWell(
            onTap: () => _bumpPoison(i, -1),
            child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.remove, size: 14))),
        Text('${p.poison}',
            style:
                const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        InkWell(
            onTap: () => _bumpPoison(i, 1),
            child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.add, size: 14))),
      ],
    );
  }

  /// Tile com ✕ para o host remover (só online, só os outros).
  /// Fake de teste mostra o ✕ mesmo sem ninguém conectado.
  /// Online: host remove qualquer um menos as identidades deste aparelho.
  Widget _playerTile(int i, {bool kickable = false}) {
    final onlineKick =
        _isOnlineHost && !_isLocalIdentity(_players[i].uid, _players[i].name);
    final canKick = kickable &&
        ((_isHost && (_peers > 0 || _fakePlayers.contains(_players[i].name))) ||
            onlineKick);
    final tile = Container(
      width: 152,
      margin: const EdgeInsets.only(right: 8),
      child: SizedBox(height: 108, child: _playerTileContent(i)),
    );
    if (!canKick) return tile;
    return Stack(
      children: [
        tile,
        Positioned(
          right: 2,
          top: 2,
          child: InkWell(
            onTap: () => _kickPlayer(_players[i].name),
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(2),
              child: const Icon(Icons.close, size: 14, color: Colors.redAccent),
            ),
          ),
        ),
      ],
    );
  }

  /// Conteúdo do tile (reusado no 1v1 centralizado). Com [style],
  /// usa o tema da mesa daquele jogador (online mostra o do oponente);
  /// sem [style], resolve sozinho pelo jogador — nada precisa mudar
  /// nos chamadores. [upsideDown] gira o menu de vida junto.
  Widget _playerTileContent(int i, {_TableStyle? style, bool upsideDown = false}) {
    final p = _players[i];
    final st = style ?? _styleFor(p);
    final isActive = i == _active;
    // Vidro fosco bem leve: painel translúcido + blur de fundo para
    // fundir com a imagem da mesa sem perder legibilidade.
    return Card(
      color: p.alive
          ? st.panel.withValues(alpha: 0.45)
          : AppTheme.panel.withValues(alpha: 0.45),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: isActive ? st.accent : AppTheme.border,
            width: isActive ? 2 : 1),
      ),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
        // Blindagem final: se a caixa for mais baixa que o conteúdo
        // (zonas apertadas de 80px), encolhe proporcional em vez de
        // estourar. Quando cabe, o scaleDown não altera nada.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: p.alive ? AppTheme.text : AppTheme.textFaint)),
              _lifeStepper(i,
                  upsideDown: upsideDown, fontSize: 23),
              _poisonStepper(i),
              // Dano de comandante (só quando existe): toque abre o menu.
              if (p.commanderMax > 0)
                InkWell(
                  onTap: () => _lifeMenu(i, upsideDown: upsideDown),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                        'Cmd ${p.commanderMax}/${_MatchPlayer.commanderLethal}',
                        style: TextStyle(
                            color: p.commanderDead
                                ? Colors.redAccent
                                : AppTheme.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              // Extras (só quando existem): resumo + atalho p/ o menu.
              if (p.counters.isNotEmpty)
                InkWell(
                  onTap: () => _lifeMenu(i, upsideDown: upsideDown),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                        p.counters.entries
                            .map((e) => '${e.key} ${e.value}')
                            .join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 10)),
                  ),
                ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  /// Menu de vida (segurar no número): presets e valor personalizado,
  /// mais veneno, dano de comandante (por oponente) e contadores extras.
  /// Vida fecha o menu ao escolher; contadores ajustam ao vivo.
  Future<void> _lifeMenu(int i, {bool upsideDown = false}) async {
    if (i < 0 || i >= _players.length) return;
    final custom = TextEditingController();
    final newCounterC = TextEditingController();
    final pick = await showModalBottomSheet<String>(
      context: context,
      // Sobe junto com o teclado (viewInsets) em vez de ficar embaixo dele.
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          if (i < 0 || i >= _players.length) {
            return const SizedBox.shrink();
          }
          final p = _players[i];
          // Linha de ajuste − n + reutilizada p/ veneno e extras.
          Widget stepperRow(String value, VoidCallback minus,
              VoidCallback plus,
              {VoidCallback? onDelete}) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 40, minHeight: 40),
                      onPressed: () {
                        minus();
                        setD(() {});
                      }),
                  SizedBox(
                    width: 44,
                    child: Text(value,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                      icon: const Icon(Icons.add_circle,
                          color: AppTheme.gold),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 40, minHeight: 40),
                      onPressed: () {
                        plus();
                        setD(() {});
                      }),
                  if (onDelete != null)
                    IconButton(
                        icon: const Icon(Icons.close,
                            size: 18, color: Colors.redAccent),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 40, minHeight: 40),
                        onPressed: () {
                          onDelete();
                          setD(() {});
                        }),
                ],
              ),
            );
          }

          return RotatedBox(
            quarterTurns: upsideDown ? 2 : 0,
            child: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                        '${AppLocale.t('life_title')}: ${p.name} (${p.life})',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 4),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final d in [-10, -5, -1, 1, 5, 10])
                          ActionChip(
                            label: Text('${d > 0 ? '+' : ''}$d'),
                            onPressed: () => Navigator.pop(ctx, 'd:$d'),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 4),
                    child: TextField(
                      controller: custom,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                          labelText: AppLocale.t('life_custom')),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx, 'reset'),
                            child: Text(AppLocale.t('life_reset')),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () =>
                                Navigator.pop(ctx, 'c:${custom.text}'),
                            child: Text(AppLocale.t('common_apply')),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 16),
                  // ---- veneno ----
                  Text('☠ ${AppLocale.t('life_poison')}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  stepperRow('${p.poison}',
                      () => _bumpPoison(i, -1), () => _bumpPoison(i, 1)),
                  const Divider(height: 16),
                  // ---- comandante (um por oponente) ----
                  Text(AppLocale.t('life_commander'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(AppLocale.t('life_commander_sub'),
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
                  for (var j = 0; j < _players.length; j++)
                    if (j != i)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(_players[j].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                            ),
                            IconButton(
                                icon: const Icon(
                                    Icons.remove_circle_outline),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 40, minHeight: 40),
                                onPressed: () {
                                  _bumpCommander(i, _players[j].name, -1);
                                  setD(() {});
                                }),
                            SizedBox(
                              width: 40,
                              child: Text(
                                  '${p.commander[_players[j].name] ?? 0}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: (p.commander[_players[j].name] ??
                                                  0) >=
                                              _MatchPlayer.commanderLethal
                                          ? Colors.redAccent
                                          : AppTheme.text)),
                            ),
                            IconButton(
                                icon: const Icon(Icons.add_circle,
                                    color: AppTheme.gold),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 40, minHeight: 40),
                                onPressed: () {
                                  _bumpCommander(i, _players[j].name, 1);
                                  setD(() {});
                                }),
                          ],
                        ),
                      ),
                  const Divider(height: 16),
                  // ---- extras (Energia, Experiência...) ----
                  Text(AppLocale.t('life_counters'),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  for (final e in p.counters.entries)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(e.key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13)),
                          ),
                          IconButton(
                              icon:
                                  const Icon(Icons.remove_circle_outline),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
                              onPressed: () {
                                _bumpPlayerCounter(i, e.key, -1);
                                setD(() {});
                              }),
                          SizedBox(
                            width: 40,
                            child: Text('${e.value}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold)),
                          ),
                          IconButton(
                              icon: const Icon(Icons.add_circle,
                                  color: AppTheme.gold),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
                              onPressed: () {
                                _bumpPlayerCounter(i, e.key, 1);
                                setD(() {});
                              }),
                          IconButton(
                              icon: const Icon(Icons.close,
                                  size: 18, color: Colors.redAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
                              onPressed: () {
                                _removePlayerCounter(i, e.key);
                                setD(() {});
                              }),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newCounterC,
                            textCapitalization:
                                TextCapitalization.words,
                            decoration: InputDecoration(
                                labelText:
                                    AppLocale.t('life_counter_hint')),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () {
                            final name = newCounterC.text.trim();
                            if (name.isEmpty) return;
                            newCounterC.clear();
                            _bumpPlayerCounter(i, name, 0);
                            setD(() {});
                          },
                          child: Text(AppLocale.t('common_add')),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ),
          );
        },
      ),
    );
    _laterDispose(custom);
    _laterDispose(newCounterC);
    if (pick == null) return;
    if (pick.startsWith('d:')) {
      _bumpLife(i, int.tryParse(pick.substring(2)) ?? 0);
    } else if (pick.startsWith('c:')) {
      final raw = pick.substring(2).trim().replaceAll('+', '');
      final d = int.tryParse(raw);
      if (d == null || d == 0) return;
      _bumpLife(i, d.clamp(-99, 99).toInt());
    } else if (pick == 'reset') {
      final delta = _startLife - _players[i].life;
      if (delta != 0) _bumpLife(i, delta);
    }
  }

  /// Linha de mana de um jogador: toque +1, segurar -1.
  /// O ✕ limpa SÓ a própria mana (cada aparelho, a sua).
  /// O nome já aparece ao lado da quantia de cartas acima, então aqui
  /// vão só os pontos (+ extras). Compacta usa pontos menores.
  /// [upsideDown] gira o quadro de marcadores p/ o player de cima.
  Widget _manaRow(String player,
      {bool compact = false, Widget? trailing, bool upsideDown = false}) {
    final pool = _mana[player] ?? {};
    final isMine = _isMinePlayer(player);
    final dotR = compact ? 7.0 : 10.0;
    final dotGap = compact ? 2.0 : 4.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          for (final c in _manaColors)
            GestureDetector(
              onTap: () => _manaAdd(player, c, 1),
              onLongPress: () => _manaAdd(player, c, -1),
              child: Container(
                margin: EdgeInsets.only(right: dotGap),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color:
                          (pool[c] ?? 0) > 0 ? AppTheme.gold : AppTheme.border),
                ),
                child: CircleAvatar(
                  radius: dotR,
                  backgroundColor: _manaDots[c],
                  child: Text('${pool[c] ?? 0}',
                      style: TextStyle(
                          fontSize: compact ? 9 : 10,
                          fontWeight: FontWeight.bold,
                          color: _manaDarkText(c)
                              ? Colors.black87
                              : Colors.white)),
                ),
              ),
            ),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing,
          ] else ...[
            const Spacer(),
            if (isMine)
              InkWell(
                onTap: () {
                  for (final c in _manaColors) {
                    _manaAdd(player, c, -99);
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_sweep,
                      size: 16, color: AppTheme.textFaint),
                ),
              ),
          ],
          // Marcadores da mesa escondidos aqui: ícone discreto ao lado
          // da mana (com selo de quantidade); abre o quadro da mesa.
          // Respiro antes p/ não grudar no limpar-mana (ou no +).
          const SizedBox(width: 8),
          _markerBtn(upsideDown: upsideDown),
        ],
      ),
    );
  }

  /// Ficha em modo lista: linha compacta com tudo à mão.
  Widget _tokenRow(_Token t) {
    final base = '${t.power}/${t.toughness}';
    final eff = '${effP(t)}/${effT(t)}';
    return Card(
      color: t.tapped ? AppTheme.goldSoft : AppTheme.card,
      child: ListTile(
        dense: true,
        leading: _tokenThumb(t, 44),
        title: Text(t.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
            '$eff${eff != base ? ' (base $base)' : ''}'
            '${t.owner.isNotEmpty ? ' • ${t.owner}' : ''}'
            '${t.tapped ? ' • virada' : ''}',
            style: const TextStyle(color: AppTheme.textMuted)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
                onTap: () => _tokenCounter(t, -1),
                child: const Icon(Icons.remove_circle_outline, size: 22)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('${t.counters}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            InkWell(
                onTap: () => _tokenCounter(t, 1),
                child: const Icon(Icons.add_circle,
                    color: AppTheme.gold, size: 22)),
            InkWell(
              onTap: () => _tokenTap(t),
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                    t.tapped ? Icons.rotate_right_outlined : Icons.rotate_right,
                    color: AppTheme.gold,
                    size: 22),
              ),
            ),
          ],
        ),
        onTap: () => _tokenOptions(t),
      ),
    );
  }

  /// Miniatura da arte da ficha (ou ícone).
  Widget _tokenThumb(_Token t, double size) {
    if (t.art.isEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: const Icon(Icons.style, color: AppTheme.textFaint),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: t.art,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
      ),
    );
  }

  /// Opções ao tocar na ficha: inclui a resolução guiada quando a ficha
  /// possui uma ação que o auxiliar conhece.
  /// Informações da carta (SEGURAR na mesa): arte, custo, tipo,
  /// habilidades, P/T, descrição, marcadores e dono. Só leitura, com
  /// atalhos para Opções e Virar — não atrapalha o toque (que vira).
  Future<void> _tokenInfo(_Token t, {bool upsideDown = false}) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          // Resolve a pilha e a líder A CADA build: viram objetos novos
          // no eco da rede; o [t] original só dá o molde (nunca muda).
          final mates = _stackMates(t);
          final show = mates.isNotEmpty ? mates.first : t;
          final base = '${show.power}/${show.toughness}';
          final eff = '${effP(show)}/${effT(show)}';
          final isUtility = show.power == 0 && show.toughness == 0;
          // Fileira rápida − n + (cópias ou +1/+1): repete sem fechar.
          Widget quickStep(
              {required String title,
              required String value,
              required VoidCallback minus,
              required VoidCallback plus}) {
            btn(IconData icon, VoidCallback fn) => IconButton(
                  icon: Icon(icon, size: 26),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 48, minHeight: 48),
                  onPressed: fn,
                );
            return Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 11)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        btn(Icons.remove_circle_outline, minus),
                        SizedBox(
                          width: 52,
                          child: Text(value,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                        ),
                        btn(Icons.add_circle, plus),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }

          void refresh() {
            if (ctx.mounted) setD(() {});
          }

          return RotatedBox(
            quarterTurns: upsideDown ? 2 : 0,
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        quickStep(
                          title: AppLocale.t('token_more'),
                          value: '×${mates.length}',
                          minus: () {
                            _stackCopyBump(t, -1);
                            if (_stackMates(t).isEmpty) {
                              Navigator.pop(ctx);
                            } else {
                              refresh();
                            }
                          },
                          plus: () {
                            _stackCopyBump(t, 1);
                            refresh();
                          },
                        ),
                        const SizedBox(width: 8),
                        quickStep(
                          title: '+1/+1',
                          value: '+${show.counters}',
                          minus: () {
                            _tokenCounterQuick(show, -1);
                            refresh();
                          },
                          plus: () {
                            _tokenCounterQuick(show, 1);
                            refresh();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (show.art.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: show.art,
                          height: 170,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(show.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17)),
                        ),
                        if (show.cost.trim().isNotEmpty)
                          ManaCostRow(_normalizeCost(show.cost), size: 17),
                      ],
                    ),
                    if (show.type.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(show.type,
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                      ),
                    if (show.keywords.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final k in show.keywords)
                              Chip(
                                label: Text(AppLocale.t('ab_$k'),
                                    style:
                                        const TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                              ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          isUtility
                              ? '◆ ${AppLocale.t('token_utility')}'
                              : (eff == base
                                  ? 'P/T $eff'
                                  : 'P/T $eff (${AppLocale.t('token_base')} $base)'),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                    if (show.description.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(show.description,
                            style: const TextStyle(fontSize: 13)),
                      ),
                    if (show.counters != 0 ||
                        show.minus != 0 ||
                        show.loyalty != 0 ||
                        show.charge != 0 ||
                        show.marks.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                            _tokenMarksSummary(show),
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          '${show.owner.isEmpty ? '' : '${show.owner} • '}${show.tapped ? AppLocale.t('token_tapped') : AppLocale.t('token_untapped')}',
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 12)),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: Icon(show.tapped
                                ? Icons.rotate_right
                                : Icons.rotate_right_outlined,
                                size: 18),
                            label: Text(show.tapped
                                ? AppLocale.t('token_untap')
                                : AppLocale.t('token_tap')),
                            onPressed: () =>
                                Navigator.pop(context, 'tap'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.tune, size: 18),
                            label:
                                Text(AppLocale.t('token_options')),
                            onPressed: () =>
                                Navigator.pop(context, 'options'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (pick == 'tap') {
      _tokenTap(t);
    } else if (pick == 'options') {
      await _tokenOptions(t, upsideDown: upsideDown);
    }
  }

  /// Resumo dos marcadores p/ o sheet de info ("+3/+3, −1/−1...").
  String _tokenMarksSummary(_Token t) {
    final bits = <String>[];
    if (t.counters != 0) bits.add('+${t.counters}/+${t.counters}');
    if (t.minus != 0) bits.add('−${t.minus}/−${t.minus}');
    if (t.loyalty != 0) bits.add('❖${t.loyalty}');
    if (t.charge != 0) bits.add('⬢${t.charge}');
    for (final m in t.marks) {
      bits.add('${m.count}× ${m.label}${m.untilEOT ? ' ⏳' : ''}');
    }
    return bits.join(' • ');
  }

  Future<void> _tokenOptions(_Token t, {bool upsideDown = false}) async {
    final action = _utilityAction(t);
    // Sheet compacto: abraça o conteúdo (nunca estica até o topo) e
    // rola por dentro se a tela for pequena.
    final pick = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      builder: (_) => RotatedBox(
        quarterTurns: upsideDown ? 2 : 0,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                ListTile(
                    dense: true,
                    leading: const Icon(Icons.edit),
                    title: Text(AppLocale.t('token_edit')),
                    onTap: () => Navigator.pop(context, 'edit')),
                if (action != _UtilityAction.none)
                  ListTile(
                      dense: true,
                      leading: const Icon(Icons.play_circle_fill,
                          color: AppTheme.gold),
                      title: Text(_resolveLabel(action)),
                      subtitle: Text(AppLocale.t('token_resolve_sub')),
                      onTap: () => Navigator.pop(context, 'resolve')),
                ListTile(
                    dense: true,
                    leading:
                        const Icon(Icons.add_to_photos, color: AppTheme.gold),
                    title: Text(AppLocale.t('token_more')),
                    subtitle: Text(AppLocale.t('token_more_sub')),
                    onTap: () => Navigator.pop(context, 'more')),
                ListTile(
                    dense: true,
                    leading:
                        const Icon(Icons.arrow_upward, color: AppTheme.gold),
                    title: Text(AppLocale.t('token_buff')),
                    subtitle: Text(AppLocale.t('token_buff_sub')),
                    onTap: () => Navigator.pop(context, 'buff')),
                ListTile(
                    dense: true,
                    leading: const Icon(Icons.bolt, color: AppTheme.gold),
                    title: Text(AppLocale.t('token_giant')),
                    subtitle: Text(AppLocale.t('token_giant_sub')),
                    onTap: () => Navigator.pop(context, 'giant')),
                ListTile(
                    dense: true,
                    leading:
                        const Icon(Icons.donut_large, color: AppTheme.gold),
                    title: Text(AppLocale.t('token_counters')),
                    subtitle: Text(AppLocale.t('token_counters_sub')),
                    onTap: () => Navigator.pop(context, 'counters')),
                ListTile(
                    dense: true,
                    leading: const Icon(Icons.bookmark_add_outlined,
                        color: AppTheme.gold),
                    title: Text(AppLocale.t('token_marker')),
                    subtitle: Text(AppLocale.t('token_marker_sub')),
                    onTap: () => Navigator.pop(context, 'marker')),
                ListTile(
                    dense: true,
                    leading: const Icon(Icons.image),
                    title: Text(AppLocale.t('token_art')),
                    onTap: () => Navigator.pop(context, 'art')),
                ListTile(
                    dense: true,
                    leading: Icon(t.hideName == true
                        ? Icons.title
                        : Icons.title_outlined),
                    title: Text(t.hideName == true
                        ? AppLocale.t('token_show')
                        : AppLocale.t('token_hide')),
                    subtitle: Text(AppLocale.t('token_hide_sub')),
                    onTap: () => Navigator.pop(context, 'name_visibility')),
                Builder(builder: (_) {
                  final mates = _stackMates(t);
                  return ListTile(
                      dense: true,
                      leading: Icon(t.tapped
                          ? Icons.rotate_right
                          : Icons.rotate_right_outlined),
                      title: Text(t.tapped
                          ? AppLocale.t('token_untap')
                          : AppLocale.t('token_tap')),
                      subtitle: mates.length > 1
                          ? Text(
                              '×${mates.length} — ${AppLocale.t('tap_title').toLowerCase()}')
                          : null,
                      onTap: () => Navigator.pop(context, 'tap'));
                }),
                ListTile(
                    dense: true,
                    leading: const Icon(Icons.delete_outline,
                        color: Colors.redAccent),
                    title: Text(AppLocale.t('token_remove')),
                    onTap: () => Navigator.pop(context, 'remove')),
              ],
            ),
          ),
        ),
      ),
    );
    if (pick == null) return;
    switch (pick) {
      case 'edit':
        await _tokenDialog(existing: t, upsideDown: upsideDown);
        break;
      case 'resolve':
        await _activateToken(t, upsideDown: upsideDown);
        break;
      case 'more':
        await _addMoreTokens(t, upsideDown: upsideDown);
        break;
      case 'buff':
        await _buffDialog(t, untilEOT: false, upsideDown: upsideDown);
        break;
      case 'giant':
        await _buffDialog(t, untilEOT: true, upsideDown: upsideDown);
        break;
      case 'counters':
        await _countersSheet(t, upsideDown: upsideDown);
        break;
      case 'marker':
        await _markerDialog(tokenId: t.id, upsideDown: upsideDown);
        break;
      case 'art':
        await _artSearch(t, upsideDown: upsideDown);
        break;
      case 'name_visibility':
        _toggleTokenName(t);
        break;
      case 'tap':
        await _tapChoice(t, upsideDown: upsideDown);
        break;
      case 'remove':
        _tokenRemove(t);
        break;
    }
  }

  void _tapMany(List<_Token> targets, bool tapped) {
    if (targets.isEmpty) return;
    final msg = AppLocale.t(
            tapped ? 'tok_many_tapped' : 'tok_many_untapped')
        .replaceAll('{q}', '${targets.length}')
        .replaceAll('{n}', targets.first.name);
    if (_isGuest) {
      for (final o in targets) {
        _send({'action': 'token_tap', 'id': o.id, 'tapped': tapped});
      }
      AppToast.show(context, msg);
      return;
    }
    _recordHistory(
        '${tapped ? 'Virou' : 'Desvirou'} ${targets.length} ${targets.first.name}');
    setState(() {
      for (final o in targets) {
        o.tapped = tapped;
      }
    });
    AppToast.show(context, msg);
    _broadcast();
  }

  /// Virar/desvirar em massa: se a pilha tem 1, alterna direto; senão
  /// abre opções rápidas (1, 2, 5, 10, todas = máx. da pilha).
  Future<void> _tapChoice(_Token t, {bool upsideDown = false}) async {
    final mates = _stackMates(t)..sort((a, b) => a.id.compareTo(b.id));
    if (mates.length < 2) {
      _tokenTap(t);
      return;
    }
    var toTap = mates.any((m) => !m.tapped);
    var count = 1;
    final custom = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setD) {
          final pool = mates.where((m) => m.tapped != toTap).toList();
          final max = pool.length;
          if (count > max && max > 0) count = max;
          if (count < 1 && max > 0) count = 1;
          return RotatedBox(
            quarterTurns: upsideDown ? 2 : 0,
            child: SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                          '${AppLocale.t('tap_title')}: ${t.name} (×${mates.length})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(
                            value: true,
                            label: Text(AppLocale.t('tap_to_tap').replaceAll(
                                '{n}',
                                '${mates.where((m) => !m.tapped).length}')),
                          ),
                          ButtonSegment(
                            value: false,
                            label: Text(AppLocale.t('tap_to_untap').replaceAll(
                                '{n}',
                                '${mates.where((m) => m.tapped).length}')),
                          ),
                        ],
                        selected: {toTap},
                        onSelectionChanged: (s) => setD(() {
                          toTap = s.first;
                          custom.clear();
                          count = mates.where((m) => m.tapped != toTap).length;
                        }),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final v in [1, 2, 5, 10])
                            if (v <= max)
                              ChoiceChip(
                                label: Text('$v'),
                                selected: count == v && custom.text.isEmpty,
                                onSelected: (_) => setD(() {
                                  count = v;
                                  custom.clear();
                                }),
                              ),
                          if (max > 0)
                            ChoiceChip(
                              label: Text(AppLocale.t('tap_all')
                                  .replaceAll('{n}', '$max')),
                              selected: count == max && custom.text.isEmpty,
                              onSelected: (_) => setD(() {
                                count = max;
                                custom.clear();
                              }),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: TextField(
                        controller: custom,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: AppLocale.t('su_qty_custom')),
                        onChanged: (v) => setD(() => count =
                            (int.tryParse(v) ?? 1).clamp(1, max > 0 ? max : 1)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(AppLocale.t('common_cancel')),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: max == 0
                                  ? null
                                  : () => Navigator.pop(ctx, true),
                              child: Text(AppLocale.t('common_apply')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    final n = count.clamp(1, mates.length);
    _laterDispose(custom);
    if (ok != true) return;
    final pool =
        mates.where((m) => m.tapped != toTap).toList().take(n).toList();
    _tapMany(pool, toTap);
  }

  Future<void> _addMoreTokens(_Token t, {bool upsideDown = false}) async {
    var amount = 1;
    final custom = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setD) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: AlertDialog(
            scrollable: true,
            title: Text(AppLocale.t('su_add_more').replaceAll('{n}', t.name)),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Wrap(spacing: 6, children: [
                for (final value in [1, 2, 5, 10])
                  ChoiceChip(
                      label: Text('+$value'),
                      selected: amount == value && custom.text.isEmpty,
                      onSelected: (_) => setD(() {
                            amount = value;
                            custom.clear();
                          })),
              ]),
              TextField(
                controller: custom,
                keyboardType: TextInputType.number,
                decoration:
                    InputDecoration(labelText: AppLocale.t('su_qty_custom')),
                onChanged: (v) => setD(() => amount = int.tryParse(v) ?? 1),
              ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(AppLocale.t('common_cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(AppLocale.t('common_add'))),
            ],
          ),
        ),
      ),
    );
    final count = amount.clamp(1, 20).toInt();
    _laterDispose(custom);
    if (ok == true) {
      _createPreset(t.name, t.power, t.toughness, t.owner,
          description: t.description,
          quantity: count,
          art: t.art.isNotEmpty ? t.art : _artForName(t.name),
          cost: t.cost,
          type: t.type,
          keywords: [...t.keywords]);
    }
  }

  /// Marcadores da carta/ficha, como no jogo real:
  /// +1/+1 e -1/-1 (entram no P/T e se anulam em pares), lealdade e carga
  /// (só selos) e personalizados (marcação pura, permanentes ou até o
  /// fim do turno, podendo ser negativos). Vale pros dois lados.
  Future<void> _countersSheet(_Token t, {bool upsideDown = false}) async {
    var plus = t.counters;
    var mn = t.minus;
    var loy = t.loyalty;
    var chg = t.charge;
    // Cópia de trabalho dos personalizados (vai inteira na rede).
    var customs = [
      for (final m in t.marks)
        _Mark(label: m.label, count: m.count, untilEOT: m.untilEOT)
    ];

    Widget stepper(int v, void Function(int) step, StateSetter setD,
        {int min = 0}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 22),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            onPressed: v <= min
                ? null
                : () {
                    step(-1);
                    setD(() {});
                  },
          ),
          SizedBox(
            width: 34,
            child: Text('$v',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle, color: AppTheme.gold, size: 22),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            onPressed: () {
              step(1);
              setD(() {});
            },
          ),
        ],
      );
    }

    Widget row(String label, String sub, int v, void Function(int) step,
        StateSetter setD,
        {int min = 0}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(sub,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 12)),
                ],
              ),
            ),
            stepper(v, step, setD, min: min),
          ],
        ),
      );
    }

    Future<void> addCustom(StateSetter setD) async {
      final created = await _newMarkDialog(upsideDown: upsideDown);
      if (created == null) return;
      final i = customs.indexWhere(
          (m) => m.label.toLowerCase() == created.label.toLowerCase());
      if (i >= 0) {
        customs[i] = _Mark(
            label: customs[i].label,
            count: (customs[i].count + created.count).clamp(-99, 99),
            untilEOT: created.untilEOT);
      } else {
        customs.add(created);
      }
      _setMarks(t, customs);
      setD(() {});
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => RotatedBox(
        quarterTurns: upsideDown ? 2 : 0,
        child: SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setD) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                        '${AppLocale.t('token_counters_title')} ${t.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  row('+1/+1', AppLocale.t('token_counters_pt'), plus, (d) {
                    _tokenCounter(t, d);
                    plus = (plus + d).clamp(0, 99);
                    // Anulação em pares pode ter mexido no -1/-1 também.
                    mn = t.minus;
                  }, setD),
                  row(AppLocale.t('mk_minus'), AppLocale.t('mk_minus_sub'), mn,
                      (d) {
                    _tokenMinus(t, d);
                    mn = (mn + d).clamp(0, 99);
                    plus = t.counters;
                  }, setD),
                  row(AppLocale.t('token_loyalty'),
                      AppLocale.t('token_counters_seal'), loy, (d) {
                    _tokenLoyalty(t, d);
                    loy = (loy + d).clamp(0, 99);
                  }, setD),
                  row(AppLocale.t('token_charge'),
                      AppLocale.t('token_counters_seal'), chg, (d) {
                    _tokenCharge(t, d);
                    chg = (chg + d).clamp(0, 99);
                  }, setD),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Divider(),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(AppLocale.t('mk_custom'),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                  if (customs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(AppLocale.t('mk_empty'),
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                      ),
                    )
                  else
                    for (var i = 0; i < customs.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      '${customs[i].label}${customs[i].untilEOT ? ' ⏳' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  Text(AppLocale.t('token_counters_seal'),
                                      style: const TextStyle(
                                          color: AppTheme.textMuted,
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                            stepper(customs[i].count, (d) {
                              customs[i] = _Mark(
                                  label: customs[i].label,
                                  count: (customs[i].count + d).clamp(-99, 99),
                                  untilEOT: customs[i].untilEOT);
                              _setMarks(t, customs);
                            }, setD, min: -99),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 20, color: Colors.redAccent),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 34, minHeight: 34),
                              onPressed: () {
                                customs.removeAt(i);
                                _setMarks(t, customs);
                                setD(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => addCustom(setD),
                        icon: const Icon(Icons.add, size: 16),
                        label: Text(AppLocale.t('mk_new')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Novo marcador personalizado: nome, quantidade (pode ser negativa)
  /// e duração (permanente ou até o fim do turno).
  Future<_Mark?> _newMarkDialog({bool upsideDown = false}) async {
    final nameC = TextEditingController();
    var count = 1;
    var eot = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setD) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: AlertDialog(
            scrollable: true,
            title: Text(AppLocale.t('mk_new')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameC,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: AppLocale.t('mk_name')),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(AppLocale.t('mk_count'),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () =>
                        setD(() => count = (count - 1).clamp(-99, 99)),
                  ),
                  Text('$count',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: AppTheme.gold),
                    onPressed: () =>
                        setD(() => count = (count + 1).clamp(-99, 99)),
                  ),
                ],
              ),
              Row(
                children: [
                  ChoiceChip(
                    label: Text(AppLocale.t('mk_perm')),
                    selected: !eot,
                    onSelected: (_) => setD(() => eot = false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(AppLocale.t('mk_eot')),
                    selected: eot,
                    onSelected: (_) => setD(() => eot = true),
                  ),
                ],
              ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(AppLocale.t('common_cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(AppLocale.t('common_add'))),
            ],
          ),
        ),
      ),
    );
    final label = nameC.text.trim();
    _laterDispose(nameC);
    if (ok != true || label.isEmpty) return null;
    return _Mark(label: label, count: count.clamp(-99, 99), untilEOT: eot);
  }

  Future<void> _buffDialog(_Token t,
      {required bool untilEOT, bool upsideDown = false}) async {
    final candidates = _tokens.where((other) =>
        other.owner == t.owner &&
        other.ownerUid == t.ownerUid &&
        _sameTemplate(other, t.name, t.power, t.toughness, t.description) &&
        other.tapped == t.tapped &&
        other.counters == t.counters &&
        other.minus == t.minus &&
        other.loyalty == t.loyalty &&
        other.charge == t.charge &&
        other.art == t.art);
    final stack = _groupTokens(candidates)
        .firstWhere((group) => group.tokens.any((token) => token.id == t.id));
    final sameStack = stack.tokens;
    var power = untilEOT ? 3 : 1;
    var toughness = untilEOT ? 3 : 1;
    var count = 1;
    final custom = TextEditingController();
    final powerCtrl = TextEditingController(text: '$power');
    final toughnessCtrl = TextEditingController(text: '$toughness');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setD) => RotatedBox(
          quarterTurns: upsideDown ? 2 : 0,
          child: AlertDialog(
            title: Text(untilEOT
                ? AppLocale.t('su_giant_t')
                : AppLocale.t('su_buff_t')),
            content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              Wrap(spacing: 6, children: [
                for (final value in [1, 2, 3, 5])
                  ChoiceChip(
                      label: Text('+$value/+$value'),
                      selected: power == value && toughness == value,
                      onSelected: (_) => setD(() {
                            power = value;
                            toughness = value;
                            powerCtrl.text = '$value';
                            toughnessCtrl.text = '$value';
                          })),
              ]),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: powerCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (v) => power = int.tryParse(v) ?? power,
                        decoration: InputDecoration(
                            labelText: AppLocale.t('su_power_full')))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: toughnessCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (v) =>
                            toughness = int.tryParse(v) ?? toughness,
                        decoration: InputDecoration(
                            labelText: AppLocale.t('su_res_full')))),
              ]),
              const SizedBox(height: 12),
              Text(AppLocale.t('su_how_many')
                  .replaceAll('{n}', '${sameStack.length}')),
              Wrap(spacing: 6, children: [
                for (final value in [1, 2, 3])
                  if (value <= sameStack.length)
                    ChoiceChip(
                        label: Text('$value'),
                        selected: count == value && custom.text.isEmpty,
                        onSelected: (_) => setD(() {
                              count = value;
                              custom.clear();
                            })),
                ChoiceChip(
                    label: Text(AppLocale.t('su_all_of')
                        .replaceAll('{n}', '${sameStack.length}')),
                    selected: count == sameStack.length && custom.text.isEmpty,
                    onSelected: (_) => setD(() {
                          count = sameStack.length;
                          custom.clear();
                        })),
              ]),
              TextField(
                  controller: custom,
                  keyboardType: TextInputType.number,
                  decoration:
                      InputDecoration(labelText: AppLocale.t('su_qty_custom')),
                  onChanged: (v) => setD(() => count = int.tryParse(v) ?? 1)),
            ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(AppLocale.t('common_cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(AppLocale.t('common_apply'))),
            ],
          ),
        ),
      ),
    );
    _laterDispose(custom);
    _laterDispose(powerCtrl);
    _laterDispose(toughnessCtrl);
    if (ok != true) return;
    _applyBuff(sameStack.take(count.clamp(1, sameStack.length).toInt()), power,
        toughness, untilEOT);
  }

  void _applyBuff(Iterable<_Token> targets, int p, int q, bool eot) {
    final tokens = targets.toList();
    if (tokens.isEmpty) return;
    if (_isGuest) {
      for (final token in tokens) {
        _send({
          'action': 'effect_add',
          'effect': _TokenEffect(
                  id: 0,
                  label: eot ? 'Bônus' : 'Marcador+',
                  power: p,
                  toughness: q,
                  targetId: token.id,
                  untilEOT: eot)
              .toJson()
        });
      }
      return;
    }
    _recordHistory('Aplicou +$p/+$q em ${tokens.length} ${tokens.first.name}');
    setState(() {
      for (final token in tokens) {
        _effects.add(_TokenEffect(
            id: _effectSeq++,
            label: eot ? 'Bônus' : 'Marcador+',
            power: p,
            toughness: q,
            targetId: token.id,
            untilEOT: eot));
      }
    });
    _broadcast();
  }

  /// Texto amigável para falha de rede/Scryfall (ex. 503 manutenção).
  String _artErrorText(Object e) {
    final s = e.toString();
    if (s.contains('503')) return AppLocale.t('art_maintenance');
    return AppLocale.t('art_error');
  }

  /// Busca arte oficial da ficha no Scryfall (t:token), no idioma escolhido.
  /// Se não existir nesse idioma, cai para qualquer idioma que tenha.
  /// Palavra do oráculo em inglês p/ o filtro `o:` do Scryfall.
  static String _abilityOracle(String key) => switch (key) {
        'first_strike' => 'first strike',
        'double_strike' => 'double strike',
        _ => key.replaceAll('_', ' '),
      };

  Future<void> _artSearch(_Token t, {bool upsideDown = false}) async {
    const langOptions = ['all', 'pt', 'en', 'es', 'ja', 'zhs'];
    var artLang = 'all';
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = (prefs.getString('token_art_lang') ?? 'all').trim();
      if (langOptions.contains(saved)) artLang = saved;
    } catch (_) {}
    if (!mounted) return;
    List<Map<String, dynamic>> results = [];
    bool loading = true;
    String? error;
    var attempt = 0;
    // Filtros Scryfall (vêm preenchidos da ficha: P/T e habilidades).
    final pC = TextEditingController(
        text: t.power > 0 ? '${t.power}' : '');
    final tC = TextEditingController(
        text: t.toughness > 0 ? '${t.toughness}' : '');
    final selAbs = <String>{...t.keywords};
    String mods() {
      final b = StringBuffer();
      final p = int.tryParse(pC.text.trim());
      final tt = int.tryParse(tC.text.trim());
      if (p != null) b.write(' pow=$p');
      if (tt != null) b.write(' tou=$tt');
      // SEM espaço após o ':' — `o: flying` vira texto livre "flying"
      // e zera tudo (404); o certo é `o:flying` / `o:"first strike"`.
      for (final k in selAbs) {
        final word = _abilityOracle(k);
        b.write(word.contains(' ') ? ' o:"$word"' : ' o:$word');
      }
      return b.toString();
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          void kickoff() {
            attempt++;
            final my = attempt;
            final m = mods();
            _findTokenArt(t.name, lang: artLang, mods: m).then((r) {
              if (!ctx.mounted || my != attempt) return;
              setD(() {
                results = r.take(15).toList();
                loading = false;
              });
            }).catchError((e) {
              if (!ctx.mounted || my != attempt) return;
              setD(() {
                error = _artErrorText(e);
                loading = false;
              });
            });
          }

          if (attempt == 0) kickoff();
          return RotatedBox(
            quarterTurns: upsideDown ? 2 : 0,
            child: SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Column(children: [
                        Text('${AppLocale.t('art_choose')} "${t.name}"',
                            textAlign: TextAlign.center,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 3),
                        Text(AppLocale.t('art_scope'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(AppLocale.t('art_lang'),
                                style: const TextStyle(
                                    color: AppTheme.textMuted, fontSize: 12)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final l in langOptions)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: ChoiceChip(
                                          label: Text(
                                              l == 'all'
                                                  ? AppLocale.t('art_all')
                                                  : (ScryfallService
                                                          .languageLabels[l] ??
                                                      l),
                                              style: const TextStyle(
                                                  fontSize: 12)),
                                          selected: artLang == l,
                                          onSelected: (_) async {
                                            if (artLang == l) return;
                                            artLang = l;
                                            try {
                                              final prefs =
                                                  await SharedPreferences
                                                      .getInstance();
                                              await prefs.setString(
                                                  'token_art_lang', l);
                                            } catch (_) {}
                                            setD(() {
                                              results = [];
                                              error = null;
                                              loading = true;
                                            });
                                            kickoff();
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Filtros: P/T + habilidades (ex. dragão 5/5
                        // voando). Vêm da ficha; filtrar rebusca.
                        Row(
                          children: [
                            SizedBox(
                              width: 64,
                              child: TextField(
                                controller: pC,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                    labelText: AppLocale.t('art_pow'),
                                    isDense: true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 64,
                              child: TextField(
                                controller: tC,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                    labelText: AppLocale.t('art_tou'),
                                    isDense: true),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.filter_alt,
                                  size: 20, color: AppTheme.gold),
                              tooltip: AppLocale.t('art_filter'),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 36, minHeight: 36),
                              onPressed: () {
                                setD(() {
                                  results = [];
                                  error = null;
                                  loading = true;
                                });
                                kickoff();
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final k in _Token.abilityKeys)
                              FilterChip(
                                label: Text(AppLocale.t('ab_$k'),
                                    style:
                                        const TextStyle(fontSize: 11)),
                                selected: selAbs.contains(k),
                                visualDensity: VisualDensity.compact,
                                onSelected: (_) {
                                  setD(() {
                                    if (!selAbs.remove(k)) selAbs.add(k);
                                    results = [];
                                    error = null;
                                    loading = true;
                                  });
                                  kickoff();
                                },
                              ),
                          ],
                        ),
                      ]),
                    ),
                    if (loading)
                      const Expanded(
                          child: Center(child: CircularProgressIndicator()))
                    else if (error != null)
                      Expanded(
                          child: Center(
                              child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.orange)),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: () {
                                setD(() {
                                  error = null;
                                  loading = true;
                                });
                                kickoff();
                              },
                              icon: const Icon(Icons.refresh, size: 16),
                              label: Text(AppLocale.t('common_retry')),
                            ),
                          ],
                        ),
                      )))
                    else if (results.isEmpty)
                      Expanded(
                          child: Center(
                              child: Text(AppLocale.t('art_empty'),
                                  style: const TextStyle(
                                      color: AppTheme.textMuted))))
                    else
                      Expanded(
                        child: GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 63 / 88,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final d = results[i];
                            final u = ScryfallService.extractImageUrl(d);
                            final lg = (d['lang'] ?? '').toString().toUpperCase();
                            return GestureDetector(
                              onTap: () => Navigator.pop(ctx, u),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (u == null || u.isEmpty)
                                      const Icon(Icons.style)
                                    else
                                      CachedNetworkImage(
                                        imageUrl: u,
                                        fit: BoxFit.cover,
                                        memCacheWidth: 300,
                                      ),
                                    if (lg.isNotEmpty)
                                      Positioned(
                                        left: 4,
                                        bottom: 4,
                                        child: Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 5, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.black
                                                .withValues(alpha: 0.65),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(lg,
                                              style: const TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white)),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).then((url) {
      _laterDispose(pC);
      _laterDispose(tC);
      if (url is String && url.isNotEmpty) {
        _setTokenArt(t, url);
      }
    });
  }

  /// Scryfall indexa a maior parte das fichas pelo nome em inglês. Tenta o
  /// nome usado na mesa e depois a tradução dos presets em português.
  /// `lang`: idioma preferido ('all' = qualquer um). Se nada for achado
  /// nesse idioma, tenta de novo sem filtro (pega o que existir).
  /// `mods`: restinho Scryfall (ex. ' pow=5 tou=5 o:"flying"').
  Future<List<Map<String, dynamic>>> _findTokenArt(String tokenName,
      {String lang = 'all', String mods = ''}) async {
    final normalized = ScryfallService.normalize(tokenName);
    const englishNames = {
      'tesouro': 'Treasure',
      'ouro': 'Gold',
      'pista': 'Clue',
      'comida': 'Food',
      'sangue': 'Blood',
      'mapa': 'Map',
      'pedra de poder': 'Powerstone',
      'soldado': 'Soldier',
      'humano': 'Human',
      'goblin': 'Goblin',
      'elfo': 'Elf',
      'espirito': 'Spirit',
      'servo': 'Servo',
      'saprofita': 'Saproling',
      'rato': 'Rat',
      'passaro': 'Bird',
      'esqueleto': 'Skeleton',
      'vampiro': 'Vampire',
      'zumbi': 'Zombie',
      'lobo': 'Wolf',
      'cavaleiro': 'Knight',
      'guerreiro': 'Warrior',
      'besta': 'Beast',
      'anjo': 'Angel',
      'dragao': 'Dragon',
      'demonio': 'Demon',
      'inseto': 'Insect',
      'gato': 'Cat',
      'peixe': 'Fish',
      'urso': 'Bear',
      'rinoceronte': 'Rhino',
    };
    final terms = <String>[];
    final english = englishNames[normalized];
    // O filtro `t:` do Scryfall só entende inglês: tentar "t:token Tesouro"
    // sempre dá 404 antes de cair no inglês. Quando há tradução conhecida,
    // tenta o inglês PRIMEIRO (acerta de 1ª e evita o 404 + requests extras).
    if (english != null) terms.add(english);
    if (!terms.contains(tokenName)) terms.add(tokenName);
    Object? lastError;
    // 1ª passada: idioma preferido. 2ª: qualquer idioma que tenha.
    // Sem bônus de coletor (dígitos de pow/tou não são nº) e, em
    // 'all', separando por idioma p/ mostrar PT/EN/ES… na grade.
    for (final passLang in [lang, if (lang != 'all') 'all']) {
      for (final term in terms) {
        try {
          final found = await ScryfallService.instance.search(
              't:token $term$mods',
              lang: passLang,
              scoreCollector: false,
              byLanguage: true);
          if (found.isNotEmpty) return found;
        } catch (e) {
          lastError = e;
          // Erro de rede/manutenção interrompe: não adianta trocar o termo.
          break;
        }
      }
      if (lastError != null) break;
    }
    if (lastError != null) throw lastError;
    return [];
  }

  void _setTokenArt(_Token t, String url) {
    // A arte é por NOME e vale para os dois players: atualiza todas as
    // fichas com esse nome, sejam minhas ou do oponente.
    final key = t.name.trim().toLowerCase();
    // Salva no aparelho: próxima mesa com esse nome já nasce com arte,
    // sem precisar buscar de novo (vale p/ host e guest).
    _rememberArt(t.name, url);
    final matching = _tokens
        .where((other) => other.name.trim().toLowerCase() == key)
        .toList();
    if (_isGuest) {
      for (final other in matching) {
        _send({'action': 'token_set', 'id': other.id, 'art': url});
      }
      return;
    }
    _recordHistory('Definiu arte para ${t.name}');
    setState(() {
      for (final other in matching) {
        other.art = url;
      }
    });
    _broadcast();
  }

  /// Selos dos marcadores personalizados (máx. 2 + contador).
  List<Widget> _customSeals(_Token t, bool namesHidden, bool upsideDown) {
    var top = (namesHidden ? 4 : 32).toDouble();
    if (t.loyalty > 0) top += 24;
    if (t.charge > 0) top += 24;
    const sealColor = Color(0xFF80DEEA);
    final out = <Widget>[];
    final shown = t.marks.length > 2 ? 2 : t.marks.length;
    for (var i = 0; i < shown; i++) {
      final m = t.marks[i];
      final short =
          m.label.length > 8 ? '${m.label.substring(0, 8)}…' : m.label;
      out.add(Positioned(
        top: top + i * 24,
        left: 5,
        child: _miniSeal('${m.count}× $short', sealColor,
            () => _countersSheet(t, upsideDown: upsideDown)),
      ));
    }
    if (t.marks.length > 2) {
      out.add(Positioned(
        top: top + shown * 24,
        left: 5,
        child: _miniSeal('+${t.marks.length - shown}', sealColor,
            () => _countersSheet(t, upsideDown: upsideDown)),
      ));
    }
    return out;
  }

  /// Selinho clicável (lealdade/carga) no canto da ficha.
  Widget _miniSeal(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 11)),
      ),
    );
  }

  /// Uma pilha ocupa o espaço de uma carta. As bordas deslocadas atrás da
  /// carta principal deixam claro que há várias cópias, sem poluir a mesa.
  /// Virada mantém o tamanho paisagem (h×w) mas centralizada
  /// verticalmente no slot — antes ficava grudada no topo. Empilhada
  /// ou não, o centro vertical fica fixo.
  /// Estilo da mesa pelo DONO da ficha (para pilhas sem contexto de
  /// zona): acha o jogador pelo nome; fora da partida, global.
  _TableStyle _ownerStyle(String owner) {
    final n = owner.trim().toLowerCase();
    if (n.isNotEmpty) {
      for (final p in _players) {
        if (p.name.trim().toLowerCase() == n) return _styleFor(p);
      }
    }
    return _tableStyle;
  }

  Widget _tokenStackMini(_TokenStack stack,
      {double w = 110,
      double h = 154,
      bool upsideDown = false,
      _TableStyle? style}) {
    // Quantas cartas visíveis: a frente + cópias atrás, até o máximo
    // dos Ajustes (1 = só a frente).
    final layers =
        (stack.count - 1).clamp(0, PlayPrefs.stackVisible.value - 1);
    final lead = stack.lead;
    final st = style ?? _ownerStyle(lead.owner);
    // Virada de verdade: a carta gira 90º (ocupa h×w em vez de w×h).
    final rot = lead.tapped && PlayPrefs.rotateTapped.value;
    final fw = rot ? h : w;
    final fh = rot ? w : h;
    // Cascata: reta desce pouco (6px) e abre 5px de lado; virada abre
    // 16px abaixo (26px descia demais) com a da frente no topo e as
    // outras à mostra. Laterais justas, sem vão grande.
    final offD = rot ? 10.0 : 0.0;
    final offL = rot ? 0.0 : 10.0;
    final innerH = fh + layers * offD;
    final body = Stack(
      children: [
        for (var layer = layers; layer > 0; layer--)
          Positioned(
            left: layer * offL,
            top: layer * offD,
            width: fw,
            height: fh,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              // Virada: as de trás giram junto com a da frente.
              child: rot
                  ? RotatedBox(
                      quarterTurns: 1,
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (lead.art.isNotEmpty)
                                CachedNetworkImage(
                                    imageUrl: lead.art,
                                    fit: BoxFit.cover,
                                    memCacheWidth: (w * 2).toInt())
                              else
                                Container(
                                    decoration: BoxDecoration(
                                  color: AppTheme.goldSoft,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: AppTheme.gold, width: 1.2),
                                )),
                              Container(
                                  color: Colors.black
                                      .withValues(alpha: 0.18)),
                            ]),
                      ),
                    )
                    : Stack(fit: StackFit.expand, children: [
                        if (lead.art.isNotEmpty)
                          CachedNetworkImage(
                              imageUrl: lead.art,
                              fit: BoxFit.cover,
                              memCacheWidth: (w * 2).toInt())
                        else
                          Container(
                              decoration: BoxDecoration(
                            color: lead.tapped
                                ? AppTheme.goldSoft
                                : st.panel,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppTheme.gold, width: 1.2),
                          )),
                      Container(
                          color: Colors.black.withValues(alpha: 0.18)),
                    ]),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            width: fw,
            height: fh,
            child: _tokenMini(lead,
                w: w,
                h: h,
                stackedCount: stack.count,
                upsideDown: upsideDown,
                style: st),
          ),
      ],
    );
    // Reta: layout original intocado. Virada: centraliza verticalmente
    // no slot para não grudar no topo.
    if (!rot) {
      return SizedBox(
        width: fw + layers * offL + 4,
        height: fh + layers * 6.0,
        child: body,
      );
    }
    return SizedBox(
      width: fw + layers * offL + 4,
      height: h + layers * 6.0,
      // Viés leve para cima (centro com -0.2): a virada respira em
      // cima sem mudar nenhum tamanho.
      child: Align(
        alignment: const Alignment(-1.0, -0.2),
        child: SizedBox(width: fw, height: innerH, child: body),
      ),
    );
  }

  /// Mini ficha (fileiras laterais): nome centralizado + P/T + descrição.
  /// Fichas utilitárias (Tesouro, Pista...) têm o botão de resolver no
  /// centro inferior, ao lado do P/T e da quantidade da pilha.
  /// Toque vira/desvira; SEGURAR mostra as informações. Opções (editar,
  /// ativar, buff, arte, remover) ficam no sheet de info e nos selos.
  Widget _tokenMini(_Token t,
      {double w = 110,
      double h = 154,
      int stackedCount = 1,
      bool upsideDown = false,
      _TableStyle? style}) {
    final st = style ?? _ownerStyle(t.owner);
    final eff = '${effP(t)}/${effT(t)}';
    final utility = t.power == 0 && t.toughness == 0;
    final action = _utilityAction(t);
    // "Sempre ocultar" (Ajustes) ou a pilha oculta: esconde o nome.
    final namesHidden = PlayPrefs.hideTokenNames.value || t.hideName == true;
    // Habilidades: faixa sob o nome ou pílula no centro (Ajustes).
    final kwCenter = PlayPrefs.keywordPos.value == 'center';
    final kwText =
        t.keywords.map((k) => AppLocale.t('ab_$k')).join(' • ');
    final canResolve = action != _UtilityAction.none && !t.tapped;
    // Virada de verdade (Ajustes): gira 90º como no jogo físico.
    // Sem a opção, mantém o selo VIRADA sobre a carta reta.
    final realRotate = t.tapped && PlayPrefs.rotateTapped.value;
    final inner = SizedBox(
      width: w,
      height: h,
      child: InkWell(
        // Toque vira/desvira direto; segurar mostra as informações.
        onTap: () => _tokenTap(t),
        onLongPress: () => _tokenInfo(t, upsideDown: upsideDown),
        borderRadius: BorderRadius.circular(12),
        child: Stack(children: [
          Positioned.fill(
            child: Card(
              margin: EdgeInsets.zero,
              color: t.tapped ? AppTheme.goldSoft : st.panel,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                // Sem arte: bordinha simples para destacar na mesa.
                side: t.art.isEmpty
                    ? const BorderSide(
                        color: AppTheme.gold, width: 1.2)
                    : BorderSide.none,
              ),
              child: Stack(fit: StackFit.expand, children: [
                if (t.art.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: t.art,
                    fit: BoxFit.cover,
                    memCacheWidth: (w * 2).toInt(),
                    errorWidget: (_, __, ___) => const Center(
                        child: Icon(Icons.broken_image,
                            color: AppTheme.textFaint)),
                  )
                else
                  Container(
                      color: t.tapped ? AppTheme.goldSoft : st.panel),
                // Habilidades no CENTRO (opção dos Ajustes): pílula com
                // letreiros infinitos de habilidades + descrição.
                if (kwCenter &&
                    (t.keywords.isNotEmpty ||
                        t.description.trim().isNotEmpty))
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 30, 8, 34),
                      child: Container(
                        constraints:
                            BoxConstraints(maxWidth: (w - 16).clamp(40.0, 600.0)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (t.keywords.isNotEmpty)
                              Marquee(kwText,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                      color: Colors.white)),
                            if (t.description.trim().isNotEmpty)
                              Marquee(t.description.trim(),
                                  style: const TextStyle(
                                      fontSize: 10,
                                      height: 1.15,
                                      color: Colors.white70)),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (!kwCenter &&
                    t.art.isEmpty &&
                    t.description.isNotEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 30, 8, 34),
                      child: Text(t.description,
                          textAlign: TextAlign.center,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10,
                              height: 1.15,
                              color: Colors.white70)),
                    ),
                  ),
                // Com giro real o giro já indica; sem ele, o selo.
                if (t.tapped && !realRotate)
                  Center(
                      child: Text(AppLocale.t('token_tapped'),
                          style: const TextStyle(
                              color: AppTheme.gold,
                              fontWeight: FontWeight.bold,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 4)
                              ]))),
              ]),
            ),
          ),
          if (!namesHidden)
            Positioned(
              top: 4,
              left: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black
                      .withValues(alpha: t.art.isNotEmpty ? 0.55 : 0.25),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    // Faixa sob o nome (padrão): letreiro infinito —
                    // anda sozinho quando passa da caixa (e dá p/ arrastar).
                    if (t.keywords.isNotEmpty && !kwCenter)
                      Marquee(kwText,
                          style: const TextStyle(
                              fontSize: 9, color: Colors.white70)),
                  ],
                ),
              ),
            ),
          // Custo de mana no canto superior direito (pips oficiais).
          if (t.cost.trim().isNotEmpty)
            Positioned(
              top: namesHidden ? 4 : 30,
              right: 5,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ManaCostRow(_normalizeCost(t.cost),
                    size: 13, spacing: 1),
              ),
            ),
          // Selos no canto (tocar abre Marcadores): lealdade, carga
          // e até 2 personalizados (+N se houver mais).
          if (t.loyalty > 0)
            Positioned(
              top: namesHidden ? 4 : 32,
              left: 5,
              child: _miniSeal('❖${t.loyalty}', const Color(0xFFB388FF),
                  () => _countersSheet(t, upsideDown: upsideDown)),
            ),
          if (t.charge > 0)
            Positioned(
              top: (namesHidden ? 4 : 32) + (t.loyalty > 0 ? 24 : 0),
              left: 5,
              child: _miniSeal('⬢${t.charge}', const Color(0xFFFFD54F),
                  () => _countersSheet(t, upsideDown: upsideDown)),
            ),
          ..._customSeals(t, namesHidden, upsideDown),
          // Pílula inferior central: [▶ resolver] [P/T ou ◆] [×N].
          Positioned(
            left: 0,
            right: 0,
            bottom: 5,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: _tableStyle.accent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 3)
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canResolve)
                      InkWell(
                        onTap: () => _activateToken(t, upsideDown: upsideDown),
                        child: const Padding(
                          padding: EdgeInsets.only(right: 5),
                          child: Icon(Icons.play_arrow,
                              size: 18, color: Color(0xFF14161D)),
                        ),
                      ),
                    Text(utility ? '◆' : eff,
                        style: const TextStyle(
                            color: Color(0xFF14161D),
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                    if (stackedCount > 1)
                      Text('  ×$stackedCount',
                          style: const TextStyle(
                              color: Color(0xFF14161D),
                              fontWeight: FontWeight.bold,
                              fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        ]),
      ),
    );
    // Virada ocupa h×w com o conteúdo girado 90º dentro
    // (tamanho paisagem correto, como antes).
    final body = realRotate ? RotatedBox(quarterTurns: 1, child: inner) : inner;
    return SizedBox(
      width: realRotate ? h : w,
      height: realRotate ? w : h,
      child: body,
    );
  }

  /// Normaliza custo digitado ("2WW", "X", "{2}{G}") para pips "{2}{W}{W}".
  /// Híbrido ("W/U") vira dois pips separados — simplificação consciente.
  static String _normalizeCost(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    if (s.contains('{')) return s;
    final buf = StringBuffer();
    final up = s.toUpperCase().replaceAll(RegExp(r'\s+'), '');
    var i = 0;
    while (i < up.length) {
      final ch = up[i];
      if (RegExp(r'\d').hasMatch(ch)) {
        var j = i;
        while (j < up.length && RegExp(r'\d').hasMatch(up[j])) {
          j++;
        }
        buf.write('{${up.substring(i, j)}}');
        i = j;
      } else if ('WUBRGCSXYZ'.contains(ch)) {
        buf.write('{$ch}');
        i++;
      } else {
        i++;
      }
    }
    return buf.toString();
  }

  /// Ficha GRANDE: P/T efetivo em destaque, dono, marcadores,
  /// virar e editar. Idêntica nos dois aparelhos (via rede).
  /// Toque abre opções (editar, buff, arte, remover).
  Widget _tokenCard(_Token t) {
    final base = '${t.power}/${t.toughness}';
    final eff = '${effP(t)}/${effT(t)}';
    final changed = eff != base;
    // Artefatos utilitários (Tesouro, Pista...) não têm P/T.
    final isUtility = t.power == 0 &&
        t.toughness == 0 &&
        t.counters == 0 &&
        _bonusP(t) == 0 &&
        _bonusT(t) == 0;
    final effLabel = isUtility ? '◆' : eff;
    return GestureDetector(
      onTap: () => _tokenOptions(t),
      child: Card(
        color: t.tapped ? AppTheme.goldSoft : AppTheme.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.tapped ? AppTheme.gold : AppTheme.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (t.art.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CachedNetworkImage(
                      imageUrl: t.art,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          const Icon(Icons.broken_image),
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Text(t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  InkWell(
                    onTap: () => _tokenRemove(t),
                    child: const Icon(Icons.close,
                        size: 16, color: AppTheme.textFaint),
                  ),
                ],
              ),
              if (t.owner.isNotEmpty)
                Text(t.owner,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.gold, fontSize: 12)),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(effLabel,
                          style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.bold,
                              color: changed ? AppTheme.gold : AppTheme.text)),
                      if (changed)
                        Text('base $base',
                            style: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                      if (isUtility)
                        const Text('artefato',
                            style: TextStyle(
                                color: AppTheme.textMuted, fontSize: 12)),
                      if (t.description.isNotEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.only(top: 2, left: 4, right: 4),
                          child: Text(t.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic)),
                        ),
                      if (t.tapped)
                        const Text('VIRADA',
                            style: TextStyle(
                                color: AppTheme.gold,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              if (_utilityAction(t) != _UtilityAction.none && !t.tapped)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _activateToken(t),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: Text(_resolveLabel(_utilityAction(t))),
                    ),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  InkWell(
                      onTap: () => _tokenCounter(t, -1),
                      child: const Icon(Icons.remove_circle_outline, size: 24)),
                  Text('${t.counters}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  InkWell(
                      onTap: () => _tokenCounter(t, 1),
                      child: const Icon(Icons.add_circle,
                          color: AppTheme.gold, size: 24)),
                  InkWell(
                    onTap: () => _tokenTap(t),
                    child: Icon(
                        t.tapped
                            ? Icons.rotate_right_outlined
                            : Icons.rotate_right,
                        color: AppTheme.gold,
                        size: 26),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão com pressão contínua acelerada (privado do arquivo).
/// [minHeight]/[minWidth] + [expand] viram zonas grandes de toque
/// (ex. metades −/+ da vida); [alignment] encosta o ícone na borda.
/// [onHoldStart]/[onHoldEnd] avisam o gesto completo (p/ mostrar o
/// quanto mudou entre apertar e soltar).
class _HoldButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final void Function(int tick) onStep;
  final double minHeight;
  final bool expand;
  final double iconSize;
  final Alignment alignment;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;
  const _HoldButton(
      {required this.icon,
      required this.onTap,
      required this.onStep,
      this.minHeight = 0,
      this.expand = false,
      this.iconSize = 20,
      this.alignment = Alignment.center,
      this.onHoldStart,
      this.onHoldEnd});

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  Timer? _timer;
  // Segurada válida em curso (start disparou): o cancel pode chegar
  // sem start (rolagem) — sem isso o onHoldEnd mentiria o delta.
  bool _held = false;

  void _start() {
    var tick = 0;
    var interval = 380;
    void schedule() {
      _timer = Timer(Duration(milliseconds: interval), () {
        if (!mounted) return;
        tick++;
        widget.onStep(tick);
        interval = (interval - 45).clamp(70, 380);
        schedule();
      });
    }

    schedule();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _begin() {
    _held = true;
    _start();
    widget.onHoldStart?.call();
  }

  void _end() {
    _stop();
    if (!_held) return;
    _held = false;
    widget.onHoldEnd?.call();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Container(
      constraints: BoxConstraints(minHeight: widget.minHeight),
      alignment: widget.alignment,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child:
            Icon(widget.icon, color: AppTheme.gold, size: widget.iconSize),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPressStart: (_) => _begin(),
      onLongPressEnd: (_) => _end(),
      onLongPressCancel: _end,
      // Largura total da zona (o pai usa stretch p/ altura total).
      child: widget.expand
          ? SizedBox(width: double.infinity, child: content)
          : content,
    );
  }
}
