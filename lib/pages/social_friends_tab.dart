import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../services/online_friends.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import 'profiles_page.dart';
import 'public_profile_page.dart';

// Amigos: código de convite, adicionar por código, pedidos e lista
// com presença. Toque abre o perfil público do amigo.
// Perfis locais (multi-conta neste aparelho) continuam em Perfis.
class FriendsTab extends StatefulWidget {
  const FriendsTab({super.key});

  @override
  State<FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<FriendsTab> {
  final _friendsApi = OnlineFriends();
  final _codeCtrl = TextEditingController();
  String _uid = '';
  String _code = '';
  String _profileId = '';
  String _profileName = '';
  List<FriendRequest> _requests = [];
  List<OnlineFriend> _friends = [];
  final Map<String, Map<String, dynamic>> _presence = {};
  StreamSubscription? _reqSub;
  StreamSubscription? _frSub;
  final Map<String, StreamSubscription> _presSubs = {};
  StreamSubscription? _authSub;
  bool _authFirst = true;
  bool _sending = false;
  bool _refreshing = false;
  // Perfis vivos dos amigos (nick/avatar atuais do servidor).
  final Map<String, Map<String, dynamic>> _liveProfiles = {};
  final _directory = CommunityService();

  @override
  void initState() {
    super.initState();
    _init();
    AppEvents.socialTab.addListener(_onSocialTab);
    AppEvents.activeProfile.addListener(_onProfile);
    AppEvents.authStopping.addListener(_onAuthStopping);
    _authSub = AuthService.authChanges().listen((_) {
      if (_authFirst) {
        _authFirst = false;
        return;
      }
      if (mounted) _init();
    });
  }

  @override
  void dispose() {
    _reqSub?.cancel();
    _frSub?.cancel();
    _authSub?.cancel();
    AppEvents.socialTab.removeListener(_onSocialTab);
    AppEvents.activeProfile.removeListener(_onProfile);
    AppEvents.authStopping.removeListener(_onAuthStopping);
    for (final s in _presSubs.values) {
      s.cancel();
    }
    _presSubs.clear();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _cancelAll() {
    _reqSub?.cancel();
    _frSub?.cancel();
    _reqSub = null;
    _frSub = null;
    for (final s in _presSubs.values) {
      s.cancel();
    }
    _presSubs.clear();
    _presence.clear();
  }

  void _onProfile() {
    if (mounted) _init();
  }

  /// Sessão caindo: derruba as escutas do UID velho ANTES do signOut
  /// completar (sem ler presence/friends sem permissão depois).
  void _onAuthStopping() {
    _cancelAll();
  }

  void _onSocialTab() {
    // Voltou para Amigos: atualiza silencioso (sem piscar).
    if (AppEvents.socialTab.value == 2 && mounted) {
      _refresh();
    }
  }

  /// Recarga manual (pull) ou ao voltar: nunca em paralelo.
  /// Limpa os perfis vivos para buscar tudo do zero.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      _liveProfiles.clear();
      await _init();
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _init() async {
    _cancelAll();
    // Sem usuário (ex. logo após logout): não recarrega nada e,
    // principalmente, não cria sessão (sem auto-entrada).
    if (AuthService.current == null) {
      if (mounted) {
        setState(() {
          _uid = '';
          _code = '';
          _requests = [];
          _friends = [];
        });
      }
      return;
    }
    try {
      // Nome local ainda não escolhido (diálogo inicial): não cria
      // identidade placeholder; o evento de perfil recarrega depois
      // com o nome real (conta nova) ou preserva (conta existente).
      if (await AppDatabase.instance.needsProfileSetup()) {
        if (mounted) setState(() => _uid = '');
        return;
      }
      final uid = await _friendsApi.myUid;
      final ref = await AppDatabasePrefs.activeProfileRef();
      if (!mounted) return;
      if ((ref['id'] ?? '').isEmpty) {
        setState(() => _uid = uid);
        return;
      }
      final pid = OnlineFriends.slotFor(
        isPermanent: AuthService.isPermanent,
        localRowId: ref['id']!,
      );
      final code = await _friendsApi.ensureFriendCode(
        // Identidade da CONTA p/ permanente; linha local p/ convidado.
        profileId: pid,
        name: ref['name']!,
      );
      if (!mounted) return;
      setState(() {
        _uid = uid;
        _code = code;
        _profileId = pid;
        _profileName = ref['name']!;
      });
      await _friendsApi.setPresence(name: ref['name']!);
      _reqSub?.cancel();
      _frSub?.cancel();
      _reqSub = _friendsApi.watchRequests(uid).listen((reqs) {
        if (mounted) setState(() => _requests = reqs);
      }, onError: (_) {});
      _frSub = _friendsApi.watchFriends(uid).listen((friends) {
        if (!mounted) return;
        setState(() => _friends = friends);
        _syncPresence();
        _refreshLiveProfiles();
      }, onError: (_) {});
    } catch (_) {}
  }

  /// Perfis vivos (nick/avatar atuais do servidor, não o snapshot
  /// gravado ao aceitar). Melhor esforço, sem travar a lista.
  Future<void> _refreshLiveProfiles() async {
    final uids = [for (final f in _friends) f.uid];
    if (uids.isEmpty || !mounted) return;
    try {
      final results = await Future.wait([
        for (final u in uids)
          _directory.publicProfile(u).catchError(
              (_) => <String, dynamic>{}),
      ]);
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < uids.length; i++) {
          final m = results[i];
          if (m is Map<String, dynamic>) {
            _liveProfiles[uids[i]] = m;
          }
        }
      });
    } catch (_) {}
  }

  void _syncPresence() {
    final want = {for (final f in _friends) f.uid};    for (final uid in _presSubs.keys.toList()) {
      if (!want.contains(uid)) {
        _presSubs.remove(uid)?.cancel();
        _presence.remove(uid);
      }
    }
    for (final uid in want) {
      if (_presSubs.containsKey(uid)) continue;
      _presSubs[uid] = _friendsApi.watchPresence(uid).listen((p) {
        if (mounted) setState(() => _presence[uid] = p);
      }, onError: (_) {});
    }
  }

  Future<void> _addByCode() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.isEmpty || _uid.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final found = await _friendsApi.lookupCode(code);
      if (!mounted) return;
      if (found == null) {
        AppToast.show(context, AppLocale.t('fr_notfound'));
        return;
      }
      await _friendsApi.sendRequest(
        toUid: found['uid']!,
        toProfile: found['profileId']!,
        fromProfile: _profileId,
        fromName: _profileName,
        fromCode: _code,
      );
      if (!mounted) return;
      setState(() => _codeCtrl.clear());
      AppToast.show(context, AppLocale.t('fr_sent'));
    } catch (e) {
      if (!mounted) return;
      final msg = e is FormatException && e.message == 'stale'
          ? AppLocale.t('fr_code_dead')
          : '${AppLocale.t('cl_add_error')} $e';
      AppToast.show(context, msg);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _changeCode() async {
    final c = TextEditingController(text: _code);
    var busy = false;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: Text(AppLocale.t('fr_edit_code')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: c,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  prefixText: '# ',
                  hintText: AppLocale.t('fr_code_hint'),
                ),
              ),
              const SizedBox(height: 8),
              Text(AppLocale.t('fr_code_rules'),
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppLocale.t('common_cancel'))),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setD(() => busy = true);
                      try {
                        final code =
                            await _friendsApi.setFriendCode(
                          profileId: _profileId,
                          rawCode: c.text,
                        );
                        if (ctx.mounted) Navigator.pop(ctx, code);
                      } catch (e) {
                        setD(() => busy = false);
                        AppToast.show(
                            ctx,
                            e is FormatException && e.message == 'taken'
                                ? AppLocale.t('fr_taken')
                                : AppLocale.t('fr_invalid'));
                      }
                    },
              child: Text(AppLocale.t('common_save')),
            ),
          ],
        ),
      ),
    );
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        c.dispose();
      } catch (_) {}
    });
    if (result == null || result.isEmpty || !mounted) return;
    setState(() => _code = result);
    AppToast.show(context,
        AppLocale.t('fr_changed').replaceAll('{c}', '#$result'));
  }

  Future<void> _respond(FriendRequest req, bool accept) async {    try {
      await _friendsApi.respondRequest(req, accept,
          myName: _profileName, myCode: _code, myProfile: _profileId);
      if (mounted && accept) {
        AppToast.show(context, AppLocale.t('fr_accepted'));
      }
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    }
  }

  Future<void> _remove(OnlineFriend f) async {
    try {
      await _friendsApi.removeFriend(f.uid, f.profileId);
      if (mounted) {
        AppToast.show(context, AppLocale.t('fr_removed'));
      }
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.characters.take(2).toString().toUpperCase();
    }
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // Mesmo padrão da Comunidade: arrastar do topo atualiza.
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                          '${AppLocale.t('fr_code')}: ${_code.isEmpty ? '…' : '#$_code'}',
                          style: const TextStyle(
                              color: AppTheme.gold,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      tooltip: AppLocale.t('fr_edit_code'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 32, minHeight: 32),
                      onPressed: (_code.isEmpty || _sending)
                          ? null
                          : () => _changeCode(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: AppLocale.t('prof_copy'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 32, minHeight: 32),
                      onPressed: _code.isEmpty
                          ? null
                          : () {
                              Clipboard.setData(
                                  ClipboardData(text: '#$_code'));
                              AppToast.show(
                                  context,
                                  AppLocale.t('prof_copied')
                                      .replaceAll('{c}', '#$_code'));
                            },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _codeCtrl,
                        textCapitalization:
                            TextCapitalization.characters,
                        decoration: InputDecoration(
                          hintText: AppLocale.t('fr_add_hint'),
                          prefixIcon: const Icon(Icons.key),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _sending ? null : _addByCode,
                      icon: const Icon(Icons.person_add, size: 16),
                      label: Text(AppLocale.t('fr_add')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_requests.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(AppLocale.t('fr_requests'),
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 15)),
          for (final r in _requests)
            Card(
              child: ListTile(
                dense: true,
                leading: const CircleAvatar(
                  radius: 14,
                  backgroundColor: AppTheme.goldSoft,
                  child: Icon(Icons.person_add_alt,
                      size: 14, color: AppTheme.gold),
                ),
                title: Text(r.fromName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(r.fromCode,
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _respond(r, true),
                      child: Text(AppLocale.t('fr_accept')),
                    ),
                    TextButton(
                      onPressed: () => _respond(r, false),
                      child: Text(AppLocale.t('fr_decline'),
                          style: const TextStyle(
                              color: Colors.redAccent)),
                    ),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: 8),
        Text(AppLocale.t('prof_friends'),
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 4),
        if (_friends.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(AppLocale.t('fr_empty'),
                  style:
                      const TextStyle(color: AppTheme.textMuted)),
            ),
          )
        else
          for (final f in _friends) _friendTile(f),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon:
              const Icon(Icons.manage_accounts_outlined, size: 18),
          label: Text(AppLocale.t('soc_manage_profiles')),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const ProfilesPage()),
          ),
        ),
      ],
      ),
    );
  }

  Widget _friendTile(OnlineFriend f) {
    final pres = _presence[f.uid];
    final online = (pres?['online'] as bool?) ?? false;
    final room = (pres?['room'] ?? '').toString();
    // Nome/avatar VIVOS do servidor (o nó de amizade guarda snapshot
    // da época do aceite e fica defasado).
    final live = _liveProfiles[f.uid];
    final liveName = (live?['displayName'] ?? '').toString().trim();
    final liveAvatar = (live?['avatar'] ?? '').toString().trim();
    final name = liveName.isEmpty ? f.name : liveName;
    final status = !online
        ? AppLocale.t('fr_offline')
        : (room.isNotEmpty
            ? '${AppLocale.t('fr_playing')} ($room)'
            : AppLocale.t('fr_available'));
    return Card(
      child: ListTile(
        dense: true,
        leading: Stack(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: AppTheme.goldSoft,
              child: liveAvatar.isNotEmpty
                  ? Text(liveAvatar,
                      style: const TextStyle(fontSize: 14))
                  : Text(_initials(name.isEmpty ? '?' : name),
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
        title: Text(name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: online ? Colors.green : AppTheme.textMuted,
                fontSize: 12)),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          padding: EdgeInsets.zero,
          constraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () => _remove(f),
        ),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PublicProfilePage(userId: f.uid)),
        ),
      ),
    );
  }
}
