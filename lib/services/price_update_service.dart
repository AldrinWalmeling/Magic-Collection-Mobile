import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_database.dart';
import 'card_price_resolver.dart';
import 'scryfall_service.dart';

enum PriceUpdateState {
  idle,
  updating,
  paused,
  completed,
}

/// Sincroniza os preços da coleção com o Scryfall de forma controlada.
///
/// Regras importantes:
/// - no máximo 1 sincronização por banco ao mesmo tempo;
/// - atualização automática no máximo 1x a cada 24h;
/// - 429 pausa a fila inteira e espera o tempo informado pelo Scryfall;
/// - a carta que sofreu 429 é tentada novamente antes de avançar;
/// - IDs pendentes ficam persistidos para a próxima execução;
/// - o estado é exposto para a interface mostrar "atualizando" / "pausado";
/// - a UI nunca precisa esperar a sincronização terminar.
/// - NUNCA sobrescreve identidade (nome/lang/set/coletor/finish):
///   atualiza só preços + price_ref_* + price_source + rarity quando vazia.
/// - Mesma impressão em outro idioma (preferindo EN) é fallback válido
///   e vai para price_usd + price_ref_usd com source 'fallback-same-print'.
/// - Outra impressão é só aproximada: fica em price_ref_usd com source
///   'approx-other-print', sem trocar o price_usd da impressão correta.
/// - Sem preço: mantém sem preço, source 'none'.
class PriceUpdateService extends ChangeNotifier {
  PriceUpdateService._();

  static final PriceUpdateService instance = PriceUpdateService._();

  static const _prefsKeyPrefix = 'prices_last_update_at::';
  static const _pendingKeyPrefix = 'prices_pending_ids::';
  static const updateInterval = Duration(hours: 24);
  static const max429RetriesPerCard = 2;
  static const defaultRateLimitPause = Duration(seconds: 60);

  bool _running = false;
  PriceUpdateState _state = PriceUpdateState.idle;
  int _pausedSeconds = 0;
  int _processed = 0;
  int _total = 0;
  String? _currentCard;
  DateTime? _lastErrorAt;
  String? _lastError;

  bool get isRunning => _running;
  PriceUpdateState get state => _state;
  int get pausedSeconds => _pausedSeconds;
  int get processed => _processed;
  int get total => _total;
  String? get currentCard => _currentCard;
  String? get lastError => _lastError;
  DateTime? get lastErrorAt => _lastErrorAt;

  void _setState(PriceUpdateState value) {
    if (_state == value) return;
    _state = value;
    notifyListeners();
  }

  void _notifyProgress() {
    notifyListeners();
  }

  Future<String> _dbKey() async {
    final prefs = await SharedPreferences.getInstance();
    final dbPath = prefs.getString('active_db_path') ?? 'default';
    return dbPath;
  }

  Future<String> _prefsKey() async {
    return '$_prefsKeyPrefix${await _dbKey()}';
  }

  Future<String> _pendingKey() async {
    return '$_pendingKeyPrefix${await _dbKey()}';
  }

