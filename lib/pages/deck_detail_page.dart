import 'dart:async';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../data/app_database.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/currency_service.dart';
import '../services/export_service.dart';
import '../services/scryfall_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import 'card_detail_sheet.dart';

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
  // Validação do formato (sininho) + modo de exibição.
  List<String> _problems = [];
  bool _deckViewGrid = false;

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
    _query.addListener(_onQueryChanged);
    AppLocale.current.addListener(_onLocale);
    AppEvents.topVisible.addListener(_onBars);
  }

  @override
  void dispose() {
    _query.dispose();
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
    if (!mounted) return;
    setState(() {
      _items = rows;
      if (deck.isNotEmpty) {
        _format = (deck.first['format'] ?? 'livre').toString();
        _commanderId = deck.first['commander_card_id'] as int?;
        _previewCardId = deck.first['preview_card_id'] as int?;
      }
    });
    await _computeProblems();
  }

  static bool _isBasicLand(Map<String, Object?> c) {
    final tl = ((c['type_line'] ?? '') as String).toLowerCase();
    if (tl.contains('basic land')) return true;
    const basics = {
      'plains',
      'island',
      'swamp',
      'mountain',
      'forest',
      'wastes'
    };
    return basics.contains(((c['name'] ?? '') as String).toLowerCase().trim());
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
          final tl = ((commander['type_line'] ?? '') as String).toLowerCase();
          if (!tl.contains('legendary')) {
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
    if (mounted) setState(() => _localResults = rows);
  }

  /// Quantidade possuída na coleção (0 = só catálogo/Scryfall).
  Future<int> _collectionQty(int cardId) async {
    final rows = await AppDatabase.instance.db.query('cards',
        columns: ['quantity'], where: 'id = ?', whereArgs: [cardId], limit: 1);
    if (rows.isEmpty) return 0;
    return (rows.first['quantity'] as num?)?.toInt() ?? 0;
  }

  /// Regra: no deck só entra até o que se tem na coleção.
  /// Carta só-de-deck (quantity 0, vinda do Scryfall) é livre.
  /// Retorna a quantidade permitida (e avisa se cortou).
  Future<int> _capByCollection(int cardId, int wanted) async {
    final owned = await _collectionQty(cardId);
    if (owned > 0 && wanted > owned) {
      if (mounted) {
        AppToast.show(
            context, AppLocale.t('dd_owned').replaceAll('{o}', '$owned'));
      }
      return owned;
    }
    return wanted;
  }

  Future<void> _addExisting(int cardId) async {
    final db = AppDatabase.instance.db;
    final existing = await db.query('deck_cards',
        where: 'deck_id = ? AND card_id = ?',
        whereArgs: [widget.deckId, cardId]);
    final cur = existing.isEmpty
        ? 0
        : ((existing.first['quantity'] as num?)?.toInt() ?? 0);
    final next = await _capByCollection(cardId, cur + 1);
    if (existing.isEmpty) {
      await db.insert('deck_cards',
          {'deck_id': widget.deckId, 'card_id': cardId, 'quantity': next});
    } else {
      if (next == cur) {
        await _reload();
        return;
      }
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
      setState(() => _scryResults = results.take(20).toList());
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
  Future<int?> _resolveAndAdd(String name, {int qty = 1}) async {
    Map<String, dynamic>? data;
    if (_scryLang != 'all') {
      data =
          await ScryfallService.instance.getCardByName(name, lang: _scryLang);
    } else {
      data = await ScryfallService.instance.getCardByName(name, lang: 'pt');
      data ??= await ScryfallService.instance.getCardByName(name, lang: 'en');
    }
    if (data == null) return null;
    return _addScryfallData(data, qty: qty);
  }

  Future<int> _addScryfallData(Map<String, dynamic> data, {int qty = 1}) async {
    final flat = ScryfallService.flatten(data);
    final db = AppDatabase.instance.db;
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
        where: 'deck_id = ? AND card_id = ?',
        whereArgs: [widget.deckId, cardId]);
    final cur = existing.isEmpty
        ? 0
        : ((existing.first['quantity'] as num?)?.toInt() ?? 0);
    final next = await _capByCollection(cardId, cur + qty);
    if (existing.isEmpty) {
      await db.insert('deck_cards',
          {'deck_id': widget.deckId, 'card_id': cardId, 'quantity': next});
    } else {
      await db.update('deck_cards', {'quantity': next},
          where: 'deck_id = ? AND card_id = ?',
          whereArgs: [widget.deckId, cardId]);
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
      final allowed = await _capByCollection(cardId, qty);
      await db.update('deck_cards', {'quantity': allowed},
          where: 'deck_id = ? AND card_id = ?',
          whereArgs: [widget.deckId, cardId]);
    }
    await _reload();
  }

  // ============ import / export ============

  Future<void> _importDialog() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(AppLocale.t('dd_import')),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: c,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '4x Relâmpago\n2 Floresta\nSol Ring',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: Text(AppLocale.t('dd_import')),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) {
      _laterDispose(c);
      return;
    }
    _laterDispose(c);
    setState(() {
      _importing = true;
      _importStatus = AppLocale.t('dd_starting');
    });
    int ok = 0;
    int fail = 0;
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line.isEmpty) continue;
      var qty = 1;
      final m = RegExp(r'^(\d+)\s*x?\s+(.+)$').firstMatch(line);
      if (m != null) {
        qty = int.tryParse(m.group(1)!) ?? 1;
        line = m.group(2)!.trim();
      }
      line = line.replaceAll(RegExp(r'\[.*?\]'), '').trim();
      if (mounted) {
        setState(() => _importStatus = '${i + 1}/${lines.length}: $line');
      }
      try {
        final id = await _resolveAndAdd(line, qty: qty);
        if (id == null) {
          fail++;
        } else {
          ok++;
        }
      } catch (_) {
        fail++;
      }
    }
    await _reload();
    if (mounted) {
      setState(() {
        _importing = false;
        _importStatus = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('dd_imported')
              .replaceAll('{ok}', '$ok')
              .replaceAll('{fail}', '$fail'))));
    }
  }

  Future<void> _export() async {
    await ExportService.exportDeckTxt(widget.deckName, _items);
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
                IconButton(
                    icon: const Icon(Icons.share),
                    tooltip: AppLocale.t('dd_export'),
                    onPressed: _items.isEmpty ? null : _export),
              ],
            )
          : null,
      body: SafeArea(
        top: !AppEvents.topVisible.value,
        bottom: false,
        child: Column(
          children: [
            Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        _stat('$_totalCards', AppLocale.t('dd_cards')),
                        _stat(
                            CurrencyService.instance
                                .formatUsd(_totalValue),
                            CurrencyService.instance.currency.value),
                        _stat('${_items.length}', AppLocale.t('dd_unique')),
                      ],
                    ),
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
                ),
              ),
            ),
            if (_importing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_importStatus,
                            style: const TextStyle(color: AppTheme.textMuted))),
                  ],
                ),
              ),
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
              Flexible(fit: FlexFit.loose, child: _localAddList()),
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
              Flexible(fit: FlexFit.loose, child: _scryAddList()),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Row(
                children: [
                  Text(
                      AppLocale.t('dd_count')
                          .replaceAll('{u}', '${_items.length}')
                          .replaceAll('{t}', '$_totalCards'),
                      style: const TextStyle(color: AppTheme.textMuted)),
                  const Spacer(),
                  IconButton(
                    icon:
                        Icon(_deckViewGrid ? Icons.view_list : Icons.grid_view),
                    tooltip: _deckViewGrid
                        ? AppLocale.t('dd_view_list')
                        : AppLocale.t('dd_view_grid'),
                    onPressed: () =>
                        setState(() => _deckViewGrid = !_deckViewGrid),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(AppLocale.t('dd_empty'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppTheme.textMuted)))
                  : _deckViewGrid
                      ? GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            // A arte ocupa todo o cartão; nome e controles ficam
                            // por cima dela, como numa carta física.
                            childAspectRatio: 0.69,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (_, i) => _deckGridTile(_items[i]),
                        )
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (_, i) {
                            final c = _items[i];
                            final q = (c['deck_qty'] as num?)?.toInt() ?? 1;
                            final isCommander =
                                _commanderId == (c['id'] as int);
                            final isCover = _previewCardId == (c['id'] as int);
                            return ListTile(
                              leading: isCommander
                                  ? const Icon(Icons.shield,
                                      color: AppTheme.gold)
                                  : null,
                              title: Text((c['name'] ?? '').toString(),
                                  style: TextStyle(
                                      fontWeight: isCommander
                                          ? FontWeight.bold
                                          : FontWeight.normal)),
                              subtitle: Text(
                                  '${c['type_line'] ?? ''} • ${CurrencyService.instance.formatUsd(((c['price_usd'] ?? c['price_ref_usd']) as num?)?.toDouble() ?? 0)}'),
                              onTap: () => showModalBottomSheet(
                                context: context,
                                isScrollControlled: true,
                                builder: (_) => CardDetailSheet(card: c),
                              ).then((_) => _reload()),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                      icon: const Icon(
                                          Icons.remove_circle_outline),
                                      onPressed: () =>
                                          _setQty(c['id'] as int, q - 1)),
                                  Text('$q',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  IconButton(
                                      icon: const Icon(Icons.add_circle,
                                          color: AppTheme.gold),
                                      onPressed: () =>
                                          _setQty(c['id'] as int, q + 1)),
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
                                            child: Text(AppLocale.t(
                                                'dd_set_commander'))),
                                      if (isCommander)
                                        PopupMenuItem(
                                            value: 'uncommander',
                                            child: Text(
                                                AppLocale.t('dd_uncommander'))),
                                      if (!isCover)
                                        PopupMenuItem(
                                            value: 'cover',
                                            child:
                                                Text(AppLocale.t('dd_cover'))),
                                      if (isCover)
                                        PopupMenuItem(
                                            value: 'uncover',
                                            child: Text(
                                                AppLocale.t('dd_uncover'))),
                                      PopupMenuItem(
                                          value: 'remove',
                                          child: Text(
                                              AppLocale.t('dd_remove_from'))),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
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
            child: PopupMenuButton<String>(
              tooltip: AppLocale.t('dd_card_options'),
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
}
