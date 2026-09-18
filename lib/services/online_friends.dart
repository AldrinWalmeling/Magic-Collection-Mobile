import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'online_match.dart';
import 'card_types.dart';

/// Amigo online (identidade = UID Firebase; nome é só exibição).
class OnlineFriend {
  final String uid;
  final String profileId;
  final String name;
  final String code;

  const OnlineFriend({
    required this.uid,
    required this.profileId,
    required this.name,
    required this.code,
  });

  factory OnlineFriend.fromEntry(
      String uid, String key, Map<String, dynamic> m) {
    // A chave é {friendUid}__{friendProfile}. O uid do AMIGO vem da
    // chave — nunca o uid do dono passado por parâmetro (era esse o
    // bug: convites iam para si mesmo e a presença vigiada era a sua).
    return OnlineFriend(
      uid: _friendUidFromKey(key, fallback: uid),
      profileId: _friendProfileFromKey(key),
      name: (m['name'] ?? '?').toString(),
      code: (m['code'] ?? '').toString(),
    );
  }

  /// Formato atual: {uid}__{perfil}. Legado: {uid}_{perfil} (UIDs
  /// anônimos têm 28 chars sem underscore — dá para separar).
  static String _friendUidFromKey(String key, {String fallback = ''}) {
    final d = key.split('__');
    if (d.length > 1 && d.first.isNotEmpty) return d.first;
    if (key.length > 29 && key[28] == '_') {
      return key.substring(0, 28);
    }
    return fallback;
  }

  static String _friendProfileFromKey(String key) {
    final d = key.split('__');
    if (d.length > 1) return d.sublist(1).join('__');
    if (key.length > 29 && key[28] == '_') return key.substring(29);
    return '';
  }
}

/// Pedido de amizade pendente.
class FriendRequest {
  final String id;
  final String fromUid;
  final String fromProfile;
  final String fromName;
  final String fromCode;
  final String toProfile;
  final int at;

  const FriendRequest({
    required this.id,
    required this.fromUid,
    required this.fromProfile,
    required this.fromName,
    required this.fromCode,
    required this.toProfile,
    required this.at,
  });

