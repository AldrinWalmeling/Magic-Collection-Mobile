import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

/// Resultado básico de uma sala online.
class OnlineRoomInfo {
  final String roomId;
  final String hostId;
  final String status;
  final int maxPlayers;
  final Map<String, dynamic> players;
  final Map<String, dynamic>? state;
  final Map<String, dynamic> settings;

  const OnlineRoomInfo({
    required this.roomId,
    required this.hostId,
    required this.status,
    required this.maxPlayers,
    required this.players,
    required this.state,
    this.settings = const {},
  });

  bool get isWaiting => status == 'waiting';
  bool get isStarted => status == 'started';

  /// Entrada tardia permitida pelo host (padrão: sim).
  bool get allowLateJoin {
    final v = settings['allowLateJoin'];
    if (v is bool) return v;
    return true;
  }

  bool get isFull => players.length >= maxPlayers;

  /// Estado legível: Aguardando / Em andamento / Cheia / Encerrada.
  String get roomStateLabel {
    if (isFull) return 'full';
    if (isWaiting) return 'waiting';
    if (isStarted) return allowLateJoin ? 'open' : 'locked';
    return status;
  }

  factory OnlineRoomInfo.fromSnapshot(DataSnapshot snapshot) {
    final raw = snapshot.value;
    final map = raw is Map
        ? Map<String, dynamic>.from(
            raw.map((key, value) => MapEntry(key.toString(), value)))
        : <String, dynamic>{};

    final rawPlayers = map['players'];
    final players = rawPlayers is Map
        ? Map<String, dynamic>.from(
            rawPlayers.map((key, value) => MapEntry(key.toString(), value)))
        : <String, dynamic>{};

    final rawState = map['state'];
    final state = rawState is Map
        ? Map<String, dynamic>.from(
            rawState.map((key, value) => MapEntry(key.toString(), value)))
        : null;

    final rawSettings = map['settings'];
    final settings = rawSettings is Map
        ? Map<String, dynamic>.from(
            rawSettings.map((key, value) => MapEntry(key.toString(), value)))
        : <String, dynamic>{};

    return OnlineRoomInfo(
      roomId: snapshot.key ?? '',
      hostId: (map['hostId'] ?? '').toString(),
      status: (map['status'] ?? 'waiting').toString(),
      maxPlayers: (map['maxPlayers'] as num?)?.toInt() ?? 6,
      players: players,
      state: state,
      settings: settings,
    );
  }
}

/// Camada de transporte/sala online do Play.
///
/// Responsabilidades nesta primeira versão:
/// - autenticação anônima;
/// - criar/entrar/sair/encerrar sala;
/// - ouvir mudanças da sala;
/// - publicar ações pedidas por guests;
/// - publicar o estado resolvido pelo host.
///
/// A lógica das regras do Magic continua no PlayPage (_applyAction, etc.).
class OnlineMatch {
  static const int defaultMaxPlayers = 6;
  static const String statusWaiting = 'waiting';
  static const String statusStarted = 'started';

  /// URL do Realtime Database. Troque se o banco estiver em outra região.
  /// Pode sobrescrever via --dart-define=RTDB_URL=https://<projeto>...firebasedatabase.app
  static const String databaseUrl = String.fromEnvironment(
    'RTDB_URL',
    defaultValue:
        'https://magic-collection-project-default-rtdb.firebaseio.com',
  );

  static FirebaseDatabase _defaultDatabase() => defaultDatabase();

