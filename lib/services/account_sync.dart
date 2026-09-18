import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_database.dart';
import 'auth_service.dart';
import 'online_match.dart';

// Backup e restauração da CONTA (plano Spark: só RTDB por UID).
//
// Separação LOCAL x CONTA:
// - LOCAL (sqlite): cache, offline, performance, imagens, ajustes do
//   aparelho (idioma/moeda). Pode ser apagado sem perda.
// - CONTA (RTDB em userCards/userDecks/userSync/{uid}, owner-only):
//   decks, coleção (qty+favoritas), favoritas. Sobrevive a
//   desinstalar/reinstalar e troca de aparelho.
// - Social (friends, requests, publicados, votos, perfil, coleção
//   pública, blocks, activity): já era por UID no servidor.
//
// Só contas PERMANENTES sincronizam com o RTDB. A conta temporária
// continua sendo uma identidade local do dispositivo e é gerenciada
// pelo fluxo de contas do aparelho.
//
// No login de uma conta permanente: se o estado remoto já existe,
// o servidor é a referência. Se local e remoto forem equivalentes,
// não há restauração repetida. Se só o local existir, fazemos o primeiro
// backup. Backup manual/lifecycle pode enviar explicitamente.
class AccountSync {
  AccountSync._();

  /// Campos só do aparelho: nunca sobem.
  static const localOnlyFields = {
    'id',
    'image_path',
    'created_at',
    'updated_at',
  };

  /// Campos de dados sincronizados na restauração (quando o local
  /// estiver vazio). Quantidade/favorita sempre; resto só preenche
  /// buraco (nunca apaga dado local existente).
  static const dataFields = [
    'scryfall_id',
    'oracle_id',
    'name',
    'printed_name',
    'lang',
    'set_code',
    'set_name',
    'collector_number',
    'mana_cost',
    'type_line',
    'oracle_text',
    'power',
    'toughness',
    'rarity',
    'cmc',
    'colors',
    'color_identity',
    'image_url',
    'price_usd',
    'price_usd_foil',
    'price_usd_etched',
    'price_eur',
    'price_eur_foil',
    'price_tix',
    'price_ref_usd',
    'price_ref_name',
    'artist',
    'released_at',
    'preferred_finish',
  ];

  static bool get canSync => AuthService.isPermanent;

  static FirebaseDatabase get _db => OnlineMatch.defaultDatabase();

  static String? _syncedUid;
  static Future<void> _operation = Future<void>.value();

  static String _deckMapPrefsKey(String uid) =>
      'account_sync_deck_map_$uid';

