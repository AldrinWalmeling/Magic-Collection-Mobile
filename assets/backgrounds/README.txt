FUNDOS DE MESA (assets/backgrounds)
=====================================
Coloque aqui as imagens de fundo da mesa (JPG ou PNG, de preferencia
escuras e em alta resolucao, ex. 1080x1920 ou maior).

Depois registre cada uma em UMA linha no arquivo:
  lib/theme/table_backgrounds.dart  ->  lista `tableBackgrounds`

Exemplo:
  const TableBackground(
    id: 'arcane',
    asset: 'assets/backgrounds/arcane.jpg',
    label: 'Arcano',
  ),

Regras:
- `id`: minusculas, sem espaco (nunca mude depois de usado).
- `asset`: caminho exato do arquivo nesta pasta.
- `label`: nome que o jogador ve no menu.
- Sem a linha no registry, a imagem NAO aparece no app.

Este arquivo .txt existe so para garantir a pasta no projeto;
pesa bytes e pode ser apagado quando houver imagens reais.
