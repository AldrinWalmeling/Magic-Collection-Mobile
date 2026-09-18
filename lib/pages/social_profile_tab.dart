import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_database.dart';
import '../services/account_sync.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../services/currency_service.dart';
import '../services/online_friends.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';
import 'community_deck_detail_page.dart';
import 'authentication_screen.dart';
import 'profiles_page.dart';

const _avatars = [
  '🧙', '🧝', '🧛', '🐉', '🦁', '🦅',
  '🐺', '🦈', '🌑', '🔥', '⚡', '💎',
  '🐻', '🦊', '🐸', '🐙', '🦄', '🐲',
  '🦂', '🦇', '🌊', '🌪️', '🌳', '🍄',
  '🌙', '☀️', '⭐', '🌈', '❄️', '🌋',
  '⚔️', '🛡️', '🏹', '🔮', '📜', '💀',
  '👑', '🎭', '👺', '🤖', '👽', '🎃',
  '🃏', '♠️', '♥️', '♣️', '♦️', '🌌',
  '🐯',
];
const _avatarsPreview = 14;

// Meu Perfil: identidade pública (nome/bio/avatar exibidos na
// Comunidade), código de amigo, estatísticas, decks publicados,
// favoritos e acesso aos perfis locais.
class MyProfileTab extends StatefulWidget {
  const MyProfileTab({super.key});

  @override
  State<MyProfileTab> createState() => _MyProfileTabState();
}

class _MyProfileTabState extends State<MyProfileTab> {
  final _service = CommunityService();
  final _friendsApi = OnlineFriends();
  final _nameC = TextEditingController();
  final _bioC = TextEditingController();
  String _avatar = _avatars.first;
  String _code = '';
  String _profileId = '';
  bool _editingName = false;
  int _published = 0;
  int _favorites = 0;
  int _likesReceived = 0;
  List<CommunityDeck> _myDecks = [];
  List<CommunityDeck> _favDecks = [];
  Map<String, dynamic> _collection = {};
  bool _loading = true;
  bool _saving = false;
  bool _syncing = false;
  StreamSubscription? _profileSub;
  StreamSubscription? _authSub;
  bool _authFirst = true;

