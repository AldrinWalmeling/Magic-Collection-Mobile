import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/app_locale.dart';
import '../services/community_service.dart';
import '../services/currency_service.dart';
import '../services/online_friends.dart';
import '../services/online_match.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/deck_view.dart';
import 'community_deck_detail_page.dart';

// Perfil público de outro jogador: identidade, bio e decks publicados.
// Bloquear grava blocks/{me}/{them}; o app deixa de sugerir o conteúdo.
class PublicProfilePage extends StatefulWidget {
  const PublicProfilePage({super.key, required this.userId});

  final String userId;

  @override
  State<PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends State<PublicProfilePage> {
  final _service = CommunityService();
  Map<String, dynamic> _profile = {};
  Map<String, dynamic> _collection = {};
  List<CommunityDeck> _decks = [];
  bool _loading = true;
  bool _blocked = false;
  bool _busy = false;
  String _me = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _service.publicProfile(widget.userId),
        _service.decksByAuthor(widget.userId),
        OnlineFriends().myUid.catchError((_) => ''),
        _service.publicCollection(widget.userId),
      ]);
      var blocked = false;
      final me = (results[2] as String?) ?? '';
      if (me.isNotEmpty && me != widget.userId) {
        try {
          final snap = await OnlineMatch.defaultDatabase()
              .ref('blocks/$me/${widget.userId}')
              .get();
          blocked = snap.exists;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _profile = results[0] as Map<String, dynamic>;
        _decks = results[1] as List<CommunityDeck>;
        _me = me;
        _collection = results[3] as Map<String, dynamic>;
        _blocked = blocked;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleBlock() async {
    if (_busy || _me.isEmpty || _me == widget.userId) return;
    setState(() => _busy = true);
    try {
      final ref = OnlineMatch.defaultDatabase()
          .ref('blocks/$_me/${widget.userId}');
      if (_blocked) {
        await ref.remove();
      } else {
        await ref.set(true);
      }
      if (!mounted) return;
      setState(() {
        _blocked = !_blocked;
        _busy = false;
      });
      AppToast.show(
          context,
          AppLocale.t(
              _blocked ? 'soc_blocked_msg' : 'soc_unblocked_msg'));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        AppToast.show(context, '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (_profile['displayName'] ?? '').toString();
    final code = (_profile['friendCode'] ?? '').toString();
    final bio = (_profile['bio'] ?? '').toString();
    final avatar = (_profile['avatar'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty
            ? AppLocale.t('soc_profile_title')
            : name),
        actions: [
          if (_me.isNotEmpty && _me != widget.userId)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'block') _toggleBlock();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'block',
                  child: Text(AppLocale.t(
                      _blocked ? 'soc_unblock' : 'soc_block')),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: _identityCard(
                        name, code, bio, avatar),
                  ),
                  const SizedBox(height: 8),
                  TabBar(
                    tabs: [
                      Tab(text: AppLocale.t('soc_tab_decks')),
                      Tab(text: AppLocale.t('soc_tab_panel')),
                      Tab(text: AppLocale.t('soc_tab_collection')),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _decksTab(),
                        _panelTab(),
                        _collectionTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _identityCard(
      String name, String code, String bio, String avatar) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: AppTheme.goldSoft,
              child: Text(avatar.isEmpty ? '🧙' : avatar,
                  style: const TextStyle(fontSize: 26)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      name.isEmpty
                          ? AppLocale.t('soc_unknown_player')
                          : name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 17)),
                  if (code.isNotEmpty)
                    Text('@$code',
                        style: const TextStyle(
                            color: AppTheme.gold, fontSize: 13)),
                  if (bio.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(bio,
                        style: const TextStyle(fontSize: 13)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _decksTab() {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          // Só a lista: agregados moram no Painel, sem duplicar.
          Text(AppLocale.t('soc_published'),
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 6),
          if (_decks.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(AppLocale.t('com_empty'),
                    style: const TextStyle(
                        color: AppTheme.textMuted)),
              ),
            )
          else
            for (final d in _decks)
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: (d.coverUrl.isEmpty &&
                          d.commanderImage.isEmpty)
                      ? const Icon(Icons.style,
                          color: AppTheme.gold)
                      : ClipRRect(
                          borderRadius:
                              BorderRadius.circular(4),
                          child: CachedNetworkImage(
                            imageUrl: d.coverUrl.isNotEmpty
                                ? d.coverUrl
                                : d.commanderImage,
                            width: 36,
                            height: 50,
                            fit: BoxFit.cover,
                            memCacheWidth: 120,
                            errorWidget: (_, __, ___) =>
                                const Icon(
                                    Icons.broken_image),
                          ),
                        ),
                  title: Text(d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                  subtitle: Text(
                      '${d.format.toUpperCase()} • ${d.cardCount} • ${CurrencyService.instance.formatUsd(d.priceUsd)}\n👍 ${d.likes}   👁 ${d.views}${d.ratingCount > 0 ? '   ★ ${d.ratingAvg.toStringAsFixed(1)}' : ''}',
                      style: const TextStyle(fontSize: 12)),
                  isThreeLine: true,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            CommunityDeckDetailPage(
                                deckId: d.id)),
                  ).then((_) => _load()),
                ),
              ),
        ],
      ),
    );
  }

  /// Painel: o essencial em agregados + destaques. Nada do que já
  /// está nas outras abas (lista de decks, números da coleção).
  Widget _panelTab() {
    final likes = _decks.fold<int>(0, (s, d) => s + d.likes);
    final views = _decks.fold<int>(0, (s, d) => s + d.views);
    var rSum = 0;
    var rCount = 0;
    for (final d in _decks) {
      rSum += d.ratingSum;
      rCount += d.ratingCount;
    }
    final avg =
        rCount > 0 ? (rSum / rCount).toStringAsFixed(1) : '—';
    CommunityDeck? top;
    for (final d in _decks) {
      if (top == null ||
          d.likes > top.likes ||
          (d.likes == top.likes && d.views > top.views)) {
        top = d;
      }
    }
    final formats = <String, int>{};
    for (final d in _decks) {
      formats[d.format] = (formats[d.format] ?? 0) + 1;
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Row(
            children: [
              Expanded(
                  child:
                      _stat('$likes', AppLocale.t('soc_likes'))),
              Expanded(
                  child: _stat('$views',
                      AppLocale.t('soc_views'))),
              Expanded(
                  child: _stat(avg,
                      AppLocale.t('soc_avg_rating'))),
            ],
          ),
          if (top != null) ...[
            const SizedBox(height: 8),
            Text(AppLocale.t('soc_top_deck'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 6),
            _topDeckCard(top),
          ],
          if (formats.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(AppLocale.t('soc_formats'),
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in formats.entries)
                  Chip(
                    label: Text(
                        '${prettyFormat(e.key)} • ${e.value}',
                        style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _topDeckCard(CommunityDeck d) {
    final img =
        d.coverUrl.isNotEmpty ? d.coverUrl : d.commanderImage;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  CommunityDeckDetailPage(deckId: d.id)),
        ).then((_) => _load()),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
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
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.broken_image,
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
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.emoji_events,
                            size: 13, color: AppTheme.gold),
                      ],
                    ),
                    Text(d.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    Text(
                        '👍 ${d.likes}   👁 ${d.views}${d.ratingCount > 0 ? '   ★ ${d.ratingAvg.toStringAsFixed(1)}' : ''}',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Coleção compartilhada em detalhe (raridades + edições).
  Widget _collectionTab() {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (_collection.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                    AppLocale.t('soc_collection_hidden'),
                    style: const TextStyle(
                        color: AppTheme.textMuted)),
              ),
            )
          else
            _collectionCard(),
        ],
      ),
    );
  }

  Widget _collectionCard() {
    final total = (_collection['totalCards'] as num?)?.toInt() ?? 0;
    final distinct =
        (_collection['distinctCards'] as num?)?.toInt() ?? 0;
    final value =
        (_collection['valueUsd'] as num?)?.toDouble() ?? 0;
    final byRarity = _collection['byRarity'];
    final topSets = _collection['topSets'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.collections_bookmark_outlined,
                    size: 16, color: AppTheme.gold),
                const SizedBox(width: 6),
                Text(AppLocale.t('soc_collection_title'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
                '$total ${AppLocale.t('soc_total')} • $distinct ${AppLocale.t('soc_distinct')} • ${CurrencyService.instance.formatUsd(value)}',
                style: const TextStyle(fontSize: 13)),
            if (byRarity is Map && byRarity.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final e in byRarity.entries)
                    Chip(
                      label: Text('${e.key}: ${e.value}',
                          style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (topSets is List && topSets.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(AppLocale.t('soc_top_sets'),
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 12)),
              for (final s in topSets.take(5))
                if (s is Map)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                        '• ${(s['name'] ?? s['code'] ?? '').toString()} — ${s['count'] ?? 0}',
                        style: const TextStyle(fontSize: 12)),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: AppTheme.gold)),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
