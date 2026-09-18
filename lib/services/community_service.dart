import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_database.dart';
import 'auth_service.dart';
import 'deck_availability.dart';
import 'deck_stats.dart';
import 'online_friends.dart';
import 'online_match.dart';

/// Backend da Comunidade (vitrine pública de decks) sobre o RTDB já
/// usado por salas/amigos. Sem mocks: tudo lê/escreve de verdade.
///
/// Nós (ver `database.rules.json`):
/// - communityDecks/{id}: meta + contadores (SEM cartas)
/// - communityCards/{deckId}: {cards: [...], updatedAt}
/// - deckLikes/{deckId}/{uid}, deckRatings/{deckId}/{uid},
///   deckViewers/{deckId}/{uid}, deckCounters/{deckId}
/// - userFavorites/{uid}/{deckId}, userPublished/{uid}/{id},
///   userActivity/{uid}/{push}
/// - users/{uid}/publicProfile, users/{uid}/publicCollection
/// - blocks/{uid}/{blockedUid}
class CommunityDeck {
  const CommunityDeck({
    required this.id,
    required this.name,
    this.description = '',
    this.format = 'livre',
    this.commanderName = '',
    this.commanderImage = '',
    this.commanderColors = const [],
    this.colors = const [],
    this.coverUrl = '',
    this.tags = const [],
    this.archetype = '',
    this.cardCount = 0,
    this.priceUsd = 0,
    this.views = 0,
    this.likes = 0,
    this.favorites = 0,
    this.ratingSum = 0,
    this.ratingCount = 0,
    this.authorUid = '',
    this.authorProfileId = '',
    this.authorName = '',
    this.authorCode = '',
    this.createdAt = 0,
    this.updatedAt = 0,
    this.allowCopy = true,
  });

  final String id;
  final String name;
  final String description;
  final String format;
  final String commanderName;
  final String commanderImage;
  final List<String> commanderColors;
  final List<String> colors;
  final String coverUrl;
  final List<String> tags;
  final String archetype;
  final int cardCount;
  final double priceUsd;
  final int views;
  final int likes;
  final int favorites;
  final int ratingSum;
  final int ratingCount;
  final String authorUid;
  final String authorProfileId;
  final String authorName;
  final String authorCode;
  final int createdAt;
  final int updatedAt;
  final bool allowCopy;

  double get ratingAvg => ratingCount == 0 ? 0 : ratingSum / ratingCount;

  /// Relevância p/ "Em alta": engajamento com viés de novidade.
  double get trendingScore {
    final ageDays =
        (DateTime.now().millisecondsSinceEpoch - createdAt) / 86400000.0;
    final engagement = likes * 3.0 + favorites * 2.0 + views * 0.1;
    return engagement / (1 + ageDays / 7.0);
  }

  static List<String> _strList(Object? raw) {
    if (raw is List) return [for (final e in raw) e.toString()];
    return [];
  }

