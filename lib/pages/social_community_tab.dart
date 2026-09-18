import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'dart:async';

import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../services/currency_service.dart';
import '../services/online_friends.dart';
import '../theme/app_theme.dart';
import '../widgets/deck_view.dart';
import '../widgets/mtg_symbols.dart';
import 'community_deck_detail_page.dart';

// Aba Comunidade: vitrine pública de decks (RTDB de verdade).
// Seções calculadas no cliente sobre o lote: Em alta, Mais curtidos,
// Mais favoritados, Mais vistos, Recentes (+ Meus favoritos).
class CommunityTab extends StatefulWidget {
  const CommunityTab({super.key});

  @override
  State<CommunityTab> createState() => _CommunityTabState();
}

class _CommunityTabState extends State<CommunityTab> {
  final _service = CommunityService();
  final _search = TextEditingController();
  List<CommunityDeck> _all = [];
  bool _loading = true;
  String? _error;
  String _section = 'all';
  String _format = 'all';
  final _colors = <String>{};
  bool _onlyFavorites = false;
  Set<String> _favIds = {};
  Set<String> _friendUids = {};
  String _scope = 'all';
  bool _grid = true;
  int _gridCols = 2;
  // Busca por carta: nomes (minúsculos) por deck, com cache.
  final Map<String, List<String>> _deckCardNames = {};
  Set<String> _cardMatch = {};
  bool _searchingCards = false;
  Timer? _searchTimer;
  StreamSubscription? _authSub;
  bool _authFirst = true;

  @override
  void initState() {
    super.initState();
    _load();
    // Volta para a aba: recarrega silencioso (sem piscar).
    AppEvents.socialTab.addListener(_onSocialTab);
    _authSub = AuthService.authChanges().listen((_) {
      if (_authFirst) {
        _authFirst = false;
        return;
      }
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchTimer?.cancel();
    _authSub?.cancel();
    AppEvents.socialTab.removeListener(_onSocialTab);
    super.dispose();
  }

  void _onSocialTab() {
    if (AppEvents.socialTab.value == 0 && mounted) {
      _load(silent: true);
    }
  }

  // Já buscando (pull + voltar na aba): não empilha requisição.
  // Flag separada de _loading (que começa true na montagem).
  bool _fetching = false;

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    // Sem usuário: a vitrine exige auth; não cria sessão sozinho.
    if (AuthService.current == null) {
      setState(() {
        _loading = false;
        _favIds = {};
        _friendUids = {};
      });
      return;
    }
    if (_fetching) return;
    _fetching = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final decks = await _service.listDecks();
      Set<String> favs = {};
      Set<String> blocked = {};
      Set<String> friendUids = {};
      try {
        favs = (await _service.myFavoriteIds()).toSet();
      } catch (_) {}
      try {
        blocked = await _service.myBlockedIds();
      } catch (_) {}
      try {
        final uid = await OnlineFriends().myUid;
        final friends = await OnlineFriends().friendsOnce(uid);
        friendUids = {for (final f in friends) f.uid};
      } catch (_) {}
      if (!mounted) {
        _fetching = false;
        return;
      }
      setState(() {
        _all = [
          for (final d in decks)
            if (!blocked.contains(d.authorUid)) d
        ];
        _favIds = favs;
        _friendUids = friendUids;
        _loading = false;
      });
      _fetching = false;
    } catch (e) {
      if (!mounted) {
        _fetching = false;
        return;
      }
      // Silencioso com conteúdo: preserva a tela em vez de trocar
      // por erro (o manual mostra erro normalmente).
      if (silent && _all.isNotEmpty) {
        _fetching = false;
        return;
      }
      setState(() {
        _loading = false;
        _error = '$e';
      });
      _fetching = false;
    }
  }

  /// Rótulo com inicial maiúscula ("commander" -> "Commander").
  static String formatLabel(String f) => prettyFormat(f);

  void _onSearchChanged() {
    setState(() {});
    _searchTimer?.cancel();
    final q = _search.text.trim().toLowerCase();
    if (_scope != 'card' || q.length < 2) {
      if (mounted) setState(() => _searchingCards = false);
      return;
    }
    _searchTimer =
        Timer(const Duration(milliseconds: 600), () => _searchCards(q));
  }

