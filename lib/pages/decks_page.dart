import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/auth_service.dart';
import '../services/deck_availability.dart';
import '../services/community_service.dart';
import '../data/app_database.dart';
import '../theme/app_theme.dart';
import '../widgets/deck_view.dart';
import 'community_deck_detail_page.dart';
import 'community_publish.dart';
import 'deck_detail_page.dart';

// Espelha pages/decks_page.py + services/decks_database.py:
// CRUD de decks, favorito, formato, preview, contagem e valor.
// Desktop tinha 12k linhas; aqui o mesmo comportamento, enxuto.

class DecksPage extends StatefulWidget {
  const DecksPage({super.key});

  @override
  State<DecksPage> createState() => _DecksPageState();
}

class _DecksPageState extends State<DecksPage> {
  List<Map<String, Object?>> _decks = [];
  bool _loading = true;
  // Deck local -> publicação (selo "publicado" + atalho p/ vitrine).
  Map<String, String> _pubMap = {};
  final _search = TextEditingController();
  String _format = 'all';
  bool _favOnly = false;
  bool _grid = false;
  int _gridCols = 2;
  StreamSubscription? _authSub;
  bool _authFirst = true;

  @override
  void initState() {
    super.initState();
    _reload();
    AppLocale.current.addListener(_onLocale);
    AppEvents.topVisible.addListener(_onBars);
    AppEvents.navVisible.addListener(_onBars);
    AppEvents.activeProfile.addListener(_onProfile);
    // Troca de conta: selo "publicado" depende do UID.
    _authSub = AuthService.authChanges().listen((_) {
      if (_authFirst) {
        _authFirst = false;
        return;
      }
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _authSub?.cancel();
    AppLocale.current.removeListener(_onLocale);
    AppEvents.topVisible.removeListener(_onBars);
    AppEvents.navVisible.removeListener(_onBars);
    AppEvents.activeProfile.removeListener(_onProfile);
    super.dispose();
  }

  /// Perfil trocou: recarrega os decks do banco novo.
  void _onProfile() {
    if (mounted) {
      _reload();
    }
  }

  void _onLocale() {
    if (mounted) {
      setState(() {});
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

  Future<void> _reload() async {
    setState(() => _loading = true);
    final db = AppDatabase.instance.db;
    final decks = await db.query('decks', orderBy: 'favorite DESC, name ASC');
    // Índice da coleção uma vez (disponibilidade de todos os decks).
    final byOracle = await DeckAvailabilityService.ownedByOracle(db);
    final byName = await DeckAvailabilityService.ownedByName(db);
    // Mapa de publicados (best-effort; offline some o selo).
    // Só com usuário: sem ele, não cria sessão sozinho.
    Map<String, String> pubMap = {};
    try {
      if (AuthService.current != null) {
        pubMap = await CommunityService().myPublicationMap();
      }
    } catch (_) {}
    final out = <Map<String, Object?>>[];
    for (final d in decks) {
      final stats = await db.rawQuery('''
        SELECT COALESCE(SUM(dc.quantity),0) AS n,
               COALESCE(SUM(dc.quantity * COALESCE(c.price_usd, c.price_ref_usd, 0)),0) AS v
        FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
        WHERE dc.deck_id = ?''', [d['id']]);
      final items = await db.rawQuery('''
        SELECT c.*, dc.quantity AS deck_qty
        FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
        WHERE dc.deck_id = ?''', [d['id']]);
      final avail =
          DeckAvailabilityService.compute(items, byOracle, byName);
      // Capa escolhida; sem escolha, usa a carta mais presente no deck.
      final cover = await db.rawQuery('''
        SELECT c.image_url, c.name
        FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
        WHERE dc.deck_id = ?
        ORDER BY CASE WHEN c.id = ? THEN 0 ELSE 1 END,
                 dc.quantity DESC, c.name ASC
        LIMIT 1''', [d['id'], d['preview_card_id'] ?? -1]);
      out.add({
        ...d,
        ...stats.first,
        'av_owned': avail.totalOwned,
        'av_need': avail.totalNeed,
        if (cover.isNotEmpty) 'cover_url': cover.first['image_url'],
        if (cover.isNotEmpty) 'cover_name': cover.first['name'],
      });
    }
    if (mounted)
      setState(() {
        _decks = out;
        _pubMap = pubMap;
        _loading = false;
      });
  }

  List<String> get _formats {
    final set = <String>{};
    for (final d in _decks) {
      final f = (d['format'] ?? '').toString();
      if (f.isNotEmpty) set.add(f);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<Map<String, Object?>> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final d in _decks)
        if (!_favOnly ||
            (((d['favorite'] as num?)?.toInt() ?? 0) == 1))
          if (_format == 'all' || (d['format'] ?? '') == _format)
            if (q.isEmpty ||
                (d['name'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(q))
              d
    ];
  }

  Future<void> _toggleFav(Map<String, Object?> d, bool fav) async {
    await AppDatabase.instance.db.update(
        'decks', {'favorite': fav ? 0 : 1},
        where: 'id = ?', whereArgs: [d['id']]);
    await _reload();
  }

  Future<void> _onDeckMenu(String v, Map<String, Object?> d) async {
    final db = AppDatabase.instance.db;
    if (v == 'rename') {
      final n = await _askName(AppLocale.t('prof_rename'),
          initial: (d['name'] ?? '').toString());
      if (n != null && n.trim().isNotEmpty) {
        await db.update('decks', {'name': n.trim()},
            where: 'id = ?', whereArgs: [d['id']]);
        await _reload();
      }
    } else if (v == 'delete') {
      await db.delete('decks', where: 'id = ?', whereArgs: [d['id']]);
      await _reload();
    } else if (v == 'publish') {
      await CommunityPublish.show(context, (d['id'] as num).toInt());
      await _reload();
    }
  }

  List<PopupMenuEntry<String>> _menuItems(bool fav) => [
        PopupMenuItem(
            value: 'rename',
            child: Text(AppLocale.t('prof_rename'))),
        PopupMenuItem(
            value: 'publish',
            child: Text(AppLocale.t('com_publish'))),
        PopupMenuItem(
            value: 'delete',
            child: Text(AppLocale.t('prof_delete'))),
      ];

  void _openDeck(Map<String, Object?> d) {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => DeckDetailPage(
              deckId: d['id'] as int,
              deckName: (d['name'] ?? '').toString())),
    ).then((_) => _reload());
  }

  void _openPublished(Map<String, Object?> d) {
    final pub = _pubMap['${d['id']}'];
    if (pub == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => CommunityDeckDetailPage(deckId: pub)),
    ).then((_) => _reload());
  }

  Future<void> _create() async {
    final name = await _askName(AppLocale.t('deck_new'));
    if (name == null || name.trim().isEmpty) return;
    await AppDatabase.instance.db.insert('decks', {'name': name.trim()});
    await _reload();
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        scrollable: true,
        title: Text(title),
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
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppEvents.topVisible.value
          ? AppBar(
              title: Text(AppLocale.t('nav_decks')),
              actions: [
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: AppLocale.t('common_focus'),
                  onPressed: AppEvents.toggleNav,
                ),
              ],
            )
          : null,
      // Sempre visível e CENTRALIZADO: no foco total o botão de voltar
      // as barras fica à direita, então não há sobreposição.
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        onPressed: _create,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        top: !AppEvents.topVisible.value,
        bottom: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _decks.isEmpty
                ? Center(
                    child: Text(AppLocale.t('deck_empty'),
                        style: const TextStyle(color: AppTheme.textMuted)))
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(12, 4, 12, 4),
                            child: TextField(
                              controller: _search,
                              textInputAction: TextInputAction.search,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                hintText:
                                    AppLocale.t('deck_search_hint'),
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: _search.text.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(Icons.clear,
                                            size: 18),
                                        onPressed: () => setState(
                                            () => _search.clear()),
                                      ),
                              ),
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(12, 4, 12, 4),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment:
                                  WrapCrossAlignment.center,
                              children: [
                                DropdownButton<String>(
                                  value: _format,
                                  dropdownColor: AppTheme.panel,
                                  underline: const SizedBox.shrink(),
                                  style: const TextStyle(
                                      color: AppTheme.gold,
                                      fontSize: 13),
                                  items: [
                                    DropdownMenuItem(
                                        value: 'all',
                                        child: Text(AppLocale.t(
                                            'com_format_all'))),
                                    for (final f in _formats)
                                      DropdownMenuItem(
                                          value: f,
                                          child:
                                              Text(prettyFormat(f))),
                                  ],
                                  onChanged: (v) => setState(
                                      () => _format = v ?? 'all'),
                                ),
                                FilterChip(
                                  avatar: Icon(
                                      _favOnly
                                          ? Icons.star
                                          : Icons.star_border,
                                      size: 14),
                                  label: Text(AppLocale.t(
                                      'deck_filter_fav'),
                                      style: const TextStyle(
                                          fontSize: 12)),
                                  selected: _favOnly,
                                  visualDensity:
                                      VisualDensity.compact,
                                  onSelected: (_) => setState(
                                      () => _favOnly = !_favOnly),
                                ),
                                DeckViewToggle(
                                    grid: _grid,
                                    onChanged: (v) => setState(
                                        () => _grid = v)),
                                if (_grid)
                                  GridColumnsToggle(
                                      columns: _gridCols,
                                      onChanged: (v) => setState(
                                          () => _gridCols = v)),
                              ],
                            ),
                          ),
                        ),
                        Builder(builder: (_) {
                          final list = _filtered;
                          // Razão imagem 63:88 + infos (mesma cura do
                          // crop da vitrine): o grid nunca espreme a capa.
                          final w = (MediaQuery.of(context)
                                      .size
                                      .width -
                                  24 -
                                  10 * (_gridCols - 1)) /
                              _gridCols;
                          final ratio = w / (w * 88 / 63 + 88);
                          if (list.isEmpty) {                            return SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                      AppLocale.t('deck_no_match'),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color:
                                              AppTheme.textMuted)),
                                ),
                              ),
                            );
                          }
                          if (_grid) {
                            return SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                  12, 4, 12, 12),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _gridCols,
                                  childAspectRatio: ratio,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                ),
                                delegate:
                                    SliverChildBuilderDelegate(
                                  (_, i) =>
                                      _deckGridCard(list[i]),
                                  childCount: list.length,
                                ),
                              ),
                            );
                          }
                          return SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (_, i) => Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    12, 3, 12, 3),
                                child: _deckListTile(list[i]),
                              ),
                              childCount: list.length,
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _deckListTile(Map<String, Object?> d) {
    final fav = ((d['favorite'] as num?)?.toInt() ?? 0) == 1;
    final coverUrl = (d['cover_url'] ?? '').toString();
    final count = (d['n'] as num?)?.toInt() ?? 0;
    final price = (d['v'] as num?)?.toDouble() ?? 0;
    final avOwned = (d['av_owned'] as num?)?.toInt() ?? 0;
    final avNeed = (d['av_need'] as num?)?.toInt() ?? 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _openDeck(d),
        child: SizedBox(
          height: 112,
          child: Row(children: [
            SizedBox(
              width: 80,
              height: double.infinity,
              child: coverUrl.isEmpty
                  ? const ColoredBox(
                      color: AppTheme.goldSoft,
                      child: Icon(Icons.style,
                          color: AppTheme.gold, size: 30))
                  : CachedNetworkImage(
                      imageUrl: coverUrl,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          const Icon(Icons.broken_image)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text((d['name'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16)),
                      ),
                      if (_pubMap.containsKey('${d['id']}'))
                        InkWell(
                          onTap: () => _openPublished(d),
                          child: Tooltip(
                            message: AppLocale.t(
                                'com_published_badge'),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.cloud_done,
                                  color: AppTheme.gold, size: 18),
                            ),
                          ),
                        ),
                      if (fav)
                        const Icon(Icons.star,
                            color: AppTheme.gold, size: 18),
                    ]),
                    const SizedBox(height: 5),
                    Text(
                        prettyFormat(
                            (d['format'] ?? 'livre').toString()),
                        style: const TextStyle(
                            color: AppTheme.gold,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(
                        '$count ${AppLocale.t('deck_cards_suffix')} • $avOwned/$avNeed • ${price.toStringAsFixed(2)} USD',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: avNeed > 0 && avOwned < avNeed
                                ? Colors.orange
                                : AppTheme.textMuted)),
                  ],
                ),
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(fav ? Icons.star : Icons.star_border,
                      color: AppTheme.gold),
                  onPressed: () => _toggleFav(d, fav),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => _onDeckMenu(v, d),
                  itemBuilder: (_) => _menuItems(fav),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Widget _deckGridCard(Map<String, Object?> d) {
    final fav = ((d['favorite'] as num?)?.toInt() ?? 0) == 1;
    final coverUrl = (d['cover_url'] ?? '').toString();
    final count = (d['n'] as num?)?.toInt() ?? 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _openDeck(d),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 63 / 88,
              child: Container(
                color: AppTheme.goldSoft,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    coverUrl.isEmpty
                        ? const Icon(Icons.style,
                            color: AppTheme.gold, size: 30)
                        : CachedNetworkImage(
                            imageUrl: coverUrl,
                            // Mesma proporção da caixa: capa inteira,
                            // sem crop e sem distorção.
                            fit: BoxFit.contain,
                            memCacheWidth: 400,
                            errorWidget: (_, __, ___) => const Icon(
                                Icons.broken_image,
                                color: AppTheme.gold),
                          ),
                    if (fav)
                      const Positioned(
                        right: 6,
                        top: 6,
                        child: Icon(Icons.star,
                            size: 16, color: AppTheme.gold),
                      ),
                    if (_pubMap.containsKey('${d['id']}'))
                      const Positioned(
                        left: 6,
                        top: 6,
                        child: Icon(Icons.cloud_done,
                            size: 16, color: AppTheme.gold),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Text((d['name'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${prettyFormat((d['format'] ?? 'livre').toString())} • $count',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11)),
                  ),
                  PopupMenuButton<String>(
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    onSelected: (v) => _onDeckMenu(v, d),
                    itemBuilder: (_) => _menuItems(fav),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