  // Versão Spark: contadores (views/likes/favorites/rating*) ficam NO DOC
  // da publicação e são atualizados pelo cliente (transação). São
  // conveniência/estatística — manipuláveis por cliente malicioso.
  // A fonte da verdade são os votos individuais (1 por UID), protegidos
  // pelas Rules. Ver docs/future/cloud_functions.md (agregados server-side).
  factory CommunityDeck.fromMap(String id, Map<String, dynamic> m) {
    return CommunityDeck(
      id: id,
      name: (m['name'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      format: (m['format'] ?? 'livre').toString(),
      commanderName: (m['commanderName'] ?? '').toString(),
      commanderImage: (m['commanderImage'] ?? '').toString(),
      commanderColors: _strList(m['commanderColors']),
      colors: _strList(m['colors']),
      coverUrl: (m['coverUrl'] ?? '').toString(),
      tags: _strList(m['tags']),
      archetype: (m['archetype'] ?? '').toString(),
      cardCount: (m['cardCount'] as num?)?.toInt() ?? 0,
      priceUsd: (m['priceUsd'] as num?)?.toDouble() ?? 0,
      views: (m['views'] as num?)?.toInt() ?? 0,
      likes: (m['likes'] as num?)?.toInt() ?? 0,
      favorites: (m['favorites'] as num?)?.toInt() ?? 0,
      ratingSum: (m['ratingSum'] as num?)?.toInt() ?? 0,
      ratingCount: (m['ratingCount'] as num?)?.toInt() ?? 0,
      authorUid: (m['authorUid'] ?? '').toString(),
      authorProfileId: (m['authorProfileId'] ?? '').toString(),
      authorName: (m['authorName'] ?? '').toString(),
      authorCode: (m['authorCode'] ?? '').toString(),
      createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      allowCopy: (m['allowCopy'] as bool?) ?? true,
    );
  }

  Map<String, Object?> toMap() => {
        'name': name,
        'description': description,
        'format': format,
        'commanderName': commanderName,
        'commanderImage': commanderImage,
        'commanderColors': commanderColors,
        'colors': colors,
        'coverUrl': coverUrl,
        'tags': tags,
        'archetype': archetype,
        'cardCount': cardCount,
        'priceUsd': priceUsd,
        'views': views,
        'likes': likes,
        'favorites': favorites,
        'ratingSum': ratingSum,
        'ratingCount': ratingCount,
        'authorUid': authorUid,
        'authorProfileId': authorProfileId,
        'authorName': authorName,
        'authorCode': authorCode,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'allowCopy': allowCopy,
      };
}

class CommunityService {
  CommunityService({FirebaseAuth? auth, FirebaseDatabase? database})
      : _database = database ?? OnlineMatch.defaultDatabase(),
        _friends = OnlineFriends(auth: auth, database: database);

  final FirebaseDatabase _database;
  final OnlineFriends _friends;

  Future<String> get _uid async => _friends.myUid;

  /// Lista decks (mais recentes primeiro). Sem filtros server-side
  /// além do limite: busca/filtros rodam no cliente sobre o lote.
  Future<List<CommunityDeck>> listDecks({int limit = 200}) async {
    final snap = await _database
        .ref('communityDecks')
        .orderByChild('updatedAt')
        .limitToLast(limit)
        .get();
    final raw = snap.value;
    if (raw is! Map) return [];
    final out = <CommunityDeck>[];
    raw.forEach((key, value) {
      if (value is Map) {
        out.add(CommunityDeck.fromMap(
            key.toString(),
            Map<String, dynamic>.from(
                value.map((k, v) => MapEntry(k.toString(), v)))));
      }
    });
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<CommunityDeck?> getDeck(String id) async {
    final snap = await _database.ref('communityDecks/$id').get();
    if (!snap.exists || snap.value is! Map) return null;
    return CommunityDeck.fromMap(
        id,
        Map<String, dynamic>.from((snap.value as Map)
            .map((k, v) => MapEntry(k.toString(), v))));
  }

  /// Cartas do deck publicado (lista de mapas da publicação).
  Future<List<Map<String, dynamic>>> getDeckCards(String deckId) async {
    final snap = await _database.ref('communityCards/$deckId/cards').get();
    final raw = snap.value;
    if (raw is! List) return [];
    return [
      for (final e in raw)
        if (e is Map)
          Map<String, dynamic>.from(
              e.map((k, v) => MapEntry(k.toString(), v)))
    ];
  }

  /// Publica snapshot de um deck local. Não referencia o deck local:
  /// edições futuras não tocam a publicação (republicar atualiza).
  /// Retorna o id público.
  Future<String> publishDeck({
    required String publicName,
    required String description,
    required String format,
    required String commanderName,
    required String commanderImage,
    required List<String> commanderColors,
    required List<String> colors,
    required String coverUrl,
    required List<String> tags,
    required String archetype,
    required bool allowCopy,
    required List<Map<String, Object?>> cards,
    String? updateId,
    int? localDeckId,
  }) async {
    final uid = await _uid;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cardCount =
        cards.fold<int>(0, (s, c) => s + (((c['qty'] as num?)?.toInt() ?? 0)));
    final price = cards.fold<double>(
        0.0,
        (s, c) =>
            s +
            (((c['qty'] as num?)?.toInt() ?? 0) *
                (((c['price_usd'] as num?)?.toDouble() ??
                    (c['price_ref_usd'] as num?)?.toDouble() ??
                    0))));
    // Autor: nome do perfil local ativo + identidade online
    // ('main' p/ permanente, linha local p/ convidado).
    String profileId = OnlineFriends.accountProfileId;
    String authorName = '';
    String authorCode = '';
    try {
      final prefs = await AppDatabasePrefs.activeProfileRef();
      authorName = prefs['name'] ?? '';
      profileId = OnlineFriends.slotFor(
        isPermanent: AuthService.isPermanent,
        localRowId: prefs['id'] ?? '',
      );
      final codes = await _friends.friendCodesOnce();
      authorCode = codes[profileId] ?? '';
    } catch (_) {}
    final meta = CommunityDeck(
      id: updateId ?? '',
      name: publicName.trim().isEmpty ? 'Deck sem nome' : publicName.trim(),
      description: description.trim(),
      format: format,
      commanderName: commanderName,
      commanderImage: commanderImage,
      commanderColors: commanderColors,
      colors: colors,
      coverUrl: coverUrl,
      tags: tags,
      archetype: archetype.trim(),
      cardCount: cardCount,
      priceUsd: price,
      authorUid: uid,
      authorProfileId: profileId,
      authorName: authorName,
      authorCode: authorCode,
      createdAt: now,
      updatedAt: now,
      allowCopy: allowCopy,
    );
    final ref = updateId == null
        ? _database.ref('communityDecks').push()
        : _database.ref('communityDecks/$updateId');
    final id = ref.key!;
    final data = meta.toMap();
    if (updateId != null) {
      // Atualizar preserva contadores/createdAt existentes.
      final cur = await getDeck(updateId);
      if (cur == null) throw StateError('Publicação não encontrada.');
      if (cur.authorUid != uid) throw StateError('Sem permissão.');
      data['views'] = cur.views;
      data['likes'] = cur.likes;
      data['favorites'] = cur.favorites;
      data['ratingSum'] = cur.ratingSum;
      data['ratingCount'] = cur.ratingCount;
      data['createdAt'] = cur.createdAt;
    }
    await ref.set(data);
    await _database.ref('communityCards/$id').set({
      'cards': [
        for (final c in cards)
          {
            'name': (c['name'] ?? '').toString(),
            'qty': (c['qty'] as num?)?.toInt() ?? 1,
            'set': (c['set'] ?? '').toString(),
            'scryfall_id': (c['scryfall_id'] ?? '').toString(),
            'oracle_id': (c['oracle_id'] ?? '').toString(),
            'image_url': (c['image_url'] ?? '').toString(),
            'cmc': DeckStatsService.manaValue(c['cmc'], c['mana_cost']) ?? 0,
            'mana_cost': (c['mana_cost'] ?? '').toString(),
            'type_line': (c['type_line'] ?? '').toString(),
            'colors': c['colors'] ?? [],
            'color_identity': c['color_identity'] ?? [],
            'price_usd': (c['price_usd'] as num?)?.toDouble() ?? 0,
          },
      ],
      'updatedAt': now,
    });
    try {
      await _database.ref('userPublished/$uid/$id').set({
        'deckName': meta.name,
        'at': now,
        if (localDeckId != null) 'localDeckId': localDeckId,
      });
      await _logActivity(
          uid, updateId == null ? 'published' : 'updated',
          deckId: id);
    } catch (_) {}
    return id;
  }

  /// Mapa deck local -> publicação ({localDeckId: pubId}) do usuário.
  Future<Map<String, String>> myPublicationMap() async {
    try {
      final uid = await _uid;
      final snap = await _database.ref('userPublished/$uid').get();
      final raw = snap.value;
      if (raw is! Map) return {};
      final out = <String, String>{};
      raw.forEach((pubId, v) {
        if (v is Map) {
          final local = (v['localDeckId'] as num?)?.toInt();
          if (local != null) out['$local'] = pubId.toString();
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  /// UIDs bloqueados por mim (p/ ocultar da vitrine).
  Future<Set<String>> myBlockedIds() async {
    try {
      final uid = await _uid;
      final snap = await _database.ref('blocks/$uid').get();
      final raw = snap.value;
      if (raw is! Map) return {};
      return {for (final k in raw.keys) k.toString()};
    } catch (_) {
      return {};
    }
  }

  /// Remove publicação do autor + dependentes.
  /// As rules só autorizam o autor a APAGAR votos alheios (nunca criar/
  /// editar), então a limpeza é folha a folha (best-effort por folha).
  Future<void> unpublishDeck(String id) async {
    final uid = await _uid;
    final cur = await getDeck(id);
    if (cur == null) return;
    if (cur.authorUid != uid) throw StateError('Sem permissão.');
    // Ordem importa: as rules validam o autor via communityDecks/$id,
    // então os dependentes saem antes do próprio deck.
    for (final node in [
      'deckLikes',
      'deckRatings',
      'deckViewers',
      'deckFavorites',
    ]) {
      try {
        final snap = await _database.ref('$node/$id').get();
        final raw = snap.value;
        if (raw is Map) {
          await Future.wait([
            for (final k in raw.keys)
              _database.ref('$node/$id/$k').remove(),
          ]);
        }
      } catch (_) {}
    }
    try {
      await _database.ref('userPublished/$uid/$id').remove();
    } catch (_) {}
    try {
      await _database.ref('communityCards/$id').remove();
    } catch (_) {}
    await _database.ref('communityDecks/$id').remove();
    try {
      await _logActivity(uid, 'unpublished', deckId: id);
    } catch (_) {}
  }

  /// Curtir / descurtir (idempotente por UID + transação no contador).
  /// Versão Spark: o contador é client-side (convenção, não antifraude).
  Future<bool> toggleLike(String deckId, bool liked) async {
    final uid = await _uid;
    final likeRef = _database.ref('deckLikes/$deckId/$uid');
    if (liked) {
      await likeRef.remove();
      await _bumpCounter(deckId, 'likes', -1);
      return false;
    }
    await likeRef.set(true);
    await _bumpCounter(deckId, 'likes', 1);
    try {
      await _logActivity(uid, 'liked', deckId: deckId);
    } catch (_) {}
    return true;
  }

  Future<bool> isLiked(String deckId) async {
    try {
      final uid = await _uid;
      final snap = await _database.ref('deckLikes/$deckId/$uid').get();
      return snap.exists;
    } catch (_) {
      return false;
    }
  }

  /// Favoritar = salvar p/ depois (índice por usuário + espelho por
  /// deck + contador client-side). Versão Spark: contador é convenção.
  Future<bool> toggleFavorite(String deckId) async {
    final uid = await _uid;
    final favRef = _database.ref('userFavorites/$uid/$deckId');
    final mirrorRef = _database.ref('deckFavorites/$deckId/$uid');
    final snap = await favRef.get();
    if (snap.exists) {
      await favRef.remove();
      try {
        await mirrorRef.remove();
      } catch (_) {}
      await _bumpCounter(deckId, 'favorites', -1);
      return false;
    }
    await favRef.set({
      'at': DateTime.now().millisecondsSinceEpoch,
      'deckId': deckId,
    });
    try {
      await mirrorRef.set(true);
    } catch (_) {}
    await _bumpCounter(deckId, 'favorites', 1);
    try {
      await _logActivity(uid, 'favorited', deckId: deckId);
    } catch (_) {}
    return true;
  }

  Future<bool> isFavorite(String deckId) async {
    try {
      final uid = await _uid;
      final snap = await _database.ref('userFavorites/$uid/$deckId').get();
      return snap.exists;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> myFavoriteIds() async {
    try {
      final uid = await _uid;
      final snap = await _database.ref('userFavorites/$uid').get();
      final raw = snap.value;
      if (raw is! Map) return [];
      return [for (final k in raw.keys) k.toString()];
    } catch (_) {
      return [];
    }
  }

  /// Avaliar 1-5 (uma por UID; trocar ajusta soma, conta 1x).
  /// Versão Spark: soma/contagem client-side (convenção, não antifraude).
  Future<void> rate(String deckId, int stars) async {
    final uid = await _uid;
    final s = stars.clamp(1, 5);
    final myRef = _database.ref('deckRatings/$deckId/$uid');
    final prev = await myRef.get();
    final old = (prev.value as num?)?.toInt() ?? 0;
    await myRef.set(s);
    final ref = _database.ref('communityDecks/$deckId');
    await ref.child('ratingSum').runTransaction((current) {
      return Transaction.success(
          ((current as num?)?.toInt() ?? 0) + s - old);
    });
    if (old == 0) {
      await ref.child('ratingCount').runTransaction((current) {
        return Transaction.success(
            ((current as num?)?.toInt() ?? 0) + 1);
      });
    }
  }

  Future<int> myRating(String deckId) async {
    try {
      final uid = await _uid;
      final snap = await _database.ref('deckRatings/$deckId/$uid').get();
      return (snap.value as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Visualização: 1 por UID (registro + incremento transacional).
  /// Versão Spark: contador client-side (convenção, não antifraude).
  Future<void> recordView(String deckId) async {
    try {
      final uid = await _uid;
      final seen =
          await _database.ref('deckViewers/$deckId/$uid').get();
      if (seen.exists) return;
      await _database.ref('deckViewers/$deckId/$uid').set(true);
      await _bumpCounter(deckId, 'views', 1);
    } catch (_) {}
  }

  Future<void> _bumpCounter(String deckId, String field, int delta) async {
    try {
      await _database
          .ref('communityDecks/$deckId/$field')
          .runTransaction((current) {
        final v = ((current as num?)?.toInt() ?? 0) + delta;
        return Transaction.success(v < 0 ? 0 : v);
      });
    } catch (_) {}
  }

  /// Copiar deck da comunidade -> NOVO deck local independente.
  /// Reusa o pipeline do Scryfall: catálogo qty 0, coleção intacta.
  /// Retorna o id do deck local criado.
  Future<int> copyDeck(String communityId, {String? nameOverride}) async {
    final deck = await getDeck(communityId);
    if (deck == null) throw StateError('Deck não encontrado.');
    if (!deck.allowCopy) throw StateError('Cópia desativada pelo autor.');
    final cards = await getDeckCards(communityId);
    final db = AppDatabase.instance.db;
    final localId = await db.insert('decks', {
      'name': (nameOverride ?? deck.name).trim().isEmpty
          ? deck.name
          : nameOverride!.trim(),
      'format': deck.format,
    });
    int? commanderId;
    for (final c in cards) {
      final name = (c['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final qty = (c['qty'] as num?)?.toInt() ?? 1;
      final sid = (c['scryfall_id'] ?? '').toString();
      int cardId;
      if (sid.isNotEmpty) {
        final found = await db.query('cards',
            columns: ['id'], where: 'scryfall_id = ?', whereArgs: [sid]);
        if (found.isNotEmpty) {
          cardId = found.first['id'] as int;
        } else {
          cardId = await db.insert('cards', {
            'scryfall_id': sid,
            'oracle_id': (c['oracle_id'] ?? '').toString(),
            'name': name,
            'set_code': (c['set'] ?? '').toString(),
            'image_url': (c['image_url'] ?? '').toString(),
            'cmc': DeckStatsService.manaValue(c['cmc'], c['mana_cost']) ?? 0,
            'mana_cost': (c['mana_cost'] ?? '').toString(),
            'type_line': (c['type_line'] ?? '').toString(),
            'quantity': 0,
            'price_usd': (c['price_usd'] as num?)?.toDouble() ?? 0,
          });
        }
      } else {
        // Sem scryfall_id: casa por nome exato no catálogo/coleção.
        final found = await db.query('cards',
            columns: ['id'],
            where: 'name = ? OR printed_name = ?',
            whereArgs: [name, name],
            limit: 1);
        if (found.isNotEmpty) {
          cardId = found.first['id'] as int;
        } else {
          cardId = await db.insert('cards', {
            'name': name,
            'set_code': (c['set'] ?? '').toString(),
            'image_url': (c['image_url'] ?? '').toString(),
            // Desconhecido = NULL (não 0): o stats exclui em vez de
            // jogar na curva de custo 0.
            'cmc': (c['cmc'] as num?)?.toDouble(),
            'type_line': (c['type_line'] ?? '').toString(),
            'quantity': 0,
            'price_usd': (c['price_usd'] as num?)?.toDouble() ?? 0,
          });
        }
      }
      await db.insert('deck_cards',
          {'deck_id': localId, 'card_id': cardId, 'quantity': qty});
      if (deck.commanderName.isNotEmpty &&
          name.toLowerCase() == deck.commanderName.toLowerCase() &&
          commanderId == null) {
        commanderId = cardId;
      }
    }
    if (commanderId != null) {
      await db.update('decks', {'commander_card_id': commanderId},
          where: 'id = ?', whereArgs: [localId]);
    }
    try {
      final uid = await _uid;
      await _logActivity(uid, 'copied', deckId: communityId);
    } catch (_) {}
    return localId;
  }

  /// Disponibilidade do deck publicado contra a coleção local.
  Future<DeckAvailability> availabilityOf(String communityId) async {
    final cards = await getDeckCards(communityId);
    final db = AppDatabase.instance.db;
    final results = await Future.wait([
      DeckAvailabilityService.ownedByOracle(db),
      DeckAvailabilityService.ownedByName(db),
    ]);
    // Adapta shape publicado -> shape do compute (deck_qty + price_usd).
    final items = [
      for (final c in cards)
        {
          'id': ('${c['scryfall_id'] ?? ''}${c['name']}'.hashCode),
          'name': c['name'],
          'oracle_id': c['oracle_id'],
          'deck_qty': c['qty'],
          'price_usd': c['price_usd'],
        },
    ];
    return DeckAvailabilityService.compute(items, results[0], results[1]);
  }

  Future<void> _logActivity(String uid, String type, {String? deckId}) async {
    try {
      final ref = _database.ref('userActivity/$uid').push();
      await ref.set({
        'type': type,
        if (deckId != null) 'deckId': deckId,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
      // Poda best-effort: mantém as 30 mais recentes.
      final snap = await _database
          .ref('userActivity/$uid')
          .orderByChild('at')
          .get();
      final raw = snap.value;
      if (raw is Map && raw.length > 30) {
        final keys = raw.keys.map((e) => e.toString()).toList();
        // Sem 'at' ordenado aqui: remove os mais antigos por chave
        // (push-ids são cronológicos).
        keys.sort();
        for (var i = 0; i < keys.length - 30; i++) {
          await _database.ref('userActivity/$uid/${keys[i]}').remove();
        }
      }
    } catch (_) {}
  }

  // ---------- coleção pública (opt-in) ----------

  /// Resumo público da coleção de [uid] (vazio se não compartilha).
  Future<Map<String, dynamic>> publicCollection(String uid) async {
    try {
      final snap =
          await _database.ref('users/$uid/publicCollection').get();
      if (snap.value is Map) {
        return Map<String, dynamic>.from((snap.value as Map)
            .map((k, v) => MapEntry(k.toString(), v)));
      }
    } catch (_) {}
    return {};
  }

  /// Agrega a coleção local (quantity>0) e publica o resumo.
  /// Só agregados — nenhuma carta individual sai do aparelho.
  Future<Map<String, dynamic>> syncPublicCollection() async {
    final uid = await _uid;
    final db = AppDatabase.instance.db;
    var total = 0;
    var distinct = 0;
    var value = 0.0;
    try {
      final t = await db.rawQuery('''
        SELECT COUNT(*) AS u, COALESCE(SUM(quantity),0) AS t,
               COALESCE(SUM(quantity*COALESCE(price_usd,price_ref_usd,0)),0) AS v
        FROM cards WHERE quantity > 0''');
      if (t.isNotEmpty) {
        distinct = (t.first['u'] as num?)?.toInt() ?? 0;
        total = (t.first['t'] as num?)?.toInt() ?? 0;
        value = (t.first['v'] as num?)?.toDouble() ?? 0;
      }
    } catch (_) {}
    final byRarity = <String, int>{};
    try {
      final r = await db.rawQuery('''
        SELECT rarity, SUM(quantity) AS n FROM cards
        WHERE quantity > 0 GROUP BY rarity''');
      for (final row in r) {
        final key = (row['rarity'] ?? 'unknown').toString();
        byRarity[key] = (row['n'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    final topSets = <Map<String, Object?>>[];
    try {
      final s = await db.rawQuery('''
        SELECT set_code, set_name, SUM(quantity) AS n FROM cards
        WHERE quantity > 0 GROUP BY set_code ORDER BY n DESC LIMIT 5''');
      for (final row in s) {
        topSets.add({
          'code': (row['set_code'] ?? '').toString(),
          'name': (row['set_name'] ?? '').toString(),
          'count': (row['n'] as num?)?.toInt() ?? 0,
        });
      }
    } catch (_) {}
    final data = <String, Object?>{
      'sharing': true,
      'totalCards': total,
      'distinctCards': distinct,
      'valueUsd': value,
      'byRarity': byRarity,
      'topSets': topSets,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await _database.ref('users/$uid/publicCollection').set(data);
    try {
      await _logActivity(uid, 'shared_collection');
    } catch (_) {}
    return Map<String, dynamic>.from(data);
  }

  /// Para de compartilhar a coleção (remove o resumo público).
  Future<void> hidePublicCollection() async {
    final uid = await _uid;
    await _database.ref('users/$uid/publicCollection').remove();
  }

  // ---------- perfil público / privacidade ----------

  Future<Map<String, dynamic>> publicProfile(String uid) async {
    try {
      final snap = await _database.ref('users/$uid/publicProfile').get();
      if (snap.value is Map) {
        return Map<String, dynamic>.from((snap.value as Map)
            .map((k, v) => MapEntry(k.toString(), v)));
      }
    } catch (_) {}
    return {};
  }

  Future<void> savePublicProfile(Map<String, Object?> data) async {
    final uid = await _uid;
    await _database.ref('users/$uid/publicProfile').set({
      ...data,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Decks públicos de um autor (p/ PublicProfilePage).
  Future<List<CommunityDeck>> decksByAuthor(String authorUid,
      {int limit = 100}) async {
    final snap = await _database
        .ref('communityDecks')
        .orderByChild('authorUid')
        .equalTo(authorUid)
        .limitToLast(limit)
        .get();
    final raw = snap.value;
    if (raw is! Map) return [];
    final out = <CommunityDeck>[];
    raw.forEach((key, value) {
      if (value is Map) {
        out.add(CommunityDeck.fromMap(
            key.toString(),
            Map<String, dynamic>.from(
                value.map((k, v) => MapEntry(k.toString(), v)))));
      }
    });
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<List<Map<String, dynamic>>> activityOf(String uid,
      {int limit = 30}) async {
    try {
      final snap = await _database
          .ref('userActivity/$uid')
          .orderByChild('at')
          .limitToLast(limit)
          .get();
      final raw = snap.value;
      if (raw is! Map) return [];
      final out = <Map<String, dynamic>>[];
      raw.forEach((key, value) {
        if (value is Map) {
          out.add({
            'id': key.toString(),
            ...Map<String, dynamic>.from(
                value.map((k, v) => MapEntry(k.toString(), v))),
          });
        }
      });
      out.sort((a, b) =>
          ((b['at'] as num?)?.toInt() ?? 0)
              .compareTo((a['at'] as num?)?.toInt() ?? 0));
      return out;
    } catch (_) {
      return [];
    }
  }
}

/// Atalhos de perfil local p/ telas sociais (evita importar o app todo).
class AppDatabasePrefs {
  /// {id, name} do perfil ativo no registro global.
  static Future<Map<String, String>> activeProfileRef() async {
    try {
      final prefs = await _prefs();
      final active = prefs.getString('active_db_path') ?? '';
      final rows = await AppDatabase.instance.mainDb().then((mdb) => mdb.query(
          'profiles',
          columns: ['id', 'name'],
          where: 'database_path = ?',
          whereArgs: [active],
          limit: 1));
      if (rows.isNotEmpty) {
        return {
          'id': (rows.first['id'] ?? '').toString(),
          'name': (rows.first['name'] ?? '').toString(),
        };
      }
    } catch (_) {}
    return {'id': '', 'name': ''};
  }

  static Future<SharedPreferences> _prefs() =>
      SharedPreferences.getInstance();
}
