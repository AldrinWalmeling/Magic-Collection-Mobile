import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';

import 'package:flutter/material.dart';

import '../data/app_database.dart';

import '../services/app_events.dart';

import '../services/app_locale.dart';
import '../services/collection_backup_service.dart';

import '../services/export_service.dart';
import '../services/price_update_service.dart';
import '../services/currency_service.dart';
import '../services/display_prefs.dart';
import '../services/rarity_repair_service.dart';
import '../widgets/quantity_editor.dart';

import '../services/scryfall_service.dart';

import '../theme/app_theme.dart';

import 'card_detail_sheet.dart';

import 'photo_mode_page.dart';

// Coleção premium em abas: [Coleção | Adicionar].

// Uma busca por vez — nada de duas caixas brigando na tela.

// Aba Coleção: busca local + filtros + grade + exportar.

// Aba Adicionar: busca Scryfall (PT/EN/...) + idioma + grade p/ adicionar.

// Espelha pages/collection_page.py do desktop.

class CollectionPage extends StatefulWidget {

  const CollectionPage({super.key});

  @override

  State<CollectionPage> createState() => _CollectionPageState();

}

class _CollectionPageState extends State<CollectionPage> {

  int _tab = 0; // 0 = coleção, 1 = adicionar

  // ---- busca local ----

  final _local = TextEditingController();

  final _typeFilter = TextEditingController();

  List<Map<String, Object?>> _cards = [];

  List<String> _allSets = [];

  bool _loading = true;

  // Paginação da coleção (sem teto de 300): carrega em páginas e o
  // scroll infinito busca o restante. _totalCount = total com o filtro.
  static const _pageSize = 200;
  int _totalCount = 0;
  bool _loadingMore = false;
  final _scrollCtrl = ScrollController();

  Timer? _localDebounce;

  String _order = 'name ASC';

  String _rarity = 'all';

  String _setName = 'all';

  String _color = 'all';

  bool _favoritesOnly = false;

  bool _showFilters = false;

  bool _collectionViewGrid = true; // grade (padrão) ou lista

  // ---- busca Scryfall ----

  final _scry = TextEditingController();

  List<String> _suggestions = [];

  List<Map<String, dynamic>> _scryfallResults = [];

  Timer? _scryDebounce;

  int _scryfallReq = 0;

  bool _scryfallLoading = false;

  String? _scryfallError;

  String? _addingName; // carta sendo adicionada (loading por item)

  String _scryLang = 'all'; // filtro de idioma dos printings

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

  static const _rarityKeys = ['all', 'common', 'uncommon', 'rare', 'mythic'];

  static const _colorKeys = [

    'all',

    'W',

    'U',

    'B',

    'R',

    'G',

    'multi',

    'colorless'

  ];

  @override

  void initState() {

    super.initState();

    _reload();

    _loadSets();

    unawaited(_refreshPricesInBackground());

    _local.addListener(_onLocalChanged);

    _scry.addListener(_onScryChanged);

    _scrollCtrl.addListener(_onScrollNearEnd);

    AppLocale.current.addListener(_onLocale);

    AppEvents.topVisible.addListener(_onBars);

    AppEvents.activeProfile.addListener(_onProfile);

  }

