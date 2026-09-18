// Cloud Functions da Comunidade Magic Collection (2nd gen).
//
// POR QUE SERVER-SIDE:
// As RTDB Rules não conseguem vincular um incremento a um voto real
// (sem agregação entre nós e sem atomicidade entre caminhos). Qualquer
// validação client-side de "±1" é burlável por repetição. Por isso:
// - VOTOS (deckLikes/deckRatings/deckViewers/deckFavorites) são a fonte
//   da verdade, com 1 registro por UID garantido pelas Rules.
// - AGREGADOS (communityStats/{deck}) são escritos SOMENTE aqui, via
//   Admin SDK (bypassa Rules). Cliente tem .read, nunca .write.
// - LIMPEZA de despublicação é refeita aqui de forma autoritativa
//   (o cliente também tenta folha-a-folha, best-effort).
//
// Deploy: `firebase deploy --only functions` (requer plano Blaze).
// Se o RTDB não for a instância default, informe `instance: '<id>''
// nas opções dos triggers abaixo.

const {
  onValueWritten,
  onValueDeleted,
} = require('firebase-functions/v2/database');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.database();

const VOTE_NODES = [
  'deckLikes',
  'deckFavorites',
  'deckViewers',
  'deckRatings',
];

async function recount(deckId) {
  const [likes, favorites, viewers, ratings] = await Promise.all([
    db.ref(`deckLikes/${deckId}`).get(),
    db.ref(`deckFavorites/${deckId}`).get(),
    db.ref(`deckViewers/${deckId}`).get(),
    db.ref(`deckRatings/${deckId}`).get(),
  ]);
  let ratingSum = 0;
  let ratingCount = 0;
  ratings.forEach((child) => {
    const v = Number(child.val());
    if (Number.isFinite(v) && v >= 1 && v <= 5) {
      ratingSum += Math.floor(v);
      ratingCount += 1;
    }
  });
  await db.ref(`communityStats/${deckId}`).set({
    likes: likes.numChildren(),
    favorites: favorites.numChildren(),
    views: viewers.numChildren(),
    ratingSum,
    ratingCount,
    updatedAt: admin.database.ServerValue.TIMESTAMP,
  });
}

// Qualquer voto criado/alterado/removido recalcula o agregado.
// Idempotente: relê os filhos e sobrescreve (sem delta).
for (const node of VOTE_NODES) {
  exports[`recountOn${node[0].toUpperCase()}${node.slice(1)}`] =
    onValueWritten(`/${node}/{deckId}/{uid}`, async (event) => {
      await recount(event.params.deckId);
    });
}

// Despublicação: remove autoritativamente todos os dependentes.
// userActivity é histórico pessoal do autor e é preservado.
exports.cleanupDeck = onValueDeleted(
  '/communityDecks/{deckId}',
  async (event) => {
    const deckId = event.params.deckId;
    const before = event.data.val() || {};
    const authorUid = (before.authorUid || '').toString();

    // Espelhos userFavorites/{uid}/{deckId} dos favoritaram.
    let favUids = [];
    try {
      const favSnap = await db.ref(`deckFavorites/${deckId}`).get();
      favSnap.forEach((child) => {
        favUids.push(child.key);
      });
    } catch (e) {
      // best-effort
    }

    const removal = {
      [`communityCards/${deckId}`]: null,
      [`communityStats/${deckId}`]: null,
      [`deckLikes/${deckId}`]: null,
      [`deckRatings/${deckId}`]: null,
      [`deckViewers/${deckId}`]: null,
      [`deckFavorites/${deckId}`]: null,
    };
    if (authorUid) {
      removal[`userPublished/${authorUid}/${deckId}`] = null;
    }
    for (const uid of favUids) {
      removal[`userFavorites/${uid}/${deckId}`] = null;
    }
    await db.ref().update(removal);
  },
);
