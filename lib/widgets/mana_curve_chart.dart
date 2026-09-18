import 'package:flutter/material.dart';

import '../services/app_locale.dart';
import '../theme/app_theme.dart';

// Curva de mana em barras verticais: proporcional, com valores,
// custo identificado e eixo organizado. Parte do visual do app
// (ouro sobre painel, sem exagero). Terrenos já vêm excluídos do
// `curve` calculado pelo DeckStatsService.
class ManaCurveChart extends StatelessWidget {
  const ManaCurveChart({super.key, required this.curve});

  /// Índice 0..6 (6 = 6+), valores = cópias.
  final Map<int, int> curve;

  @override
  Widget build(BuildContext context) {
    var max = 1;
    for (var i = 0; i <= 6; i++) {
      final v = curve[i] ?? 0;
      if (v > max) max = v;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppLocale.t('stats_curve'),
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 12)),
        const SizedBox(height: 6),
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i <= 6; i++)
                Expanded(child: _Bar(i, curve[i] ?? 0, max)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(this.cost, this.value, this.max);

  final int cost;
  final int value;
  final int max;

  @override
  Widget build(BuildContext context) {
    final frac = max <= 0 ? 0.0 : value / max;
    return Tooltip(
      message: '$value',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text('$value',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: value > 0
                      ? AppTheme.gold
                      : AppTheme.textMuted)),
          const SizedBox(height: 2),
          Expanded(
            child: FractionallySizedBox(
              heightFactor: 1,
              alignment: Alignment.bottomCenter,
              child: LayoutBuilder(
                builder: (_, cons) => Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: 26,
                    height: (cons.maxHeight * frac)
                        .clamp(0.0, cons.maxHeight),
                    decoration: BoxDecoration(
                      color: value > 0
                          ? AppTheme.gold
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(cost == 6 ? '6+' : '$cost',
              style: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}