  /// Database padrão (público para reuso, ex. amigos/presença).
  static FirebaseDatabase defaultDatabase() {
    try {
      return FirebaseDatabase.instance;
    } catch (_) {
      // firebase_options sem databaseURL: usa a URL explícita.
      return FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: databaseUrl,
      );
    }
  }

  OnlineMatch({FirebaseAuth? auth, FirebaseDatabase? database})
      : _auth = auth ?? FirebaseAuth.instance,
        _database = database ?? _defaultDatabase();

  final FirebaseAuth _auth;
  final FirebaseDatabase _database;

  /// Expostos para construir serviços por sessão (amigos/convites
  /// com o UID correto de cada sessão).
  FirebaseAuth get auth => _auth;
  FirebaseDatabase get database => _database;

  StreamSubscription<DatabaseEvent>? _roomSubscription;
  StreamSubscription<DatabaseEvent>? _actionSubscription;
  String? _roomId;
  String? _myUid;
  bool _closed = false;

  final StreamController<OnlineRoomInfo> _roomController =
      StreamController<OnlineRoomInfo>.broadcast();
  final StreamController<Map<String, dynamic>> _actionController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<DatabaseEvent> _rawEventController =
      StreamController<DatabaseEvent>.broadcast();

  Stream<OnlineRoomInfo> get roomStream => _roomController.stream;
  Stream<Map<String, dynamic>> get actionStream => _actionController.stream;
  Stream<DatabaseEvent> get rawEventStream => _rawEventController.stream;

  String? get roomId => _roomId;
  String? get myUid => _myUid ?? _auth.currentUser?.uid;
  bool get isInRoom => _roomId != null;

  DatabaseReference? get roomRef {
    final id = _roomId;
    if (id == null || id.isEmpty) return null;
    return _database.ref('rooms/$id');
  }

  /// Garante uma identidade estável por instalação/usuário Firebase.
  Future<User> authenticate() async {
    final current = _auth.currentUser;
    if (current != null) {
      _myUid = current.uid;
      return current;
    }

    final credential = await _auth.signInAnonymously();
    final user = credential.user;
    if (user == null) {
      throw StateError('Não foi possível criar a identidade online.');
    }
    _myUid = user.uid;
    return user;
  }

  /// Cria uma sala com código curto e legível, ex. ABC7K2.
  /// O nome do jogador é mantido no nó players/<uid>.
  Future<OnlineRoomInfo> createRoom({
    required String playerName,
    String format = 'livre',
    int startLife = 20,
    String tableTheme = 'midnight',
    int maxPlayers = defaultMaxPlayers,
    bool allowLateJoin = true,
    Map<String, dynamic>? initialState,
  }) async {
    _ensureOpen();
    await leaveRoom(deleteIfHost: true);
    final user = await authenticate();
    final safeName = _sanitizeName(playerName);
    final roomCode = await _generateRoomCode();
    final room = _database.ref('rooms/$roomCode');

    final now = ServerValue.timestamp;
    final state = initialState ??
        <String, dynamic>{
          'playMode': 'online',
          'format': format,
          'startLife': startLife,
          'tableTheme': tableTheme,
          'round': 1,
          'active': 0,
          'players': <dynamic>[],
          'tokens': <dynamic>[],
          'effects': <dynamic>[],
          'mana': <String, dynamic>{},
          'activity': <dynamic>['Mesa criada por $safeName'],
        };

    await room.set({
      'hostId': user.uid,
      'status': statusWaiting,
      'maxPlayers': maxPlayers.clamp(2, defaultMaxPlayers),
      'createdAt': now,
      'updatedAt': now,
      'settings': {
        'format': format,
        'startLife': startLife,
        'tableTheme': tableTheme,
        'allowLateJoin': allowLateJoin,
      },
      'players': {
        user.uid: {
          'name': safeName,
          'joinedAt': now,
          'connected': true,
        },
      },
      'state': state,
    });

    _roomId = roomCode;
    _myUid = user.uid;
    _listenToRoom();
    return await _readRoom(roomCode);
  }

  /// Entra em uma sala pelo código exibido ao usuário.
  /// Vale na espera e, se o host permitir, com a partida em andamento
  /// (entrada tardia: o host adiciona o jogador à mesa).
  Future<OnlineRoomInfo> joinRoom({
    required String roomCode,
    required String playerName,
  }) async {
    _ensureOpen();
    final normalized = _normalizeRoomCode(roomCode);
    if (normalized.isEmpty) {
      throw ArgumentError('Código da sala inválido.');
    }

    await leaveRoom(deleteIfHost: true);
    final user = await authenticate();
    final room = _database.ref('rooms/$normalized');
    final snap = await room.get();
    if (!snap.exists) {
      throw StateError('Sala $normalized não encontrada.');
    }

    final info = OnlineRoomInfo.fromSnapshot(snap);
    if (info.isStarted && !info.allowLateJoin) {
      throw StateError('Partida em andamento (entrada tardia fechada).');
    }
    if (info.isFull && !info.players.containsKey(user.uid)) {
      throw StateError('A sala está cheia.');
    }

    final safeName = _sanitizeName(playerName);
    await room.child('players/${user.uid}').set({
      'name': safeName,
      'joinedAt': ServerValue.timestamp,
      'connected': true,
    });
    await room.update({'updatedAt': ServerValue.timestamp});

    _roomId = normalized;
    _myUid = user.uid;
    _listenToRoom();
    return await _readRoom(normalized);
  }

  /// Reconecta a uma sala existente (volta ao app, trocou de rede...).
  /// Vale para host (retoma a autoridade) e guest (volta a receber).
  /// Não recria o jogador: se o UID não está na sala, foi removido.
  Future<OnlineRoomInfo> attach(String roomCode) async {
    _ensureOpen();
    final normalized = _normalizeRoomCode(roomCode);
    if (normalized.isEmpty) {
      throw ArgumentError('Código da sala inválido.');
    }
    final user = await authenticate();
    final snap = await _database.ref('rooms/$normalized').get();
    if (!snap.exists) {
      throw StateError('Sala $normalized não encontrada.');
    }
    final info = OnlineRoomInfo.fromSnapshot(snap);
    if (!info.players.containsKey(user.uid)) {
      throw StateError('Você foi removido dessa sala.');
    }
    _roomId = normalized;
    _myUid = user.uid;
    _listenToRoom();
    try {
      await setConnected(true);
    } catch (_) {}
    return await _readRoom(normalized);
  }

  /// Liga/desliga a entrada tardia. Apenas o host pode fazer isso.
  Future<void> setLateJoin(bool allow) async {
    _ensureInRoom();
    await authenticate();
    final room = roomRef!;
    final snap = await room.get();
    if (!snap.exists) throw StateError('Sala não encontrada.');
    final info = OnlineRoomInfo.fromSnapshot(snap);
    if (info.hostId != myUid) {
      throw StateError('Somente o host pode mudar essa opção.');
    }
    await room.update({
      'settings/allowLateJoin': allow,
      'updatedAt': ServerValue.timestamp,
    });
  }

  /// Marca a sala como iniciada. Apenas o host pode fazer isso.
  /// Solo liberado (igual ao LAN): dá para entrar na mesa sozinho,
  /// praticar e receber gente depois. Sala vazia continua fora.
  Future<void> startRoom() async {
    _ensureInRoom();
    await authenticate();
    final room = roomRef!;
    final snap = await room.get();
    if (!snap.exists) throw StateError('Sala não encontrada.');
    final info = OnlineRoomInfo.fromSnapshot(snap);
    if (info.hostId != myUid) {
      throw StateError('Somente o anfitrião pode iniciar a partida.');
    }
    if (info.players.isEmpty) {
      throw StateError('Não há jogadores na sala.');
    }
    await room.update({
      'status': statusStarted,
      'updatedAt': ServerValue.timestamp,
    });
  }

  /// Publica uma ação enviada por um jogador.
  ///
  /// O host/PlayPage deve ouvir actionStream, validar/resolver a ação e
  /// então chamar publishState().
  Future<void> sendAction(Map<String, dynamic> action) async {
    _ensureInRoom();
    await authenticate();
    final uid = myUid!;
    await roomRef!.child('actions').push().set({
      ...action,
      'fromUid': uid,
      'createdAt': ServerValue.timestamp,
    });
  }

  /// Publica o estado oficial da partida depois de _applyAction() / host.
  Future<void> publishState(
    Map<String, dynamic> state, {
    String? hostUid,
  }) async {
    _ensureInRoom();
    await authenticate();
    final uid = myUid!;
    final room = roomRef!;
    final snap = await room.get();
    if (!snap.exists) throw StateError('Sala não encontrada.');
    final info = OnlineRoomInfo.fromSnapshot(snap);
    if (info.hostId != uid && info.hostId != hostUid) {
      throw StateError('Apenas o host pode publicar o estado oficial.');
    }
    await room.update({
      'state': state,
      'updatedAt': ServerValue.timestamp,
    });
  }

  /// Marca/desmarca a presença do meu UID sem apagar a sala.
  Future<void> setConnected(bool connected) async {
    if (_roomId == null || myUid == null) return;
    await roomRef!.child('players/$myUid/connected').set(connected);
    await roomRef!.update({'updatedAt': ServerValue.timestamp});
  }

  /// Saída normal. Se for host e deleteIfHost=true, a sala inteira é removida.
  Future<void> leaveRoom({bool deleteIfHost = false}) async {
    final room = roomRef;
    final uid = myUid;
    if (room == null || uid == null) {
      await _stopRoomListener();
      _roomId = null;
      return;
    }

    try {
      final snap = await room.get();
      if (snap.exists) {
        final info = OnlineRoomInfo.fromSnapshot(snap);
        if (deleteIfHost && info.hostId == uid) {
          await room.remove();
        } else {
          await room.child('players/$uid').remove();
          await room.update({'updatedAt': ServerValue.timestamp});
        }
      }
    } finally {
      await _stopRoomListener();
      _roomId = null;
    }
  }

  /// Host: remove a sala explicitamente.
  Future<void> closeRoom() => leaveRoom(deleteIfHost: true);

  /// Remove uma ação da fila depois que o host a processou.
  /// Isso evita que ações antigas sejam reaplicadas ao reconectar.
  Future<void> consumeAction(String actionId) async {
    _ensureInRoom();
    if (actionId.trim().isEmpty) return;
    await roomRef!.child('actions/${actionId.trim()}').remove();
  }

  /// Host remove outro UID da sala. A lógica visual pode ficar no PlayPage.
  Future<void> kick(String uid) async {
    _ensureInRoom();
    await authenticate();
    final room = roomRef!;
    final snap = await room.get();
    if (!snap.exists) throw StateError('Sala não encontrada.');
    final info = OnlineRoomInfo.fromSnapshot(snap);
    if (info.hostId != myUid) {
      throw StateError('Somente o host pode remover jogadores.');
    }
    if (uid == myUid) {
      throw StateError('O host não pode remover a si mesmo.');
    }
    await room.child('players/$uid').remove();
    await room.update({'updatedAt': ServerValue.timestamp});
  }

  Future<OnlineRoomInfo> getCurrentRoom() async {
    _ensureInRoom();
    return _readRoom(_roomId!);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    await _stopRoomListener();
    await _roomController.close();
    await _actionController.close();
    await _rawEventController.close();
  }

  void _listenToRoom() {
    _stopRoomListener();
    final room = roomRef;
    if (room == null) return;

    _roomSubscription = room.onValue.listen((event) {
      if (!_roomController.isClosed) {
        try {
          final info = OnlineRoomInfo.fromSnapshot(event.snapshot);
          _roomController.add(info);
          _rawEventController.add(event);
        } catch (_) {}
      }
    });

    _actionSubscription = room.child('actions').onChildAdded.listen((event) {
      if (_actionController.isClosed) return;
      final raw = event.snapshot.value;
      if (raw is! Map) return;
      final action = Map<String, dynamic>.from(
          raw.map((key, value) => MapEntry(key.toString(), value)));
      action['actionId'] = event.snapshot.key;
      _actionController.add(action);
    });
  }

  Future<void> _stopRoomListener() async {
    await _roomSubscription?.cancel();
    await _actionSubscription?.cancel();
    _roomSubscription = null;
    _actionSubscription = null;
  }

  Future<OnlineRoomInfo> _readRoom(String code) async {
    final snap = await _database.ref('rooms/$code').get();
    if (!snap.exists) {
      throw StateError('Sala não encontrada.');
    }
    return OnlineRoomInfo.fromSnapshot(snap);
  }

  Future<String> _generateRoomCode() async {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    for (var attempt = 0; attempt < 20; attempt++) {
      final code = List.generate(
        6,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      final snap = await _database.ref('rooms/$code').get();
      if (!snap.exists) return code;
    }
    throw StateError('Não foi possível gerar um código de sala único.');
  }

  static String _normalizeRoomCode(String value) =>
      value.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static String _sanitizeName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Jogador';
    return trimmed.length <= 40 ? trimmed : trimmed.substring(0, 40);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('OnlineMatch já foi encerrado.');
    }
  }

  void _ensureInRoom() {
    _ensureOpen();
    if (_roomId == null || _roomId!.isEmpty) {
      throw StateError('Você não está em uma sala online.');
    }
  }
}
