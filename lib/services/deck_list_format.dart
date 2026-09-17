import 'dart:convert';

/// Formatos de decklist (Fase A §36-40): parse tolerante de texto e
/// JSON fiel `.mcdeck.json`. Centralizado para reuso (deck pessoal,
/// comunidade, arquivo). Não toca em banco nem rede.
class DeckListFormat {
  /// Linha parseada: quantidade + nome (+ set opcional).
  static Map<String, Object>? parseDeckLine(String raw) {
    var line = raw.trim();
    if (line.isEmpty) return null;
    // Comentários e prefixo de sideboard por linha.
    if (line.startsWith('#') ||
        line.startsWith('//') ||
        line.startsWith(';')) {
      return null;
    }
    line = line.replaceAll(RegExp(r'^(SB|Sideboard)\s*:\s*', caseSensitive: false), '').trim();
    var qty = 1;
    var m = RegExp(r'^(\d+)\s*[x×]?\s+(.+)$').firstMatch(line);
    if (m != null) {
      qty = (int.tryParse(m.group(1)!) ?? 1).clamp(1, 99);
      line = m.group(2)!.trim();
    } else {
      m = RegExp(r'^(.+?)\s+[x×]\s*(\d+)$').firstMatch(line);
      if (m != null) {
        qty = (int.tryParse(m.group(2)!) ?? 1).clamp(1, 99);
        line = m.group(1)!.trim();
      }
    }
    var set = '';
    final sm = RegExp(r'\[(.*?)\]\s*$').firstMatch(line);
    if (sm != null) {
      set = sm.group(1)!.trim();
      line = line.substring(0, sm.start).trim();
    }
    if (line.isEmpty) return null;
    return {'qty': qty, 'name': line, 'set': set};
  }

  /// Parser tolerante: seções Commander:/Deck:/Mainboard:, "4x Nome
  /// [SET]", "4 Nome", "Nome x4". Sideboard é ignorado (não entra).
  /// Retorna {'entries': [...], 'commander': nome?}.
  static Map<String, Object?> parseDeckText(String text) {
    final entries = <Map<String, Object?>>[];
    String? commander;
    var inSideboard = false;
    var inCommander = false;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final head =
          RegExp(r'^(commander|deck|mainboard|main deck|sideboard)\s*:?\s*$',
                  caseSensitive: false)
              .firstMatch(line);
      if (head != null) {
        final which = head.group(1)!.toLowerCase();
        inSideboard = which == 'sideboard';
        inCommander = which == 'commander';
        continue;
      }
      if (inSideboard) continue;
      final e = parseDeckLine(line);
      if (e == null) continue;
      // Seção Commander: primeira carta vira o comandante (não entra
      // na lista — comandante é entidade separada no app).
      if (inCommander && commander == null) {
        commander = (e['name'] ?? '').toString();
        if (commander.isNotEmpty) continue;
      }
      entries.add(Map<String, Object?>.from(e));
    }
    return {'entries': entries, 'commander': commander};
  }

  /// Importa .mcdeck.json (fiel) ou lista genérica {cards:[...]}.
  /// Retorna {'entries': [...], 'commander': nome?} ou null.
  static Map<String, Object?>? parseDeckJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final m = Map<String, Object?>.from(decoded);
      final rawCards = m['cards'];
      if (rawCards is! List) return null;
      final entries = <Map<String, Object?>>[];
      for (final e in rawCards) {
        if (e is! Map) continue;
        final name = (e['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        entries.add({
          'qty': ((e['quantity'] ?? e['deck_qty'] ?? 1) as num?)
                  ?.toInt()
                  .clamp(1, 99) ??
              1,
          'name': name,
          'set': (e['set_code'] ?? e['set'] ?? '').toString(),
        });
      }
      String? commander;
      final cmd = m['commander'];
      if (cmd is Map) {
        commander = (cmd['name'] ?? '').toString().trim();
        if (commander.isEmpty) commander = null;
      } else if (cmd is String && cmd.trim().isNotEmpty) {
        commander = cmd.trim();
      }
      return {'entries': entries, 'commander': commander};
    } catch (_) {
      return null;
    }
  }
}