  factory FriendRequest.fromSnapshot(DataSnapshot snap) {
    final raw = snap.value;
    final m = raw is Map
        ? Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};
    return FriendRequest(
      id: snap.key ?? '',
      fromUid: (m['fromUid'] ?? '').toString(),
      fromProfile: (m['fromProfile'] ?? '').toString(),
      fromName: (m['fromName'] ?? '?').toString(),
      fromCode: (m['fromCode'] ?? '').toString(),
      toProfile: (m['toProfile'] ?? '').toString(),
      at: (m['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Convite para sala Online.
class RoomInvite {
  final String id;
  final String fromUid;
  final String fromName;
  final String roomCode;
  final int at;

  const RoomInvite({
    required this.id,
    required this.fromUid,
    required this.fromName,
    required this.roomCode,
    required this.at,
  });

  factory RoomInvite.fromSnapshot(DataSnapshot snap) {
    final raw = snap.value;
    final m = raw is Map
        ? Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};
    return RoomInvite(
      id: snap.key ?? '',
      fromUid: (m['fromUid'] ?? '').toString(),
      fromName: (m['fromName'] ?? '?').toString(),
      roomCode: (m['roomCode'] ?? '').toString(),
      at: (m['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Amigos, presença e convites via Realtime Database.
///
/// Estrutura (sem duplicar dados além do necessário):
/// - users/{uid}/profiles/{profileId}: {friendCode, name, updatedAt}
/// - friendCodes/{code}: {uid, profileId} (índice reverso p/ busca)
/// - friendRequests/{toUid}/{pushId}: {fromUid, fromProfile, fromName,
///   fromCode, toProfile, at} (apagado ao aceitar/recusar)
/// - friends/{uid}/{friendUid__friendProfile}: {name, code, at}
/// - presence/{uid}: {name, online, room, updatedAt} (+ onDisconnect)
/// - roomInvites/{toUid}/{pushId}: {fromUid, fromName, roomCode, at}
///
/// Tudo chaveado por UID; nome de perfil é só display.
class OnlineFriends {
  OnlineFriends({FirebaseAuth? auth, FirebaseDatabase? database})
      : _auth = auth ?? FirebaseAuth.instance,
        _database = database ?? OnlineMatch.defaultDatabase();

  final FirebaseAuth _auth;
  final FirebaseDatabase _database;

  static const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// Futuros de sign-in anônimo em voo, um por FirebaseAuth.
  static final Map<FirebaseAuth, Future<String>> _anonInflight = {};

  /// Código personalizado: MAIÚSCULAS, letras/números/_/-, 3-16 chars.
  /// "#Meu Codigo" -> "MEU_CODIGO". Hífen preservado para os códigos
  /// legados "MC-XXXXX" continuarem acháveis. Retorna '' se vazio.
  static String sanitizeCode(String raw) {
    var s = CardTypes.flat(raw).toUpperCase();
    if (s.startsWith('#')) s = s.substring(1);
    s = s.replaceAll(RegExp(r'\s+'), '_');
    s = s.replaceAll(RegExp(r'[^A-Z0-9_\-]'), '');
    s = s.replaceAll(RegExp(r'_+'), '_');
    s = s.replaceAll(RegExp(r'^_+|_+$'), '');
    return s;
  }

  /// Entrada de busca: aceita com/sem #, minúsculas e espaços
  /// ("#meu codigo" acha "MEU_CODIGO").
  static String normalizeLookup(String raw) => sanitizeCode(raw);

  /// Último código conhecido do slot (p/ exibir sem sessão).
  static Future<String> cachedCode(String profileId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('known_code_$profileId') ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> _cacheCode(
      String profileId, String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('known_code_$profileId', code);
    } catch (_) {}
  }

  /// Troca o código do perfil (ex. "#MEUCODIGO").
  /// Garante unicidade global: a rule nega se outro UID já tem.
  /// Erros: FormatException('invalid') | FormatException('taken').
  Future<String> setFriendCode({
    required String profileId,
    required String rawCode,
  }) async {
    final uid = await myUid;
    final code = sanitizeCode(rawCode);
    if (code.length < 3 || code.length > 16) {
      throw const FormatException('invalid');
    }
    final ref = _database.ref('users/$uid/profiles/$profileId');
    final snap = await ref.get();
    final cur = snap.value is Map
        ? Map<String, dynamic>.from(
            (snap.value as Map).map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};
    final oldCode = (cur['friendCode'] ?? '').toString();
    if (oldCode == code) return code;
    // Checagem amigável; a atomicidade real é da rule (!data.exists()).
    try {
      final taken = await _database.ref('friendCodes/$code').get();
      if (taken.exists) {
        final m = taken.value is Map
            ? Map<String, dynamic>.from((taken.value as Map)
                .map((k, v) => MapEntry(k.toString(), v)))
            : <String, dynamic>{};
        if ((m['uid'] ?? '').toString() != uid) {
          throw const FormatException('taken');
        }
      }
      await _database.ref('friendCodes/$code').set({
        'uid': uid,
        'profileId': profileId,
      });
    } catch (e) {
      if (e is FormatException) rethrow;
      throw const FormatException('taken');
    }
    try {
      await ref.update({'friendCode': code});
    } catch (_) {}
    if (oldCode.isNotEmpty) {
      try {
        await _database.ref('friendCodes/$oldCode').remove();
      } catch (_) {}
    }
    // Mantém o perfil público coerente (melhor esforço).
    try {
      await _database
          .ref('users/$uid/publicProfile/friendCode')
          .set(code);
    } catch (_) {}
    await _cacheCode(profileId, code);
    return code;
  }

  Future<String> get myUid async {
    final current = _auth.currentUser;
    if (current != null) return current.uid;
    // Single-flight por instância: N chamadas concorrentes com
    // currentUser==null (ex. várias tabs recarregando após logout)
    // criavam N usuários novos. Todas aguardam a mesma criação.
    return _anonInflight.putIfAbsent(_auth, () async {
      try {
        final again = _auth.currentUser;
        if (again != null) return again.uid;
        final cred = await _auth.signInAnonymously();
        final user = cred.user;
        if (user == null) throw StateError('Sem identidade online.');
        return user.uid;
      } finally {
        _anonInflight.remove(_auth);
      }
    });
  }

  /// Identidade online ÚNICA por conta Firebase, estável entre
  /// aparelhos. Usada pelas contas PERMANENTES.
  static const accountProfileId = 'main';

  /// Slot online a usar: permanentes usam 'main' (estável entre
  /// aparelhos); convidados usam o id da linha local (estável no
  /// aparelho, reativável sem credencial). Puro e testado.
  static String slotFor(
      {required bool isPermanent, required String localRowId}) {
    if (isPermanent) return accountProfileId;
    if (localRowId.isNotEmpty) return localRowId;
    return accountProfileId;
  }

  /// Código público da conta (cria se não existir). Regra fundamental:
  /// conta existente (mesmo UID) NUNCA é renomeada nem recodificada —
  /// carrega nick e código como estão, mesmo em aparelho novo.
  /// Só conta realmente nova (sem perfil no UID) ganha identidade,
  /// com o nick escolhido pelo usuário e código derivado dele.
  Future<String> ensureFriendCode({
    required String profileId,
    required String name,
  }) async {
    final uid = await myUid;
    final ref = _database.ref('users/$uid/profiles/$profileId');
    final snap = await ref.get();
    final cur = snap.value is Map
        ? Map<String, dynamic>.from(
            (snap.value as Map).map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};
    final existing = (cur['friendCode'] ?? '').toString();
    if (existing.isNotEmpty) {
      // Existe: só garante o índice (aponta para este UID/perfil).
      // NÃO toca em nome nem código — primeiro acesso no aparelho
      // não é conta nova.
      try {
        await _database.ref('friendCodes/$existing').set({
          'uid': uid,
          'profileId': profileId,
        });
      } catch (_) {}
      // Limpeza de legados só no slot único ('main'): slots por
      // perfil de convidado são identidades independentes legítimas.
      if (profileId == accountProfileId) {
        await _dropStaleUidCodes(uid,
            keepProfile: profileId, keepCode: existing);
      }
      await _cacheCode(profileId, existing);
      return existing;
    }
    final code = await _claimCode(
        uid: uid, profileId: profileId, name: name);
    if (profileId == accountProfileId) {
      await _dropStaleUidCodes(uid,
          keepProfile: profileId, keepCode: code);
    }
    await _cacheCode(profileId, code);
    return code;
  }

  /// Remove índices/linhas de identidades legadas do MESMO uid
  /// (profileIds locais de aparelhos antigos). Só o dono escreve aqui.
  /// Nunca remove o código vigente (keepCode).
  Future<void> _dropStaleUidCodes(String uid,
      {required String keepProfile, required String keepCode}) async {
    try {
      final all =
          await _database.ref('users/$uid/profiles').get();
      if (all.value is! Map) return;
      final rows = Map<String, dynamic>.from((all.value as Map)
          .map((k, v) => MapEntry(k.toString(), v)));
      for (final e in rows.entries) {
        if (e.key == keepProfile || e.value is! Map) continue;
        final m = Map<String, dynamic>.from((e.value as Map)
            .map((k, v) => MapEntry(k.toString(), v)));
        final stale = (m['friendCode'] ?? '').toString();
        if (stale.isNotEmpty && stale != keepCode) {
          try {
            await _database.ref('friendCodes/$stale').remove();
          } catch (_) {}
        }
        // Linha legada sai mesmo que o código tenha sido reaproveitado
        // (o índice já aponta para o perfil vigente).
        try {
          await _database
              .ref('users/$uid/profiles/${e.key}')
              .remove();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Gera e assume um código novo: nome do perfil ("João Silva" ->
  /// "JOAO_SILVA", "JOAO_SILVA2"...), senão MC- aleatório.
  /// Se o código for do próprio UID (migração), reassume em vez de
  /// numerar: nunca "Aldrin2" para a mesma conta.
  Future<String> _claimCode({
    required String uid,
    required String profileId,
    required String name,
  }) async {
    final ref = _database.ref('users/$uid/profiles/$profileId');
    final displayName =
        name.trim().isEmpty ? 'Jogador' : name.trim();

    Future<String?> tryTake(String candidate) async {
      try {
        final hit =
            await _database.ref('friendCodes/$candidate').get();
        if (hit.exists) {
          final m = hit.value is Map
              ? Map<String, dynamic>.from((hit.value as Map)
                  .map((k, v) => MapEntry(k.toString(), v)))
              : <String, dynamic>{};
          // Mesmo UID (migração de aparelho/perfil): reassume.
          if ((m['uid'] ?? '').toString() != uid) return null;
        }
        await _database.ref('friendCodes/$candidate').set({
          'uid': uid,
          'profileId': profileId,
        });
      } catch (_) {
        return null;
      }
      try {
        await ref.set({
          'friendCode': candidate,
          'name': displayName,
          'updatedAt': ServerValue.timestamp,
        });
      } catch (_) {
        return null;
      }
      return candidate;
    }

    final rnd = Random.secure();
    var base = sanitizeCode(name);
    if (base.length > 12) base = base.substring(0, 12);
    if (base.length >= 3) {
      for (var n = 0; n < 100; n++) {
        var candidate = n == 0 ? base : '$base$n';
        if (candidate.length > 16) {
          candidate = candidate.substring(0, 16);
        }
        final got = await tryTake(candidate);
        if (got != null) return got;
      }
    }
    for (var i = 0; i < 12; i++) {
      final code =
          'MC-${List.generate(5, (_) => _codeAlphabet[rnd.nextInt(_codeAlphabet.length)]).join()}';
      final got = await tryTake(code);
      if (got != null) return got;
    }
    throw StateError('Não foi possível gerar um código único.');
  }

  /// Busca código MC-XXXXX -> {uid, profileId, name}.
  /// Código de perfil apagado/reinstalado (UID morto): avisa como
  /// expirado em vez de mandar o pedido para o vazio.
  Future<Map<String, String>?> lookupCode(String rawCode) async {
    final code = normalizeLookup(rawCode);
    if (code.isEmpty) return null;
    final snap = await _database.ref('friendCodes/$code').get();
    if (!snap.exists || snap.value is! Map) return null;
    final m = Map<String, dynamic>.from(
        (snap.value as Map).map((k, v) => MapEntry(k.toString(), v)));
    final uid = (m['uid'] ?? '').toString();
    final profileId = (m['profileId'] ?? '').toString();
    if (uid.isEmpty) return null;
    var name = '';
    var alive = false;
    try {
      final usnap = await _database.ref('users/$uid/profiles/$profileId').get();
      if (usnap.value is Map) {
        alive = true;
        name = ((usnap.value as Map)['name'] ?? '').toString();
      }
    } catch (_) {}
    if (!alive) throw const FormatException('stale');
    return {'uid': uid, 'profileId': profileId, 'name': name};
  }

  Future<void> sendRequest({
    required String toUid,
    required String toProfile,
    required String fromProfile,
    required String fromName,
    required String fromCode,
  }) async {
    final uid = await myUid;
    if (toUid == uid) throw StateError('Você não pode se adicionar.');
    final existing = await _database.ref('friends/$uid').get();
    if (existing.value is Map) {
      final m = Map<String, dynamic>.from(
          (existing.value as Map).map((k, v) => MapEntry(k.toString(), v)));
      // Casa os dois formatos de chave (__ atual, _ legado).
      if (m.keys.any((k) {
        final key = k.toString();
        return key == toUid || key.startsWith('${toUid}_');
      })) {
        throw StateError('Vocês já são amigos.');
      }
    }
    await _database.ref('friendRequests/$toUid').push().set({
      'fromUid': uid,
      'fromProfile': fromProfile,
      'fromName': fromName,
      'fromCode': fromCode,
      'toProfile': toProfile,
      'at': ServerValue.timestamp,
    });
  }

  static FriendRequest _parseRequest(String id, Object? raw) {
    final m = raw is Map
        ? Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};
    return FriendRequest(
      id: id,
      fromUid: (m['fromUid'] ?? '').toString(),
      fromProfile: (m['fromProfile'] ?? '').toString(),
      fromName: (m['fromName'] ?? '?').toString(),
      fromCode: (m['fromCode'] ?? '').toString(),
      toProfile: (m['toProfile'] ?? '').toString(),
      at: (m['at'] as num?)?.toInt() ?? 0,
    );
  }

  Stream<List<FriendRequest>> watchRequests(String uid) {
    return _database.ref('friendRequests/$uid').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return <FriendRequest>[];
      final out = <FriendRequest>[];
      raw.forEach((key, value) {
        out.add(_parseRequest(key.toString(), value));
      });
      out.sort((a, b) => b.at.compareTo(a.at));
      return out;
    });
  }

  Future<void> respondRequest(
    FriendRequest req,
    bool accept, {
    required String myName,
    required String myCode,
    required String myProfile,
  }) async {
    final uid = await myUid;
    if (accept) {
      const at = ServerValue.timestamp;
      await _database
          .ref('friends/$uid/${req.fromUid}__${req.fromProfile}')
          .set({
        'name': req.fromName,
        'code': req.fromCode,
        'at': at,
      });
      // Mesmo separador (__) dos dois lados — misturar _ e __ quebrava
      // a leitura do par (perfil vazio, duplicatas).
      await _database.ref('friends/${req.fromUid}/${uid}__$myProfile').set({
        'name': myName,
        'code': myCode,
        'at': at,
      });
    }
    await _database.ref('friendRequests/$uid/${req.id}').remove();
  }

  Future<void> removeFriend(String friendUid, String friendProfile) async {
    final uid = await myUid;
    // Tenta os dois formatos (__ atual, _ legado).
    try {
      await _database
          .ref('friends/$uid/${friendUid}__$friendProfile')
          .remove();
    } catch (_) {}
    if (friendProfile.isNotEmpty) {
      try {
        await _database
            .ref('friends/$uid/${friendUid}_$friendProfile')
            .remove();
      } catch (_) {}
    }
    // Melhor esforço do outro lado (pode falhar por regras/uid).
    try {
      final snap = await _database.ref('friends/$friendUid').get();
      if (snap.value is Map) {
        final m = Map<String, dynamic>.from(
            (snap.value as Map).map((k, v) => MapEntry(k.toString(), v)));
        for (final k in m.keys) {
          if (k.toString().startsWith('${uid}_')) {
            await _database.ref('friends/$friendUid/$k').remove();
          }
        }
      }
    } catch (_) {}
  }

  Stream<List<OnlineFriend>> watchFriends(String uid) {    return _database.ref('friends/$uid').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return <OnlineFriend>[];
      final out = <OnlineFriend>[];
      raw.forEach((key, value) {
        if (value is! Map) return;
        out.add(OnlineFriend.fromEntry(
            uid,
            key.toString(),
            Map<String, dynamic>.from(
                value.map((k, v) => MapEntry(k.toString(), v)))));
      });
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    });
  }

  Future<List<OnlineFriend>> friendsOnce(String uid) async {
    final snap = await _database.ref('friends/$uid').get();
    final raw = snap.value;
    if (raw is! Map) return [];
    final out = <OnlineFriend>[];
    raw.forEach((key, value) {
      if (value is! Map) return;
      out.add(OnlineFriend.fromEntry(
          uid,
          key.toString(),
          Map<String, dynamic>.from(
              value.map((k, v) => MapEntry(k.toString(), v)))));
    });
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Códigos de amigo de TODOS os perfis deste aparelho
  /// ({profileId: MC-XXXXX}). Uma identidade (UID), um código por
  /// perfil — é o ÚNICO código que o usuário precisa conhecer.
  Future<Map<String, String>> friendCodesOnce() async {
    final out = <String, String>{};
    try {
      final uid = await myUid;
      final snap = await _database.ref('users/$uid/profiles').get();
      if (snap.value is Map) {
        (snap.value as Map).forEach((pid, v) {
          if (v is Map) {
            final code = (v['friendCode'] ?? '').toString();
            if (code.isNotEmpty) out[pid.toString()] = code;
          }
        });
      }
    } catch (_) {}
    return out;
  }

  /// Presença: online + sala atual. onDisconnect marca offline.
  Future<void> setPresence({required String name, String? room}) async {
    final uid = await myUid;
    final ref = _database.ref('presence/$uid');
    await ref.set({
      'name': name,
      'online': true,
      'room': room ?? '',
      'updatedAt': ServerValue.timestamp,
    });
    try {
      await ref.onDisconnect().update({
        'online': false,
        'room': '',
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  Stream<Map<String, dynamic>> watchPresence(String uid) {
    return _database.ref('presence/$uid').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return <String, dynamic>{};
      return Map<String, dynamic>.from(
          raw.map((k, v) => MapEntry(k.toString(), v)));
    });
  }

  Future<void> sendRoomInvite({
    required String toUid,
    required String fromName,
    required String roomCode,
  }) async {
    final uid = await myUid;
    await _database.ref('roomInvites/$toUid').push().set({
      'fromUid': uid,
      'fromName': fromName,
      'roomCode': roomCode.trim().toUpperCase(),
      'at': ServerValue.timestamp,
    });
  }

  static RoomInvite _parseInvite(String id, Object? raw) {
    final m = raw is Map
        ? Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry(k.toString(), v)))
        : <String, dynamic>{};
    return RoomInvite(
      id: id,
      fromUid: (m['fromUid'] ?? '').toString(),
      fromName: (m['fromName'] ?? '?').toString(),
      roomCode: (m['roomCode'] ?? '').toString(),
      at: (m['at'] as num?)?.toInt() ?? 0,
    );
  }

  Stream<List<RoomInvite>> watchRoomInvites(String uid) {
    return _database.ref('roomInvites/$uid').onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return <RoomInvite>[];
      final out = <RoomInvite>[];
      raw.forEach((key, value) {
        out.add(_parseInvite(key.toString(), value));
      });
      out.sort((a, b) => b.at.compareTo(a.at));
      return out;
    });
  }

  Future<void> consumeRoomInvite(String uid, String id) async {
    if (id.isEmpty) return;
    await _database.ref('roomInvites/$uid/$id').remove();
  }
}