  Future<DateTime?> get lastUpdate async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await _prefsKey());
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  Future<bool> shouldUpdate({bool force = false}) async {
    if (force) return true;
    final last = await lastUpdate;
    if (last == null) return true;
    return DateTime.now().difference(last) >= updateInterval;
  }

  Future<List<int>> _loadPendingIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(await _pendingKey());
    if (raw == null || raw.isEmpty) return <int>[];

    try {
      final data = jsonDecode(raw) as List?;
      return (data ?? const [])
          .map((e) => int.tryParse(e.toString()))
          .whereType<int>()
          .toSet()
          .toList();
    } catch (_) {
      return <int>[];
    }
  }

  Future<void> _savePendingIds(Iterable<int> ids) async {
    final unique = ids.toSet().toList()..sort();
    final prefs = await SharedPreferences.getInstance();
    if (unique.isEmpty) {
      await prefs.remove(await _pendingKey());
      return;
    }
    await prefs.setString(await _pendingKey(), jsonEncode(unique));
  }

  Future<void> _removePendingId(int id) async {
    final pending = await _loadPendingIds();
    if (!pending.remove(id)) return;
    await _savePendingIds(pending);
  }

  Future<void> _pauseForRateLimit(Duration duration) async {
    final totalSeconds = duration.inSeconds.clamp(1, 600);
    _pausedSeconds = totalSeconds;
    _setState(PriceUpdateState.paused);

    while (_pausedSeconds > 0 && _running) {
      await Future.delayed(const Duration(seconds: 1));
      if (!_running) break;
      _pausedSeconds -= 1;
      _notifyProgress();
    }

    _pausedSeconds = 0;
    if (_running) {
      _setState(PriceUpdateState.updating);
    }
  }

  Future<PriceResolution?> _fetchResolution(
    int localId,
    Map<String, Object?> row,
  ) async {
    var retries429 = 0;
    final name = ((row['name'] ?? row['printed_name']) ?? '').toString();

    while (_running) {
      try {
        final res =
            await CardPriceResolver.instance.resolveForLocalCard(
          name: name,
          scryfallId: (row['scryfall_id'] ?? '').toString(),
          oracleId: (row['oracle_id'] ?? '').toString(),
          lang: (row['lang'] ?? '').toString(),
          setCode: (row['set_code'] ?? '').toString(),
          collectorNumber: (row['collector_number'] ?? '').toString(),
          finish: (row['preferred_finish'] ?? '').toString(),
        );
        return res;
      } on ScryfallRateLimitException catch (e) {
        retries429++;
        await _savePendingIds({
          ...(await _loadPendingIds()),
          localId,
        });

        debugPrint(
          '[Prices] Scryfall limit atingido em "${name.isEmpty ? localId : name}"; '
          'pausando ${e.retryAfter.inSeconds}s antes de continuar.',
        );

        await _pauseForRateLimit(e.retryAfter);

        if (retries429 >= max429RetriesPerCard) {
          _lastError =
              'Limite do Scryfall persistente em ${name.isEmpty ? localId : name}';
          _lastErrorAt = DateTime.now();
          _notifyProgress();
          return null;
        }
      } catch (e) {
        debugPrint(
          '[Prices] erro ao consultar ${name.isEmpty ? localId : name}: $e',
        );
        return null;
      }
    }

    return null;
  }

  /// Monta o UPDATE preservando identidade: só preços + referência +
  /// fonte + rarity (só quando a local está vazia).
  Map<String, Object?> _buildPriceValues(
    Map<String, Object?> row,
    PriceResolution res,
  ) {
    final now = DateTime.now().toUtc().toIso8601String();
    final values = <String, Object?>{
      'price_source': res.source,
      'price_updated_at': now,
    };

    if (res.source == 'exact' || res.source == 'fallback-same-print') {
      // Preço da mesma edição: pode compor price_usd e totais.
      values['price_usd'] = res.usd;
      values['price_usd_foil'] = res.usdFoil;
      values['price_usd_etched'] = res.usdEtched;
      values['price_eur'] = res.eur;
      values['price_eur_foil'] = res.eurFoil;
      values['price_tix'] = res.tix;
      if (res.source == 'exact') {
        values['price_ref_usd'] = null;
        values['price_ref_name'] = null;
      } else {
        final finish =
            (row['preferred_finish'] ?? '').toString().trim().toLowerCase();
        final refUsd = res.priceForFinish(finish);
        values['price_ref_usd'] = refUsd ?? res.usd ?? res.usdFoil;
        values['price_ref_name'] =
            '${res.sourceName} (mesma impressão, outro idioma)';
      }
    } else if (res.source == 'approx-other-print') {
      // Outra impressão: NÃO troca o price_usd da edição correta.
      // Guarda só como referência aproximada.
      final finish =
          (row['preferred_finish'] ?? '').toString().trim().toLowerCase();
      final refUsd = res.priceForFinish(finish);
      values['price_ref_usd'] = refUsd ?? res.usd ?? res.usdFoil;
      values['price_ref_name'] =
          '${res.sourceName} (outra impressão, aproximado)';
    } else {
      // 'none': mantém preços existentes, só carimba a fonte.
    }

    final localRarity = (row['rarity'] ?? '').toString().trim();
    if (localRarity.isEmpty) {
      // Raridade vem do resolver indiretamente? Mantém vazio aqui —
      // o fetch exato já expõe via printings quando preciso.
      // Não inventa raridade de outra impressão.
    }

    return values;
  }

  Future<bool> _applyResolution(int localId, Map<String, Object?> row,
      PriceResolution res) async {
    final db = AppDatabase.instance.db;
    try {
      final values = _buildPriceValues(row, res);
      await db.update(
        'cards',
        values,
        where: 'id = ?',
        whereArgs: [localId],
      );

      final name = ((row['name'] ?? row['printed_name']) ?? localId).toString();
      debugPrint(
        '[Prices] $name -> source=${res.source} '
        'USD=${values['price_usd'] ?? row['price_usd']} '
        'ref=${values['price_ref_usd']}',
      );

      if (res.source == 'exact' || res.source == 'fallback-same-print') {
        await _removePendingId(localId);
      } else {
        // Aproximado/sem preço: tenta de novo no próximo ciclo.
        await _savePendingIds({
          ...(await _loadPendingIds()),
          localId,
        });
      }
      return true;
    } catch (e) {
      debugPrint('[Prices] falha ao salvar $localId: $e');
      await _savePendingIds({
        ...(await _loadPendingIds()),
        localId,
      });
      return false;
    }
  }

  /// Atualiza UMA carta sob demanda (botão "atualizar preço").
  /// Sempre consulta a API, ignorando o intervalo de 24h.
  Future<bool> refreshSingleCard(int localId) async {
    final wasRunning = _running;
    if (!_running) {
      _running = true;
      _setState(PriceUpdateState.updating);
    }
    try {
      final db = AppDatabase.instance.db;
      final rows = await db.query('cards', where: 'id = ?', whereArgs: [localId], limit: 1);
      if (rows.isEmpty) return false;
      final row = rows.first;
      _currentCard = ((row['name'] ?? row['printed_name']) ?? '#$localId').toString();
      _notifyProgress();
      final res = await _fetchResolution(localId, row);
      if (res == null) return false;
      return await _applyResolution(localId, row, res);
    } finally {
      _currentCard = null;
      if (!wasRunning) {
        _running = false;
        _setState(PriceUpdateState.completed);
      }
      notifyListeners();
    }
  }

  Future<int> refreshCollectionPrices({bool force = false}) async {
    if (_running) return 0;
    if (!await shouldUpdate(force: force)) return 0;

    _running = true;
    _setState(PriceUpdateState.updating);
    _processed = 0;
    _total = 0;
    _currentCard = null;
    _lastError = null;
    _lastErrorAt = null;

    var updated = 0;

    try {
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
          'set_name',
          'collector_number',
          'preferred_finish',
          'rarity',
          'price_usd',
          'price_ref_usd',
        ],
        where: 'quantity > 0',
        orderBy: 'id ASC',
      );

      final byId = <int, Map<String, Object?>>{};
      for (final row in rows) {
        final id = (row['id'] as num?)?.toInt();
        if (id != null) byId[id] = row;
      }

      final pendingIds = await _loadPendingIds();
      final ordered = <Map<String, Object?>>[];

      if (pendingIds.isNotEmpty && !force) {
        // Há uma fila pendente: nesta execução trabalhamos somente nela.
        for (final id in pendingIds) {
          final row = byId[id];
          if (row != null) ordered.add(row);
        }
        debugPrint('[Prices] retomando ${ordered.length} carta(s) pendente(s).');
      } else {
        ordered.addAll(rows);
      }

      _total = ordered.length;
      _notifyProgress();

      for (final row in ordered) {
        if (!_running) break;

        final localId = (row['id'] as num?)?.toInt();
        if (localId == null) continue;

        final scryfallId = (row['scryfall_id'] ?? '').toString().trim();
        final name = ((row['name'] ?? row['printed_name']) ?? '')
            .toString()
            .trim();

        if (scryfallId.isEmpty && name.isEmpty) {
          _processed++;
          _notifyProgress();
          continue;
        }

        _currentCard = name.isEmpty ? '#$localId' : name;
        _notifyProgress();

        final res = await _fetchResolution(localId, row);
        if (!_running) break;

        _processed++;
        _notifyProgress();

        if (res == null) {
          await _savePendingIds({
            ...(await _loadPendingIds()),
            localId,
          });
          continue;
        }

        if (await _applyResolution(localId, row, res)) {
          updated++;
        }
      }

      final pendingAfter = await _loadPendingIds();
      if (updated > 0 && pendingAfter.isEmpty && _running) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          await _prefsKey(),
          DateTime.now().toUtc().toIso8601String(),
        );
      }

      return updated;
    } finally {
      _currentCard = null;
      _pausedSeconds = 0;
      _running = false;
      _setState(PriceUpdateState.completed);
      notifyListeners();
    }
  }
}
