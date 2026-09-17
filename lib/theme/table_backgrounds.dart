// Registro MODULAR de fundos de mesa.
//
// COMO ADICIONAR UM FUNDO NOVO (2 passos, sem mexer em lógica):
//   1. Coloque a imagem em assets/backgrounds/ (ex. arcane.jpg).
//   2. Adicione UMA linha na lista `tableBackgrounds` abaixo.
//
// A imagem aparece sozinha no menu de fundo de cada jogador (setup e
// mesa). Dica: use imagens escuras — a vinheta da mesa escurece só as
// bordas, o centro precisa de contraste com cartas e textos.
class TableBackground {
  /// Identificador estável (salvo na carta/mesa; nunca mude depois).
  final String id;

  /// Caminho do asset, ex. 'assets/backgrounds/arcane.jpg'.
  final String asset;

  /// Nome exibido no menu (texto direto do dev).
  final String label;

  const TableBackground({
    required this.id,
    required this.asset,
    required this.label,
  });
}

/// Todos os fundos disponíveis no app. Lista vazia = menu escondido.
const tableBackgrounds = <TableBackground>[
  TableBackground(
    id: 'default',
    asset: 'assets/backgrounds/default.png',
    label: 'Padrão',
  ),
  TableBackground(
    id: 'ceus',
    asset: 'assets/backgrounds/ceus.png',
    label: 'Céus',
  ),
  TableBackground(
    id: 'gold_throne',
    asset: 'assets/backgrounds/gold_throne.png',
    label: 'Gold Throne',
  ),
  TableBackground(
    id: 'obsidian_sky',
    asset: 'assets/backgrounds/obsidian_sky.png',
    label: 'Obsidian Sky',
  ),
  TableBackground(
    id: 'pisoteando_montanhas',
    asset: 'assets/backgrounds/pisoteando_montanhas.png',
    label: 'Pisoteando Montanhas',
  ),

  // Exemplos (descomente quando os arquivos existirem):
  // TableBackground(
  //   id: 'arcane',
  //   asset: 'assets/backgrounds/arcane.jpg',
  //   label: 'Arcano',
  // ),
  // TableBackground(
  //   id: 'forest_night',
  //   asset: 'assets/backgrounds/forest_night.jpg',
  //   label: 'Floresta Noturna',
  // ),
];
