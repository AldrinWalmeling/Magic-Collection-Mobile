import 'package:flutter/foundation.dart';

// Barramento simples de eventos do app.
// Qualquer tela que muda a coleção chama notifyCollectionChanged()
// e o Painel (e outras telas inscritas) se atualizam sozinhas.
class AppEvents {
  static final ValueNotifier<int> collectionChanged = ValueNotifier<int>(0);

  static void notifyCollectionChanged() {
    collectionChanged.value++;
  }

  /// Barra inferior visível ou escondida (modo imersivo).
  static final ValueNotifier<bool> navVisible = ValueNotifier<bool>(true);

  /// Barra superior (AppBar) visível ou escondida junto (modo foco total).
  static final ValueNotifier<bool> topVisible = ValueNotifier<bool>(true);

  /// Quando a mesa está em foco, nem o botão flutuante de reabrir a
  /// navegação deve aparecer por cima da partida.
  static final ValueNotifier<bool> playFocusActive = ValueNotifier<bool>(false);

  /// Alterna o modo foco total: esconde/mostra as DUAS barras.
  /// (A mesa Jogar tem seu próprio foco e não usa este toggle.)
  static void toggleNav() {
    final show = !navVisible.value;
    navVisible.value = show;
    topVisible.value = show;
  }

  /// Garante as duas barras visíveis (voltar do foco).
  static void showBars() {
    navVisible.value = true;
    topVisible.value = true;
  }

  /// Perfil ativo trocou SEM restart: cada tela recarrega seus dados
  /// do banco novo. Partida em andamento na mesa não é mexida.
  static final ValueNotifier<int> activeProfile = ValueNotifier<int>(0);

  static void notifyProfileChanged() {
    activeProfile.value++;
  }

  /// Pedido de troca de aba (ex. Social -> Jogar ao chamar p/ mesa).
  /// AppShell consome (volta a null). Sem reloads nem timers.
  static final ValueNotifier<int?> requestedTab = ValueNotifier<int?>(null);

  static void requestTab(int index) {
    requestedTab.value = index;
  }

  /// Sessão vai cair (signOut real): cada tela cancela NA HORA suas
  /// escutas RTDB do UID velho, antes do signOut completar. Sem isso,
  /// o servidor derruba as escutas com permission-denied no meio da
  /// transição (e sem onError, derrubava o app).
  static final ValueNotifier<int> authStopping = ValueNotifier<int>(0);

  static void notifyAuthStopping() {
    authStopping.value++;
  }

  /// Aba ativa do Social (0 Comunidade, 1 Perfil, 2 Amigos).
  /// As tabs escutam e recarregam ao VOLTAR para elas (sem polling).
  static final ValueNotifier<int> socialTab = ValueNotifier<int>(0);
}
