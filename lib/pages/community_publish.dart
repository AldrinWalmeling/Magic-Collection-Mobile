import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../services/app_locale.dart';
import '../services/community_service.dart';
import '../services/deck_stats.dart';
import '../widgets/app_toast.dart';

// Publicação de deck local na Comunidade (snapshot público).
// Usado pelo menu dos Meus Decks e pelo detalhe do deck.
class CommunityPublish {
  static Future<String?> show(BuildContext context, int deckId) async {
    final db = AppDatabase.instance.db;
    final deck = await db.query('decks',
        where: 'id = ?', whereArgs: [deckId], limit: 1);
    if (deck.isEmpty) return null;
    final drow = deck.first;
    final items = await db.rawQuery('''
      SELECT c.*, dc.quantity AS deck_qty
      FROM deck_cards dc JOIN cards c ON c.id = dc.card_id
      WHERE dc.deck_id = ? ORDER BY c.name''', [deckId]);
    if (items.isEmpty) {
      AppToast.show(context, AppLocale.t('com_publish_empty'));
      return null;
    }
    // Deck já publicado? Oferece atualizar (preserva curtidas/
    // avaliações/views) ou publicar como novo.
    final service = CommunityService();
    String? existingId;
    CommunityDeck? existing;
    try {
      existingId = (await service.myPublicationMap())['$deckId'];
      if (existingId != null) {
        existing = await service.getDeck(existingId);
        if (existing == null) existingId = null;
      }
    } catch (_) {
      existingId = null;
    }
    var modeUpdate = false;
    if (existingId != null) {
      if (!context.mounted) return null;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppLocale.t('com_republish_title')),
          content: Text(AppLocale.t('com_republish_body')
              .replaceAll('{n}', existing?.name ?? '')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppLocale.t('common_cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'new'),
                child: Text(AppLocale.t('com_publish_new'))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, 'update'),
                child: Text(AppLocale.t('com_republish'))),
          ],
        ),
      );
      if (choice == null) return null;
      modeUpdate = choice == 'update';
      if (!modeUpdate) {
        existingId = null;
        existing = null;
      }
    }
    String? commanderName;
    String commanderImage = '';
    List<String> commanderColors = [];
    final commanderId = drow['commander_card_id'] as int?;
    if (commanderId != null) {
      for (final c in items) {
        if ((c['id'] as int?) == commanderId) {
          commanderName = (c['name'] ?? '').toString();
          commanderImage = (c['image_url'] ?? '').toString();
          commanderColors = [
            for (final e in DeckStatsService.colorList(
                c['color_identity']))
              e.toString()
          ];
        }
      }
    }
    // Capa: preview ou carta com maior qty (mesma regra da vitrine).
    String coverUrl = '';
    var bestQty = -1;
    for (final c in items) {
      final q = (c['deck_qty'] as num?)?.toInt() ?? 0;
      final img = (c['image_url'] ?? '').toString();
      final isPreview =
          (c['id'] as int?) == (drow['preview_card_id'] as int?);
      if (isPreview && img.isNotEmpty) {
        coverUrl = img;
        break;
      }
      if (q > bestQty && img.isNotEmpty) {
        bestQty = q;
        coverUrl = img;
      }
    }
    final colors = <String>{};
    for (final c in items) {
      for (final e
          in DeckStatsService.colorList(c['color_identity'])) {
        colors.add(e.toString().toUpperCase());
      }
    }
    colors.removeWhere((c) => !DeckStatsService.colorOrder.contains(c));

    final pub = existing;
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => _PublishDialog(
        modeUpdate: modeUpdate,
        initialName:
            pub?.name ?? (drow['name'] ?? '').toString(),
        initialDescription: pub?.description ?? '',
        initialTags: pub == null ? '' : pub.tags.join(', '),
        initialArchetype: pub?.archetype ?? '',
        initialAllowCopy: pub?.allowCopy ?? true,
        onSubmit: ({
          required String name,
          required String description,
          required List<String> tags,
          required String archetype,
          required bool allowCopy,
        }) =>
            service.publishDeck(
          publicName: name,
          description: description,
          format: (drow['format'] ?? 'livre').toString(),
          commanderName: commanderName ?? '',
          commanderImage: commanderImage,
          commanderColors: commanderColors,
          colors: colors.toList(),
          coverUrl: coverUrl,
          tags: tags,
          archetype: archetype,
          allowCopy: allowCopy,
          updateId: modeUpdate ? existingId : null,
          localDeckId: deckId,
          cards: [
            for (final c in items)
              {
                'name': c['name'],
                'qty': c['deck_qty'],
                'set': c['set_code'],
                'scryfall_id': c['scryfall_id'],
                'oracle_id': c['oracle_id'],
                'image_url': c['image_url'],
                'cmc': c['cmc'],
                'type_line': c['type_line'],
                'colors': c['colors'],
                'color_identity': c['color_identity'],
                'price_usd':
                    c['price_usd'] ?? c['price_ref_usd'],
              },
          ],
        ),
      ),
    );
    if (id != null && context.mounted) {
      AppToast.show(context,
          AppLocale.t(modeUpdate ? 'com_updated' : 'com_published'));
    }
    return id;
  }
}