  static Future<Map<String, int>> _loadDeckMap(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_deckMapPrefsKey(uid));
      if (raw == null || raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (int.tryParse(e.value.toString()) != null)
            e.key.toString(): int.parse(e.value.toString()),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveDeckMap(String uid, Map<String, int> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_deckMapPrefsKey(uid), jsonEncode(map));
    } catch (_) {}
  }

  static Future<T> _serial<T>(Future<T> Function() action) {
    final next = _operation.then((_) => action());
    _operation = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  static bool get isSessionSynced {
    final uid = AuthService.current?.uid;
    return canSync &&
        uid != null &&
        _syncedUid == uid &&
        AppDatabase.instance.openUid == uid;
  }

  static bool _stillSameAccount(String uid) =>
      AuthService.current?.uid == uid &&
      canSync &&
      AppDatabase.instance.openUid == uid;

  static String _snapshotFingerprint(Map<String, dynamic> snapshot) {
    dynamic normalize(Object? value) {
      if (value is Map) {
        final entries = value.entries
            .map((e) => MapEntry(e.key.toString(), normalize(e.value)))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        return {for (final e in entries) e.key: e.value};
      }
      if (value is List) {
        return value.map(normalize).toList();
      }
      return value;
    }

    final cards = <Map<String, dynamic>>[];
    final rawCards = snapshot['cards'];
    if (rawCards is Map) {
      for (final e in rawCards.entries) {
        if (e.value is Map) {
          cards.add({
            'key': e.key.toString(),
            'value': normalize(e.value),
          });
        }
      }
    }
    cards.sort((a, b) => a['key'].toString().compareTo(b['key'].toString()));

    final decks = <dynamic>[];
    final rawDecks = snapshot['decks'];
    if (rawDecks is Map) {
      for (final e in rawDecks.entries) {
        if (e.value is! Map) continue;
        final d = Map<String, dynamic>.from(
            (e.value as Map).map((k, v) => MapEntry(k.toString(), v)));
        d.remove('updatedAt');
        final items = d['cards'];
        if (items is List) {
          final normalizedItems = items
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(
                  m.map((k, v) => MapEntry(k.toString(), normalize(v)))))
              .toList();
          normalizedItems.sort((a, b) =>
              a['sid'].toString().compareTo(b['sid'].toString()));
          d['cards'] = normalizedItems;
        }
        decks.add(normalize(d));
      }
    }
    decks.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));

    return jsonEncode({
      'cards': cards,
      'decks': decks,
    });
  }

  static String _cardKey(Map<String, Object?> c) {
    final sid = (c['scryfall_id'] ?? '').toString().trim();
    if (sid.isNotEmpty) return sid;
    return 'n:${(c['name'] ?? '').toString().trim().toLowerCase()}';
  }

  /// Coleta o estado local sincronizável (cartas com qty>0 ou em uso
  /// em decks + todos os decks). Puro em I/O, sem Firebase.
  static Future<Map<String, dynamic>> collectLocal() async {
    final db = AppDatabase.instance.db;
    final deckLinks = await db.query('deck_cards');
    final used = {
      for (final r in deckLinks)
        ((r['card_id'] as num?)?.toInt() ?? -1)
    };
    final cards = await db.query('cards');
    final cardRows = <String, Map<String, Object?>>{};
    for (final c in cards) {
      final qty = (c['quantity'] as num?)?.toInt() ?? 0;
      final id = (c['id'] as num?)?.toInt() ?? -1;
      if (qty <= 0 && !used.contains(id)) continue;
      final row = Map<String, Object?>.of(c)
        ..removeWhere((k, _) => localOnlyFields.contains(k));
      cardRows[_cardKey(c)] = row;
    }
    final decks = await db.query('decks');
    final uid = AuthService.current?.uid;
    final deckMap = uid == null ? <String, int>{} : await _loadDeckMap(uid);
    final localIdToSyncKey = <int, String>{
      for (final e in deckMap.entries) e.value: e.key,
    };
    final byId = <int, Map<String, Object?>>{};
    for (final c in cards) {
      final id = (c['id'] as num?)?.toInt() ?? -1;
      byId[id] = c;
    }
    final deckRows = <String, Map<String, Object?>>{};
    for (final d in decks) {
      final deckId = (d['id'] as num?)?.toInt() ?? -1;
      final items = await db.query('deck_cards',
          where: 'deck_id = ?', whereArgs: [deckId]);
      final cardIds = <int, int>{};
      for (final it in items) {
        cardIds[((it['card_id'] as num?)?.toInt() ?? -1)] =
            ((it['quantity'] as num?)?.toInt() ?? 1);
      }
      String? sidOf(int? cardId) {
        if (cardId == null || cardId < 0) return null;
        final c = byId[cardId];
        if (c == null) return null;
        final sid = (c['scryfall_id'] ?? '').toString().trim();
        if (sid.isNotEmpty) return sid;
        return 'n:${(c['name'] ?? '').toString().trim().toLowerCase()}';
      }

      final syncKey = localIdToSyncKey[deckId] ?? 'd$deckId';
      deckRows[syncKey] = {
        'name': (d['name'] ?? '').toString(),
        'format': (d['format'] ?? 'livre').toString(),
        'favorite': (d['favorite'] as num?)?.toInt() ?? 0,
        'commanderSid': sidOf((d['commander_card_id'] as num?)?.toInt()),
        'previewSid': sidOf((d['preview_card_id'] as num?)?.toInt()),
        'updatedAt': (d['updated_at'] ?? '').toString(),
        'cards': [
          for (final e in cardIds.entries)
            {'sid': sidOf(e.key), 'qty': e.value},
        ],
      };
    }
    return {'cards': cardRows, 'decks': deckRows};
  }

  /// Envia o estado local para a conta (sobrescreve o backup).
  /// Só com o arquivo da conta aberto (nunca mistura).
  static Future<void> push() => _serial(() async {
    final uid = AuthService.current?.uid;
    if (uid == null || !canSync) return;
    if (AppDatabase.instance.openUid != null &&
        AppDatabase.instance.openUid != uid) {
      return;
    }
    final local = await collectLocal();
    if (!_stillSameAccount(uid)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.ref('userCards/$uid').set(local['cards']);
    if (!_stillSameAccount(uid)) return;
    await _db.ref('userDecks/$uid').set(local['decks']);
    if (!_stillSameAccount(uid)) return;
    try {
      await _db.ref('userSync/$uid').set({
        'updatedAt': now,
        'cards': (local['cards'] as Map).length,
        'decks': (local['decks'] as Map).length,
      });
    } catch (_) {}
    if (_stillSameAccount(uid)) {
      _syncedUid = uid;
    }
  });

  /// Lê o backup da conta (vazio se nunca sincronizou).
  static Future<Map<String, dynamic>> fetchRemote() async {
    final uid = AuthService.current?.uid;
    if (uid == null || !canSync) return {};
    try {
      final results = await Future.wait([
        _db.ref('userCards/$uid').get(),
        _db.ref('userDecks/$uid').get(),
      ]);
      Map<String, dynamic> asMap(Object? v) {
        if (v is! Map) return {};
        return Map<String, dynamic>.from(
            v.map((k, e) => MapEntry(k.toString(), e)));
      }

      return {
        'cards': asMap(results[0].value),
        'decks': asMap(results[1].value),
      };
    } catch (e) {
      // Nunca transforme falha de rede/permissão em "backup vazio": isso
      // poderia fazer o próximo passo sobrescrever os dados remotos.
      rethrow;
    }
  }

  /// Último sync conhecido (meta do servidor).
  static Future<Map<String, dynamic>> lastSync() async {
    final uid = AuthService.current?.uid;
    if (uid == null || !canSync) return {};
    try {
      final snap = await _db.ref('userSync/$uid').get();
      if (snap.value is Map) {
        return Map<String, dynamic>.from((snap.value as Map)
            .map((k, v) => MapEntry(k.toString(), v)));
      }
    } catch (_) {}
    return {};
  }

  /// Identidade do servidor p/ pular o diálogo de nome quando a conta
  /// já existe (outro aparelho/reinstalação).
  static Future<Map<String, String>?> fetchServerIdentity() async {
    final uid = AuthService.current?.uid;
    if (uid == null || !canSync) return null;
    try {
      final snap =
          await _db.ref('users/$uid/profiles/main').get();
      if (snap.value is! Map) return null;
      final m = Map<String, dynamic>.from((snap.value as Map)
          .map((k, v) => MapEntry(k.toString(), v)));
      final name = (m['name'] ?? '').toString().trim();
      final code = (m['friendCode'] ?? '').toString().trim();
      if (name.isEmpty && code.isEmpty) return null;
      return {'name': name, 'code': code};
    } catch (_) {
      return null;
    }
  }

  static bool _blank(Object? v) =>
      v == null || v.toString().trim().isEmpty;

  static int _matchCardId(
      List<Map<String, Object?>> local, Map<String, dynamic> remote) {
    final sid = (remote['scryfall_id'] ?? '').toString().trim();
    if (sid.isNotEmpty) {
      for (final c in local) {
        if ((c['scryfall_id'] ?? '').toString().trim() == sid) {
          return (c['id'] as num?)?.toInt() ?? -1;
        }
      }
    }
    final oracle = (remote['oracle_id'] ?? '').toString().trim();
    final set = (remote['set_code'] ?? '').toString().trim();
    final cn = (remote['collector_number'] ?? '').toString().trim();
    if (oracle.isNotEmpty && set.isNotEmpty && cn.isNotEmpty) {
      for (final c in local) {
        if ((c['oracle_id'] ?? '').toString().trim() == oracle &&
            (c['set_code'] ?? '').toString().trim() == set &&
            (c['collector_number'] ?? '').toString().trim() == cn) {
          return (c['id'] as num?)?.toInt() ?? -1;
        }
      }
    }
    final name = (remote['name'] ?? '').toString().trim().toLowerCase();
    if (name.isNotEmpty) {
      for (final c in local) {
        final n1 = (c['name'] ?? '').toString().trim().toLowerCase();
        final n2 =
            (c['printed_name'] ?? '').toString().trim().toLowerCase();
        if (n1 == name || n2 == name) {
          return (c['id'] as num?)?.toInt() ?? -1;
        }
      }
    }
    return -1;
  }

  /// Restaura o backup no banco local. Retorna contagens reais de itens
  /// inseridos/atualizados. O processo é idempotente para a mesma conta.
  static Future<Map<String, int>> restore(
      Map<String, dynamic> remote) async {
    final uid = AuthService.current?.uid;
    if (uid == null || !canSync) return {'cards': 0, 'decks': 0};

    final db = AppDatabase.instance.db;
    final pathBefore = AppDatabase.instance.currentPath;
    final remoteCards = remote['cards'];
    final remoteDecks = remote['decks'];
    var cardCount = 0;
    var deckCount = 0;
    final sidToId = <String, int>{};

    if (remoteCards is Map && remoteCards.isNotEmpty) {
      final local = (await db.query('cards'))
          .map((c) => Map<String, Object?>.of(c))
          .toList();
      final batch = db.batch();
      for (final e in remoteCards.entries) {
        if (!_stillSameAccount(uid) ||
            AppDatabase.instance.currentPath != pathBefore) {
          return {'cards': cardCount, 'decks': deckCount};
        }
        if (e.value is! Map) continue;
        final r = Map<String, dynamic>.from((e.value as Map)
            .map((k, v) => MapEntry(k.toString(), v)));
        final qty = (r['quantity'] as num?)?.toInt() ?? 0;
        final fav = (r['favorite'] as num?)?.toInt() ?? 0;
        final match = _matchCardId(local, r);
        if (match >= 0) {
          final cur = local.firstWhere(
              (c) => (c['id'] as num?)?.toInt() == match);
          final patch = <String, Object?>{};
          if (((cur['quantity'] as num?)?.toInt() ?? 0) != qty) {
            patch['quantity'] = qty;
          }
          if (((cur['favorite'] as num?)?.toInt() ?? 0) != fav) {
            patch['favorite'] = fav;
          }
          for (final f in dataFields) {
            if (_blank(cur[f]) && !_blank(r[f])) patch[f] = r[f];
          }
          if (patch.isNotEmpty) {
            batch.update('cards', patch,
                where: 'id = ?', whereArgs: [match]);
            cardCount++;
            local.remove(cur);
            local.add({...cur, ...patch});
          }
          final remoteSid = (r['scryfall_id'] ?? '').toString().trim();
          if (remoteSid.isNotEmpty) sidToId[remoteSid] = match;
          final sid = (cur['scryfall_id'] ?? '').toString().trim();
          sidToId[sid.isNotEmpty
              ? sid
              : 'n:${(cur['name'] ?? '').toString().trim().toLowerCase()}'] = match;
        } else {
          final row = <String, Object?>{
            for (final f in dataFields)
              if (r.containsKey(f)) f: r[f],
            'quantity': qty,
            'favorite': fav,
          };
          final newId = await db.insert('cards', row);
          sidToId[e.key.toString()] = newId;
          cardCount++;
          local.add({...row, 'id': newId});
        }
      }
      if (!_stillSameAccount(uid)) return {'cards': cardCount, 'decks': deckCount};
      await batch.commit(noResult: true);
    }

    if (remoteDecks is Map && remoteDecks.isNotEmpty) {
      if (!_stillSameAccount(uid) ||
          AppDatabase.instance.currentPath != pathBefore) {
        return {'cards': cardCount, 'decks': deckCount};
      }

      final localDecks = (await db.query('decks'))
          .map((d) => Map<String, Object?>.of(d))
          .toList();
      final deckMap = await _loadDeckMap(uid);
      final adopted = <int>{};

      int? mappedLocalId(String remoteKey) {
        final id = deckMap[remoteKey];
        if (id == null) return null;
        final exists = localDecks.any(
            (d) => (d['id'] as num?)?.toInt() == id);
        if (!exists) {
          deckMap.remove(remoteKey);
          return null;
        }
        return id;
      }

      int matchDeckId(String name) {
        final want = name.trim().toLowerCase();
        if (want.isEmpty) return -1;
        for (final d in localDecks) {
          final id = (d['id'] as num?)?.toInt() ?? -1;
          if (id < 0 || adopted.contains(id)) continue;
          final n = (d['name'] ?? '').toString().trim().toLowerCase();
          if (n == want) return id;
        }
        return -1;
      }

      for (final e in remoteDecks.entries) {
        if (!_stillSameAccount(uid) ||
            AppDatabase.instance.currentPath != pathBefore) {
          return {'cards': cardCount, 'decks': deckCount};
        }
        if (e.value is! Map) continue;
        final remoteKey = e.key.toString();
        final r = Map<String, dynamic>.from((e.value as Map)
            .map((k, v) => MapEntry(k.toString(), v)));
        final name = (r['name'] ?? 'Deck').toString();
        int? deckId = mappedLocalId(remoteKey);
        deckId ??= matchDeckId(name);
        var inserted = false;
        if (deckId == null || deckId < 0) {
          final newDeckId = await db.insert('decks', {
            'name': name,
            'format': (r['format'] ?? 'livre').toString(),
            'favorite': (r['favorite'] as num?)?.toInt() ?? 0,
          });
          deckId = newDeckId;
          localDecks.add({
            'id': newDeckId,
            'name': name,
            'format': (r['format'] ?? 'livre').toString(),
            'favorite': (r['favorite'] as num?)?.toInt() ?? 0,
          });
          inserted = true;
        }

        final current = localDecks.firstWhere(
            (d) => (d['id'] as num?)?.toInt() == deckId);
        final oldName = (current['name'] ?? '').toString();
        final oldFormat = (current['format'] ?? 'livre').toString();
        final oldFavorite = (current['favorite'] as num?)?.toInt() ?? 0;

        int? resolveSid(Object? sid) {
          final s = (sid ?? '').toString().trim();
          if (s.isEmpty) return null;
          return sidToId[s];
        }

        final cmd = resolveSid(r['commanderSid']);
        final prev = resolveSid(r['previewSid']);

        // O backend pode ser de uma versão antiga sem os IDs das cartas.
        // Só altera commander/preview quando a referência existe; caso seja
        // explicitamente null, limpa o valor local para refletir o servidor.
        final currentCmd = (current['commander_card_id'] as num?)?.toInt();
        final currentPrev = (current['preview_card_id'] as num?)?.toInt();
        final requestedCmd = r.containsKey('commanderSid') ? cmd : currentCmd;
        final requestedPrev = r.containsKey('previewSid') ? prev : currentPrev;

        var changed = inserted ||
            oldName != name ||
            oldFormat != (r['format'] ?? 'livre').toString() ||
            oldFavorite != ((r['favorite'] as num?)?.toInt() ?? 0) ||
            currentCmd != requestedCmd ||
            currentPrev != requestedPrev;

        if (!inserted) {
          await db.update(
              'decks',
              {
                'name': name,
                'format': (r['format'] ?? 'livre').toString(),
                'favorite': (r['favorite'] as num?)?.toInt() ?? 0,
                'commander_card_id': requestedCmd,
                'preview_card_id': requestedPrev,
              },
              where: 'id = ?',
              whereArgs: [deckId]);
        } else {
          await db.update(
              'decks',
              {
                'commander_card_id': requestedCmd,
                'preview_card_id': requestedPrev,
              },
              where: 'id = ?',
              whereArgs: [deckId]);
        }

        try {
          final existingItems = await db.query('deck_cards',
              where: 'deck_id = ?', whereArgs: [deckId]);
          final existingMap = <String, int>{};
          for (final it in existingItems) {
            final cid = (it['card_id'] as num?)?.toInt();
            if (cid == null) continue;
            existingMap[cid.toString()] =
                (it['quantity'] as num?)?.toInt() ?? 1;
          }
          final remoteMap = <String, int>{};
          final items = r['cards'];
          if (items is List) {
            for (final it in items) {
              if (it is! Map) continue;
              final m = Map<String, dynamic>.from(
                  (it as Map).map((k, v) => MapEntry(k.toString(), v)));
              final cid = resolveSid(m['sid']);
              if (cid == null) continue;
              remoteMap[cid.toString()] =
                  (m['qty'] as num?)?.toInt() ?? 1;
            }
          }
          if (existingMap.length != remoteMap.length ||
              existingMap.entries.any((e) => remoteMap[e.key] != e.value)) {
            changed = true;
            await db.delete('deck_cards',
                where: 'deck_id = ?', whereArgs: [deckId]);
            final batch = db.batch();
            for (final e2 in remoteMap.entries) {
              batch.insert('deck_cards', {
                'deck_id': deckId,
                'card_id': int.parse(e2.key),
                'quantity': e2.value,
              });
            }
            await batch.commit(noResult: true);
          }
        } catch (_) {}

        deckMap[remoteKey] = deckId;
        adopted.add(deckId);
        final idx = localDecks.indexWhere(
            (d) => (d['id'] as num?)?.toInt() == deckId);
        if (idx >= 0) {
          localDecks[idx] = {
            ...localDecks[idx],
            'name': name,
            'format': (r['format'] ?? 'livre').toString(),
            'favorite': (r['favorite'] as num?)?.toInt() ?? 0,
            'commander_card_id': requestedCmd,
            'preview_card_id': requestedPrev,
          };
        }
        if (changed) deckCount++;
      }

      await _saveDeckMap(uid, deckMap);
    }

    return {'cards': cardCount, 'decks': deckCount};
  }

  /// Decide o fluxo semântica/efetivamente:
  /// - local vazio + remoto existente -> restore;
  /// - remoto vazio + local existente -> push;
  /// - snapshots iguais -> nothing;
  /// - conflito -> restore (servidor vence no login).
  static String decide({
    required bool localEmpty,
    required bool remoteEmpty,
    bool sameSnapshot = false,
    bool preferPush = false,
  }) {
    if (preferPush && !localEmpty) return 'pushed';
    if (remoteEmpty && localEmpty) return 'nothing';
    if (!remoteEmpty && sameSnapshot) return 'nothing';
    if (!remoteEmpty) return 'restored';
    return 'pushed';
  }

  /// Fluxo completo pós-login/setup. A sincronização é serializada para
  /// impedir dois restores/pushes concorrentes para a mesma conta.
  static Future<Map<String, dynamic>> syncNow({bool preferPush = false}) =>
      _serial(() async {
    if (!canSync) return {'action': 'skipped'};
    final uid = AuthService.current?.uid;
    if (uid == null) return {'action': 'skipped'};
    String serverName = '';
    try {
      serverName = (await fetchServerIdentity())?['name'] ?? '';
    } catch (_) {}

    await AppDatabase.instance.switchToAccount(
      uid: uid,
      kind: AuthService.accountKind,
      displayName: serverName,
    );
    if (!_stillSameAccount(uid)) return {'action': 'skipped'};

    final local = await collectLocal();
    if (!_stillSameAccount(uid)) return {'action': 'skipped'};

    final remote = await fetchRemote();
    if (!_stillSameAccount(uid)) return {'action': 'skipped'};

    final localEmpty =
        (local['cards'] as Map).isEmpty && (local['decks'] as Map).isEmpty;
    final remoteEmpty =
        (remote['cards'] as Map).isEmpty && (remote['decks'] as Map).isEmpty;
    final sameSnapshot = !localEmpty &&
        !remoteEmpty &&
        _snapshotFingerprint(local) == _snapshotFingerprint(remote);

    final action = decide(
      localEmpty: localEmpty,
      remoteEmpty: remoteEmpty,
      sameSnapshot: sameSnapshot,
      preferPush: preferPush,
    );

    switch (action) {
      case 'nothing':
        _syncedUid = uid;
        return {'action': 'nothing'};
      case 'restored':
        final report = await restore(remote);
        if (!_stillSameAccount(uid)) return {'action': 'skipped'};
        _syncedUid = uid;
        if ((report['cards'] ?? 0) == 0 && (report['decks'] ?? 0) == 0) {
          return {'action': 'nothing'};
        }
        return {'action': 'restored', ...report};
      default:
        final localForPush = await collectLocal();
        if (!_stillSameAccount(uid)) return {'action': 'skipped'};
        final now = DateTime.now().millisecondsSinceEpoch;
        await _db.ref('userCards/$uid').set(localForPush['cards']);
        if (!_stillSameAccount(uid)) return {'action': 'skipped'};
        await _db.ref('userDecks/$uid').set(localForPush['decks']);
        if (!_stillSameAccount(uid)) return {'action': 'skipped'};
        try {
          await _db.ref('userSync/$uid').set({
            'updatedAt': now,
            'cards': (localForPush['cards'] as Map).length,
            'decks': (localForPush['decks'] as Map).length,
          });
        } catch (_) {}
        _syncedUid = uid;
        return {'action': 'pushed'};
    }
  });

  static void resetSession() {
    _syncedUid = null;
  }
}
