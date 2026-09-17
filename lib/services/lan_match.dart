import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Mesa em rede local (mesmo Wi-Fi), sem servidor e sem internet.
// Um aparelho HOSPEDA (ServerSocket TCP) e os outros ENTRAM pelo IP.
// Protocolo JSON separado por \n:
//  host -> todos: {"type":"state", players, tokens, effects, ...}
//  guest -> host: {"type":"hello","name"} ou {"type":"action", ...}
// O host é a fonte da verdade: aplica a ação e retransmite o estado.

typedef JsonCallback = void Function(Map<String, dynamic> msg);
typedef PeerCallback = void Function(int count);

class LanMatch {
  static const port = 40404;

  static Future<String> localIp() async {
    final ips = await allIps();
    return ips.isEmpty ? '127.0.0.1' : ips.first;
  }

  /// Todos os IPv4 locais (Wi-Fi, hotspot...). O host alterna
  /// entre eles para achar o que o outro celular alcança.
  static Future<List<String>> allIps() async {
    final found = <String>[];
    final fallback = <String>[];
    try {
      final ifs = await NetworkInterface.list();
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (a.type != InternetAddressType.IPv4 || a.isLoopback) {
            continue;
          }
          final ip = a.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            if (!found.contains(ip)) found.add(ip);
          } else if (!fallback.contains(ip)) {
            fallback.add(ip);
          }
        }
      }
    } catch (_) {}
    return [...found, ...fallback];
  }
}

class LanHost {
  ServerSocket? _server;
  final List<Socket> _sockets = [];
  final Map<Socket, String> _names = {};
  JsonCallback? onMessage; // hello ou action de um guest
  PeerCallback? onPeers;

  int get peerCount => _sockets.length;

  Future<String> start() async {
    await stop();
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, LanMatch.port);
    _server!.listen(_handle);
    return await LanMatch.localIp();
  }

  void _handle(Socket s) {
    _sockets.add(s);
    onPeers?.call(_sockets.length);
    var buf = '';
    s.listen(
      (data) {
        buf += utf8.decode(data, allowMalformed: true);
        var idx = buf.indexOf('\n');
        while (idx >= 0) {
          final line = buf.substring(0, idx).trim();
          buf = buf.substring(idx + 1);
          if (line.isNotEmpty) {
            try {
              final msg = Map<String, dynamic>.from(jsonDecode(line));
              if (msg['type'] == 'hello') {
                final n = (msg['name'] ?? '').toString();
                if (n.isNotEmpty) _names[s] = n;
              }
              onMessage?.call(msg);
            } catch (_) {}
          }
          idx = buf.indexOf('\n');
        }
      },
      onDone: () => _drop(s),
      onError: (_) => _drop(s),
      cancelOnError: true,
    );
  }

  void _drop(Socket s) {
    _sockets.remove(s);
    _names.remove(s);
    try {
      s.destroy();
    } catch (_) {}
    onPeers?.call(_sockets.length);
  }

  /// Expulsa o aparelho pelo nome do jogador (host remove da mesa).
  void kick(String name) {
    for (final e in List<MapEntry<Socket, String>>.of(_names.entries)) {
      if (e.value == name) _drop(e.key);
    }
    _names.removeWhere((_, v) => v == name);
  }

  void broadcast(Map<String, dynamic> state) {
    if (_sockets.isEmpty) return;
    final line = '${jsonEncode({'type': 'state', ...state})}\n';
    for (final s in List<Socket>.of(_sockets)) {
      try {
        s.write(line);
      } catch (_) {
        _drop(s);
      }
    }
  }

  /// Aviso rápido (ex. resultado de dado) para todos os guests.
  void flash(String text) {
    if (_sockets.isEmpty) return;
    final line = '${jsonEncode({'type': 'flash', 'text': text})}\n';
    for (final s in List<Socket>.of(_sockets)) {
      try {
        s.write(line);
      } catch (_) {
        _drop(s);
      }
    }
  }

  Future<void> stop() async {
    for (final s in List<Socket>.of(_sockets)) {
      try {
        await s.close();
      } catch (_) {}
    }
    _sockets.clear();
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }
}

class LanGuest {
  Socket? _socket;
  JsonCallback? onState;
  void Function(String text)? onFlash;
  void Function()? onDisconnect;

  Future<void> connect(String ip, String name,
      {String theme = '', String bg = ''}) async {
    await disconnect();
    final entered = ip.trim();
    // Aceita tanto "192.168.0.10" quanto o endereço completo exibido
    // pelo anfitrião, "192.168.0.10:40404".
    var host = entered;
    var port = LanMatch.port;
    final match = RegExp(r'^([^:]+):(\d+)$').firstMatch(entered);
    if (match != null) {
      host = match.group(1)!;
      port = int.tryParse(match.group(2)!) ?? LanMatch.port;
    }
    _socket =
        await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    send({'type': 'hello', 'name': name, 'theme': theme, 'bg': bg});
    var buf = '';
    _socket!.listen(
      (data) {
        buf += utf8.decode(data, allowMalformed: true);
        var idx = buf.indexOf('\n');
        while (idx >= 0) {
          final line = buf.substring(0, idx).trim();
          buf = buf.substring(idx + 1);
          if (line.isNotEmpty) {
            try {
              final msg = Map<String, dynamic>.from(jsonDecode(line));
              if (msg['type'] == 'state') {
                onState?.call(msg);
              } else if (msg['type'] == 'flash') {
                onFlash?.call((msg['text'] ?? '').toString());
              }
            } catch (_) {}
          }
          idx = buf.indexOf('\n');
        }
      },
      onDone: () => onDisconnect?.call(),
      onError: (_) => onDisconnect?.call(),
      cancelOnError: true,
    );
  }

  void send(Map<String, dynamic> msg) {
    try {
      _socket?.write('${jsonEncode(msg)}\n');
    } catch (_) {}
  }

  Future<void> disconnect() async {
    final s = _socket;
    _socket = null;
    try {
      await s?.close();
    } catch (_) {}
  }
}
