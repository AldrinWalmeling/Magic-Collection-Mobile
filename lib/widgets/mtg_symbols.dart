import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

// Símbolos de mana/eventos do Magic como ícones, não como texto.
// Usa os SVGs oficiais do Scryfall (assets/icons/magic/*.svg):
// "{3}{W}{W}" vira pips oficiais; "{T}" vira a seta de virar;
// o texto das regras mistura os pips no meio da frase.
// Códigos sem SVG (ex. genérico 30+) usam um pip desenhado reserva.

/// Um pip de mana/evento. [code] sem chaves: "W", "3", "T", "W/U"...
class MtgPip extends StatelessWidget {
  const MtgPip(this.code, {super.key, this.size = 18});

  final String code;
  final double size;

  static const _base = 'assets/icons/magic';

  /// Arquivos SVG disponíveis (nomes sem extensão).
  static const _available = {
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12',
    '13', '14', '15', '16', '17', '18', '19', '20', '100', '1000000',
    '2_B', '2_G', '2_R', '2_U', '2_W',
    'A', 'B', 'B_G', 'B_G_P', 'B_P', 'B_R', 'B_R_P',
    'C', 'C_B', 'C_G', 'C_P', 'C_R', 'C_U', 'C_W',
    'CHAOS', 'D', 'E',
    'G', 'G_P', 'G_U', 'G_U_P', 'G_W', 'G_W_P',
    'H', 'HR', 'HW', 'L', 'P', 'PW', 'Q',
    'R', 'R_G', 'R_G_P', 'R_P', 'R_W', 'R_W_P',
    'S', 'T', 'TK',
    'U', 'U_B', 'U_B_P', 'U_P', 'U_R', 'U_R_P',
    'W', 'W_B', 'W_B_P', 'W_P', 'W_U', 'W_U_P',
    'X', 'Y', 'Z',
  };

  /// SVGs largos (proporção 28:15) em vez de quadrados.
  static const _wide = {'100', '1000000'};

  /// Nome do arquivo para o código ("W/U" -> "W_U").
  static String fileNameFor(String code) =>
      code.trim().toUpperCase().replaceAll('/', '_');

  @override
  Widget build(BuildContext context) {
    final file = fileNameFor(code);
    if (_available.contains(file)) {
      // errorBuilder: asset novo ainda não empacotado no APK instalado
      // (hot reload não adiciona arquivos novos — precisa rebuild) cai
      // no pip reserva em vez de estourar exceção.
      final fallback =
          _FallbackPip(code: code.trim(), size: size);
      if (_wide.contains(file)) {
        return SizedBox(
          width: size * 1.87,
          height: size,
          child: SvgPicture.asset(
            '$_base/$file.svg',
            errorBuilder: (_, __, ___) => fallback,
          ),
        );
      }
      return SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(
          '$_base/$file.svg',
          errorBuilder: (_, __, ___) => fallback,
        ),
      );
    }
    // Reserva: pip cinza desenhado (genérico alto, ½, desconhecidos).
    return _FallbackPip(code: code.trim(), size: size);
  }
}

/// Pip reserva desenhado para códigos sem SVG oficial.
class _FallbackPip extends StatelessWidget {
  const _FallbackPip({required this.code, required this.size});

  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFCCC6BE),
        border: Border.all(
            color: Colors.black.withValues(alpha: 0.75), width: size * 0.07),
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: EdgeInsets.all(size * 0.08),
          child: Text(
            code.toUpperCase(),
            style: TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.4,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

final _symbolRe = RegExp(r'\{([^}]*)\}');

/// Linha de custo de mana: "{3}{W}{W}" -> pips. Vazio/nulo -> "—".
class ManaCostRow extends StatelessWidget {
  const ManaCostRow(this.cost,
      {super.key, this.size = 19, this.spacing = 3});

  final String? cost;
  final double size;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final codes = _symbolRe
        .allMatches(cost ?? '')
        .map((m) => m.group(1)!.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (codes.isEmpty) {
      return Text('—',
          style: TextStyle(color: Colors.grey[400], fontSize: size * 0.8));
    }
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [for (final c in codes) MtgPip(c, size: size)],
    );
  }
}

/// Texto de regras com os símbolos {..} renderizados como pips no meio
/// da frase. Quebras de linha viram parágrafos; texto de lembrete
/// "(...)" fica em itálico esmaecido, como na carta real.
class OracleText extends StatelessWidget {
  const OracleText(this.text, {super.key, this.size = 15});

  final String? text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final raw = (text ?? '').trim();
    if (raw.isEmpty) return const SizedBox.shrink();
    final base =
        DefaultTextStyle.of(context).style.copyWith(fontSize: size, height: 1.5);
    final reminder = base.copyWith(
        fontStyle: FontStyle.italic, color: Colors.grey[400]);
    final paragraphs = raw.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < paragraphs.length; i++) ...[
          if (i > 0) SizedBox(height: size * 0.5),
          Text.rich(
            TextSpan(children: _spans(paragraphs[i], base, reminder)),
            style: base,
          ),
        ],
      ],
    );
  }

  List<InlineSpan> _spans(
      String para, TextStyle base, TextStyle reminder) {
    final out = <InlineSpan>[];
    // Separa lembrete "(...)" do resto para estilizar.
    final chunks =
        RegExp(r'\([^)]*\)|[^(]+').allMatches(para);
    for (final ch in chunks) {
      final part = ch.group(0)!;
      final style = part.startsWith('(') ? reminder : base;
      var pos = 0;
      for (final m in _symbolRe.allMatches(part)) {
        if (m.start > pos) {
          out.add(TextSpan(text: part.substring(pos, m.start), style: style));
        }
        final code = m.group(1)!.trim();
        if (code.isNotEmpty) {
          out.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: MtgPip(code, size: size * 1.1),
          ));
        }
        pos = m.end;
      }
      if (pos < part.length) {
        out.add(TextSpan(text: part.substring(pos), style: style));
      }
    }
    return out;
  }
}