  void _onScrollNearEnd() {
    if (_loading || _loadingMore) return;
    if (!_scrollCtrl.hasClients) return;
    // A 400px do fim, busca a próxima página.
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  @override

  void dispose() {

    _local.dispose();

    _typeFilter.dispose();

    _scry.dispose();

    _scrollCtrl.dispose();

    _localDebounce?.cancel();

    _scryDebounce?.cancel();

    AppLocale.current.removeListener(_onLocale);

    AppEvents.topVisible.removeListener(_onBars);

    AppEvents.activeProfile.removeListener(_onProfile);

    super.dispose();

  }

  void _onLocale() {

    if (mounted) setState(() {});

  }

  /// Perfil trocou: recarrega coleção e sets do banco novo.

  void _onProfile() {

    if (!mounted) return;

    _reload();

    _loadSets();

  }

  void _onBars() {

    if (mounted) setState(() {});

  }

  Future<void> _refreshPricesInBackground() async {
    final updated = await PriceUpdateService.instance.refreshCollectionPrices();
    if (updated <= 0 || !mounted) return;
    await _reload();
  }

  bool _refreshingPrices = false;

  /// Atualização manual (força nova consulta, ignora cache de 24h).
  Future<void> _forceRefreshPrices() async {
    if (_refreshingPrices) return;
    setState(() => _refreshingPrices = true);
    try {
      final updated = await PriceUpdateService.instance
          .refreshCollectionPrices(force: true);
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(updated > 0
                ? '$updated preço(s) atualizado(s).'
                : 'Nenhum preço novo encontrado.')));
      }
    } finally {
      if (mounted) setState(() => _refreshingPrices = false);
    }
  }

  Future<void> _loadSets() async {

    final sets = await AppDatabase.instance.distinctSets();

    if (mounted) setState(() => _allSets = sets);

  }

  void _switchTab(int tab, {String? carryQuery}) {

    setState(() => _tab = tab);

    if (carryQuery != null && carryQuery.trim().length >= 2) {

      _scry.text = carryQuery.trim();

      _searchScryfall();

    }

  }

  // ================= BUSCA LOCAL =================

  void _onLocalChanged() {

    _localDebounce?.cancel();

    _localDebounce = Timer(const Duration(milliseconds: 400), _reload);

  }

  Future<void> _reload() async {

    // Spinner de tela cheia SÓ na primeira carga. Nas demais a lista
    // atual fica visível enquanto busca (sem piscar a página toda).
    final firstLoad = _cards.isEmpty;
    if (firstLoad) {
      setState(() {
        _loading = true;
        _loadingMore = false;
      });
    }

    try {

      final total = await AppDatabase.instance.countCollection(

        query: _local.text.trim(),

        rarity: _rarity,

        setName: _setName,

        color: _color,

        typeQuery: _typeFilter.text,

        favoritesOnly: _favoritesOnly,

      );

      final rows = await AppDatabase.instance.searchCollection(

        query: _local.text.trim(),

        orderBy: _order,

        limit: _pageSize,

        offset: 0,

        rarity: _rarity,

        setName: _setName,

        color: _color,

        typeQuery: _typeFilter.text,

        favoritesOnly: _favoritesOnly,

      );

      if (mounted) setState(() {
        // Cópia mutável: db.query devolve lista somente-leitura e a
        // atualização otimista (_applyLocalQty) edita no lugar.
        _cards = List<Map<String, Object?>>.of(rows);
        _totalCount = total;
      });

    } finally {

      if (mounted) setState(() => _loading = false);

    }

  }

  bool get _hasMore => _cards.length < _totalCount;

  /// Próxima página do scroll infinito (anexa, sem recarregar tudo).
  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final rows = await AppDatabase.instance.searchCollection(
        query: _local.text.trim(),
        orderBy: _order,
        limit: _pageSize,
        offset: _cards.length,
        rarity: _rarity,
        setName: _setName,
        color: _color,
        typeQuery: _typeFilter.text,
        favoritesOnly: _favoritesOnly,
      );
      if (mounted && rows.isNotEmpty) {
        setState(() => _cards = [..._cards, ...rows]);
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _clearFilters() {

    setState(() {

      _rarity = 'all';

      _setName = 'all';

      _color = 'all';

      _favoritesOnly = false;

      _typeFilter.clear();

    });

    _reload();

  }

  bool get _hasActiveFilters =>

      _rarity != 'all' ||

      _setName != 'all' ||

      _color != 'all' ||

      _favoritesOnly ||

      _typeFilter.text.trim().isNotEmpty;

  Future<void> _setQuantity(Map<String, Object?> card) async {
    final current = ((card['quantity'] as num?)?.toInt() ?? 0);
    final id = card['id'] as int;
    // Editor com Adicionar/Remover/Definir (o zero já vem confirmado
    // de dentro do editor; a linha é mantida com quantity 0).
    final result = await QuantityEditor.show(context, current);
    if (result == null || !mounted) return;
    await AppDatabase.instance.db
        .update('cards', {'quantity': result}, where: 'id = ?', whereArgs: [id]);
    // Otimista: atualiza a linha no lugar, sem recarregar a página
    // (sem piscar, sem perder o scroll).
    _applyLocalQty(id, result);
    AppEvents.notifyCollectionChanged();
  }

  /// Aplica a nova quantidade direto na lista visível (sem _reload):
  /// quantity 0 sai da lista (filtro quantity>0), o resto atualiza
  /// no lugar. Reordena só se a ordenação for por quantidade.
  void _applyLocalQty(int id, int qty) {
    if (!mounted) return;
    setState(() {
      if (qty <= 0) {
        _cards.removeWhere((c) => (c['id'] as num?)?.toInt() == id);
        if (_totalCount > 0) _totalCount--;
        return;
      }
      for (var i = 0; i < _cards.length; i++) {
        if ((_cards[i]['id'] as num?)?.toInt() == id) {
          _cards[i] = {..._cards[i], 'quantity': qty};
          break;
        }
      }
      if (_order.startsWith('quantity')) {
        final desc = !_order.toUpperCase().contains('ASC');
        _cards.sort((a, b) {
          final qa = ((a['quantity'] as num?)?.toInt() ?? 0);
          final qb = ((b['quantity'] as num?)?.toInt() ?? 0);
          return desc ? qb.compareTo(qa) : qa.compareTo(qb);
        });
      }
    });
  }

  Future<void> _bump(Map<String, Object?> card, int delta) async {

    final db = AppDatabase.instance.db;

    final id = card['id'] as int;

    final current = ((card['quantity'] as num?)?.toInt() ?? 0);

    // 1→0 exige confirmação e zera MANTENDO a linha (quantity=0 =
    // fora da coleção, preservada p/ histórico/decks/favoritos/tags).
    // Nunca deleta o registro aqui.
    if (delta < 0 && current <= 1 && current > 0) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remover última cópia?'),
          content: const Text(
              'Esta é a última cópia desta carta na sua coleção. Ao continuar, ela deixará de fazer parte da sua coleção.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remover')),
          ],
        ),
      );
      if (ok != true) return;
      await db.update('cards', {'quantity': 0},
          where: 'id = ?', whereArgs: [id]);
      _applyLocalQty(id, 0);
      AppEvents.notifyCollectionChanged();
      return;
    }

    final q = current + delta;

    if (q < 0) return;

    await db.update('cards', {'quantity': q}, where: 'id = ?', whereArgs: [id]);

    _applyLocalQty(id, q);

    AppEvents.notifyCollectionChanged();

  }

  // ================= BUSCA SCRYFALL =================

  void _onScryChanged() {

    _scryDebounce?.cancel();

    _scryDebounce = Timer(const Duration(milliseconds: 600), () {

      final q = _scry.text.trim();

      if (q.length >= 2) {

        _fetchSuggestions(q);

        // Busca completa dispara sozinha a partir de 3 letras.

        if (q.length >= 3) _searchScryfall(silent: true);

      } else if (mounted) {

        setState(() {

          _suggestions = [];

          _scryfallResults = [];

          _scryfallError = null;

        });

      }

    });

  }

  Future<void> _fetchSuggestions(String q) async {

    try {

      final s = await ScryfallService.instance.autocomplete(q);

      if (mounted) setState(() => _suggestions = s.take(6).toList());

    } catch (_) {

      if (mounted) setState(() => _suggestions = []);

    }

  }

  /// Busca full-text no Scryfall (automática ao digitar, lupa, Enter).

  /// \`silent\` (digitação): não mostra "nada encontrado" nem snackbar;

  /// erros de rede aparecem sempre para não parecer que "nada acontece".

  Future<void> _searchScryfall({bool silent = false}) async {

    final q = _scry.text.trim();

    if (q.length < 2) {

      if (!silent) {

        ScaffoldMessenger.of(context)

            .showSnackBar(SnackBar(content: Text(AppLocale.t('cl_type2'))));

      }

      return;

    }

    final req = ++_scryfallReq;

    setState(() {

      _scryfallLoading = true;

      _scryfallError = null;

      if (!silent) _scryfallResults = [];

    });

    try {

      final results = await ScryfallService.instance.search(q, lang: _scryLang);

      if (!mounted || req != _scryfallReq) return; // busca nova venceu

      setState(() => _scryfallResults = results.take(30).toList());

      if (results.isEmpty && !silent) {

        final langLabel = ScryfallService.languageLabels[_scryLang] ?? '';

        setState(() => _scryfallError = _scryLang == 'all'

            ? AppLocale.t('dd_nothing').replaceAll('{q}', q)

            : AppLocale.t('dd_nothing_lang')

                .replaceAll('{l}', langLabel)

                .replaceAll('{q}', q));

      }

    } catch (e) {

      if (!mounted || req != _scryfallReq) return;

      setState(() =>

          _scryfallError = AppLocale.t('dd_fail_net').replaceAll('{e}', '$e'));

    } finally {

      if (mounted && req == _scryfallReq) {

        setState(() => _scryfallLoading = false);

      }

    }

  }

  /// Adiciona carta do Scryfall. Se já existe na coleção, soma +1

  /// em vez de zerar a quantidade.

  Future<void> _addFromScryfall(Map<String, dynamic> data) async {

    final name = ((data['printed_name'] ?? data['name']) ?? '?').toString();

    setState(() => _addingName = (data['name'] ?? '?').toString());

    try {

      final db = AppDatabase.instance.db;

      final scryfallId = data['id']?.toString();

      int qty = 1;

      if (scryfallId != null) {

        final found = await db.query('cards',

            columns: ['id', 'quantity'],

            where: 'scryfall_id = ?',

            whereArgs: [scryfallId],

            limit: 1);

        if (found.isNotEmpty) {

          qty = ((found.first['quantity'] as num?)?.toInt() ?? 0) + 1;

          await db.update('cards', {'quantity': qty},

              where: 'id = ?', whereArgs: [found.first['id']]);

          await _reload();

          await _loadSets();

          AppEvents.notifyCollectionChanged();

          if (mounted) {

            ScaffoldMessenger.of(context).showSnackBar(SnackBar(

                content: Text(AppLocale.t('cl_added_now')

                    .replaceAll('{n}', name)

                    .replaceAll('{q}', '$qty'))));

          }

          return;

        }

      }

      final flat = ScryfallService.flatten(data);

      flat['quantity'] = 1;
      // Cache da origem: se a impressão já veio com preço, é exata.
      // Se veio sem preço (comum em PT), deixa sem fonte para o
      // PriceUpdateService resolver via fallback mesma-impressão/EN
      // sem nunca trocar idioma/set/coletor da carta salva.
      final hasPrice = flat['price_usd'] != null ||
          flat['price_usd_foil'] != null ||
          flat['price_usd_etched'] != null ||
          flat['price_eur'] != null ||
          flat['price_eur_foil'] != null ||
          flat['price_tix'] != null;
      if (hasPrice) {
        flat['price_source'] = 'exact';
        flat['price_updated_at'] = DateTime.now().toUtc().toIso8601String();
      }

      await AppDatabase.instance.ensureCard(flat);

      await _reload();

      await _loadSets();

      AppEvents.notifyCollectionChanged();

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(

            content: Text(AppLocale.t('cl_added').replaceAll('{n}', name))));

      }

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(

            content:

                Text(AppLocale.t('cl_add_error').replaceAll('{e}', '$e'))));

      }

    } finally {

      if (mounted) setState(() => _addingName = null);

    }

  }

  /// Adiciona por nome exato (chips de autocomplete).

  /// Idioma fixo = estrito: só adiciona se existir impressão nesse

  /// idioma (sem cair para inglês escondido). "Todos" tenta PT e EN.

  Future<void> _addByName(String name) async {

    setState(() => _addingName = name);

    try {

      Map<String, dynamic>? data;

      if (_scryLang != 'all') {

        data =

            await ScryfallService.instance.getCardByName(name, lang: _scryLang);

        if (data == null && mounted) {

          final label = ScryfallService.languageLabels[_scryLang] ?? _scryLang;

          ScaffoldMessenger.of(context).showSnackBar(SnackBar(

              content: Text(AppLocale.t('cl_no_version')

                  .replaceAll('{n}', name)

                  .replaceAll('{l}', label))));

          return;

        }

      } else {

        data = await ScryfallService.instance.getCardByName(name, lang: 'pt');

        data ??= await ScryfallService.instance.getCardByName(name, lang: 'en');

        if (data == null && mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

              SnackBar(content: Text(AppLocale.t('cl_notfound'))));

          return;

        }

      }

      await _addFromScryfall(data!);

    } catch (e) {

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(

            content: Text(AppLocale.t('dd_fail_net').replaceAll('{e}', '$e'))));

      }

    } finally {

      if (mounted) setState(() => _addingName = null);

    }

  }

  Future<List<Map<String, Object?>>> _loadAllCardsForBackup() async {
    return AppDatabase.instance.db.query(
      'cards',
      orderBy: 'id ASC',
    );
  }

  Future<void> _exportCompleteBackup() async {
    try {
      final cards = await _loadAllCardsForBackup();
      await ExportService.exportCompleteBackup(cards);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup completo exportado.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao exportar backup: $e')),
      );
    }
  }

  Future<void> _importCollectionBackup() async {
    try {
      final result = await CollectionBackupService.pickAndReadBackup();
      if (result == null) return;

      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Importar coleção'),
          content: Text(
            'Arquivo: ${result.fileName}\n\n'
            'Cartas encontradas: ${result.cards.length}\n'
            'O backup será aplicado pela identificação da carta, '
            'priorizando Scryfall ID e usando nome + edição + número coletor como fallback.\n\n'
            'Os IDs internos do banco não serão reutilizados.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Importar'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      final importResult = await CollectionBackupService.importCards(
        result.cards,
      );

      await _reload();
      await _loadSets();
      AppEvents.notifyCollectionChanged();
      // Importação pode trazer cartas sem raridade: repara em segundo
      // plano (scryfall_id exato primeiro) e recarrega ao terminar.
      unawaited(RarityRepairService.repairMissingRarities().then((fixed) async {
        if (fixed > 0 && mounted) {
          await _reload();
          AppEvents.notifyCollectionChanged();
        }
      }));

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Importação concluída'),
          content: Text(
            'Adicionadas: ${importResult.added}\n'
            'Atualizadas: ${importResult.updated}\n'
            'Ignoradas: ${importResult.skipped}\n'
            'Com erro: ${importResult.errors}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao importar backup: $e')),
      );
    }
  }

  // ================= UI =================

  @override

  Widget build(BuildContext context) {

    final inCollection = _tab == 0;

    return Scaffold(

      appBar: AppEvents.topVisible.value

          ? AppBar(

              title: Text(AppLocale.t('nav_collection')),

              actions: [

                if (inCollection)
                  IconButton(
                    icon: _refreshingPrices
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.price_change_outlined),
                    tooltip: 'Atualizar preços',
                    onPressed: _forceRefreshPrices,
                  ),

                IconButton(

                  icon: const Icon(Icons.photo_camera),

                  tooltip: AppLocale.t('cl_photo'),

                  onPressed: () => Navigator.push(

                    context,

                    MaterialPageRoute(builder: (_) => const PhotoModePage()),

                  ).then((_) => _reload()),

                ),

                if (inCollection)

                  PopupMenuButton<String>(

                    icon: const Icon(Icons.sort),

                    tooltip: AppLocale.t('cl_sort'),

                    onSelected: (v) {

                      setState(() => _order = v);

                      _reload();

                    },

                    itemBuilder: (_) => [

                      PopupMenuItem(

                          value: 'name ASC',

                          child: Text(AppLocale.t('cl_sort_name'))),

                      PopupMenuItem(

                          value: 'price_usd DESC',

                          child: Text(AppLocale.t('cl_sort_value'))),

                      PopupMenuItem(

                          value: 'set_name ASC',

                          child: Text(AppLocale.t('cl_sort_set'))),

                      PopupMenuItem(

                          value: 'quantity DESC',

                          child: Text(AppLocale.t('cl_sort_qty'))),

                    ],

                  ),

                if (inCollection)
                  IconButton(
                    icon: const Icon(Icons.ios_share),
                    tooltip: AppLocale.t('cl_export'),
                    onPressed: () => showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      builder: (_) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.backup_outlined),
                              title: const Text('Backup completo (JSON)'),
                              subtitle: const Text('Restauração da coleção'),
                              onTap: () {
                                Navigator.pop(context);
                                _exportCompleteBackup();
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.file_upload_outlined),
                              title: const Text('Importar backup (JSON)'),
                              subtitle: const Text('Adicionar ou restaurar cartas'),
                              onTap: () {
                                Navigator.pop(context);
                                _importCollectionBackup();
                              },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(Icons.table_chart),
                              title: Text(AppLocale.t('cl_exp_csv')),
                              onTap: () {
                                Navigator.pop(context);
                                ExportService.exportCsv(_cards);
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.data_object),
                              title: Text(AppLocale.t('cl_exp_json')),
                              onTap: () {
                                Navigator.pop(context);
                                ExportService.exportJson(_cards);
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.text_snippet),
                              title: Text(AppLocale.t('cl_exp_txt')),
                              onTap: () {
                                Navigator.pop(context);
                                ExportService.exportTxt(_cards);
                              },
                            ),
                          ],
                        ),
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

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.stretch,

          children: [

            Padding(

              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),

              child: SegmentedButton<int>(

                segments: [

                  ButtonSegment(

                      value: 0,

                      icon: const Icon(Icons.style, size: 18),

                      label: Text(AppLocale.t('cl_tab_count')

                          .replaceAll('{n}', '${_cards.length}'))),

                  ButtonSegment(

                      value: 1,

                      icon: const Icon(Icons.add, size: 18),

                      label: Text(AppLocale.t('cl_tab_add'))),

                ],

                selected: {_tab},

                onSelectionChanged: (s) => _switchTab(s.first),

              ),

            ),

            Expanded(

              child: AnimatedSwitcher(

                duration: const Duration(milliseconds: 220),

                child: inCollection ? _collectionTab() : _addTab(),

              ),

            ),

          ],

        ),

      ),

    );

  }

  // ---------- aba COLEÇÃO ----------

  Widget _collectionTab() {

    return Column(

      key: const ValueKey('tab-collection'),

      children: [

        Padding(

          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),

          child: TextField(

            controller: _local,

            decoration: InputDecoration(

              hintText: AppLocale.t('cl_search_local'),

              prefixIcon: const Icon(Icons.search),

            ),

          ),

        ),

        Padding(

          padding: const EdgeInsets.symmetric(horizontal: 12),

          child: Row(

            children: [

              TextButton.icon(

                onPressed: () => setState(() => _showFilters = !_showFilters),

                icon: Icon(

                    _showFilters ? Icons.filter_list_off : Icons.filter_list,

                    color:

                        _hasActiveFilters ? AppTheme.gold : AppTheme.textMuted),

                label: Text(

                    _hasActiveFilters

                        ? AppLocale.t('cl_filters_on')

                        : AppLocale.t('cl_filters'),

                    style: TextStyle(

                        color: _hasActiveFilters

                            ? AppTheme.gold

                            : AppTheme.textMuted)),

              ),

              const Spacer(),

              Text(

                  AppLocale.t('cl_n_cards')

                      .replaceAll('{n}', '$_totalCount'),

                  style: const TextStyle(color: AppTheme.textMuted)),

              IconButton(

                icon: Icon(

                    _collectionViewGrid ? Icons.view_list : Icons.grid_view),

                tooltip: _collectionViewGrid

                    ? AppLocale.t('dd_view_list')

                    : AppLocale.t('dd_view_grid'),

                onPressed: () =>

                    setState(() => _collectionViewGrid = !_collectionViewGrid),

              ),

            ],

          ),

        ),

        if (_showFilters) _filtersPanel(),

        // Reage na hora aos interruptores de Exibição (Ajustes) e à
        // moeda. Via builder (não initState) para valer com hot reload.
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              DisplayPrefs.showCardName,
              DisplayPrefs.showCardSet,
              DisplayPrefs.showCardPrice,
              CurrencyService.instance.currency,
            ]),
            builder: (_, __) => _collectionViewGrid
                ? _localGrid()
                : _localList(),
          ),
        ),

      ],

    );

  }

  Widget _localGrid() {

    if (_loading) {

      return const Center(child: CircularProgressIndicator());

    }

    if (_cards.isEmpty) {

      return Center(

        child: Padding(

          padding: const EdgeInsets.all(24),

          child: Column(

            mainAxisSize: MainAxisSize.min,

            children: [

              const Icon(Icons.style_outlined,

                  size: 56, color: AppTheme.textFaint),

              const SizedBox(height: 12),

              Text(AppLocale.t('cl_empty_filter'),

                  textAlign: TextAlign.center,

                  style: const TextStyle(color: AppTheme.textMuted)),

              const SizedBox(height: 12),

              ElevatedButton.icon(

                onPressed: () => _switchTab(1, carryQuery: _local.text),

                icon: const Icon(Icons.travel_explore),

                label: Text(AppLocale.t('cl_scry_btn')),

              ),

            ],

          ),

        ),

      );

    }

    // Altura da célula acompanha os textos exibidos (Ajustes >
    // Exibição) e a largura da tela: a arte escala com a largura,
    // mas os textos têm altura fixa — proporção fixa quebra num dos
    // extremos. Medidas calibradas: arte 63:88 + fileira qtd (34) +
    // paddings (12) + nome (23) + linha info (19) + 2 de folga.
    final showName = DisplayPrefs.showCardName.value;
    final showInfo =
        DisplayPrefs.showCardSet.value || DisplayPrefs.showCardPrice.value;
    final cellW =
        (MediaQuery.of(context).size.width - 24 - 12) / 2;
    final infoH = 12.0 +
        34.0 +
        (showName ? 23.0 : 0.0) +
        (showInfo ? 19.0 : 0.0) +
        2.0;
    final cellAspect = cellW / (cellW * 88 / 63 + infoH);

    return GridView.builder(

      controller: _scrollCtrl,

      padding: const EdgeInsets.all(12),

      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(

        crossAxisCount: 2,

        // Célula justa: arte 63:88 inteira + infos, sem sobra vazia
        // embaixo e sem estouro (0.55 estourava, 0.52 dava folga).

        childAspectRatio: cellAspect,

        crossAxisSpacing: 12,

        mainAxisSpacing: 12,

      ),

      itemCount: _cards.length + (_hasMore ? 1 : 0),

      itemBuilder: (_, i) {
        if (i >= _cards.length) {
          return const Center(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator()));
        }
        return _cardTile(_cards[i]);
      },

    );

  }

  /// Modo lista: linha compacta com arte, nome, set/preço e quantidade.

  Widget _localList() {

    if (_loading) {

      return const Center(child: CircularProgressIndicator());

    }

    if (_cards.isEmpty) {

      return Center(

        child: Padding(

          padding: const EdgeInsets.all(24),

          child: Column(

            mainAxisSize: MainAxisSize.min,

            children: [

              const Icon(Icons.style_outlined,

                  size: 56, color: AppTheme.textFaint),

              const SizedBox(height: 12),

              Text(AppLocale.t('cl_empty_filter'),

                  textAlign: TextAlign.center,

                  style: const TextStyle(color: AppTheme.textMuted)),

              const SizedBox(height: 12),

              ElevatedButton.icon(

                onPressed: () => _switchTab(1, carryQuery: _local.text),

                icon: const Icon(Icons.travel_explore),

                label: Text(AppLocale.t('cl_scry_btn')),

              ),

            ],

          ),

        ),

      );

    }

    return ListView.builder(

      controller: _scrollCtrl,

      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),

      itemCount: _cards.length + (_hasMore ? 1 : 0),

      itemBuilder: (_, i) {
        if (i >= _cards.length) {
          return const Center(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator()));
        }
        return _cardListTile(_cards[i]);
      },

    );

  }

  Widget _cardListTile(Map<String, Object?> c) {

    final url = c['image_url'] as String?;

    final qty = (c['quantity'] as num?)?.toInt() ?? 0;

    return Card(

      margin: const EdgeInsets.only(bottom: 8),

      child: ListTile(

        dense: true,

        leading: SizedBox(

          width: 34,

          height: 48,

          child: url == null || url.isEmpty

              ? const Icon(Icons.style, color: AppTheme.textFaint)

              : ClipRRect(

                  borderRadius: BorderRadius.circular(4),

                  child: CachedNetworkImage(

                    imageUrl: url,

                    fit: BoxFit.cover,

                    memCacheWidth: 100,

                    errorWidget: (_, __, ___) => const Icon(Icons.broken_image),

                  ),

                ),

        ),

        title: Text((c['name'] ?? '').toString(),

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: const TextStyle(fontWeight: FontWeight.bold)),

        subtitle: Text(
            '${c['set_name'] ?? ''} • ${CurrencyService.instance.formatUsd(((c['price_usd'] ?? c['price_ref_usd']) as num?)?.toDouble() ?? 0)}',

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),

        trailing: Row(

          mainAxisSize: MainAxisSize.min,

          children: [

            InkWell(

              onTap: () => _bump(c, -1),

              child: const Padding(

                padding: EdgeInsets.all(6),

                child: Icon(Icons.remove_circle_outline, size: 22),

              ),

            ),

            InkWell(

              onTap: () => _setQuantity(c),

              child: Padding(

                padding: const EdgeInsets.all(6),

                child: Text('$qty',

                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),

            InkWell(

              onTap: () => _bump(c, 1),

              child: const Padding(

                padding: EdgeInsets.all(6),

                child: Icon(Icons.add_circle, color: AppTheme.gold, size: 22),

              ),

            ),

          ],

        ),

        onTap: () => showModalBottomSheet(

          context: context,

          isScrollControlled: true,

          builder: (_) => CardDetailSheet(card: c),

        ).then((_) => _reload()),

      ),

    );

  }

  Widget _filtersPanel() {

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

                  decoration:

                      InputDecoration(labelText: AppLocale.t('cl_rarity')),

                  items: _rarityKeys

                      .map((k) => DropdownMenuItem(

                          value: k,

                          child: Text(rarityLabel(k),

                              overflow: TextOverflow.ellipsis)))

                      .toList(),

                  onChanged: (v) {

                    setState(() => _rarity = v ?? 'all');

                    _reload();

                  },

                ),

              ),

              const SizedBox(width: 8),

              Expanded(

                child: DropdownButtonFormField<String>(

                  initialValue: _colorKeys.contains(_color) ? _color : 'all',

                  isExpanded: true,

                  decoration:

                      InputDecoration(labelText: AppLocale.t('cl_color')),

                  items: _colorKeys

                      .map((k) => DropdownMenuItem(

                          value: k,

                          child: Text(colorLabel(k),

                              overflow: TextOverflow.ellipsis)))

                      .toList(),

                  onChanged: (v) {

                    setState(() => _color = v ?? 'all');

                    _reload();

                  },

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

                        child: Text(AppLocale.t('cl_all'),

                            overflow: TextOverflow.ellipsis)),

                    for (final s in _allSets)

                      DropdownMenuItem(

                          value: s,

                          child: Text(s, overflow: TextOverflow.ellipsis)),

                  ],

                  onChanged: (v) {

                    setState(() => _setName = v ?? 'all');

                    _reload();

                  },

                ),

              ),

              const SizedBox(width: 8),

              Expanded(

                child: TextField(

                  controller: _typeFilter,

                  decoration:

                      InputDecoration(labelText: AppLocale.t('cl_type_ex')),

                  onSubmitted: (_) => _reload(),

                ),

              ),

            ],

          ),

          Row(

            children: [

              FilterChip(

                label: Text(AppLocale.t('cl_fav')),

                selected: _favoritesOnly,

                onSelected: (v) {

                  setState(() => _favoritesOnly = v);

                  _reload();

                },

              ),

              const Spacer(),

              if (_hasActiveFilters)

                TextButton(

                    onPressed: _clearFilters,

                    child: Text(AppLocale.t('cl_clear'))),

            ],

          ),

        ],

      ),

    );

  }

  /// Linha de info da grade: edição e/ou preço, conforme os
  /// interruptores de Exibição (Ajustes). Dá para mostrar só um.
  /// O preço sai na moeda selecionada nos Ajustes (BRL por padrão).
  static String _gridSubLine(Map<String, Object?> c) {
    final parts = <String>[];
    if (DisplayPrefs.showCardSet.value) {
      final s = (c['set_name'] ?? '').toString().trim();
      if (s.isNotEmpty) parts.add(s);
    }
    if (DisplayPrefs.showCardPrice.value) {
      parts.add(CurrencyService.instance.formatUsd(
          ((c['price_usd'] ?? c['price_ref_usd']) as num?)?.toDouble() ?? 0));
    }
    return parts.join(' • ');
  }

  Widget _cardTile(Map<String, Object?> c) {

    final url = c['image_url'] as String?;

    final qty = (c['quantity'] as num?)?.toInt() ?? 0;

    return GestureDetector(

      onTap: () => showModalBottomSheet(

        context: context,

        isScrollControlled: true,

        builder: (_) => CardDetailSheet(card: c),

      ).then((_) => _reload()),

      child: Card(

        clipBehavior: Clip.antiAlias,

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.stretch,

          children: [

            // Arte sempre inteira na proporção real da carta (63:88).

            AspectRatio(

              aspectRatio: 63 / 88,

              child: url == null || url.isEmpty

                  ? const Icon(Icons.style, size: 48, color: AppTheme.textFaint)

                  : CachedNetworkImage(

                      imageUrl: url,

                      fit: BoxFit.cover,

                      // Grade 2 colunas: 400px basta (evita decodificar

                      // o full-size e o lag ao rolar).

                      memCacheWidth: 400,

                      placeholder: (_, __) =>

                          const Center(child: CircularProgressIndicator()),

                      errorWidget: (_, __, ___) =>

                          const Icon(Icons.broken_image),

                    ),

            ),

            Padding(

              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),

              child: Column(

                crossAxisAlignment: CrossAxisAlignment.start,

                mainAxisSize: MainAxisSize.min,

                children: [

                  if (DisplayPrefs.showCardName.value)
                    Text((c['name'] ?? '').toString(),

                        maxLines: 1,

                        overflow: TextOverflow.ellipsis,

                        style: const TextStyle(fontWeight: FontWeight.bold)),

                  if (DisplayPrefs.showCardSet.value ||
                      DisplayPrefs.showCardPrice.value)
                    Text(_gridSubLine(c),

                        maxLines: 1,

                        overflow: TextOverflow.ellipsis,

                        style: const TextStyle(

                            color: AppTheme.textMuted, fontSize: 12)),

                  Row(

                    mainAxisAlignment: MainAxisAlignment.spaceBetween,

                    children: [

                      InkWell(

                        onTap: () => _bump(c, -1),

                        child: const Padding(

                          padding: EdgeInsets.all(6),

                          child: Icon(Icons.remove_circle_outline, size: 22),

                        ),

                      ),

                      InkWell(

                        onTap: () => _setQuantity(c),

                        child: Padding(

                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),

                          child: Text('$qty',

                              style: const TextStyle(

                                  fontWeight: FontWeight.bold, fontSize: 16)),
                        ),
                      ),

                      InkWell(

                        onTap: () => _bump(c, 1),

                        child: const Padding(

                          padding: EdgeInsets.all(6),

                          child: Icon(Icons.add_circle,

                              color: AppTheme.gold, size: 22),

                        ),

                      ),

                    ],

                  ),

                ],

              ),

            ),

          ],

        ),

      ),

    );

  }

  // ---------- aba ADICIONAR (Scryfall) ----------

  Widget _addTab() {

    return Column(

      key: const ValueKey('tab-add'),

      crossAxisAlignment: CrossAxisAlignment.stretch,

      children: [

        Padding(

          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),

          child: TextField(

            controller: _scry,

            textInputAction: TextInputAction.search,

            onSubmitted: (_) => _searchScryfall(),

            decoration: InputDecoration(

              hintText: AppLocale.t('cl_scry_hint'),

              prefixIcon: const Icon(Icons.travel_explore),

              suffixIcon: IconButton(

                icon: const Icon(Icons.search, color: AppTheme.gold),

                tooltip: AppLocale.t('cl_scry_btn'),

                onPressed: _searchScryfall,

              ),

            ),

          ),

        ),

        Padding(

          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),

          child: Row(

            children: [

              const Icon(Icons.language, color: AppTheme.textMuted, size: 16),

              const SizedBox(width: 4),

              Text(AppLocale.t('cl_lang'),

                  style: const TextStyle(color: AppTheme.textMuted)),

              const SizedBox(width: 4),

              Expanded(child: _languageDropdown()),

            ],

          ),

        ),

        if (_suggestions.isNotEmpty)

          SizedBox(

            height: 44,

            child: ListView(

              scrollDirection: Axis.horizontal,

              padding: const EdgeInsets.symmetric(horizontal: 12),

              children: [

                for (final s in _suggestions)

                  Padding(

                    padding: const EdgeInsets.only(right: 8),

                    child: _addingName == s

                        ? ActionChip(

                            avatar: const SizedBox(

                                width: 16,

                                height: 16,

                                child:

                                    CircularProgressIndicator(strokeWidth: 2)),

                            label: Text(AppLocale.t('cl_adding')),

                            onPressed: null,

                          )

                        : ActionChip(

                            label: Text(s),

                            avatar: const Icon(Icons.add, size: 16),

                            onPressed: () => _addByName(s),

                          ),

                  ),

              ],

            ),

          ),

        if (_scryfallLoading)

          Padding(

            padding: const EdgeInsets.all(12),

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

        if (_scryfallError != null)

          Padding(

            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),

            child: Text(_scryfallError!,

                style: const TextStyle(color: Colors.orange)),

          ),

        Expanded(child: _scryGrid()),

      ],

    );

  }

  Widget _scryGrid() {

    if (_scryfallLoading && _scryfallResults.isEmpty) {

      return const Center(child: CircularProgressIndicator());

    }

    if (_scryfallResults.isEmpty) {

      return Center(

        child: Padding(

          padding: const EdgeInsets.all(24),

          child: Column(

            mainAxisSize: MainAxisSize.min,

            children: [

              const Icon(Icons.travel_explore,

                  size: 56, color: AppTheme.textFaint),

              const SizedBox(height: 12),

              Text(AppLocale.t('cl_scry_empty'),

                  textAlign: TextAlign.center,

                  style: const TextStyle(color: AppTheme.textMuted)),

            ],

          ),

        ),

      );

    }

    return GridView.builder(

      padding: const EdgeInsets.all(12),

      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(

        crossAxisCount: 2,

        childAspectRatio: 0.50,

        crossAxisSpacing: 12,

        mainAxisSpacing: 12,

      ),

      itemCount: _scryfallResults.length,

      itemBuilder: (_, i) => _scryTile(_scryfallResults[i]),

    );

  }

  Widget _scryTile(Map<String, dynamic> data) {

    final name = (data['name'] ?? '?').toString();

    final printed = (data['printed_name'] ?? '').toString();

    final url = ScryfallService.extractImageUrl(data);

    final adding = _addingName == name;

    final lang = ((data['lang'] ?? '?') as String).toUpperCase();

    return Card(

      clipBehavior: Clip.antiAlias,

      child: Column(

        crossAxisAlignment: CrossAxisAlignment.stretch,

        children: [

          Expanded(

            child: Stack(

              fit: StackFit.expand,

              children: [

                url == null || url.isEmpty

                    ? const Icon(Icons.style, color: AppTheme.textFaint)

                    : CachedNetworkImage(

                        imageUrl: url,

                        fit: BoxFit.cover,

                        memCacheWidth: 400,

                        errorWidget: (_, __, ___) =>

                            const Icon(Icons.broken_image),

                      ),

                Positioned(

                  top: 6,

                  right: 6,

                  child: Container(

                    padding:

                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),

                    decoration: BoxDecoration(

                      color: Colors.black54,

                      borderRadius: BorderRadius.circular(4),

                    ),

                    child: Text(lang,

                        style: const TextStyle(

                            color: AppTheme.gold,

                            fontSize: 11,

                            fontWeight: FontWeight.bold)),

                  ),

                ),

              ],

            ),

          ),

          Padding(

            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),

            child: Column(

              crossAxisAlignment: CrossAxisAlignment.start,

              mainAxisSize: MainAxisSize.min,

              children: [

                Text(printed.isNotEmpty ? printed : name,

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    style: const TextStyle(fontWeight: FontWeight.bold)),

                Text(

                    '${data['set_name'] ?? ''} • #${data['collector_number'] ?? '—'}',

                    maxLines: 1,

                    overflow: TextOverflow.ellipsis,

                    style: const TextStyle(

                        color: AppTheme.textMuted, fontSize: 12)),

                const SizedBox(height: 2),

                SizedBox(

                  width: double.infinity,

                  child: adding

                      ? const Center(

                          child: SizedBox(

                              width: 20,

                              height: 20,

                              child: CircularProgressIndicator(strokeWidth: 2)))

                      : OutlinedButton.icon(

                          onPressed: () => _addFromScryfall(data),

                          icon: const Icon(Icons.add, size: 16),

                          label: Text(AppLocale.t('cl_add')),

                        ),

                ),

              ],

            ),

          ),

        ],

      ),

    );

  }

  /// Seletor de idioma dos printings do Scryfall.

  Widget _languageDropdown() {

    return DropdownButton<String>(

      value: _scryLang,

      dropdownColor: AppTheme.panel,

      underline: const SizedBox.shrink(),

      isExpanded: true,

      icon: const Icon(Icons.arrow_drop_down, color: AppTheme.gold, size: 18),

      style: const TextStyle(color: AppTheme.gold, fontSize: 13),

      items: ScryfallService.languageLabels.entries

          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))

          .toList(),

      onChanged: (v) {

        if (v == null) return;

        setState(() {

          _scryLang = v;

          // Limpa na hora: nada de resultado velho em outro idioma.

          _scryfallResults = [];

          _scryfallError = null;

          _suggestions = [];

        });

        // Reexecuta a busca atual no novo idioma.

        if (_scry.text.trim().length >= 2) _searchScryfall();

      },

    );

  }

}