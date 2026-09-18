import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import 'deck_stats.dart';
import 'scryfall_service.dart';

// Repara dados de carta usados por curva/composição/fontes.
//
// Duas etapas (sem sistema paralelo ao repair de raridade):
// 1. OFFLINE: cmc nulo derivado do mana_cost já gravado ("{2}{R}"->3).
// 2. REDE: linhas ainda sem color_identity/type_line/mana_cost são
//    enriquecidas via Scryfall (impressão exata > oracle+set+coletor >
//    nome+idioma), atualizando cmc, mana_cost, type_line, colors,
//    color_identity e oracle_id. Só faltantes; preços/quantidade e
//    nomes impressos locais nunca são sobrescritos.
// Roda em segundo plano com limite por execução (rate-limit).
class ManaRepairService {
  ManaRepairService._();

  static Future<int> repairMissingCmc({int maxRows = 2000}) async {
    final db = AppDatabase.instance.db;
    List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        'cards',
        columns: ['id', 'cmc', 'mana_cost'],
        where: 'cmc IS NULL AND mana_cost IS NOT NULL AND TRIM(mana_cost) != ?',
        whereArgs: [''],
        limit: maxRows,
      );
    } catch (_) {
      // Banco antigo sem as colunas (a migração v8 resolve na abertura).
      return 0;
    }
    if (rows.isEmpty) return 0;
    var fixed = 0;
    final batch = db.batch();
    for (final r in rows) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      double? cmc;
      try {
        cmc = DeckStatsService.manaValue(null, r['mana_cost']);
      } catch (_) {
        cmc = null;
      }
      if (cmc == null) continue;
      batch.update('cards', {'cmc': cmc}, where: 'id = ?', whereArgs: [id]);
      fixed++;
    }
    try {
      await batch.commit(noResult: true);
    } catch (_) {
      return 0;
    }
    if (fixed > 0) {
      debugPrint('[Mana] $fixed cmc(s) derivados do mana_cost.');
    }
    return fixed;
  }

  /// Passada completa: offline primeiro, depois rede para o que
  /// continua sem identidade/tipo/custo. Retorna total corrigido.
  static Future<int> repairMissingCardData({int maxCards = 60}) async {
    var fixed = await repairMissingCmc();
    fixed += await _enrichMissingFields(maxCards: maxCards);
    return fixed;
  }

  static bool _blank(Object? v) =>
      v == null || v.toString().trim().isEmpty;

  static Future<int> _enrichMissingFields({int maxCards = 60}) async {
    final db = AppDatabase.instance.db;
    List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        'cards',
        columns: [
          'id',
          'name',
          'printed_name',
          'scryfall_id',
          'oracle_id',
          'lang',
          'set_code',
          'collector_number',
        ],
        where: 'quantity > 0 AND (color_identity IS NULL '
            "OR TRIM(color_identity) = '' "
            "OR color_identity = '[]' "
            'OR type_line IS NULL '
            "OR TRIM(type_line) = '' "
            'OR mana_cost IS NULL)',
        orderBy: 'id ASC',
        limit: maxCards,
      );
    } catch (_) {
      return 0;
    }
    if (rows.isEmpty) return 0;
    final api = ScryfallService.instance;
    final cache = <String, Map<String, dynamic>?>{};
    var fixed = 0;
    for (final row in rows) {
      final id = (row['id'] as num?)?.toInt();
      if (id == null) continue;
      Map<String, dynamic>? data;
      final scryId = (row['scryfall_id'] ?? '').toString().trim();
      // IDs legados/lixo ("2", "45") geram 404 à toa: só UUID real.
      if (scryId.isNotEmpty && scryId.length >= 32) {
        final key = 's:$scryId';
        if (cache.containsKey(key)) {
          data = cache[key];
        } else {
          try {
            data = await api.getCardByScryfallId(scryId);
          } catch (_) {
            data = null;
          }
          cache[key] = data;
        }
      }
      if (data == null) {
        final oracle = (row['oracle_id'] ?? '').toString().trim();
        final set = (row['set_code'] ?? '').toString().trim();
        final cn = (row['collector_number'] ?? '').toString().trim();
        if (oracle.isNotEmpty && set.isNotEmpty && cn.isNotEmpty) {
          final key =
              '$oracle|$set|${ScryfallService.normalizeCollector(cn)}';
          if (cache.containsKey(key)) {
            data = cache[key];
          } else {
            try {
              final prints =
                  await api.getPrintings(oracle, setCode: set);
              for (final p in prints) {
                if (ScryfallService.sameCollector(
                    (p['collector_number'] ?? '').toString(), cn)) {
                  data = Map<String, dynamic>.from(p);
                  break;
                }
              }
            } catch (_) {
              data = null;
            }
            cache[key] = data;
          }
        }
      }
      if (data == null) {
        final name =
            ((row['name'] ?? row['printed_name']) ?? '').toString().trim();
        final lang = (row['lang'] ?? '').toString().trim();
        if (name.isNotEmpty) {
          final key = 'n:${name.toLowerCase()}|$lang';
          if (cache.containsKey(key)) {
            data = cache[key];
          } else {
            for (final l in [if (lang.isNotEmpty) lang, 'pt', 'en']) {
              try {
                data = await api.getCardByName(name, lang: l);
                if (data != null) break;
              } catch (_) {}
            }
            cache[key] = data;
          }
        }
      }
      if (data == null) continue;
      final flat = ScryfallService.flatten(data);
      final patch = <String, Object?>{
        'cmc': flat['cmc'],
        'mana_cost': flat['mana_cost'],
        'type_line': flat['type_line'],
        'colors': flat['colors'],
        'color_identity': flat['color_identity'],
        'oracle_id': flat['oracle_id'],
      };
      patch.removeWhere((_, v) => _blank(v) && v != 0);
      if (patch.isEmpty) continue;
      try {
        await db.update('cards', patch,
            where: 'id = ?', whereArgs: [id]);
        fixed++;
      } catch (_) {}
    }
    if (fixed > 0) {
      debugPrint('[Mana] $fixed carta(s) enriquecida(s) via Scryfall.');
    }
    return fixed;
  }
}
