import 'package:flutter/material.dart';

import '../services/app_events.dart';
import '../services/app_locale.dart';
import 'social_community_tab.dart';
import 'social_friends_tab.dart';
import 'social_profile_tab.dart';

// Aba Social: Comunidade | Meu Perfil | Amigos.
// Substitui "Perfis" na navegação (índice 4). Perfis locais continuam
// gerenciáveis via "Gerenciar perfis" dentro de Meu Perfil.
class SocialPage extends StatefulWidget {
  const SocialPage({super.key});

  @override
  State<SocialPage> createState() => _SocialPageState();
}

class _SocialPageState extends State<SocialPage> {
  int _tab = 0;

  void _onLocale() {
    if (mounted) setState(() {});
  }

  void _onBars() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    AppLocale.current.addListener(_onLocale);
    AppEvents.topVisible.addListener(_onBars);
    AppEvents.navVisible.addListener(_onBars);
  }

  @override
  void dispose() {
    AppLocale.current.removeListener(_onLocale);
    AppEvents.topVisible.removeListener(_onBars);
    AppEvents.navVisible.removeListener(_onBars);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppEvents.topVisible.value
          ? AppBar(title: Text(AppLocale.t('nav_social')))
          : null,
      body: SafeArea(
        top: !AppEvents.topVisible.value,
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SegmentedButton<int>(
                style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(
                      value: 0,
                      icon: const Icon(Icons.public_outlined, size: 16),
                      label: Text(AppLocale.t('soc_community'),
                          style: const TextStyle(fontSize: 12))),
                  ButtonSegment(
                      value: 1,
                      icon: const Icon(Icons.person_outline, size: 16),
                      label: Text(AppLocale.t('soc_profile'),
                          style: const TextStyle(fontSize: 12))),
                  ButtonSegment(
                      value: 2,
                      icon: const Icon(Icons.group_outlined, size: 16),
                      label: Text(AppLocale.t('soc_friends'),
                          style: const TextStyle(fontSize: 12))),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  setState(() => _tab = s.first);
                  AppEvents.socialTab.value = s.first;
                },
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [
                  CommunityTab(),
                  MyProfileTab(),
                  FriendsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
