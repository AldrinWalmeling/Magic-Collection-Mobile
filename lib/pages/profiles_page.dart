import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/app_events.dart';
import '../services/account_sync.dart';
import '../services/auth_service.dart';
import '../services/online_friends.dart';
import '../services/app_locale.dart';
import '../services/lan_presence.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../data/app_database.dart';
import '../theme/app_theme.dart';

// Perfis melhorados + amigos.
// - Cada perfil tem um CÓDIGO de convite (6 letras). Mostre seu
//   código ao seu irmão e cadastrem-se como amigos pelo código.
// - Amigos entram no setup da aba Jogar.
// - "Convidado" é o login local atual. Login Gmail real (OAuth +
//   servidor p/ partida online ao vivo) é a próxima fase.

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key});

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  List<Map<String, Object?>> _profiles = [];
  List<Map<String, Object?>> _friends = [];
  String? _activePath;

  // Amigos online (Firebase, identidade = UID; nome é display).
  final _friendsApi = OnlineFriends();
  final _friendCodeCtrl = TextEditingController();
  String _fbUid = '';
  String _fbCode = '';
  String _fbProfileId = '';
  String _fbProfileName = '';
  // UM código por perfil (MC-XXXXX), mesma identidade do aparelho.
  // É o único código exibido/copiado — sem segunda "id" legada.
  Map<String, String> _fbCodes = {};
  List<FriendRequest> _fbRequests = [];
  List<OnlineFriend> _fbFriends = [];
  final Map<String, Map<String, dynamic>> _fbPresence = {};
  StreamSubscription? _fbReqSub;
  StreamSubscription? _fbFrSub;
  final Map<String, StreamSubscription> _fbPresSubs = {};
  StreamSubscription? _authSub;
  bool _authFirst = true;

  @override
  void initState() {
    super.initState();
    _reload();
    // Garante o discovery ligado para mostrar quem está online na rede.
    LanPresence.ensureStarted();
    AppLocale.current.addListener(_onLocale);
    AppEvents.topVisible.addListener(_onBars);
    AppEvents.navVisible.addListener(_onBars);
    AppEvents.activeProfile.addListener(_onProfileChanged);
    AppEvents.authStopping.addListener(_onAuthStopping);
    _initOnlineFriends();
    // Troca de conta: sem usuário, derruba as escutas do UID velho
    // (senão dão permission-denied e crash); com usuário, religa.
    _authSub = AuthService.authChanges().listen((u) {
      if (_authFirst) {
        _authFirst = false;
        return;
      }
      if (!mounted) return;
      if (u == null) {
        _cancelOnlineSubs();
        setState(() {
          _fbUid = '';
          _fbCode = '';
          _fbRequests = [];
          _fbFriends = [];
          _fbPresence.clear();
        });
      } else {
        _initOnlineFriends();
      }
    });
  }

  /// Derruba todas as escutas RTDB (chamado no dispose, na troca de
  /// conta e ANTES do signOut via authStopping).
  void _cancelOnlineSubs() {
    _fbReqSub?.cancel();
    _fbFrSub?.cancel();
    _fbReqSub = null;
    _fbFrSub = null;
    for (final s in _fbPresSubs.values) {
      s.cancel();
    }
    _fbPresSubs.clear();
  }

  void _onAuthStopping() {
    _cancelOnlineSubs();
  }

  @override
  void dispose() {
    AppLocale.current.removeListener(_onLocale);
    AppEvents.topVisible.removeListener(_onBars);
    AppEvents.navVisible.removeListener(_onBars);
    AppEvents.activeProfile.removeListener(_onProfileChanged);
    AppEvents.authStopping.removeListener(_onAuthStopping);
    _authSub?.cancel();
    _cancelOnlineSubs();
    _friendCodeCtrl.dispose();
    super.dispose();
  }

  void _onLocale() {
    if (mounted) setState(() {});
  }

  void _onBars() {
    if (mounted) setState(() {});
  }

  void _onProfileChanged() {
    // Primeiro nome definido no setup (main) ou troca feita em outro
    // lugar: recarrega a lista para sair do "Convidado" sem restart.
    _reload();
  }

  static void _laterDispose(TextEditingController c) {
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        c.dispose();
      } catch (_) {}
    });
  }

  bool _friendOnline(String name, List<LanPeer> peers) {
    final key = name.trim().toLowerCase();
    if (key.isEmpty) return false;
    return peers.any((p) => p.name.trim().toLowerCase() == key);
  }

  /// Liga amigos online: código do perfil atual, caixa de entrada,
  /// lista e presença. Tudo pela identidade Firebase (UID).
  Future<void> _initOnlineFriends() async {
    _fbReqSub?.cancel();
    _fbFrSub?.cancel();
    for (final s in _fbPresSubs.values) {
      s.cancel();
    }
    _fbPresSubs.clear();
    try {
      // Nome local pendente: não cria identidade placeholder; o
      // evento de perfil recarrega após a escolha.
      if (await AppDatabase.instance.needsProfileSetup()) return;
      final uid = await _friendsApi.myUid;
      final ref = await _currentProfileRef();
      if (!mounted || ref == null) return;
      final code = await _friendsApi.ensureFriendCode(
        // Slot: 'main' p/ permanente (entre aparelhos), linha local
        // p/ convidado (reativável no aparelho, sem credencial).
        profileId: OnlineFriends.slotFor(
          isPermanent: AuthService.isPermanent,
          localRowId: ref['id']!,
        ),
        name: ref['name']!,
      );
      if (!mounted) return;
      setState(() {
        _fbUid = uid;
        _fbCode = code;
        _fbProfileId = OnlineFriends.slotFor(
          isPermanent: AuthService.isPermanent,
          localRowId: ref['id']!,
        );
        _fbProfileName = ref['name']!;
      });
      // Mapa de códigos da conta (tiles mostram o da conta ativa).
      _friendsApi.friendCodesOnce().then((codes) {
        if (!mounted) return;
        setState(() => _fbCodes = codes);
      });
      await _friendsApi.setPresence(name: ref['name']!);
      _fbReqSub?.cancel();
      _fbFrSub?.cancel();
      _fbReqSub = _friendsApi.watchRequests(uid).listen((reqs) {
        if (!mounted) return;
        // Mostra pedidos para qualquer perfil deste UID (marca o alvo).
        setState(() => _fbRequests = reqs);
      }, onError: (_) {});
      _fbFrSub = _friendsApi.watchFriends(uid).listen((friends) {
        if (!mounted) return;
        setState(() => _fbFriends = friends);
        _syncPresenceSubs();
      }, onError: (_) {});
    } catch (_) {}
  }

  /// Perfil ativo atual (id+nome) pelo registro global.
  Future<Map<String, String>?> _currentProfileRef() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getString('active_db_path') ?? '';
      final reg = await AppDatabase.instance.registryProfiles();
      for (final r in reg) {
        if ((r['database_path'] ?? '').toString() == active) {
          return {
            'id': (r['id'] ?? '').toString(),
            'name': (r['name'] ?? '').toString(),
          };
        }
      }
      if (reg.isNotEmpty) {
        return {
          'id': (reg.first['id'] ?? '').toString(),
          'name': (reg.first['name'] ?? '').toString(),
        };
      }
    } catch (_) {}
    return null;
  }

  void _syncPresenceSubs() {
    final want = {for (final f in _fbFriends) f.uid};
    for (final uid in _fbPresSubs.keys.toList()) {
      if (!want.contains(uid)) {
        _fbPresSubs.remove(uid)?.cancel();
        _fbPresence.remove(uid);
      }
    }
    for (final uid in want) {
      if (_fbPresSubs.containsKey(uid)) continue;
      _fbPresSubs[uid] = _friendsApi.watchPresence(uid).listen((p) {
        if (!mounted) return;
        setState(() => _fbPresence[uid] = p);
      }, onError: (_) {});
    }
  }

  Future<void> _addFriendByCode() async {
    final code = _friendCodeCtrl.text.trim().toUpperCase();
    if (code.isEmpty || _fbUid.isEmpty) return;
    try {
      final found = await _friendsApi.lookupCode(code);
      if (!mounted) return;
      if (found == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocale.t('fr_notfound'))));
        return;
      }      await _friendsApi.sendRequest(
        toUid: found['uid']!,
        toProfile: found['profileId']!,
        fromProfile: _fbProfileId,
        fromName: _fbProfileName,
        fromCode: _fbCode,
      );
      if (!mounted) return;
      setState(() => _friendCodeCtrl.clear());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocale.t('fr_sent'))));
    } catch (e) {
      if (!mounted) return;
      final msg = e is FormatException && e.message == 'stale'
          ? AppLocale.t('fr_code_dead')
          : '${AppLocale.t('cl_add_error')} $e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _respondRequest(FriendRequest req, bool accept) async {
    try {
      await _friendsApi.respondRequest(req, accept,
          myName: _fbProfileName, myCode: _fbCode, myProfile: _fbProfileId);
      if (mounted && accept) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocale.t('fr_accepted'))));
      }
    } catch (_) {}
  }

  Future<void> _removeOnlineFriend(OnlineFriend f) async {
    try {
      await _friendsApi.removeFriend(f.uid, f.profileId);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocale.t('fr_removed'))));
      }
    } catch (_) {}
  }

  /// Lista = união do banco atual + registro global (manda o registro).
  /// Assim ninguém some ao trocar de perfil: cada um tem seus dados
  /// no próprio arquivo, mas a lista mora no banco principal.
  Future<void> _reload() async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, Object?>> profiles = [];
    try {
      final local = await AppDatabase.instance.db.query('profiles');
      final reg = await AppDatabase.instance.registryProfiles();
      final byId = <String, Map<String, Object?>>{};
      for (final r in local) {
        final id = (r['id'] ?? '').toString();
        if (id.isNotEmpty) byId[id] = r;
      }
      for (final r in reg) {
        final id = (r['id'] ?? '').toString();
        if (id.isNotEmpty) byId[id] = r;
      }
      profiles = byId.values.toList();
      profiles.sort(((a, b) => ((b['last_opened_at'] ?? '').toString())
          .compareTo((a['last_opened_at'] ?? '').toString())));
    } catch (_) {}
    List<Map<String, Object?>> friends = [];
    try {
      friends =
          await AppDatabase.instance.db.query('friends', orderBy: 'name ASC');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _profiles = profiles;
        _friends = friends;
        _activePath = prefs.getString('active_db_path');
      });
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, c.text),
              child: Text(AppLocale.t('common_save'))),
        ],
      ),
    );
    _laterDispose(c);
    return result;
  }

  Future<void> _rename(Map<String, Object?> pr) async {
    final rowUid = (pr['firebase_uid'] ?? '').toString();
    final cur = AuthService.current;
    if (rowUid.isNotEmpty && (cur == null || rowUid != cur.uid)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('acc_switch_required'))));
      return;
    }
    final name = await _askName(AppLocale.t('prof_rename'),
        initial: (pr['name'] ?? '').toString());
    if (name == null || name.trim().isEmpty) return;
    final id = (pr['id'] ?? '').toString();
    try {
      await AppDatabase.instance.db.update('profiles', {'name': name.trim()},
          where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
    try {
      final reg = await AppDatabase.instance.registryProfiles();
      final match = reg.where((r) => (r['id'] ?? '').toString() == id);
      if (match.isNotEmpty) {
        final row = Map<String, Object?>.of(match.first);
        row['name'] = name.trim();
        await AppDatabase.instance.registryUpsert(row);
      }
    } catch (_) {}
    await _reload();
  }

  /// Uma linha por CONTA (ver gateOpen): nome, tipo e UID curto.
  /// Legado (sem uid) mostra tipo Local e pode ser adotado.
  String _accountLabel(Map<String, Object?> pr) {
    final rowUid = (pr['firebase_uid'] ?? '').toString();
    if (rowUid.isEmpty) return AppLocale.t('acc_type_local');
    var kind = (pr['auth_type'] ?? '').toString();
    if (kind.isEmpty) {
      final cur = AuthService.current;
      if (cur != null && rowUid == cur.uid) {
        kind = AuthService.accountKind;
      }
    }
    final type = switch (kind) {
      'google' => AppLocale.t('acc_type_google'),
      'email' => AppLocale.t('acc_type_email'),
      'guest' => AppLocale.t('acc_type_guest'),
      _ => AppLocale.t('acc_type_unknown'),
    };
    final short =
        rowUid.length > 6 ? '${rowUid.substring(0, 6)}…' : rowUid;
    return '$type • UID $short';
  }

  Future<void> _activate(Map<String, Object?> profile) async {
    final cur = AuthService.current;
    final rowUid = (profile['firebase_uid'] ?? '').toString();
    final gate = AppDatabase.gateOpen(
      rowUid: rowUid,
      currentUid: cur?.uid,
      signedIn: cur != null,
    );
    if (gate == 'need_login') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('acc_switch_required'))));
      return;
    }
    if (gate == 'legacy') {
      await _adoptLegacy(profile);
      return;
    }
    // Conta própria: troca transacional (arquivo + contexto).
    try {
      await AppDatabase.instance.switchToAccount(
        uid: cur!.uid,
        kind: AuthService.accountKind,
        displayName: (profile['name'] ?? '').toString(),
      );
    } catch (_) {}
    try {
      await LanPresence.ensureStarted();
    } catch (_) {}
    AppEvents.notifyProfileChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('prof_activated')
              .replaceAll('{n}', '${profile['name']}'))));
    }
    await _reload();
    _initOnlineFriends();
  }

  /// Adota arquivo legado na conta atual (explícito + confirmado).
  /// Recusado se a conta já tem arquivo (sem fusão silenciosa).
  Future<void> _adoptLegacy(Map<String, Object?> profile) async {
    final cur = AuthService.current;
    if (cur == null || !mounted) return;
    final name = (profile['name'] ?? '?').toString();
    final id = (profile['id'] ?? '').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('acc_adopt_title')),
        content: Text(AppLocale.t('acc_adopt_body')
            .replaceAll('{n}', name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('acc_adopt_confirm'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppDatabase.instance.openProfileRow(profile,
          bindUid: cur.uid);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('acc_adopt_blocked'))));
      return;
    }
    try {
      await LanPresence.ensureStarted();
    } catch (_) {}
    AppEvents.notifyProfileChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('prof_activated')
              .replaceAll('{n}', name))));
    }
    await _reload();
    _initOnlineFriends();
  }

  /// Exclui o perfil: confirma, troca para o principal se for o ativo,
  /// apaga o arquivo de dados e limpa o registro. O principal (save.db)
  /// nunca tem o arquivo apagado.
  Future<void> _deleteProfile(Map<String, Object?> pr) async {
    final name = (pr['name'] ?? '?').toString();
    final id = (pr['id'] ?? '').toString();
    final path = (pr['database_path'] ?? '').toString();
    final rowUid = (pr['firebase_uid'] ?? '').toString();
    final cur = AuthService.current;
    // Só dono (ou legado sem dono): nunca apaga conta de outro UID.
    if (rowUid.isNotEmpty && (cur == null || rowUid != cur.uid)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('acc_switch_required'))));
      return;
    }
    final mainPath = await AppDatabase.instance.mainDbPath();
    if (!mounted) return;
    if (path == mainPath) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocale.t('prof_nodelete'))));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('prof_del_title').replaceAll('{n}', name)),
        content: Text(AppLocale.t('prof_del_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('prof_delete'))),
        ],
      ),
    );
    if (ok != true) return;
    final wasActive = path == _activePath;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      await AppDatabase.instance.registryDelete(id);
    } catch (_) {}
    try {
      await AppDatabase.instance.db
          .delete('profiles', where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
    if (wasActive && cur != null) {
      // Reabre o arquivo da conta (vazio) e tenta restaurar do backup.
      // Cache local apagado; dados da conta voltam do servidor.
      try {
        await AppDatabase.instance.switchToAccount(
          uid: cur.uid,
          kind: AuthService.accountKind,
          displayName: (pr['name'] ?? '').toString(),
        );
      } catch (_) {}
      try {
        await AccountSync.syncNow();
      } catch (_) {}
    }
    // Sem restart: as telas recarregam do banco atual na hora.
    AppEvents.notifyProfileChanged();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocale.t('prof_deleted'))));
    }
    await _reload();
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('prof_copied').replaceAll('{c}', code))));
    }
  }

  Future<void> _addFriend() async {
    final nameC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        scrollable: true,
        title: Text(AppLocale.t('prof_addfriend')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameC,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration:
                    InputDecoration(labelText: AppLocale.t('prof_name_ex'))),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(AppLocale.t('common_add'))),
        ],
      ),
    );
    final name = nameC.text.trim();
    _laterDispose(nameC);
    if (ok != true) return;
    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocale.t('prof_fill'))));
      }
      return;
    }
    await AppDatabase.instance.db.insert('friends', {
      'id': const Uuid().v4().substring(0, 8),
      'name': name,
      'code': '',
    });
    await _reload();
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.characters.take(2).toString().toUpperCase();
    }
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppEvents.topVisible.value
          ? AppBar(
              title: Text(AppLocale.t('nav_profiles')),
              actions: [
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: AppLocale.t('common_focus'),
                  onPressed: AppEvents.toggleNav,
                ),
              ],
            )
          : null,
      // Sempre visível e CENTRALIZADO: no foco total o botão de voltar
      // as barras fica à direita, então não há sobreposição.
      // Sem FAB: contas vêm do login/vínculo, não de criação local.
      // Arquivos legados aparecem na lista e podem ser adotados.
      body: SafeArea(
        top: !AppEvents.topVisible.value,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(
              children: [
                Text(AppLocale.t('prof_my'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 8),
            for (final pr in _profiles) _profileTile(pr),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(AppLocale.t('prof_friends'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addFriend,
                  icon: const Icon(Icons.person_add, size: 16),
                  label: Text(AppLocale.t('prof_add')),
                ),
              ],
            ),
            Text(AppLocale.t('prof_hint'),
                style: const TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            if (_friends.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(AppLocale.t('prof_empty'),
                      style: const TextStyle(color: AppTheme.textMuted)),
                ),
              ),
            ValueListenableBuilder<List<LanPeer>>(
              valueListenable: LanPresence.instance.peers,
              builder: (_, onlinePeers, __) => Column(
                children: [
                  for (final f in _friends)
                    Builder(builder: (_) {
                      final online = _friendOnline(
                          (f['name'] ?? '').toString(), onlinePeers);
                      return Card(
                        child: ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                backgroundColor: AppTheme.goldSoft,
                                child: Text(
                                    _initials((f['name'] ?? '?').toString()),
                                    style: const TextStyle(
                                        color: AppTheme.gold,
                                        fontWeight: FontWeight.bold)),
                              ),
                              if (online)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: AppTheme.panel, width: 2),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Text((f['name'] ?? '').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: online
                              ? Text('• ${AppLocale.t('prof_online')}',
                                  style: const TextStyle(
                                      color: Colors.green))
                              : null,
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await AppDatabase.instance.db.delete('friends',
                                  where: 'id = ?', whereArgs: [f['id']]);
                              await _reload();
                            },
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _onlineFriendsSection(),
          ],
        ),
      ),
    );
  }

  /// Amigos online (Firebase): código do perfil, adicionar por código,
  /// pedidos e lista com presença. Identidade = UID, nome é display.
  Widget _onlineFriendsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_outlined,
                    size: 16, color: AppTheme.gold),
                const SizedBox(width: 6),
                Text(AppLocale.t('fr_online'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                      "${AppLocale.t('fr_code')}: ${_fbCode.isEmpty ? '…' : '#$_fbCode'}",
                      style: const TextStyle(
                          color: AppTheme.gold,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: AppLocale.t('prof_copy'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: _fbCode.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: '#$_fbCode'));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(AppLocale.t('prof_copied')
                                  .replaceAll('{c}', '#$_fbCode'))));
                        },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _friendCodeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: AppLocale.t('fr_add_hint'),
                      prefixIcon: const Icon(Icons.key),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _addFriendByCode,
                  icon: const Icon(Icons.person_add, size: 16),
                  label: Text(AppLocale.t('fr_add')),
                ),
              ],
            ),
            if (_fbRequests.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(AppLocale.t('fr_requests'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
              for (final r in _fbRequests)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    radius: 14,
                    backgroundColor: AppTheme.goldSoft,
                    child: Icon(Icons.person_add_alt,
                        size: 14, color: AppTheme.gold),
                  ),
                  title: Text(r.fromName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(r.fromCode,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => _respondRequest(r, true),
                        child: Text(AppLocale.t('fr_accept')),
                      ),
                      TextButton(
                        onPressed: () => _respondRequest(r, false),
                        child: Text(AppLocale.t('fr_decline'),
                            style: const TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            if (_fbFriends.isEmpty)
              Text(AppLocale.t('fr_empty'),
                  style: const TextStyle(color: AppTheme.textMuted))
            else
              for (final f in _fbFriends) _onlineFriendTile(f),
          ],
        ),
      ),
    );
  }

  Widget _onlineFriendTile(OnlineFriend f) {
    final pres = _fbPresence[f.uid];
    final online = (pres?['online'] as bool?) ?? false;
    final room = (pres?['room'] ?? '').toString();
    final status = !online
        ? AppLocale.t('fr_offline')
        : (room.isNotEmpty
            ? '${AppLocale.t('fr_playing')} ($room)'
            : AppLocale.t('fr_available'));
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppTheme.goldSoft,
            child: Text(_initials(f.name.isEmpty ? '?' : f.name),
                style: const TextStyle(
                    color: AppTheme.gold,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: online ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.panel, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(status,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: online ? Colors.green : AppTheme.textMuted,
              fontSize: 12)),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 18),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: () => _removeOnlineFriend(f),
      ),
    );
  }

  Widget _profileTile(Map<String, Object?> pr) {
    final isActive = pr['database_path'] == _activePath;
    // Cada linha tem seu código (slot próprio: linha local p/
    // convidado, 'main' p/ permanente). Fallback do ativo.
    var code = _fbCodes[(pr['id'] ?? '').toString()] ?? '';
    if (code.isEmpty && isActive) {
      code = _fbCodes[OnlineFriends.accountProfileId] ?? '';
    }
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.gold,
          child: Text(_initials((pr['name'] ?? '?').toString()),
              style: const TextStyle(
                  color: Color(0xFF14161D), fontWeight: FontWeight.bold)),
        ),
        title: Text((pr['name'] ?? '').toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                isActive ? AppLocale.t('prof_active') : AppLocale.t('prof_tap'),
                style: const TextStyle(color: AppTheme.textMuted)),
            Text(_accountLabel(pr),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 11)),
            if (code.isNotEmpty)
              InkWell(
                onTap: () => _copyCode(code),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${AppLocale.t('prof_code')}: #$code',
                        style: const TextStyle(
                            color: AppTheme.gold, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    const Icon(Icons.copy, size: 14, color: AppTheme.gold),
                  ],
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'rename') {
              _rename(pr);
            } else if (v == 'delete') {
              _deleteProfile(pr);
            } else if (v == 'code' && code.isNotEmpty) {
              _copyCode(code);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
                value: 'rename', child: Text(AppLocale.t('prof_rename'))),
            if (code.isNotEmpty)
              PopupMenuItem(
                  value: 'code', child: Text(AppLocale.t('prof_copy'))),
            PopupMenuItem(
                value: 'delete', child: Text(AppLocale.t('prof_delete'))),
          ],
        ),
        onTap: () => _activate(pr),
      ),
    );
  }
}
