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
}
