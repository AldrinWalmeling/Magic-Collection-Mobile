import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../data/app_database.dart';
import '../theme/app_theme.dart';
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

  @override
  void initState() {
    super.initState();
    _reload();
    AppLocale.current.addListener(_onLocale);
    AppEvents.topVisible.addListener(_onBars);
    AppEvents.navVisible.addListener(_onBars);
    AppEvents.activeProfile.addListener(_onProfile);
  }

  @override
  void dispose() {
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
    final out = <Map<String, Object?>>[];
    for (final d in decks) {
      final stats = await db.rawQuery('''
        SELECT COALESCE(SUM(dc.quantity),0) AS n,
               COALESCE(SUM(dc.quantity * COALESCE(c.price_usd, c.price_ref_usd, 0)),0) AS v
        FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
        WHERE dc.deck_id = ?''', [d['id']]);
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
        if (cover.isNotEmpty) 'cover_url': cover.first['image_url'],
        if (cover.isNotEmpty) 'cover_name': cover.first['name'],
      });
    }
    if (mounted)
      setState(() {
        _decks = out;
        _loading = false;
      });
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
                    child: ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _decks.length,
                      itemBuilder: (_, i) {
                        final d = _decks[i];
                        final fav =
                            ((d['favorite'] as num?)?.toInt() ?? 0) == 1;
                        final coverUrl = (d['cover_url'] ?? '').toString();
                        final count = (d['n'] as num?)?.toInt() ?? 0;
                        final price = (d['v'] as num?)?.toDouble() ?? 0;
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => DeckDetailPage(
                                      deckId: d['id'] as int,
                                      deckName: (d['name'] ?? '').toString())),
                            ).then((_) => _reload()),
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
                                    padding:
                                        const EdgeInsets.fromLTRB(12, 10, 4, 8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          Expanded(
                                            child: Text(
                                                (d['name'] ?? '').toString(),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 16)),
                                          ),
                                          if (fav)
                                            const Icon(Icons.star,
                                                color: AppTheme.gold, size: 18),
                                        ]),
                                        const SizedBox(height: 5),
                                        Text(
                                            (d['format'] ?? 'livre')
                                                .toString()
                                                .toUpperCase(),
                                            style: const TextStyle(
                                                color: AppTheme.gold,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold)),
                                        const Spacer(),
                                        Text(
                                            '$count ${AppLocale.t('deck_cards_suffix')} • ${price.toStringAsFixed(2)} USD',
                                            style: const TextStyle(
                                                color: AppTheme.textMuted)),
                                      ],
                                    ),
                                  ),
                                ),
                                Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                          fav ? Icons.star : Icons.star_border,
                                          color: AppTheme.gold),
                                      onPressed: () async {
                                        await AppDatabase.instance.db.update(
                                            'decks', {'favorite': fav ? 0 : 1},
                                            where: 'id = ?',
                                            whereArgs: [d['id']]);
                                        await _reload();
                                      },
                                    ),
                                    PopupMenuButton<String>(
                                      onSelected: (v) async {
                                        final db = AppDatabase.instance.db;
                                        if (v == 'rename') {
                                          final n = await _askName(
                                              AppLocale.t('prof_rename'),
                                              initial:
                                                  (d['name'] ?? '').toString());
                                          if (n != null &&
                                              n.trim().isNotEmpty) {
                                            await db.update(
                                                'decks', {'name': n.trim()},
                                                where: 'id = ?',
                                                whereArgs: [d['id']]);
                                            await _reload();
                                          }
                                        } else if (v == 'delete') {
                                          await db.delete('decks',
                                              where: 'id = ?',
                                              whereArgs: [d['id']]);
                                          await _reload();
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        PopupMenuItem(
                                            value: 'rename',
                                            child: Text(
                                                AppLocale.t('prof_rename'))),
                                        PopupMenuItem(
                                            value: 'delete',
                                            child: Text(
                                                AppLocale.t('prof_delete'))),
                                      ],
                                    ),
                                  ],
                                ),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    );
  }
}
