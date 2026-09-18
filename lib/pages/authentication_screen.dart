import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../services/app_locale.dart';
import '../services/auth_service.dart';
import '../services/online_friends.dart';
import '../theme/app_theme.dart';

// Entrada do app: Google, Email/senha (entrar ou criar) ou visitante.
//
// Dois fluxos separados e explícitos:
// - linkMode=false (tela de login, sem usuário): entra/cria/continua
//   como visitante. Nenhuma vinculação acontece aqui.
// - linkMode=true (aberta sobre um visitante): Google/Email VINCULAM
//   (preservam UID, coleção, decks e sociais). Se a credencial já for
//   de outra conta, dá erro e orienta a sair antes — nunca troca
//   sozinho. Botão de visitante escondido (já é visitante).
class AuthenticationScreen extends StatefulWidget {
  const AuthenticationScreen({super.key, this.linkMode = false});

  final bool linkMode;

  @override
  State<AuthenticationScreen> createState() =>
      _AuthenticationScreenState();
}

class _AuthenticationScreenState
    extends State<AuthenticationScreen> {
  final _mailC = TextEditingController();
  final _passC = TextEditingController();
  bool _busy = false;
  bool _create = false;
  bool _obscure = true;
  String? _error;
  String _lastAction = 'email';
  bool _showGuests = false;
  bool _loadingGuests = false;
  List<Map<String, Object?>> _guestRows = [];
  Map<String, String> _guestCodes = {};

  @override
  void dispose() {
    _mailC.dispose();
    _passC.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
      if (!mounted) return;
      // Fluxo inicial: o gate troca de tela sozinho. Vinculação:
      // volta para o perfil.
      if (Navigator.canPop(context)) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      // Entrar em outra conta com temporária ativa a abandona
      // (irrecuperável): confirmação explícita antes de prosseguir.
      if (e is StateError && e.message == 'auth_abandon_guest') {
        setState(() => _busy = false);
        await _confirmAbandon();
        return;
      }
      setState(() {
        _busy = false;
        _error = AuthService.message(e, AppLocale.t);
      });
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _confirmAbandon() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocale.t('auth_abandon_title')),
        content: Text(AppLocale.t('auth_abandon_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppLocale.t('auth_abandon_confirm'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Reexecuta a última ação com abandono confirmado.
    if (_lastAction == 'google') {
      await _run(() async {
        await AuthService.signInWithGoogle(
            link: widget.linkMode, forceAbandon: true);
      });
    } else {
      await _run(() async {
        await AuthService.signInWithEmail(
            email: _mailC.text,
            password: _passC.text,
            create: _create,
            link: widget.linkMode,
            forceAbandon: true);
      });
    }
  }

  /// Contas temporárias do aparelho (leitura local, sem auth):
  /// convidadas (auth guest) ou legadas sem dono. Permanentes pedem
  /// Google/Email acima, nunca entram por aqui.
  Future<void> _toggleGuestList() async {
    if (_showGuests) {
      setState(() => _showGuests = false);
      return;
    }
    setState(() {
      _showGuests = true;
      _loadingGuests = true;
    });
    try {
      final rows =
          await AppDatabase.instance.registryProfiles();
      final guests = [
        for (final r in rows)
          if ((r['firebase_uid'] ?? '').toString().isEmpty ||
              (r['auth_type'] ?? '').toString() == 'guest')
            Map<String, Object?>.of(r),
      ];
      final codes = <String, String>{};
      for (final g in guests) {
        final c = await OnlineFriends.cachedCode(
            (g['id'] ?? '').toString());
        if (c.isNotEmpty) codes[(g['id'] ?? '').toString()] = c;
      }
      if (!mounted) return;
      setState(() {
        _guestRows = guests;
        _guestCodes = codes;
        _loadingGuests = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingGuests = false);
    }
  }

  Widget _guestList() {
    if (_loadingGuests) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child:
                    CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        Text(AppLocale.t('auth_device_list_title'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 4),
        for (final g in _guestRows)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 3),
            child: ListTile(
              dense: true,
              leading: CircleAvatar(
                backgroundColor: AppTheme.goldSoft,
                child: Text(
                    ((g['name'] ?? '?').toString().isEmpty
                            ? '?'
                            : (g['name'] ?? '?')
                                .toString()[0])
                        .toUpperCase(),
                    style: const TextStyle(
                        color: AppTheme.gold,
                        fontWeight: FontWeight.bold)),
              ),
              title: Text((g['name'] ?? '?').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: _guestCodes[(g['id'] ?? '').toString()] ==
                      null
                  ? null
                  : Text(
                      '#${_guestCodes[(g['id'] ?? '').toString()]}',
                      style: const TextStyle(
                          color: AppTheme.gold, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: _busy ? null : () => _selectGuestRow(g),
            ),
          ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.person_add_outlined, size: 18),
          label: Text(AppLocale.t('auth_guest_new')),
          onPressed: _busy ? null : () => _createGuestRowUI(),
        ),
      ],
    );
  }

  /// Ativa a linha existente (arquivo dela) e entra como convidado.
  /// Nunca cria outra no lugar: reuso explícito. A linha é vinculada
  /// à sessão resultante (mesma de antes, ou a nova).
  Future<void> _selectGuestRow(Map<String, Object?> row) async {
    await _run(() async {
      await AppDatabase.instance.openProfileRow(row);
      final user = await AuthService.signInGuest();
      await AppDatabase.instance
          .openProfileRow(row, bindUid: user.uid);
    });
  }

  /// Nova temporária: pede nick, cria linha+arquivo e entra nela.
  /// Único ponto de criação (nunca no logout, nunca sozinho).
  Future<void> _createGuestRowUI() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(AppLocale.t('auth_guest_new_title')),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
              hintText: AppLocale.t('auth_guest_new_hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocale.t('common_cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: Text(AppLocale.t('auth_create'))),
        ],
      ),
    );
    Future.delayed(const Duration(milliseconds: 350), () {
      try {
        c.dispose();
      } catch (_) {}
    });
    if (name == null || name.isEmpty || !mounted) return;
    await _run(() async {
      // Sessão primeiro para vincular a linha já no UID certo
      // (sem isso o switch criava outra linha "Nome • XXXX").
      final user = await AuthService.signInGuest();
      final row = await AppDatabase.instance
          .createGuestRow(name, firebaseUid: user.uid);
      await AppDatabase.instance.openProfileRow(row);
    });
    if (mounted) setState(() => _showGuests = false);
  }

  @override
  Widget build(BuildContext context) {
    final linking = AuthService.isAnonymous && AuthService.isSignedIn;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.style,
                    color: AppTheme.gold, size: 56),
                const SizedBox(height: 12),
                const Text('Magic Collection',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppTheme.gold,
                        fontSize: 28,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                    AppLocale.t(linking
                        ? 'auth_link_hint'
                        : 'auth_subtitle'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 13)),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  icon: const Text('G',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: AppTheme.gold)),
                  label: Text(AppLocale.t('auth_google')),
                  onPressed: _busy
                      ? null
                      : () {
                          _lastAction = 'google';
                          _run(() async {
                            await AuthService.signInWithGoogle(
                                link: widget.linkMode);
                          });
                        },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8),
                      child: Text(AppLocale.t('auth_or'),
                          style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12)),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _mailC,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  enabled: !_busy,
                  decoration: InputDecoration(
                      labelText: AppLocale.t('auth_email'),
                      prefixIcon:
                          const Icon(Icons.mail_outline, size: 18)),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _passC,
                  obscureText: _obscure,
                  enabled: !_busy,
                  onSubmitted: (_) {
                    _lastAction = 'email';
                    _run(() async {
                      await AuthService.signInWithEmail(
                          email: _mailC.text,
                          password: _passC.text,
                          create: _create,
                          link: widget.linkMode);
                    });
                  },
                  decoration: InputDecoration(
                    labelText: AppLocale.t('auth_password'),
                    prefixIcon:
                        const Icon(Icons.lock_outline, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () =>
                          setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _lastAction = 'email';
                          _run(() async {
                            await AuthService.signInWithEmail(
                                email: _mailC.text,
                                password: _passC.text,
                                create: _create,
                                link: widget.linkMode);
                          });
                        },
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2))
                      : Text(AppLocale.t(_create
                          ? 'auth_signup'
                          : 'auth_signin')),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () =>
                          setState(() => _create = !_create),
                  child: Text(AppLocale.t(_create
                      ? 'auth_have_account'
                      : 'auth_no_account')),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 13)),
                ],
                if (!widget.linkMode) ...[
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  if (AuthService.hasPausedGuest) ...[
                    TextButton.icon(
                      icon:
                          const Icon(Icons.person_outline, size: 18),
                      label: Text(
                          AppLocale.t('auth_device_account')),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                await AuthService.signInGuest();
                              }),
                    ),
                    Text(
                        AppLocale.t('auth_device_account_hint'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12)),
                  ] else ...[
                    TextButton.icon(
                      icon: const Icon(Icons.person_outline,
                          size: 18),
                      label:
                          Text(AppLocale.t('auth_guest')),
                      onPressed: _busy
                          ? null
                          : () => _toggleGuestList(),
                    ),
                    if (_showGuests) _guestList(),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
