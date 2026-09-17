import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../data/app_database.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/currency_service.dart';
import '../services/price_reference.dart';
import '../services/price_update_service.dart';
import '../services/scryfall_service.dart';
import '../theme/app_theme.dart';
import '../widgets/mtg_symbols.dart';
import '../widgets/quantity_editor.dart';

// Bottom sheet de detalhes — equivale a
// ui/dialogs/card_details.py + components/card_details_dialog.py:
// imagem grande, textos, preços, quantidade, favorito, remover.

class CardDetailSheet extends StatefulWidget {
  final Map<String, Object?> card;
  const CardDetailSheet({super.key, required this.card});

  @override
  State<CardDetailSheet> createState() => _CardDetailSheetState();
}

class _CardDetailSheetState extends State<CardDetailSheet> {
  late Map<String, Object?> _card;
  bool _refreshingPrice = false;
  bool _loadingPrints = false;

  @override
  void initState() {
    super.initState();
    _card = Map.of(widget.card);
  }

  Future<void> _reloadRow() async {
    final rows = await AppDatabase.instance.db
        .query('cards', where: 'id = ?', whereArgs: [_card['id']], limit: 1);
    if (rows.isNotEmpty && mounted) setState(() => _card = rows.first);
  }

  Future<void> _update(Map<String, Object?> values) async {
    await AppDatabase.instance.db
        .update('cards', values, where: 'id = ?', whereArgs: [_card['id']]);
    await _reloadRow();
  }

  /// Editor completo: tocar no número abre Adicionar/Remover/Definir
  /// (ex. tem 20, achou 7 -> +7 = 27). Zerar pede confirmação.
  Future<void> _editQuantity() async {
    final current = ((_card['quantity'] as num?)?.toInt() ?? 0);
    final result = await QuantityEditor.show(context, current);
    if (result == null) return;
    await _update({'quantity': result});
  }

  /// 5→4 … 2→1 sem confirmação. 1→0 pede confirmação e, ao remover,
  /// zera a quantidade MANTENDO a linha (quantity=0 = fora da coleção,
  /// mas preservada p/ histórico, decks, favoritos e tags).
  /// Nunca deleta o registro aqui.
  Future<void> _decrementWithConfirm() async {
    final q = ((_card['quantity'] as num?)?.toInt() ?? 0);
    if (q > 1) {
      await _update({'quantity': q - 1});
      return;
    }
    if (q <= 0) return;
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
    if (ok == true) {
      await _update({'quantity': 0});
    }
  }

