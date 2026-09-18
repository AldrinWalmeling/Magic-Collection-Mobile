import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_database.dart';
import '../services/app_locale.dart';
import '../services/card_types.dart';
import '../services/community_service.dart';
import '../services/currency_service.dart';
import '../services/deck_availability.dart';
import '../services/deck_stats.dart';
import '../services/export_service.dart';
import '../services/online_friends.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/deck_view.dart';
import '../widgets/mana_curve_chart.dart';
import '../widgets/mtg_symbols.dart';
import 'deck_detail_page.dart';
import 'community_publish.dart';
import 'public_profile_page.dart';

// Detalhe do deck público: cabeçalho, stats reais, cartas agrupadas
// com disponibilidade, curtir/favoritar/avaliar, copiar, exportar.
class CommunityDeckDetailPage extends StatefulWidget {
  const CommunityDeckDetailPage({super.key, required this.deckId});

  final String deckId;

  @override
  State<CommunityDeckDetailPage> createState() =>
      _CommunityDeckDetailPageState();
}

class _CommunityDeckDetailPageState
    extends State<CommunityDeckDetailPage> {
  final _service = CommunityService();
  CommunityDeck? _deck;
  List<Map<String, dynamic>> _cards = [];
  DeckAvailability _avail = DeckAvailability.empty;
  DeckStats _stats = DeckStats.empty;
  bool _loading = true;
  String? _error;
  bool _liked = false;
  bool _fav = false;
  int _myStars = 0;
  bool _busy = false;
  bool _grid = false;
  int _gridCols = 3;
  int? _myLocalDeckId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final deck = await _service.getDeck(widget.deckId);
      if (!mounted) return;
      if (deck == null) {
        setState(() {
          _loading = false;
          _error = AppLocale.t('com_gone');
        });
        return;
      }
      final cards = await _service.getDeckCards(widget.deckId);
      final items = [
        for (final c in cards)
          {
            'id': ('${c['scryfall_id'] ?? ''}${c['name']}'.hashCode),
            'name': c['name'],
            'oracle_id': c['oracle_id'],
            'deck_qty': c['qty'],
            'price_usd': c['price_usd'],
            'cmc': c['cmc'],
            'type_line': c['type_line'],
            'colors': c['colors'],
            'color_identity': c['color_identity'],
          },
      ];
      final db = AppDatabase.instance.db;
      final idx = await Future.wait([
        DeckAvailabilityService.ownedByOracle(db),
        DeckAvailabilityService.ownedByName(db),
      ]);
      final results = await Future.wait([
        _service.isLiked(widget.deckId),
        _service.isFavorite(widget.deckId),
        _service.myRating(widget.deckId),
      ]);
      if (!mounted) return;
      setState(() {
        _deck = deck;
        _cards = cards;
        _avail = DeckAvailabilityService.compute(items, idx[0], idx[1]);
        _stats = DeckStatsService.compute([
          for (final c in cards)
            {
              ...c,
              'deck_qty': c['qty'],
              'price_usd': c['price_usd'],
            },
        ]);
        _liked = results[0] as bool;
        _fav = results[1] as bool;
        _myStars = results[2] as int;
        _loading = false;
      });
      await _service.recordView(widget.deckId);
      if (!mounted) return;
      final fresh = await _service.getDeck(widget.deckId);
      if (mounted && fresh != null) setState(() => _deck = fresh);
      await _resolveOwnPublication(deck);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Se a publicação é minha e existe o deck local correspondente,
  /// libera o botão de republicar (atualizar dados defasados).
  Future<void> _resolveOwnPublication(CommunityDeck deck) async {
    try {
      final uid = await OnlineFriends().myUid;
      if (uid.isEmpty || deck.authorUid != uid) return;
      final map = await _service.myPublicationMap();
      int? localId;
      map.forEach((local, pub) {
        if (pub == widget.deckId) localId = int.tryParse(local);
      });
      if (!mounted || localId == null) return;
      // Confirma que o deck local ainda existe.
      final rows = await AppDatabase.instance.db.query('decks',
          columns: ['id'], where: 'id = ?', whereArgs: [localId]);
      if (!mounted || rows.isEmpty) return;
      setState(() => _myLocalDeckId = localId);
    } catch (_) {}
  }

  Future<void> _toggleLike() async {
    if (_busy || _deck == null) return;
    setState(() => _busy = true);
    try {
      final v = await _service.toggleLike(widget.deckId, _liked);
      if (!mounted) return;
      setState(() {
        _liked = v;
        _busy = false;
      });
      await _refreshCounters();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.show(context, '$e');
    }
  }

  Future<void> _toggleFav() async {
    if (_busy || _deck == null) return;
    setState(() => _busy = true);
    try {
      final v = await _service.toggleFavorite(widget.deckId);
      if (!mounted) return;
      setState(() {
        _fav = v;
        _busy = false;
      });
      await _refreshCounters();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.show(context, '$e');
    }
  }

  Future<void> _refreshCounters() async {
    try {
      final fresh = await _service.getDeck(widget.deckId);
      if (mounted && fresh != null) setState(() => _deck = fresh);
    } catch (_) {}
  }

  Future<void> _rateDialog() async {
    var stars = _myStars == 0 ? 5 : _myStars;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(AppLocale.t('com_rate_title')),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  icon: Icon(i <= stars ? Icons.star : Icons.star_border,
                      color: AppTheme.gold, size: 30),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 40, minHeight: 40),
                  onPressed: () => setD(() => stars = i),
                ),
            ],
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
    );
    if (ok != true || !mounted) return;
    try {
      await _service.rate(widget.deckId, stars);
      if (!mounted) return;
      setState(() => _myStars = stars);
      await _refreshCounters();
      AppToast.show(context, AppLocale.t('com_rated'));
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    }
  }

  Future<void> _copy() async {
    final d = _deck;
    if (d == null || !d.allowCopy) return;
    setState(() => _busy = true);
    try {
      final localId = await _service.copyDeck(widget.deckId);
      if (!mounted) return;
      setState(() => _busy = false);
      final avail = await DeckAvailabilityService.forDeck(
          AppDatabase.instance.db, localId);
      if (!mounted) return;
      final missing = avail.totalMissing;
      AppToast.show(
          context,
          missing == 0
              ? AppLocale.t('com_copied_full')
              : AppLocale.t('com_copied_missing')
                  .replaceAll('{n}', '$missing'));
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                DeckDetailPage(deckId: localId, deckName: d.name)),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.show(context, '$e');
    }
  }

  Future<void> _export({required bool json}) async {
    final d = _deck;
    if (d == null) return;
    try {
      final items = [
        for (final c in _cards)
          {
            'name': c['name'],
            'deck_qty': c['qty'],
            'set_code': c['set'],
          },
      ];
      if (json) {
        await ExportService.exportDeckJson(
          d.name,
          format: d.format,
          commanderName: d.commanderName,
          cards: items,
        );
      } else {
        await ExportService.exportDeckTxt(d.name, items);
      }
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    }
  }

  Future<void> _share() async {
    final d = _deck;
    if (d == null) return;
    try {
      await SharePlus.instance.share(ShareParams(
          text: AppLocale.t('com_share_text')
              .replaceAll('{n}', d.name)
              .replaceAll('{c}', d.id)));
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, d.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _deck;
    return Scaffold(
      appBar: AppBar(
        title: Text(d?.name ?? AppLocale.t('nav_social')),
        actions: [
          // Publicação minha com dados defasados? Um toque republica
          // do deck local (oferece atualizar, preservando votos).
          if (_myLocalDeckId != null)
            IconButton(
              icon: const Icon(Icons.sync, size: 20),
              tooltip: AppLocale.t('com_republish'),
              onPressed: () => CommunityPublish.show(
                      context, _myLocalDeckId!)
                  .then((_) {
                if (mounted) _load();
              }),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null || d == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error ?? AppLocale.t('com_gone'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.orange)),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh, size: 16),
                          label:
                              Text(AppLocale.t('common_retry')),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    children: [
                      _header(d),
                      const SizedBox(height: 8),
                      _actions(d),
                      const SizedBox(height: 8),
                      _statsCard(),
                      const SizedBox(height: 8),
                      _availCard(),
                      const SizedBox(height: 8),
                      ..._groupedCards(),
                    ],
                  ),
                ),
    );
  }

  Widget _header(CommunityDeck d) {
    final img = d.coverUrl.isNotEmpty
        ? d.coverUrl
        : d.commanderImage;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Carta principal inteira, proporção de carta real
                // (63:88), sem crop. Largura fixa generosa + stats
                // fora da coluna lateral para nada espremer a carta.
                if (img.isNotEmpty)
                  Container(
                    width: 112,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: AppTheme.goldSoft,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: AspectRatio(
                      aspectRatio: 63 / 88,
                      child: CachedNetworkImage(
                        imageUrl: img,
                        fit: BoxFit.contain,
                        memCacheWidth: 360,
                        errorWidget: (_, __, ___) => const Icon(
                            Icons.broken_image,
                            color: AppTheme.gold),
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18)),
                      const SizedBox(height: 4),
                      InkWell(
                        onTap: d.authorUid.isEmpty
                            ? null
                            : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          PublicProfilePage(
                                              userId:
                                                  d.authorUid)),
                                ),
                        child: Text(
                            '${d.authorName.isEmpty ? '?' : d.authorName}'
                            '${d.authorCode.isEmpty ? '' : ' • @${d.authorCode}'}',
                            style: const TextStyle(
                                color: AppTheme.gold, fontSize: 13)),
                      ),
                      if (d.commanderName.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.shield,
                                size: 14, color: AppTheme.gold),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(d.commanderName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _miniStat(Icons.style, '${d.cardCount}'),
                _miniStat(Icons.attach_money,
                    CurrencyService.instance.formatUsd(d.priceUsd)),
                _miniStat(
                    Icons.visibility_outlined, '${d.views}'),
                _miniStat(
                    Icons.thumb_up_outlined, '${d.likes}'),
                _miniStat(
                    Icons.favorite_border, '${d.favorites}'),
                _miniStat(
                    Icons.star,
                    d.ratingCount > 0
                        ? '${d.ratingAvg.toStringAsFixed(1)} (${d.ratingCount})'
                        : '—'),
              ],
            ),
            if (d.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(d.description,
                  style: const TextStyle(fontSize: 13)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                    label: Text(d.format.toUpperCase(),
                        style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact),
                if (d.colors.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var k = 0;
                          k < d.colors.length && k < 5;
                          k++) ...[
                        if (k > 0) const SizedBox(width: 2),
                        MtgPip(d.colors[k], size: 16),
                      ],
                    ],
                  ),
                if (d.tags.isNotEmpty)
                  Text('#${d.tags.take(3).join(' #')}',
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppTheme.textMuted),
        const SizedBox(width: 3),
        Text(text,
            style:
                const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
      ],
    );
  }

  Widget _actions(CommunityDeck d) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(
                    _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                    size: 16),
                label: Text('${d.likes}'),
                onPressed: _busy ? null : _toggleLike,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(
                    _fav ? Icons.favorite : Icons.favorite_border,
                    size: 16,
                    color: _fav ? Colors.redAccent : null),
                label: Text('${d.favorites}'),
                onPressed: _busy ? null : _toggleFav,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.star_border, size: 16),
                label: Text(_myStars > 0
                    ? '$_myStars★'
                    : AppLocale.t('com_rate')),
                onPressed: _busy ? null : _rateDialog,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (d.allowCopy)
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(AppLocale.t('com_copy')),
                  onPressed: _busy ? null : _copy,
                ),
              ),
            if (d.allowCopy) const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.ios_share, size: 16),
                label: Text(AppLocale.t('com_export')),
                onPressed: () => showMenu<bool>(
                  context: context,
                  position: const RelativeRect.fromLTRB(100, 100, 0, 0),
                  items: [
                    PopupMenuItem(
                        value: false,
                        child: Text(
                            AppLocale.t('com_export_txt'))),
                    PopupMenuItem(
                        value: true,
                        child: Text(
                            AppLocale.t('com_export_json'))),
                  ],
                ).then((json) {
                  if (json != null) _export(json: json);
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.share_outlined, size: 16),
                label: Text(AppLocale.t('com_share')),
                onPressed: _share,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statsCard() {
    final s = _stats;
    if (s.totalCards == 0) return const SizedBox.shrink();
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        dense: true,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        title: Text(
            'MV ${s.avgMv.toStringAsFixed(2)} • ${s.landCount} ${AppLocale.t('cat_lands').toLowerCase()}',
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ManaCurveChart(curve: s.curve),
                const SizedBox(height: 8),
                _compositionRows(s),
                const SizedBox(height: 8),
                _manaSources(s),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Composição com rótulos localizados e ellipsis (nunca quebra
  /// palavra no meio).
  Widget _compositionRows(DeckStats s) {
    final rows = [
      (AppLocale.t('cat_creatures'), s.types.creatures),
      (AppLocale.t('cat_planeswalkers'), s.types.planeswalkers),
      (AppLocale.t('cat_artifacts'), s.types.artifacts),
      (AppLocale.t('cat_enchantments'), s.types.enchantments),
      (AppLocale.t('cat_instants'), s.types.instants),
      (AppLocale.t('cat_sorceries'), s.types.sorceries),
      (AppLocale.t('cat_lands'), s.types.lands),
      (AppLocale.t('cat_other'), s.types.other),
    ];
    final max = rows.fold<int>(1, (m, r) => r.$2 > m ? r.$2 : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppLocale.t('stats_types'),
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 12)),
        const SizedBox(height: 4),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(r.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 10,
                      child: Row(
                        children: [
                          if (r.$2 > 0)
                            Expanded(
                                flex: r.$2,
                                child: const ColoredBox(
                                    color: Colors.lightBlue)),
                          if (max - r.$2 > 0)
                            Expanded(
                                flex: max - r.$2,
                                child: ColoredBox(
                                    color: Colors.white.withValues(
                                        alpha: 0.08))),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: Text('${r.$2}',
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Fontes por cor (cartas / fontes) a partir dos dados reais.
  Widget _manaSources(DeckStats s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppLocale.t('stats_mana'),
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 12)),
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
                      style: const TextStyle(fontSize: 12)),
                  Text(' / ${s.sourcesByColor[col] ?? 0}',
                      style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12)),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _availCard() {
    final a = _avail;
    if (a.totalNeed == 0) return const SizedBox.shrink();
    final complete = a.totalMissing == 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(complete ? Icons.check_circle : Icons.warning_amber,
                color: complete ? Colors.green : Colors.orange,
                size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  complete
                      ? AppLocale.t('av_complete')
                      : AppLocale.t('av_summary')
                          .replaceAll('{o}', '${a.totalOwned}')
                          .replaceAll('{t}', '${a.totalNeed}'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _groupedCards() {
    final groups = <String, List<Map<String, dynamic>>>{};
    String bucket(Map<String, dynamic> c) {
      final name = (c['name'] ?? '').toString();
      if (_deck?.commanderName.isNotEmpty ?? false) {
        final cmd = _deck!.commanderName;
        if (CardTypes.flat(name) == CardTypes.flat(cmd)) {
          return CardCategory.commander;
        }
      }
      return CardTypes.category(c['type_line']);
    }

    for (final c in _cards) {
      groups.putIfAbsent(bucket(c), () => []).add(c);
    }
    String title(String g) => deckGroupTitle(g);

    int qtyOf(List<Map<String, dynamic>> items) =>
        items.fold<int>(
            0, (s, c) => s + (((c['qty'] as num?)?.toInt() ?? 0)));
    final out = <Widget>[];
    out.add(Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: DeckViewToggle(
                grid: _grid,
                onChanged: (v) => setState(() => _grid = v)),
          ),
          if (_grid) ...[
            const SizedBox(width: 8),
            GridColumnsToggle(
                columns: _gridCols,
                onChanged: (v) =>
                    setState(() => _gridCols = v)),
          ],
        ],
      ),
    ));
    for (final g in CardCategory.order) {
      final items = groups[g];
      if (items == null || items.isEmpty) continue;
      out.add(DeckGroupHeader(title: title(g), count: qtyOf(items)));
      if (_grid) {
        out.add(GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridCols,
            childAspectRatio: 63 / 96,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: items.length,
          itemBuilder: (_, i) => _gridTile(items[i]),
        ));
      } else {
        for (final c in items) {
          out.add(_listTile(c));
        }
      }
    }
    return out;
  }

  Widget _gridTile(Map<String, dynamic> c) {
    final qty = (c['qty'] as num?)?.toInt() ?? 1;
    final img = (c['image_url'] ?? '').toString();
    final key =
        '${c['scryfall_id'] ?? ''}${c['name']}'.hashCode;
    final av = _avail.forCard(key);
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
      imageUrl: img,
      name: (c['name'] ?? '').toString(),
      qtyText: '${qty}x',
      badge: badge,
    );
  }

  Widget _listTile(Map<String, dynamic> c) {
    final key =
        '${c['scryfall_id'] ?? ''}${c['name']}'.hashCode;
    final av = _avail.forCard(key);
    final qty = (c['qty'] as num?)?.toInt() ?? 1;
    final img = (c['image_url'] ?? '').toString();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: img.isEmpty
            ? const Icon(Icons.style)
            : ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: img,
                  width: 32,
                  height: 44,
                  fit: BoxFit.cover,
                  memCacheWidth: 100,
                  errorWidget: (_, __, ___) =>
                      const Icon(Icons.broken_image),
                ),
              ),
        title: Text((c['name'] ?? '').toString(),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
        subtitle: Text(
            '${qty}x'
            '${av.need > 0 ? (av.status == AvailStatus.ok ? ' ✓' : ' • faltam ${av.missing}') : ''}',
            style: TextStyle(
                fontSize: 11,
                color: av.need > 0 && av.status != AvailStatus.ok
                    ? Colors.orange
                    : AppTheme.textMuted)),
        trailing: Text(
            ((c['price_usd'] as num?)?.toDouble() ?? 0) > 0
                ? CurrencyService.instance.formatUsd(
                    (c['price_usd'] as num).toDouble())
                : '—',
            style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
