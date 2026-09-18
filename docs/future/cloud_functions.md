# Cloud Functions (futuro — requer plano Blaze)

> Status atual: **NÃO usado em produção.** O app roda 100% no plano Spark
> (RTDB + Auth + Flutter). Este documento preserva a arquitetura futura.

## ATUAL — Firebase Spark

- Sem Cloud Functions, sem Cloud Build, sem Artifact Registry.
- Contadores (`likes`, `favorites`, `views`, `ratingSum`, `ratingCount`)
  ficam **no doc** `communityDecks/$deckId` e são atualizados pelo cliente
  via transação (`_bumpCounter` em `community_service.dart`).
- **Contadores = conveniência/estatística** (manipuláveis por cliente
  malicioso — limitação conhecida e aceita).
- **Votos individuais = fonte de verdade**, protegidos pelas Rules
  (1 registro por UID em `deckLikes/`, `deckFavorites/`, `deckViewers/`,
  `deckRatings/` — ninguém escreve na folha de outro usuário).

## Por que Functions foram consideradas

As RTDB Rules não conseguem vincular um incremento a um voto real: não há
agregação entre nós nem atomicidade entre caminhos. Qualquer validação
client-side de "±1" é burlável por repetição (um script dispara N
transações). Apresentar isso como antifraude seria uma solução falsa —
por isso os agregados, para serem confiáveis, precisam de cálculo
server-side via Admin SDK (que bypassa as Rules).

## Como funcionaria com Functions (Blaze)

- Novo nó `communityStats/$deckId` **sem nenhuma rule de escrita**
  (somente Admin SDK escreve; cliente tem `.read`).
- `CommunityDeck.fromMap` passaria a ler os contadores do overlay de
  stats em vez do doc (código dessa variante existiu e foi revertido;
  ver histórico do `community_service.dart`).
- Cliente **para** de escrever agregados (remove `_bumpCounter` e as
  transações em `rate`); escreve só os votos.

## Triggers planejados (nomes reais em `functions/index.js`)

| Function | Trigger | Efeito |
|---|---|---|
| `recountOnDeckLikes` | `onValueWritten(/deckLikes/{deckId}/{uid})` | Recalcula `likes` |
| `recountOnDeckFavorites` | `onValueWritten(/deckFavorites/{deckId}/{uid})` | Recalcula `favorites` |
| `recountOnDeckViewers` | `onValueWritten(/deckViewers/{deckId}/{uid})` | Recalcula `views` |
| `recountOnDeckRatings` | `onValueWritten(/deckRatings/{deckId}/{uid})` | Recalcula `ratingSum`/`ratingCount` |
| `cleanupDeck` | `onValueDeleted(/communityDecks/{deckId})` | Remove cards, stats, votos, `userPublished` do autor e espelhos `userFavorites` |

Todos idempotentes (relê os filhos e sobrescreve, sem delta).

## Limitações sem Functions (versão Spark)

1. Contadores podem ser inflados/deflacionados por cliente malicioso
   (qualquer autenticado pode transacionar os 5 campos).
2. Limpeza de despublicação é best-effort folha-a-folha pelo autor
   (suficiente na prática; sem garantia admin).
3. Rankings (Em alta, Mais curtidos etc.) refletem os contadores
   client-side.

## Reativação futura (quando migrar para Blaze)

1. Plano Blaze + `firebase deploy --only functions`
   (habilita `cloudfunctions`/`cloudbuild`/`artifactregistry`).
2. `cd functions && npm install` (requerido só então, nunca hoje).
3. Recolocar no `firebase.json`: `"functions": [{"source": "functions", "codebase": "default"}]`.
4. Recolocar o nó `communityStats` nas Rules (somente `.read`).
5. Reverter o serviço para a variante com overlay de stats:
   `fromMap(id, map, stats)`, join via `_statsMap()` em
   `listDecks`/`getDeck`/`decksByAuthor`, remover `_bumpCounter` e
   transações de `rate`, remover contadores do `toMap`.
6. Se o RTDB não for a instância default, informar `instance:` nos triggers.
7. Rodar a suíte do emulator (`ruletest/`, fora do repo) contra as
   rules com `communityStats` antes do deploy.

O código em `functions/` (package.json, index.js) já está pronto e
**não é referenciado pelo `firebase.json`** — não entra no deploy atual
e nada no fluxo do desenvolvedor (`flutter pub get` / `flutter run`)
depende dele.