  /// Força nova consulta à API (ignora cache de 24h).
  Future<void> _forcePriceRefresh() async {
    final id = (_card['id'] as num?)?.toInt();
    if (id == null || _refreshingPrice) return;
    setState(() => _refreshingPrice = true);
    try {
      final ok = await PriceUpdateService.instance.refreshSingleCard(id);
      await _reloadRow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok ? 'Preço atualizado.' : 'Sem preço encontrado.')));
      }
    } finally {
      if (mounted) setState(() => _refreshingPrice = false);
    }
  }

  /// Descobre o oracle_id da carta (identidade da CARTA, não do imprint)
  /// para listar todos os printings. Nome sozinho não identifica imprint.
  Future<String> _resolveOracleId() async {
    final local = (_card['oracle_id'] ?? '').toString().trim();
    if (local.isNotEmpty) return local;
    final scryId = (_card['scryfall_id'] ?? '').toString().trim();
    if (scryId.isNotEmpty) {
      try {
        final exact =
            await ScryfallService.instance.getCardByScryfallId(scryId);
        final oid = (exact?['oracle_id'] ?? '').toString().trim();
        if (oid.isNotEmpty) return oid;
      } catch (_) {}
    }
    final name = ((_card['name'] ?? _card['printed_name']) ?? '').toString();
    final lang = (_card['lang'] ?? '').toString();
    for (final l in [if (lang.isNotEmpty) lang, 'pt', 'en']) {
      try {
        final byName = await ScryfallService.instance.getCardByName(name, lang: l);
        final oid = (byName?['oracle_id'] ?? '').toString().trim();
        if (oid.isNotEmpty) return oid;
      } catch (_) {}
    }
    return '';
  }

  /// Abre a lista de imprints da MESMA carta (mesmo oracle_id) com
  /// dados suficientes para diferenciar: set, coletor completo, idioma,
  /// data, raridade, finish, imagem e preço.
  Future<void> _showSwapImprint() async {
    if (_loadingPrints) return;
    setState(() => _loadingPrints = true);
    try {
      final oracleId = await _resolveOracleId();
      if (!mounted) return;
      if (oracleId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Não foi possível identificar a carta no Scryfall.')));
        return;
      }
      final prints =
          await ScryfallService.instance.getPrintings(oracleId);
      if (!mounted) return;
      if (prints.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Nenhuma outra impressão encontrada.')));
        return;
      }
      // Ordena: mesmo set/coletor/idioma da carta atual primeiro.
      final sorted = ScryfallService.sortPrintings(
        prints,
        (_card['collector_number'] ?? '').toString(),
        setCode: (_card['set_code'] ?? '').toString(),
        langHint: (_card['lang'] ?? '').toString(),
      );
      final currentId = (_card['scryfall_id'] ?? '').toString();
      final currentFinish =
          (_card['preferred_finish'] ?? 'normal').toString();
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetCtx) => _SwapImprintSheet(
          printings: sorted,
          currentId: currentId,
          currentFinish: currentFinish,
          onPick: (p, finish) async {
            Navigator.pop(sheetCtx);
            await _applyImprint(p, finish: finish);
          },
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Falha ao buscar impressões: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingPrints = false);
    }
  }

  /// Troca o IMPRINT da carta já cadastrada: substitui SÓ os dados da
  /// impressão (scryfall_id, set, coletor, imagem, preços, raridade...),
  /// preservando quantidade, favorito, tags, decks e histórico
  /// (a linha é a mesma — só o imprint muda; nada é recriado).
  /// [finish] grava o acabamento escolhido (normal/foil).
  Future<void> _applyImprint(Map<String, dynamic> selected,
      {String finish = 'normal'}) async {
    final id = (_card['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      final flat = ScryfallService.flatten(selected);
      final values = <String, Object?>{
        'scryfall_id': flat['scryfall_id'],
        'oracle_id': flat['oracle_id'],
        'name': flat['name'],
        'printed_name': flat['printed_name'],
        'lang': flat['lang'],
        'set_code': flat['set_code'],
        'set_name': flat['set_name'],
        'collector_number': flat['collector_number'],
        'mana_cost': flat['mana_cost'],
        'type_line': flat['type_line'],
        'oracle_text': flat['oracle_text'],
        'power': flat['power'],
        'toughness': flat['toughness'],
        'rarity': flat['rarity'],
        'cmc': flat['cmc'],
        'colors': flat['colors'],
        'color_identity': flat['color_identity'],
        'image_url': flat['image_url'],
        'price_usd': flat['price_usd'],
        'price_usd_foil': flat['price_usd_foil'],
        'price_usd_etched': flat['price_usd_etched'],
        'price_eur': flat['price_eur'],
        'price_eur_foil': flat['price_eur_foil'],
        'price_tix': flat['price_tix'],
        'price_source': (flat['price_usd'] != null ||
                flat['price_usd_foil'] != null ||
                flat['price_eur'] != null)
            ? 'exact'
            : null,
        'price_updated_at': DateTime.now().toUtc().toIso8601String(),
        'price_ref_usd': null,
        'price_ref_name': null,
        'preferred_finish': finish,
        'artist': flat['artist'],
        'released_at': flat['released_at'],
        // quantity, favorite, image_path, custom_tags,
        // keywords/games/legalities e deck_cards ficam intactos.
      };
      await AppDatabase.instance.db
          .update('cards', values, where: 'id = ?', whereArgs: [id]);
      await _reloadRow();
      AppEvents.notifyCollectionChanged();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Impressão atualizada.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Falha ao trocar impressão: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _card['image_url'] as String?;
    final source = (_card['price_source'] ?? '').toString();
    final sourceLabel = PriceReference.sourceLabel(source);
    final refUsd = (_card['price_ref_usd'] as num?)?.toDouble();
    final refName = (_card['price_ref_name'] ?? '').toString();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      builder: (_, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(16),
        children: [
          if (url != null && url.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                  imageUrl: url, fit: BoxFit.cover, memCacheWidth: 900),
            ),
          const SizedBox(height: 12),
          Text((_card['name'] ?? '').toString(),
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(
              '${_card['printed_name'] ?? ''} • ${_card['set_name'] ?? ''} #${_card['collector_number'] ?? ''} • ${(_card['lang'] ?? '').toString().toUpperCase()}',
              style: const TextStyle(color: AppTheme.textMuted)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('${AppLocale.t('cd_cost')}: ',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: ManaCostRow((_card['mana_cost'] ?? '').toString())),
            ],
          ),
          Text('${_card['type_line'] ?? ''}',
              style: const TextStyle(fontStyle: FontStyle.italic)),
          if (((_card['power'] ?? '').toString().isNotEmpty) ||
              ((_card['toughness'] ?? '').toString().isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${(_card['power'] ?? '?')} / ${(_card['toughness'] ?? '?')}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          const SizedBox(height: 8),
          OracleText((_card['oracle_text'] ?? '').toString()),
          const SizedBox(height: 8),
          Text(
              '${CurrencyService.instance.formatUsd((_card['price_usd'] as num?)?.toDouble() ?? 0)} • Foil ${CurrencyService.instance.formatUsd((_card['price_usd_foil'] as num?)?.toDouble() ?? 0)} • EUR ${_card['price_eur'] ?? 0}',
              style: const TextStyle(
                  color: AppTheme.gold, fontWeight: FontWeight.bold)),
          if (sourceLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: source == 'approx-other-print'
                        ? Colors.orange.withValues(alpha: 0.2)
                        : AppTheme.goldSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    source == 'exact'
                        ? 'Valor da impressão exata'
                        : source == 'fallback-same-print'
                            ? 'Ref. mesma impressão ($sourceLabel)'
                            : source == 'approx-other-print'
                                ? 'Valor aproximado ($sourceLabel)'
                                : sourceLabel,
                    style: TextStyle(
                        color: source == 'approx-other-print'
                            ? Colors.orange
                            : AppTheme.gold,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  onPressed: _forcePriceRefresh,
                  icon: _refreshingPrice
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 14),
                  label: const Text('Atualizar preço',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
          if (refUsd != null && source != 'exact') ...[
            const SizedBox(height: 4),
            Text(
              'Ref: ${CurrencyService.instance.formatUsd(refUsd)}${refName.isNotEmpty ? ' • $refName' : ''}',
              style:
                  const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ],
          if ((_card['price_tix'] as num?) != null)
            Text('TIX ${_card['price_tix']}',
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _loadingPrints ? null : _showSwapImprint,
              icon: _loadingPrints
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.swap_horiz, size: 18),
              label: const Text('Trocar impressão'),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Flexible(
                child: Text('${AppLocale.t('cd_qty')}: ',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  onPressed: _decrementWithConfirm),
              InkWell(
                onTap: _editQuantity,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  child: Text('${_card['quantity'] ?? 0}',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.add_circle, color: AppTheme.gold),
                  onPressed: () => _update({
                        'quantity':
                            ((_card['quantity'] as num?)?.toInt() ?? 0) + 1
                      })),
              const Spacer(),
              IconButton(
                icon: Icon(
                    ((_card['favorite'] as num?)?.toInt() ?? 0) == 1
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: AppTheme.gold),
                onPressed: () => _update({
                  'favorite':
                      ((_card['favorite'] as num?)?.toInt() ?? 0) == 1 ? 0 : 1
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Sheet de troca de impressão com filtros locais de edição, idioma,
/// numero e acabamento (normal/foil). So filtra a lista ja carregada.
class _SwapImprintSheet extends StatefulWidget {
  const _SwapImprintSheet({
    required this.printings,
    required this.currentId,
    required this.currentFinish,
    required this.onPick,
  });

  final List<Map<String, dynamic>> printings;
  final String currentId;
  final String currentFinish;
  final Future<void> Function(Map<String, dynamic> p, String finish) onPick;

  @override
  State<_SwapImprintSheet> createState() => _SwapImprintSheetState();
}

class _SwapImprintSheetState extends State<_SwapImprintSheet> {
  late String _finish;
  String _setF = 'all';
  String _langF = 'all';
  final _cnCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _finish = widget.currentFinish.toLowerCase().contains('foil')
        ? 'foil'
        : 'normal';
  }

  @override
  void dispose() {
    _cnCtrl.dispose();
    super.dispose();
  }

  /// Preço da opção na moeda selecionada (ou — sem valor).
  String _fmtSwapPrice(Object? v) {
    final d = double.tryParse((v ?? '').toString());
    if (d == null) return '—';
    return CurrencyService.instance.formatUsd(d);
  }

  @override
  Widget build(BuildContext context) {
    final sets = <String, String>{};
    final langs = <String>{};
    for (final p in widget.printings) {
      final code = (p['set'] ?? '').toString();
      if (code.isNotEmpty) {
        sets.putIfAbsent(
            code.toLowerCase(), () => (p['set_name'] ?? code).toString());
      }
      final lang = (p['lang'] ?? '').toString().toLowerCase();
      if (lang.isNotEmpty) langs.add(lang);
    }
    final cnQ =
        ScryfallService.normalizeCollector(_cnCtrl.text.trim());
    final filtered = widget.printings.where((p) {
      if (_setF != 'all' &&
          (p['set'] ?? '').toString().toLowerCase() != _setF) {
        return false;
      }
      if (_langF != 'all' &&
          (p['lang'] ?? '').toString().toLowerCase() != _langF) {
        return false;
      }
      if (cnQ.isNotEmpty &&
          !ScryfallService.normalizeCollector(
                  (p['collector_number'] ?? '').toString())
              .contains(cnQ)) {
        return false;
      }
      return true;
    }).toList();
    final setCodes = sets.keys.toList()..sort();
    final langCodes = langs.toList()..sort();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      builder: (_, controller) => ListView.builder(
        controller: controller,
        padding: const EdgeInsets.all(16),
        itemCount: filtered.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Trocar impressão - escolha a versão que você possui',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Edição (set) - número - idioma - acabamento:',
                    style:
                        TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'normal',
                        icon: Icon(Icons.circle_outlined, size: 14),
                        label: Text('Normal'),
                      ),
                      ButtonSegment(
                        value: 'foil',
                        icon: Icon(Icons.auto_awesome, size: 14),
                        label: Text('Foil'),
                      ),
                    ],
                    selected: {_finish},
                    onSelectionChanged: (s) =>
                        setState(() => _finish = s.first),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<String>(
                          initialValue: _setF,
                          isDense: true,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Edição',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: 'all',
                              child: Text('Todas',
                                  style: TextStyle(fontSize: 12)),
                            ),
                            for (final c in setCodes)
                              DropdownMenuItem(
                                value: c,
                                child: Text(
                                  '${c.toUpperCase()} - ${sets[c] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _setF = v ?? 'all'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          initialValue: _langF,
                          isDense: true,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Idioma',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: 'all',
                              child: Text('Todos',
                                  style: TextStyle(fontSize: 12)),
                            ),
                            for (final l in langCodes)
                              DropdownMenuItem(
                                value: l,
                                child: Text(
                                  l.toUpperCase(),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _langF = v ?? 'all'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _cnCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Número (ex. 266/271)',
                      isDense: true,
                      prefixIcon: Icon(Icons.numbers, size: 16),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            );
          }
          final p = filtered[i - 1];
          final isCurrent =
              (p['id'] ?? '').toString() == widget.currentId;
          final img = ScryfallService.extractImageUrl(p);
          final prices = (p['prices'] as Map?) ?? const {};
          final finishes =
              ((p['finishes'] as List?) ?? const [])
                  .map((e) => e.toString())
                  .toList();
          final hasFinish = finishes.isEmpty ||
              finishes.contains(_finish) ||
              (_finish == 'normal' && finishes.contains('nonfoil'));
          final price = _finish == 'foil'
              ? _fmtSwapPrice(prices['usd_foil'] ??
                  prices['usd'] ??
                  prices['eur'])
              : _fmtSwapPrice(prices['usd'] ??
                  prices['eur'] ??
                  prices['usd_foil']);
          return Card(
            color: isCurrent ? AppTheme.goldSoft : null,
            child: ListTile(
              leading: SizedBox(
                width: 40,
                height: 56,
                child: (img == null || img.isEmpty)
                    ? const Icon(Icons.style, color: AppTheme.textFaint)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CachedNetworkImage(
                          imageUrl: img,
                          fit: BoxFit.cover,
                          memCacheWidth: 120,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.broken_image),
                        ),
                      ),
              ),
              title: Text(
                '${p['set_name'] ?? ''} [${(p['set'] ?? '').toString().toUpperCase()}] #${p['collector_number'] ?? '-'}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${(p['lang'] ?? '').toString().toUpperCase()} - ${p['released_at'] ?? '-'} - ${p['rarity'] ?? '-'}${finishes.isNotEmpty ? ' - ${finishes.join(', ')}' : ''} - $price${hasFinish ? '' : ' - sem $_finish'}',
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 12),
              ),
              trailing: isCurrent
                  ? const Icon(Icons.check_circle, color: AppTheme.gold)
                  : const Icon(Icons.swap_horiz),
              onTap: isCurrent ? null : () => widget.onPick(p, _finish),
            ),
          );
        },
      ),
    );
  }
}