  @override
  void initState() {
    super.initState();
    _load();
    AppEvents.activeProfile.addListener(_onProfile);
    // Troca de conta: recarrega perfil/decks/favoritos do novo UID
    // (nada da conta anterior pode vazar).
    _authSub = AuthService.authChanges().listen((_) {
      if (_authFirst) {
        _authFirst = false;
        return;
      }
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _nameC.dispose();
    _bioC.dispose();
    _profileSub?.cancel();
    _authSub?.cancel();
    AppEvents.activeProfile.removeListener(_onProfile);
    super.dispose();
  }

  void _onProfile() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    // Sem usuário: não busca nada (nunca cria sessão sozinho).
    if (AuthService.current == null) return;
    // Nome local pendente: aguarda a escolha (ver Amigos).
    if (await AppDatabase.instance.needsProfileSetup()) return;
    setState(() => _loading = true);
    try {
      final uid = await _friendsApi.myUid;
      final results = await Future.wait([
        _service.publicProfile(uid),
        _service.decksByAuthor(uid),
        _service.myFavoriteIds().catchError((_) => <String>[]),
        _service.listDecks().catchError((_) => <CommunityDeck>[]),
        _service.publicCollection(uid),
      ]);
      final profile = results[0] as Map<String, dynamic>;
      final mine = results[1] as List<CommunityDeck>;
      final favIds = (results[2] as List).map((e) => '$e').toSet();
      final all = results[3] as List<CommunityDeck>;
      final collection = results[4] as Map<String, dynamic>;
      String code = '';
      String profileId = OnlineFriends.accountProfileId;
      String localName = '';
      try {
        final ref = await AppDatabasePrefs.activeProfileRef();
        localName = (ref['name'] ?? '').toString();
        if ((ref['id'] ?? '').isNotEmpty) {
          profileId = OnlineFriends.slotFor(
            isPermanent: AuthService.isPermanent,
            localRowId: ref['id']!,
          );
          code = await _friendsApi.ensureFriendCode(
            profileId: profileId,
            name: ref['name']!,
          );
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _nameC.text = (profile['displayName'] ?? '').toString();
        // Conta nova sem display: mostra o nome local escolhido na
        // entrada (só exibição; grava no Salvar).
        if (_nameC.text.trim().isEmpty &&
            localName.isNotEmpty &&
            localName != 'Convidado') {
          _nameC.text = localName;
        }
        _bioC.text = (profile['bio'] ?? '').toString();
        final av = (profile['avatar'] ?? '').toString();
        if (av.isNotEmpty) _avatar = av;
        _code = code;
        _profileId = profileId;
        _editingName = false;
        _myDecks = mine;
        _published = mine.length;
        _likesReceived = mine.fold<int>(0, (s, d) => s + d.likes);
        _favDecks = [for (final d in all) if (favIds.contains(d.id)) d];
        _favorites = _favDecks.length;
        _collection = collection;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _service.savePublicProfile({
        'displayName': _nameC.text.trim(),
        'bio': _bioC.text.trim(),
        'avatar': _avatar,
        if (_code.isNotEmpty) 'friendCode': _code,
      });
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.show(context, AppLocale.t('soc_saved'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.show(context, '$e');
    }
  }

  Future<void> _toggleCollection(bool on) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      if (on) {
        final data = await _service.syncPublicCollection();
        if (!mounted) return;
        setState(() => _collection = data);
        AppToast.show(context, AppLocale.t('soc_synced'));
      } else {
        await _service.hidePublicCollection();
        if (!mounted) return;
        setState(() => _collection = {});
      }
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }
  Future<void> _unpublish(CommunityDeck d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('soc_unpublish_title')
            .replaceAll('{n}', d.name)),
        content: Text(AppLocale.t('soc_unpublish_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('soc_unpublish'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.unpublishDeck(d.id);
      if (!mounted) return;
      AppToast.show(context, AppLocale.t('soc_unpublished'));
      await _load();
    } catch (e) {
      if (mounted) AppToast.show(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          _editor(),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: _stat('$_published',
                      AppLocale.t('soc_stats_published'))),
              Expanded(
                  child: _stat('$_favorites',
                      AppLocale.t('soc_stats_favorites'))),
              Expanded(
                  child: _stat('$_likesReceived',
                      AppLocale.t('soc_stats_likes'))),
            ],
          ),
          const SizedBox(height: 8),
          _collectionCard(),
          const SizedBox(height: 8),
          _deckSection(
              AppLocale.t('soc_my_published'), _myDecks, true),
          const SizedBox(height: 8),
          _deckSection(
              AppLocale.t('soc_my_favorites'), _favDecks, false),
          const SizedBox(height: 8),
          _accountCard(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.manage_accounts_outlined, size: 18),
            label: Text(AppLocale.t('soc_manage_profiles')),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const ProfilesPage()),
            ).then((_) => _load()),
          ),
        ],
      ),
    );
  }

  Widget _editor() {
    final shownName = _nameC.text.trim().isEmpty
        ? AppLocale.t('soc_unknown_player')
        : _nameC.text.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar: toca para trocar (picker com "mostrar mais").
                InkWell(
                  onTap: _pickAvatar,
                  borderRadius: BorderRadius.circular(26),
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: AppTheme.goldSoft,
                        child: Text(_avatar,
                            style:
                                const TextStyle(fontSize: 26)),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: AppTheme.gold,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                              Icons.edit,
                              size: 12,
                              color: Color(0xFF14161D)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Nome: lápis edita ali mesmo.
                      if (_editingName)
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _nameC,
                                autofocus: true,
                                textCapitalization:
                                    TextCapitalization.words,
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: AppLocale.t(
                                      'soc_display_name'),
                                ),
                                onSubmitted: (_) => setState(
                                    () => _editingName = false),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.check,
                                  size: 18, color: AppTheme.gold),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 32, minHeight: 32),
                              onPressed: () => setState(
                                  () => _editingName = false),
                            ),
                          ],
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: Text(shownName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit,
                                  size: 16),
                              tooltip: AppLocale.t(
                                  'soc_edit_name'),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 32, minHeight: 32),
                              onPressed: () => setState(
                                  () => _editingName = true),
                            ),
                          ],
                        ),
                      if (_code.isNotEmpty)
                        Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () {
                                  Clipboard.setData(ClipboardData(
                                      text: '#$_code'));
                                  AppToast.show(
                                      context,
                                      AppLocale.t('prof_copied')
                                          .replaceAll(
                                              '{c}', '#$_code'));
                                },
                                child: Text(
                                    '${AppLocale.t('fr_code')}: #$_code',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: AppTheme.gold,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit,
                                  size: 14),
                              tooltip: AppLocale.t(
                                  'fr_edit_code'),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 28, minHeight: 28),
                              onPressed: _profileId.isEmpty
                                  ? null
                                  : () => _changeCode(),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bioC,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: AppLocale.t('soc_bio'),
                hintText: AppLocale.t('soc_bio_hint'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.save_outlined, size: 16),
                label: Text(AppLocale.t('soc_save')),
                onPressed: _saving ? null : _save,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAvatar() async {
    var expanded = false;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final list =
              expanded ? _avatars : _avatars.take(_avatarsPreview).toList();
          return AlertDialog(
            scrollable: true,
            title: Text(AppLocale.t('soc_pick_avatar')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final a in list)
                      InkWell(
                        onTap: () => Navigator.pop(ctx, a),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: _avatar == a
                                    ? AppTheme.gold
                                    : Colors.transparent,
                                width: 2),
                            color: _avatar == a
                                ? AppTheme.goldSoft
                                : null,
                          ),
                          child: Text(a,
                              style: const TextStyle(
                                  fontSize: 22)),
                        ),
                      ),
                  ],
                ),
                if (!expanded) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.expand_more, size: 16),
                    label:
                        Text(AppLocale.t('soc_show_more')),
                    onPressed: () =>
                        setD(() => expanded = true),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
    if (picked != null && picked.isNotEmpty && mounted) {
      setState(() => _avatar = picked);
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

  Widget _stat(String value, String label) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: AppTheme.gold)),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _collectionCard() {
    final sharing = _collection.isNotEmpty;
    final total = (_collection['totalCards'] as num?)?.toInt() ?? 0;
    final distinct = (_collection['distinctCards'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              value: sharing,
              contentPadding: EdgeInsets.zero,
              secondary: _syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.collections_bookmark_outlined,
                      color: AppTheme.gold),
              title: Text(AppLocale.t('soc_share_collection'),
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              subtitle: Text(
                  AppLocale.t('soc_share_collection_sub'),
                  style: const TextStyle(fontSize: 12)),
              onChanged: _syncing ? null : _toggleCollection,
            ),
            if (sharing)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                          '$total ${AppLocale.t('soc_total')} • $distinct ${AppLocale.t('soc_distinct')}',
                          style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 13)),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.sync, size: 16),
                      label: Text(AppLocale.t('soc_sync_now')),
                      onPressed: _syncing
                          ? null
                          : () => _toggleCollection(true),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Conta Firebase: visitante vira conta permanente (vincula,
  /// preserva tudo); conta permanente pode sair (dados locais ficam).
  Widget _accountCard() {
    final permanent = AuthService.isPermanent;
    final mail = AuthService.displayEmail;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    permanent
                        ? Icons.verified_user_outlined
                        : Icons.person_outline,
                    size: 18,
                    color: AppTheme.gold),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      permanent
                          ? (mail.isEmpty
                              ? AppLocale.t('auth_account')
                              : mail)
                          : AppLocale.t('auth_guest_account'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (permanent)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.logout, size: 16),
                  label: Text(AppLocale.t('auth_signout')),
                  onPressed: () => _confirmSignOut(false),
                ),
              )
            else ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.link, size: 16),
                  label: Text(AppLocale.t('auth_link_account')),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            const AuthenticationScreen(
                                linkMode: true)),
                  ).then((_) async {
                    if (!mounted) return;
                    await _load();
                    // Vinculação preserva o UID: os dados locais SÃO os
                    // da conta — envia (nunca restaura por cima).
                    if (!mounted) return;
                    try {
                      await AccountSync.syncNow(preferPush: true);
                    } catch (_) {}
                    if (mounted) _load();
                  }),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.logout, size: 16),
                  label: Text(AppLocale.t('auth_signout')),
                  onPressed: () => _confirmSignOut(true),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Sair: permanente faz signOut real; visitante PAUSA (sem signOut
  /// Firebase, que tornaria a conta irrecuperável) e volta ao login,
  /// onde "Conta deste dispositivo" retoma o mesmo UID/dados.
  Future<void> _confirmSignOut(bool guest) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('auth_signout_title')),
        content: Text(AppLocale.t(guest
            ? 'auth_signout_guest_body'
            : 'auth_signout_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('auth_signout'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (guest) {
        await AuthService.pauseGuest();
      } else {
        // Salva o estado atual na conta antes de sair.
        try {
          await AccountSync.push();
        } catch (_) {}
        await AuthService.signOut();
      }
      AccountSync.resetSession();
      // O AuthGate volta ao login sozinho; dados locais intactos.
    } catch (e) {
      if (mounted) {
        AppToast.show(
            context, AuthService.message(e, AppLocale.t));
      }
    }
  }

  Widget _deckSection(
      String title, List<CommunityDeck> decks, bool mine) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 4),
        if (decks.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(AppLocale.t('com_empty'),
                  style:
                      const TextStyle(color: AppTheme.textMuted)),
            ),
          )
        else
          for (final d in decks)
            Card(
              child: ListTile(
                dense: true,
                title: Text(d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: Text(
                    '${d.format.toUpperCase()} • ${d.cardCount} • ${CurrencyService.instance.formatUsd(d.priceUsd)} • 👍 ${d.likes}',
                    style: const TextStyle(fontSize: 12)),
                trailing: mine
                    ? PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'unpublish') _unpublish(d);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'unpublish',
                              child: Text(AppLocale.t(
                                  'soc_unpublish'))),
                        ],
                      )
                    : null,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => CommunityDeckDetailPage(
                          deckId: d.id)),
                ).then((_) => _load()),
              ),
            ),
      ],
    );
  }
}
