import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'online_match.dart';

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

  Future<String> get myUid async {
    final current = _auth.currentUser;
    if (current != null) return current.uid;
    final cred = await _auth.signInAnonymously();
    final user = cred.user;
    if (user == null) throw StateError('Sem identidade online.');
    return user.uid;
  }

  /// Código público deste perfil (cria se não existir). Estável.
  /// Reaponta o índice a cada abertura: se o UID mudou (reinstalação
  /// em outro aparelho, nova identidade), o código volta a funcionar
  /// em vez de apontar para um UID morto.
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
      await ref.update({
        'name': name.trim().isEmpty ? 'Jogador' : name.trim(),
        'updatedAt': ServerValue.timestamp,
      });
      // Reaponta o índice (o UID pode ter mudado desde a criação).
      try {
        await _database.ref('friendCodes/$existing').set({
          'uid': uid,
          'profileId': profileId,
        });
      } catch (_) {}
      return existing;
    }
    final rnd = Random.secure();
    for (var i = 0; i < 12; i++) {
      final code =
          'MC-${List.generate(5, (_) => _codeAlphabet[rnd.nextInt(_codeAlphabet.length)]).join()}';
      final taken = await _database.ref('friendCodes/$code').get();
      if (taken.exists) continue;
      await _database.ref('friendCodes/$code').set({
        'uid': uid,
        'profileId': profileId,
      });
      await ref.set({
        'friendCode': code,
        'name': name.trim().isEmpty ? 'Jogador' : name.trim(),
        'updatedAt': ServerValue.timestamp,
      });
      return code;
    }
    throw StateError('Não foi possível gerar um código único.');
  }

  /// Busca código MC-XXXXX -> {uid, profileId, name}.
  /// Código de perfil apagado/reinstalado (UID morto): avisa como
  /// expirado em vez de mandar o pedido para o vazio.
  Future<Map<String, String>?> lookupCode(String rawCode) async {
    final code = rawCode.trim().toUpperCase();
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
