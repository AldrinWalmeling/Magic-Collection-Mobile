import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

import 'theme/app_theme.dart';
import 'data/app_database.dart';

import 'pages/authentication_screen.dart';

import 'pages/dashboard_page.dart';
import 'pages/collection_page.dart';
import 'pages/decks_page.dart';
import 'pages/play_page.dart';
import 'pages/settings_page.dart';
import 'pages/social_page.dart';

import 'services/app_events.dart';
import 'services/app_locale.dart';
import 'services/account_sync.dart';
import 'services/auth_service.dart';
import 'services/play_prefs.dart';
import 'services/display_prefs.dart';
import 'services/currency_service.dart';
import 'services/lan_presence.dart';

// ============================================================
// MAGIC COLLECTION — MOBILE (Flutter)
// Migração do app desktop PySide6 para Android (APK).
// ============================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa o Firebase antes dos serviços que poderão utilizá-lo.
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Banco principal (coleção) + decks + snapshots
  await AppDatabase.instance.init();

  await AppLocale.load();
  await PlayPrefs.load();
  await DisplayPrefs.load();
  await AuthService.load();
  await CurrencyService.instance.loadCurrency();
  // Moeda padrão segue o idioma (PT->BRL, demais->USD), exceto se o
  // usuário já escolheu manualmente. Vale para trocas futuras também.
  await CurrencyService.instance.applyLanguageDefault(AppLocale.code);
  AppLocale.current.addListener(() {
    CurrencyService.instance.applyLanguageDefault(AppLocale.code);
  });

  // Câmbio em segundo plano
  CurrencyService.instance.startBackgroundRefresh();

  runApp(const MagicCollectionApp());
}

class MagicCollectionApp extends StatelessWidget {
  const MagicCollectionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Magic Collection',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const AuthGate(),
    );
  }
}

/// Porta de entrada: sem usuário -> login; visitante pausado -> login
/// (sessão preservada, sem auto-entrada); liberado -> AppShell.
/// Firebase persiste a sessão sozinho; o stream emite rápido, com
/// fallback de loading (nunca trava em tela vazia).
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    // guestPaused não emite evento de auth: escuta dedicada para o
    // Sair do visitante refletir na hora.
    return ListenableBuilder(
      listenable: AuthService.guestPaused,
      builder: (context, _) => StreamBuilder<User?>(
        stream: AuthService.authChanges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snap.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(AuthService.message(
                          snap.error!, AppLocale.t)),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: AuthService.signOut,
                        child: Text(AppLocale.t('common_retry')),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          if (!AuthService.canEnterApp(snap.data)) {
            return const AuthenticationScreen();
          }
          return const AppShell();
        },
      ),
    );
  }
}

