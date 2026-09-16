import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';

import 'theme/app_theme.dart';
import 'data/app_database.dart';

import 'pages/dashboard_page.dart';
import 'pages/collection_page.dart';
import 'pages/decks_page.dart';
import 'pages/profiles_page.dart';
import 'pages/play_page.dart';
import 'pages/settings_page.dart';

import 'services/app_events.dart';
import 'services/app_locale.dart';
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
  await CurrencyService.instance.loadCurrency();

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
      home: const AppShell(),
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

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _checkingProfile = true;

  static const _pages = [
    DashboardPage(),
    CollectionPage(),
    DecksPage(),
    PlayPage(),
    ProfilesPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _checkProfile();
  }

  Future<void> _checkProfile() async {
    final needsName = await AppDatabase.instance.needsProfileSetup();
    if (!mounted) return;
    setState(() => _checkingProfile = false);
    if (needsName) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askProfileName());
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
              await AppDatabase.instance.nameActiveProfile(clean);
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
                    icon: const Icon(Icons.person_outline),
                    selectedIcon: const Icon(Icons.person),
                    label: AppLocale.t('nav_profiles')),
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
