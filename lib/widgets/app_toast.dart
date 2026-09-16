import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

// Toast rápido e estilizado (dark + ouro), some sozinho.
// Substitui o snackbar branco padrão nos avisos de jogo/coleção.
class AppToast {
  static void show(BuildContext context, String msg) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          msg,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.text),
        ),
        duration: const Duration(milliseconds: 2600),
      ),
    );
  }
}