/// Shell principal: no desktop era QMainWindow + Sidebar fixa (200px).
/// No mobile vira Scaffold + BottomNavigationBar com as mesmas 5 seções.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _checkingProfile = true;
  // Última aba aberta: volta para ela se o SO matar o app em 2º plano.
  static const _lastTabKey = 'app_last_tab';

  static const _pages = [
    DashboardPage(),
    CollectionPage(),
    DecksPage(),
    PlayPage(),
    SocialPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreTab();
    _checkProfile();
    AppEvents.requestedTab.addListener(_onRequestedTab);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppEvents.requestedTab.removeListener(_onRequestedTab);
    super.dispose();
  }

  /// App indo para segundo plano/fechando: salva o backup da conta
  /// (sem isso, algo apagado voltava no próximo login via restore).
  /// Melhor esforço, silencioso, só conta permanente.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        AccountSync.isSessionSynced) {
      // Nunca faça backup automático durante a janela de login/troca de
      // conta: só envie quando o arquivo local já estiver sincronizado
      // com a identidade ativa. Isso evita sobrescrever o backup remoto
      // com dados da conta anterior ou um arquivo ainda não restaurado.
      unawaited(AccountSync.push().catchError((_) {}));
    }
  }

  /// Troca de aba pedida por outra tela (ex. Social -> Jogar).
  void _onRequestedTab() {
    final i = AppEvents.requestedTab.value;
    if (i == null || !mounted) return;
    AppEvents.requestedTab.value = null;
    if (i >= 0 && i < _pages.length) {
      setState(() => _index = i);
      _saveTab(i);
    }
  }

  Future<void> _restoreTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final i = prefs.getInt(_lastTabKey) ?? 0;
      if (!mounted) return;
      if (i >= 0 && i < _pages.length) setState(() => _index = i);
    } catch (_) {}
  }

  Future<void> _saveTab(int i) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastTabKey, i);
    } catch (_) {}
  }

  Future<void> _checkProfile() async {
    // Primeiro o ARQUIVO da conta (UID manda), depois o nome.
    // Sem isso, login B com arquivo A aberto misturava tudo.
    String serverName = '';
    try {
      try {
        serverName =
            (await AccountSync.fetchServerIdentity())?['name'] ?? '';
      } catch (_) {}
      await AppDatabase.instance.switchToAccount(
        uid: AuthService.current?.uid,
        kind: AuthService.accountKind,
        displayName: serverName,
      );
    } catch (_) {}
    if (!mounted) return;
    // Se a conta permanente já tem identidade no servidor, não trate
    // a reinstalação/novo aparelho como uma conta sem nome. O primeiro
    // acesso ao dispositivo não pode pedir um novo nick para uma conta
    // que já possui identidade persistida.
    final needsName = serverName.trim().isEmpty &&
        await AppDatabase.instance.needsProfileSetup();
    if (!mounted) return;
    setState(() => _checkingProfile = false);
    if (needsName) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askProfileName());
    }
    unawaited(_syncAccount());
  }

  /// Backup/restauração da conta (uma vez por sessão): aparelho vazio
  /// + backup existente = restaura; senão, envia o estado local.
  Future<void> _syncAccount() async {
    try {
      final res = await AccountSync.syncNow();
      if (!mounted) return;
      if (res['action'] == 'restored') {
        AppEvents.notifyProfileChanged();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocale.t('acc_restored')
                .replaceAll('{d}', '${res['decks'] ?? 0}')
                .replaceAll('{c}', '${res['cards'] ?? 0}'))));
      }
    } catch (e) {
      debugPrint('[AccountSync] falha (tentarei de novo): $e');
    }
  }

  Future<void> _askProfileName() async {
    final controller = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) {
          String err(String? e) {
            if (e == 'empty') return AppLocale.t('setup_empty');
            if (e == 'used') return AppLocale.t('setup_used');
            return e ?? '';
          }

          Future<void> submit(String name) async {
            if (name.isEmpty) {
              setDialogState(() => error = 'empty');
              return;
            }
            try {
              final clean = name.trim();
              await AppDatabase.instance.nameActiveProfile(
                clean,
                firebaseUid: AuthService.current?.uid,
                authType: AuthService.accountKind,
              );
              // Sem isso as telas já montadas (Jogar, Perfis, Painel...)
              // continuavam com o nome antigo cacheado ("Convidado").
              AppEvents.notifyProfileChanged();
              try {
                await LanPresence.ensureStarted();
                LanPresence.instance.updateIdentity(clean);
              } catch (_) {}
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            } catch (_) {
              setDialogState(() => error = 'used');
            }
          }

          return AlertDialog(
            scrollable: true,
            title: Text(AppLocale.t('setup_title')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(AppLocale.t('setup_sub')),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                onSubmitted: (_) async => submit(controller.text.trim()),
                decoration: InputDecoration(
                  labelText: AppLocale.t('setup_name'),
                  errorText: error == null ? null : err(error),
                ),
              ),
            ]),
            actions: [
              ElevatedButton(
                onPressed: () async => submit(controller.text.trim()),
                child: Text(AppLocale.t('setup_go')),
              ),
            ],
          );
        },
      ),
    );
    // showDialog completa assim que Navigator.pop é chamado, mas o diálogo
    // ainda passa pela animação de saída por alguns frames. Descartar o
    // controller imediatamente fazia o TextField da animação usar um objeto
    // já destruído (e quebrava a primeira criação de perfil).
    await Future<void>.delayed(const Duration(milliseconds: 350));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingProfile) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      // Botão flutuante p/ revelar a barra quando escondida.
      // Volta as DUAS barras (inferior + superior).
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: AppEvents.navVisible,
        builder: (_, visible, __) => ValueListenableBuilder<bool>(
          valueListenable: AppEvents.topVisible,
          builder: (_, top, ___) => ValueListenableBuilder<bool>(
            valueListenable: AppEvents.playFocusActive,
            builder: (_, focusActive, ___) => (visible && top) || focusActive
                ? const SizedBox.shrink()
                : FloatingActionButton.small(
                    heroTag: null,
                    onPressed: AppEvents.showBars,
                    tooltip: AppLocale.t('nav_show'),
                    child: const Icon(Icons.fullscreen_exit),
                  ),
          ),
        ),
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: AppEvents.navVisible,
        builder: (_, visible, __) => ValueListenableBuilder<AppLang>(
          valueListenable: AppLocale.current,
          builder: (_, ___, ____) {
            if (!visible) return const SizedBox.shrink();
            return NavigationBar(
              selectedIndex: _index,
              // Trocar de aba atualiza o Painel sozinho.
              onDestinationSelected: (i) {
                setState(() => _index = i);
                _saveTab(i);
                AppEvents.notifyCollectionChanged();
              },
              destinations: [
                NavigationDestination(
                    icon: const Icon(Icons.dashboard_outlined),
                    selectedIcon: const Icon(Icons.dashboard),
                    label: AppLocale.t('nav_dashboard')),
                NavigationDestination(
                    icon: const Icon(Icons.style_outlined),
                    selectedIcon: const Icon(Icons.style),
                    label: AppLocale.t('nav_collection')),
                NavigationDestination(
                    icon: const Icon(Icons.layers_outlined),
                    selectedIcon: const Icon(Icons.layers),
                    label: AppLocale.t('nav_decks')),
                NavigationDestination(
                    icon: const Icon(Icons.sports_esports_outlined),
                    selectedIcon: const Icon(Icons.sports_esports),
                    label: AppLocale.t('nav_play')),
                NavigationDestination(
                    icon: const Icon(Icons.groups_outlined),
                    selectedIcon: const Icon(Icons.groups),
                    label: AppLocale.t('nav_social')),
                NavigationDestination(
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings),
                    label: AppLocale.t('nav_settings')),
              ],
            );
          },
        ),
      ),
    );
  }
}
