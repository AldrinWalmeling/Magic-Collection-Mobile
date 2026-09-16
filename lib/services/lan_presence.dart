import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../data/app_database.dart';
import 'lan_match.dart';

/// Quem está na mesma rede Wi-Fi — sem servidor (gambiarra honesta).
///
/// Cada aparelho anuncia (UDP broadcast 255.255.255.255:40405, a cada 3s):
///   {t: beacon, id, name, hasTable, players, port}
/// e escuta os anúncios dos outros. Quem some há >9s sai da lista.
/// Entrar na mesa = TCP direto no IP anunciado ([LanHost]/[LanGuest]).
/// Convidar = UDP unicast {t: invite, from} — o IP da mesa é o IP de
/// origem do pacote, então não precisa saber o IP do anfitrião.
///
/// Limitações: depende de broadcast na rede (a maioria dos roteadores e
/// hotspots de celular permite; rede de hotel/empresa pode bloquear).
/// O IP manual continua existindo como fallback.
class LanPeer {
  final String id;
  final String name;
  final String ip;
  final bool hasTable;
  final int players;
  final int port;
  final DateTime lastSeen;

  LanPeer({
    required this.id,
    required this.name,
    required this.ip,
    required this.hasTable,
    required this.players,
    required this.port,
    required this.lastSeen,
  });

  LanPeer copyWith({bool? hasTable, int? players, DateTime? lastSeen}) =>
      LanPeer(
        id: id,
        name: name,
        ip: ip,
        hasTable: hasTable ?? this.hasTable,
        players: players ?? this.players,
        port: port,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

class LanPresence {
  LanPresence._();
  static final LanPresence instance = LanPresence._();

  static const udpPort = 40405;
  static const _beaconMs = 3000;
  static const _expiryMs = 9000;

  RawDatagramSocket? _sock;
  Timer? _beaconT;
  Timer? _pruneT;
  final ValueNotifier<List<LanPeer>> peers = ValueNotifier([]);

  /// (nome de quem convidou, ip da mesa dele).
  void Function(String fromName, String tableIp)? onInvite;

  String _myId = '';
  String _myName = '';
  bool _hasTable = false;
  int _players = 0;
  final int _tablePort = LanMatch.port;

  bool get running => _sock != null;

  /// Idempotente: chama de Play e Perfis sem medo. Barato (1 beacon/3s).
  static Future<void> ensureStarted() async {
    final inst = instance;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id') ?? '';
    if (id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }
    var name = '';
    try {
      name = (await AppDatabase.instance.activeProfileName()).trim();
    } catch (_) {}
    if (name.isEmpty) name = 'Jogador';
    if (inst._sock != null) {
      inst._myId = id;
      inst._myName = name;
      return;
    }
    await inst.start(deviceId: id, name: name);
  }

  Future<void> start(
      {required String deviceId, required String name}) async {
    _myId = deviceId;
    _myName = name;
    if (_sock != null) return;
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort,
          reuseAddress: true);
      _sock!.broadcastEnabled = true;
      _sock!.listen(_onDatagram);
      _beaconT =
          Timer.periodic(const Duration(milliseconds: _beaconMs), (_) {
        _sendBeacon();
      });
      _pruneT = Timer.periodic(const Duration(seconds: 3), (_) => _prune());
      _sendBeacon();
    } catch (_) {
      // Rede sem broadcast/UDP: a lista fica vazia e o IP manual cobre.
      _sock = null;
    }
  }

  void updateIdentity(String name) {
    if (name.trim().isNotEmpty) _myName = name.trim();
  }

  Future<void> stop() async {
    _beaconT?.cancel();
    _pruneT?.cancel();
    _beaconT = null;
    _pruneT = null;
    try {
      _sock?.close();
    } catch (_) {}
    _sock = null;
    peers.value = [];
  }

  /// Chamado pela mesa sempre que o estado muda (via _broadcast).
  /// Só guarda os campos — o beacon periódico lê daqui.
  void setTable({required bool open, int players = 0}) {
    _hasTable = open;
    _players = players;
  }

  /// Convida o aparelho: ele recebe um diálogo "entrar na mesa?".
  void invite(String ip) {
    final s = _sock;
    if (s == null) return;
    try {
      s.send(
          utf8.encode(jsonEncode(
              {'t': 'invite', 'id': _myId, 'from': _myName})),
          InternetAddress(ip),
          udpPort);
    } catch (_) {}
  }

  void _sendBeacon() {
    final s = _sock;
    if (s == null || _myId.isEmpty) return;
    try {
      s.send(
          utf8.encode(jsonEncode({
            't': 'beacon',
            'id': _myId,
            'name': _myName,
            'hasTable': _hasTable,
            'players': _players,
            'port': _tablePort,
          })),
          InternetAddress('255.255.255.255'),
          udpPort);
    } catch (_) {}
  }

  void _onDatagram(RawSocketEvent ev) {
    if (ev != RawSocketEvent.read) return;
    final s = _sock;
    if (s == null) return;
    Datagram? d;
    while ((d = s.receive()) != null) {
      try {
        final dg = d!;
        final m =
            Map<String, dynamic>.from(jsonDecode(utf8.decode(dg.data)));
        if ((m['id'] ?? '').toString() == _myId) continue;
        if (m['t'] == 'beacon') {
          _upsert(LanPeer(
            id: (m['id'] ?? '').toString(),
            name: (m['name'] ?? 'Jogador').toString(),
            ip: dg.address.address,
            hasTable: (m['hasTable'] as bool?) ?? false,
            players: (m['players'] as num?)?.toInt() ?? 0,
            port: (m['port'] as num?)?.toInt() ?? LanMatch.port,
            lastSeen: DateTime.now(),
          ));
        } else if (m['t'] == 'invite') {
          onInvite?.call(
              (m['from'] ?? 'Jogador').toString(), dg.address.address);
        }
      } catch (_) {}
    }
  }

  void _upsert(LanPeer peer) {
    final list = peers.value.toList();
    final i = list.indexWhere((p) => p.id == peer.id);
    if (i >= 0) {
      list[i] = peer;
    } else {
      list.add(peer);
    }
    peers.value = list;
  }

  void _prune() {
    final now = DateTime.now();
    final list = peers.value
        .where((p) =>
            now.difference(p.lastSeen).inMilliseconds < _expiryMs)
        .toList();
    if (list.length != peers.value.length) peers.value = list;
  }
}
