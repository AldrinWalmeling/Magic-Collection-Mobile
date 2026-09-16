import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import 'scryfall_service.dart';

// Repara raridades vazias (que aparecem como "desconhecida" no Painel).
//
// Comum após importar backup: o arquivo pode vir sem `rarity`.
// Estratégia por carta (sem chutar impressão errada):
//   1. scryfall_id exato -> raridade da impressão correta;
//   2. oracle_id + set + collector_number -> acha o printing exato;
//   3. nome + idioma -> último recurso (cacheado por nome).
// Limitado por execução para não estourar o rate-limit do Scryfall
// (a fila continua na próxima abertura/importação).
class RarityRepairService {
  RarityRepairService._();

  static Future<int> repairMissingRarities({int maxCards = 150}) async {
    final db = AppDatabase.instance.db;
    final rows = await db.query(
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
        'rarity',
      ],
      where: 'quantity > 0 AND (rarity IS NULL OR TRIM(rarity) = ?)',
      whereArgs: [''],
      orderBy: 'id ASC',
      limit: maxCards,
    );
    if (rows.isEmpty) return 0;

    final api = ScryfallService.instance;
    final rarityCache = <String, String?>{};
    var fixed = 0;

    for (final row in rows) {
      final id = (row['id'] as num?)?.toInt();
      if (id == null) continue;
      String? rarity;

      // 1. Impressão exata.
      final scryId = (row['scryfall_id'] ?? '').toString().trim();
      if (scryId.isNotEmpty) {
        try {
          final exact = await api.getCardByScryfallId(scryId);
          rarity = (exact?['rarity'] ?? '').toString().trim();
          if (rarity.isEmpty) rarity = null;
        } catch (_) {
          rarity = null;
        }
      }

      // 2. Mesmo printing via oracle + set + coletor (cache por impressão).
      if (rarity == null) {
        final oracle = (row['oracle_id'] ?? '').toString().trim();
        final set = (row['set_code'] ?? '').toString().trim();
        final cn = (row['collector_number'] ?? '').toString().trim();
        if (oracle.isNotEmpty && set.isNotEmpty && cn.isNotEmpty) {
          final key = '$oracle|$set|${ScryfallService.normalizeCollector(cn)}';
          if (rarityCache.containsKey(key)) {
            rarity = rarityCache[key];
          } else {
            try {
              final prints =
                  await api.getPrintings(oracle, setCode: set);
              for (final p in prints) {
                if (ScryfallService.sameCollector(
                    (p['collector_number'] ?? '').toString(), cn)) {
                  rarity = (p['rarity'] ?? '').toString().trim();
                  if (rarity.isEmpty) rarity = null;
                  break;
                }
              }
            } catch (_) {
              rarity = null;
            }
            rarityCache[key] = rarity;
          }
        }
      }

      // 3. Nome + idioma (último recurso, cacheado).
      if (rarity == null) {
        final name =
            ((row['name'] ?? row['printed_name']) ?? '').toString().trim();
        final lang = (row['lang'] ?? '').toString().trim();
        if (name.isNotEmpty) {
          final key = 'n:${name.toLowerCase()}|$lang';
          if (rarityCache.containsKey(key)) {
            rarity = rarityCache[key];
          } else {
            for (final l in [if (lang.isNotEmpty) lang, 'pt', 'en']) {
              try {
                final data = await api.getCardByName(name, lang: l);
                final r = (data?['rarity'] ?? '').toString().trim();
                if (r.isNotEmpty) {
                  rarity = r;
                  break;
                }
              } catch (_) {}
            }
            rarityCache[key] = rarity;
          }
        }
      }

      if (rarity == null || rarity.isEmpty) continue;
      try {
        await db.update('cards', {'rarity': rarity},
            where: 'id = ?', whereArgs: [id]);
        fixed++;
      } catch (_) {}
    }

    if (fixed > 0) {
      debugPrint('[Rarity] $fixed raridade(s) reparada(s).');
    }
    return fixed;
  }
}
