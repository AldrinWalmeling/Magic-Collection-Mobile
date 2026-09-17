import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Editor de quantidade: toca no número e escolhe ADICIONAR (+7),
// REMOVER (−3) ou DEFINIR (=27), com prévia ao vivo.
// Ex.: tem 20, achou 7 -> Adicionar 7 -> 27.
// Zerar pede confirmação (mantém a linha com quantity 0).
class QuantityEditor {
  /// Devolve a nova quantidade ou null (cancelado).
  static Future<int?> show(BuildContext context, int current) {
    return showDialog<int>(
      context: context,
      builder: (_) => _QuantityDialog(current: current),
    ).then((result) async {
      if (result == null) return null;
      // Zerou uma carta que tinha cópias? Confirma (a linha é mantida
      // com quantity 0 — histórico, decks e favoritos preservados).
      if (result == 0 && current > 0) {
        final ok = await showDialog<bool>(
          // ignore: use_build_context_synchronously
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Remover última(s) cópia(s)?'),
            content: const Text(
                'A quantidade vai a zero e a carta sai da coleção (os dados são mantidos para histórico, decks e favoritos).'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar')),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Remover')),
            ],
          ),
        );
        if (ok != true) return null;
      }
      return result;
    });
  }
}

/// Diálogo com ciclo de vida próprio: o controller morre junto com a
/// rota (nunca antes — evita "used after dispose" na saída animada).
class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({required this.current});

  final int current;

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  var _mode = 0; // 0 = adicionar, 1 = remover, 2 = definir
  // Sem TextEditingController de propósito: sem controller, sem
  // "used after dispose" em rebuild da rota (teclado etc.).
  var _text = '';

  @override
  Widget build(BuildContext context) {
    final n = int.tryParse(_text.trim());
    int? preview;
    String? error;
    if (_text.trim().isEmpty) {
      preview = null;
    } else if (n == null || n < 0) {
      error = 'Digite um número válido.';
    } else if (_mode == 0) {
      preview = widget.current + n;
    } else if (_mode == 1) {
      preview = widget.current - n;
      if (preview < 0) error = 'Não há tantas cópias.';
    } else {
      preview = n;
    }
    return AlertDialog(
      scrollable: true,
      title: Text('Quantidade (atual: ${widget.current})'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.add, size: 14),
                  label:
                      Text('Adicionar', style: TextStyle(fontSize: 12))),
              ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.remove, size: 14),
                  label: Text('Remover', style: TextStyle(fontSize: 12))),
              ButtonSegment(
                  value: 2,
                  icon: Icon(Icons.edit, size: 14),
                  label: Text('Definir', style: TextStyle(fontSize: 12))),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) => setState(() => _text = v),
            onSubmitted: (_) {
              if (preview != null && error == null) {
                Navigator.pop(context, preview);
              }
            },
            decoration: InputDecoration(
              labelText:
                  _mode == 2 ? 'Nova quantidade' : 'Quantas cartas?',
              errorText: error,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            preview == null
                ? ' '
                : _mode == 0
                    ? '${widget.current} + $n = $preview'
                    : _mode == 1
                        ? '${widget.current} − $n = $preview'
                        : '= $preview',
            style:
                const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: (preview == null || error != null)
              ? null
              : () => Navigator.pop(context, preview),
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}