// Diálogo de publicação dono dos próprios controllers: o framework só
// chama dispose() depois que a rota sai de cena, então nenhum TextField
// reconstrói sobre controller descartado (crash de "used after dispose").
class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.modeUpdate,
    required this.initialName,
    required this.initialDescription,
    required this.initialTags,
    required this.initialArchetype,
    required this.initialAllowCopy,
    required this.onSubmit,
  });

  final bool modeUpdate;
  final String initialName;
  final String initialDescription;
  final String initialTags;
  final String initialArchetype;
  final bool initialAllowCopy;
  final Future<String> Function({
    required String name,
    required String description,
    required List<String> tags,
    required String archetype,
    required bool allowCopy,
  }) onSubmit;

  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  late final TextEditingController _nameC =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _descC =
      TextEditingController(text: widget.initialDescription);
  late final TextEditingController _tagsC =
      TextEditingController(text: widget.initialTags);
  late final TextEditingController _archC =
      TextEditingController(text: widget.initialArchetype);
  late bool _allowCopy = widget.initialAllowCopy;
  bool _busy = false;

  @override
  void dispose() {
    _nameC.dispose();
    _descC.dispose();
    _tagsC.dispose();
    _archC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _nameC.text.trim();
    if (name.isEmpty) {
      AppToast.show(context, AppLocale.t('com_publish_need_name'));
      return;
    }
    setState(() => _busy = true);
    try {
      final tags = _tagsC.text
          .split(RegExp(r'[,#\n]'))
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .take(8)
          .toList();
      final pid = await widget.onSubmit(
        name: name,
        description: _descC.text,
        tags: tags,
        archetype: _archC.text,
        allowCopy: _allowCopy,
      );
      if (mounted) Navigator.pop(context, pid);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(AppLocale.t(widget.modeUpdate
          ? 'com_republish_title'
          : 'com_publish_title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameC,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: AppLocale.t('com_publish_name')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descC,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
                labelText: AppLocale.t('com_publish_desc')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _tagsC,
            decoration: InputDecoration(
                labelText: AppLocale.t('com_publish_tags'),
                hintText: AppLocale.t('com_publish_tags_hint')),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _archC,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: AppLocale.t('com_publish_archetype')),
          ),
          CheckboxListTile(
            value: _allowCopy,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(AppLocale.t('com_publish_allow_copy'),
                style: const TextStyle(fontSize: 14)),
            onChanged: (v) => setState(() => _allowCopy = v ?? true),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocale.t('common_cancel'))),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          child: Text(AppLocale.t(
              widget.modeUpdate ? 'com_republish' : 'com_publish')),
        ),
      ],
    );
  }
}