  /// Busca por carta contida no deck: baixa as listas dos candidatos
  /// em paralelo (só os ainda sem cache) e filtra localmente.
  Future<void> _searchCards(String q) async {
    if (!mounted) return;
    setState(() => _searchingCards = true);
    try {
      final candidates = _all.where((d) {
        if (_onlyFavorites && !_favIds.contains(d.id)) return false;
        if (_section == 'friends' &&
            !_friendUids.contains(d.authorUid)) {
          return false;
        }
        if (_format != 'all' && d.format != _format) return false;
        return true;
      }).toList();
      final missing = [
        for (final d in candidates)
          if (!_deckCardNames.containsKey(d.id)) d
      ];
      if (missing.isNotEmpty) {
        final fetched = await Future.wait([
          for (final d in missing)
            _service.getDeckCards(d.id).catchError((_) => <Map<String, dynamic>>[]),
        ]);
        if (!mounted) return;
        for (var i = 0; i < missing.length; i++) {
          _deckCardNames[missing[i].id] = [
            for (final c in fetched[i])
              (c['name'] ?? '').toString().toLowerCase()
          ];
        }
      }
      if (!mounted) return;
      setState(() {
        _cardMatch = {
          for (final d in candidates)
            if ((_deckCardNames[d.id] ?? [])
                .any((n) => n.contains(q)))
              d.id
        };
        _searchingCards = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searchingCards = false);
    }
  }

  // Bloco de infos com altura UNIFORME (linhas sempre presentes):
  // nome + (comandante ou autor) + cores/views/rating + qtd/preço/like.
  // A razão do card (imagem 63:88 + infos) é calculada em
  // _DeckCard.cardRatio a partir dela.
  static const _infoH = 104.0;

  List<CommunityDeck> get _filtered {
    final q = _search.text.trim().toLowerCase();
    var list = _all.where((d) {
      if (_onlyFavorites && !_favIds.contains(d.id)) return false;
      if (_section == 'friends' && !_friendUids.contains(d.authorUid)) {
        return false;
      }
      if (_format != 'all' && d.format != _format) return false;
      if (_colors.isNotEmpty) {
        final dc = d.colors.map((e) => e.toUpperCase()).toSet();
        if (_colors.length == 1 && _colors.contains('C')) {
          if (dc.isNotEmpty) return false;
        } else {
          final want = _colors.where((c) => c != 'C').toSet();
          if (want.isNotEmpty &&
              !want.every((c) => dc.contains(c))) {
            return false;
          }
        }
      }
      if (q.isEmpty) return true;
      switch (_scope) {
        case 'deck':          return d.name.toLowerCase().contains(q) ||
              d.tags.any((t) => t.toLowerCase().contains(q)) ||
              d.archetype.toLowerCase().contains(q);
        case 'commander':
          return d.commanderName.toLowerCase().contains(q);
        case 'card':
          if (q.length < 2) return true;
          return _cardMatch.contains(d.id);
        case 'author':
          return d.authorName.toLowerCase().contains(q) ||
              d.authorCode.toLowerCase().contains(q);
        default:
          return d.name.toLowerCase().contains(q) ||
              d.authorName.toLowerCase().contains(q) ||
              d.authorCode.toLowerCase().contains(q) ||
              d.commanderName.toLowerCase().contains(q) ||
              d.tags.any((t) => t.toLowerCase().contains(q)) ||
              d.archetype.toLowerCase().contains(q);
      }
    }).toList();
    switch (_section) {
      case 'trending':
        list.sort((a, b) => b.trendingScore.compareTo(a.trendingScore));
        break;
      case 'liked':
        list.sort((a, b) => b.likes.compareTo(a.likes));
        break;
      case 'favorited':
        list.sort((a, b) => b.favorites.compareTo(a.favorites));
        break;
      case 'viewed':
        list.sort((a, b) => b.views.compareTo(a.views));
        break;
      case 'rated':
        list.sort((a, b) {
          final r = b.ratingAvg.compareTo(a.ratingAvg);
          if (r != 0) return r;
          return b.ratingCount.compareTo(a.ratingCount);
        });
        break;
      default:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.orange)),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(AppLocale.t('common_retry')),
              ),
            ],
          ),
        ),
      );
    }
    final list = _filtered;
    final screenW = MediaQuery.of(context).size.width;
    final cols = _grid ? _gridCols : 1;
    final cardW =
        (screenW - 24 - 10 * (cols - 1)) / cols;
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onChanged: (_) => _onSearchChanged(),
                decoration: InputDecoration(
                  hintText: AppLocale.t('com_search_hint'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupMenuButton<String>(
                        icon: Icon(
                            _scope == 'all'
                                ? Icons.filter_list
                                : Icons.filter_alt,
                            size: 18,
                            color: _scope == 'all'
                                ? AppTheme.textMuted
                                : AppTheme.gold),
                        tooltip: AppLocale.t('com_scope_${_scope}'),
                        padding: EdgeInsets.zero,
                        onSelected: (v) =>
                            setState(() => _scope = v),
                        itemBuilder: (_) => [
                          for (final s in [
                            'all',
                            'deck',
                            'card',
                            'commander',
                            'author',
                          ])
                            PopupMenuItem(
                                value: s,
                                child: Text(AppLocale.t(
                                    'com_scope_$s'))),
                        ],
                      ),
                      if (_search.text.isNotEmpty)
                        IconButton(
                          icon:
                              const Icon(Icons.clear, size: 18),
                          onPressed: () =>
                              setState(() => _search.clear()),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_searchingCards &&
              _scope == 'card' &&
              _search.text.trim().length >= 2)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: LinearProgressIndicator(),
              ),
            ),
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (final s in [
                    'all',
                    'trending',
                    'liked',
                    'favorited',
                    'viewed',
                    'recent',
                    'friends',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(AppLocale.t('com_section_$s'),
                            style: const TextStyle(fontSize: 12)),
                        selected: _section == s,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) =>
                            setState(() => _section = s),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      avatar: Icon(
                          _onlyFavorites
                              ? Icons.favorite
                              : Icons.favorite_border,
                          size: 14),
                      label: Text(AppLocale.t('com_section_favorites'),
                          style: const TextStyle(fontSize: 12)),
                      selected: _onlyFavorites,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(
                          () => _onlyFavorites = !_onlyFavorites),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String>(
                    value: _format,
                    dropdownColor: AppTheme.panel,
                    underline: const SizedBox.shrink(),
                    style: const TextStyle(
                        color: AppTheme.gold, fontSize: 13),
                    items: [
                      DropdownMenuItem(
                          value: 'all',
                          child: Text(AppLocale.t('com_format_all'))),
                      for (final f in [
                        'livre',
                        'standard',
                        'pioneer',
                        'modern',
                        'legacy',
                        'vintage',
                        'pauper',
                        'commander',
                        'brawl',
                      ])
                        DropdownMenuItem(
                            value: f, child: Text(formatLabel(f))),
                    ],
                    onChanged: (v) =>
                        setState(() => _format = v ?? 'all'),
                  ),
                  for (final c in ['W', 'U', 'B', 'R', 'G', 'C'])
                    InkWell(
                      onTap: () => setState(() {
                        if (!_colors.remove(c)) _colors.add(c);
                      }),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: _colors.contains(c)
                                  ? AppTheme.gold
                                  : Colors.transparent,
                              width: 2),
                        ),
                        child: MtgPip(c, size: 22),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: DeckViewToggle(
                        grid: _grid,
                        onChanged: (v) =>
                            setState(() => _grid = v)),
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
            ),
          ),
          if (list.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(AppLocale.t('com_empty'),
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: AppTheme.textMuted)),
                ),
              ),
            )
          else if (_grid)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              sliver: SliverGrid(
                gridDelegate:
                    SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _gridCols,
                  childAspectRatio:
                      _DeckCard.cardRatio(cardW),
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _DeckCard(
                    deck: list[i],
                    isFav: _favIds.contains(list[i].id),
                    onChanged: _load,
                  ),
                  childCount: list.length,
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => Padding(
                  padding:
                      const EdgeInsets.fromLTRB(12, 3, 12, 3),
                  child: _DeckListTile(
                    deck: list[i],
                    isFav: _favIds.contains(list[i].id),
                    onChanged: _load,
                  ),
                ),
                childCount: list.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _DeckCard extends StatelessWidget {
  const _DeckCard(
      {required this.deck, required this.isFav, required this.onChanged});

  final CommunityDeck deck;
  final bool isFav;
  final VoidCallback onChanged;

  /// Razão w/h do card = imagem 63:88 + bloco de infos uniforme.
  /// É ELA (não um número mágico) que impede o crop: a área da imagem
  /// nunca é espremida pelo texto, em qualquer largura/colunas.
  static double cardRatio(double cardW) =>
      cardW / (cardW * 88 / 63 + _CommunityTabState._infoH);

  @override
  Widget build(BuildContext context) {
    final img = deck.coverUrl.isNotEmpty
        ? deck.coverUrl
        : deck.commanderImage;
    // Segunda linha SEMPRE presente (comandante ou autor): sem ela,
    // cards com/sem comandante teriam alturas diferentes e o grid
    // voltaria a espremer a imagem.
    final line2 = deck.commanderName.isNotEmpty
        ? deck.commanderName
        : (deck.authorName.isEmpty ? '?' : deck.authorName);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => CommunityDeckDetailPage(deckId: deck.id)),
        ).then((_) => onChanged()),
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
                    img.isEmpty
                        ? const Icon(Icons.style,
                            color: AppTheme.gold, size: 30)
                        : CachedNetworkImage(
                            imageUrl: img,
                            // Mesma proporção da caixa: inteira, sem
                            // crop e sem distorção.
                            fit: BoxFit.contain,
                            memCacheWidth: 400,
                            errorWidget: (_, __, ___) => const Icon(
                                Icons.broken_image,
                                color: AppTheme.gold),
                          ),
                    if (isFav)
                      const Positioned(
                        right: 6,
                        top: 6,
                        child: Icon(Icons.favorite,
                            size: 16, color: Colors.redAccent),
                      ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                            _CommunityTabState.formatLabel(
                                deck.format),
                            style: const TextStyle(
                                color: AppTheme.gold,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Text(deck.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(line2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 11)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
              child: Row(
                children: [
                  if (deck.colors.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var k = 0;
                            k < deck.colors.length && k < 5;
                            k++) ...[
                          if (k > 0) const SizedBox(width: 2),
                          MtgPip(deck.colors[k], size: 13),
                        ],
                      ],
                    ),
                  const Spacer(),
                  const Icon(Icons.visibility_outlined,
                      size: 12, color: AppTheme.textMuted),
                  const SizedBox(width: 2),
                  Text('${deck.views}',
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
                  const SizedBox(width: 6),
                  Icon(
                      deck.ratingCount > 0
                          ? Icons.star
                          : Icons.star_border,
                      size: 12,
                      color: AppTheme.gold),
                  const SizedBox(width: 2),
                  Text(
                      deck.ratingCount > 0
                          ? deck.ratingAvg.toStringAsFixed(1)
                          : '—',
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${deck.cardCount} • ${CurrencyService.instance.formatUsd(deck.priceUsd)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 11)),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.thumb_up_outlined,
                      size: 12, color: AppTheme.textMuted),
                  const SizedBox(width: 2),
                  Text('${deck.likes}',
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modo lista da vitrine: fileira horizontal compacta com capa
/// proporcional (sem crop) + todas as infos do modo grade.
class _DeckListTile extends StatelessWidget {
  const _DeckListTile(
      {required this.deck, required this.isFav, required this.onChanged});

  final CommunityDeck deck;
  final bool isFav;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final img = deck.coverUrl.isNotEmpty
        ? deck.coverUrl
        : deck.commanderImage;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => CommunityDeckDetailPage(deckId: deck.id)),
        ).then((_) => onChanged()),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: AppTheme.goldSoft,
                ),
                clipBehavior: Clip.antiAlias,
                child: AspectRatio(
                  aspectRatio: 63 / 88,
                  child: img.isEmpty
                      ? const Icon(Icons.style,
                          color: AppTheme.gold, size: 20)
                      : CachedNetworkImage(
                          imageUrl: img,
                          fit: BoxFit.contain,
                          memCacheWidth: 150,
                          errorWidget: (_, __, ___) => const Icon(
                              Icons.broken_image,
                              color: AppTheme.gold),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(deck.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    Text(
                        '${_CommunityTabState.formatLabel(deck.format)} • ${deck.cardCount} ${AppLocale.t('deck_cards_suffix')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(
                            color: AppTheme.gold, fontSize: 11)),
                    if (deck.commanderName.isNotEmpty)
                      Text(deck.commanderName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 11)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.visibility_outlined,
                            size: 12,
                            color: AppTheme.textMuted),
                        const SizedBox(width: 2),
                        Text('${deck.views}',
                            style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 11)),
                        const SizedBox(width: 8),
                        const Icon(Icons.thumb_up_outlined,
                            size: 12,
                            color: AppTheme.textMuted),
                        const SizedBox(width: 2),
                        Text('${deck.likes}',
                            style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 11)),
                        const SizedBox(width: 8),
                        const Icon(Icons.star,
                            size: 12, color: AppTheme.gold),
                        const SizedBox(width: 2),
                        Text(
                            deck.ratingCount > 0
                                ? deck.ratingAvg
                                    .toStringAsFixed(1)
                                : '—',
                            style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 11)),
                        const Spacer(),
                        if (isFav)
                          const Icon(Icons.favorite,
                              size: 14,
                              color: Colors.redAccent),
                      ],
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
}
