import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/app_locale.dart';
import '../services/card_types.dart';
import '../theme/app_theme.dart';

// Componentes compartilhados de visualização de deck (Comunidade +
// deck local): mesmo toggle, mesmos cabeçalhos de grupo, mesmo tile
// de grade. Um sistema só, sem duplicação entre as telas.

/// Título localizado de uma categoria de composição.
String deckGroupTitle(String category) {
  switch (category) {
    case CardCategory.commander:
      return AppLocale.t('cat_commander');
    case CardCategory.creatures:
      return AppLocale.t('cat_creatures');
    case CardCategory.planeswalkers:
      return AppLocale.t('cat_planeswalkers');
    case CardCategory.artifacts:
      return AppLocale.t('cat_artifacts');
    case CardCategory.enchantments:
      return AppLocale.t('cat_enchantments');
    case CardCategory.instants:
      return AppLocale.t('cat_instants');
    case CardCategory.sorceries:
      return AppLocale.t('cat_sorceries');
    case CardCategory.lands:
      return AppLocale.t('cat_lands');
    default:
      return AppLocale.t('cat_other');
  }
}

/// Seletor [ Lista ] [ Grade ].
class DeckViewToggle extends StatelessWidget {
  const DeckViewToggle(
      {super.key, required this.grid, required this.onChanged});

  final bool grid;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact),
      segments: [
        ButtonSegment(
            value: false,
            icon: const Icon(Icons.view_list_outlined, size: 16),
            label: Text(AppLocale.t('deck_view_list'),
                style: const TextStyle(fontSize: 12))),
        ButtonSegment(
            value: true,
            icon: const Icon(Icons.grid_view_outlined, size: 16),
            label: Text(AppLocale.t('deck_view_grid'),
                style: const TextStyle(fontSize: 12))),
      ],
      selected: {grid},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// Cabeçalho de grupo de composição ("Criaturas (12)").
class DeckGroupHeader extends StatelessWidget {
  const DeckGroupHeader(
      {super.key, required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text('$title ($count)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: AppTheme.gold)),
    );
  }
}

/// Tile de carta para o modo grade: imagem proporcional de carta real
/// (63:88), nome com ellipsis (nunca quebra no meio da palavra),
/// selo de quantidade e toque opcional.
class CardGridTile extends StatelessWidget {
  const CardGridTile({
    super.key,
    required this.imageUrl,
    required this.name,
    required this.qtyText,
    this.badge,
    this.onTap,
  });

  final String imageUrl;
  final String name;
  final String qtyText;
  final Widget? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  imageUrl.isEmpty
                      ? const ColoredBox(
                          color: AppTheme.goldSoft,
                          child: Icon(Icons.style,
                              color: AppTheme.gold, size: 26))
                      : Container(
                          color: AppTheme.goldSoft,
                          alignment: Alignment.center,
                          child: CachedNetworkImage(
                            imageUrl: imageUrl,
                            // Carta inteira, sem crop: com mais infos
                            // embaixo, o cover cortava as bordas.
                            fit: BoxFit.contain,
                            memCacheWidth: 300,
                            errorWidget: (_, __, ___) =>
                                const ColoredBox(
                                    color: AppTheme.goldSoft,
                                    child: Icon(Icons.broken_image,
                                        color: AppTheme.gold,
                                        size: 26)),
                          ),
                        ),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(qtyText,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                        left: 4, bottom: 4, child: badge!),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Seletor de colunas da grade: 2 (maior) ou 3 (compacta).
class GridColumnsToggle extends StatelessWidget {
  const GridColumnsToggle(
      {super.key, required this.columns, required this.onChanged});

  final int columns;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(
            value: 2,
            icon: Icon(Icons.grid_view, size: 14),
            label: Text('2', style: TextStyle(fontSize: 12))),
        ButtonSegment(
            value: 3,
            icon: Icon(Icons.grid_3x3_outlined, size: 14),
            label: Text('3', style: TextStyle(fontSize: 12))),
      ],
      selected: {columns},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// Rótulo com inicial maiúscula ("commander" -> "Commander").
String prettyFormat(String f) =>
    f.isEmpty ? f : f[0].toUpperCase() + f.substring(1);
