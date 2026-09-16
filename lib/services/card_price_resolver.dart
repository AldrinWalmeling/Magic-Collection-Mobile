// Resolve preço da impressão exata com fallback por idioma.
//
// Prioridade absoluta:
//   mesma carta + mesmo set + mesmo collector_number + mesmo finish
// Fallbacks, nesta ordem:
//   1. scryfall_id exato (impressão + idioma exatos) -> source 'exact'
//   2. mesma impressão (set + collector_number) em outro idioma,
//      preferindo EN -> source 'fallback-same-print'
//      (valor de referência válido, mesma edição)
//   3. outra impressão da mesma carta (mesmo oracle_id) ->
//      source 'approx-other-print' (valor aproximado, NÃO vai para
//      price_usd — fica só em price_ref_usd)
//   4. nada -> source 'none' (mantém sem preço, não inventa valor)
//
// Preservação: o resolver NUNCA devolve nome/lang/set/collector para
// sobrescrever a carta local. Só preços + identificação da fonte.
// Quem chama atualiza APENAS as colunas de preço + price_ref_* +
// price_source, mantendo idioma/impressão/finish originais.

import 'package:flutter/foundation.dart';

import 'scryfall_service.dart';

class PriceResolution {
  final double? usd;
  final double? usdFoil;
  final double? usdEtched;
  final double? eur;
  final double? eurFoil;
  final double? tix;

  /// 'exact' | 'fallback-same-print' | 'approx-other-print' | 'none'
  final String source;

  /// Descrição legível, ex.: "EN #123 mesma impressão" ou "aproximada".
  final String sourceName;
  final String sourceLang;
  final String sourceScryfallId;
  final bool exactFound;

  const PriceResolution({
    this.usd,
    this.usdFoil,
    this.usdEtched,
    this.eur,
    this.eurFoil,
    this.tix,
    required this.source,
    this.sourceName = '',
    this.sourceLang = '',
    this.sourceScryfallId = '',
    this.exactFound = false,
  });

  bool get hasAnyPrice =>
      usd != null ||
      usdFoil != null ||
      usdEtched != null ||
      eur != null ||
      eurFoil != null ||
      tix != null;

  /// Preço correspondente ao finish da carta local.
  double? priceForFinish(String finish) {
    final f = finish.trim().toLowerCase();
    if (f.contains('etch')) {
      return usdEtched ?? usdFoil ?? usd;
    }
    if (f.contains('foil')) {
      return usdFoil ?? usdEtched ?? usd;
    }
    return usd ?? usdFoil ?? usdEtched;
  }
}

class CardPriceResolver {
  CardPriceResolver._();
  static final CardPriceResolver instance = CardPriceResolver._();

  static double? _parse(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return null;
    return double.tryParse(s);
  }

  static PriceResolution _fromData(
    Map<String, dynamic> data, {
    required String source,
    required bool exactFound,
    String sourceName = '',
  }) {
    final prices = (data['prices'] as Map?) ?? const {};
    final lang = (data['lang'] ?? '').toString();
    final set = (data['set'] ?? '').toString().toUpperCase();
    final cn = (data['collector_number'] ?? '').toString();
    final name = sourceName.isNotEmpty
        ? sourceName
        : '${data['name'] ?? ''} [$set #$cn $lang]'.trim();
    return PriceResolution(
      usd: _parse(prices['usd']),
      usdFoil: _parse(prices['usd_foil']),
      usdEtched: _parse(prices['usd_etched']),
      eur: _parse(prices['eur']),
      eurFoil: _parse(prices['eur_foil']),
      tix: _parse(prices['tix']),
      source: source,
      sourceName: name,
      sourceLang: lang,
      sourceScryfallId: (data['id'] ?? '').toString(),
      exactFound: exactFound,
    );
  }

  static bool _hasUsablePrice(Map<String, dynamic> data, String finish) {
    final r = _fromData(data, source: 'exact', exactFound: true);
    if (!r.hasAnyPrice) return false;
    // Exige ao menos o campo do finish; se não houver, aceita qualquer
    // outro campo como referência da mesma impressão.
    return r.priceForFinish(finish) != null;
  }

  static String _normCn(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'^0+'), '');

  static bool _sameCollector(String a, String b) {
    if (a.trim().isEmpty || b.trim().isEmpty) return false;
    if (a.trim().toLowerCase() == b.trim().toLowerCase()) return true;
    return _normCn(a) == _normCn(b);
  }

  /// Resolve o preço para a carta local sem nunca trocar sua identidade.
  Future<PriceResolution> resolveForLocalCard({
    required String name,
    String scryfallId = '',
    String oracleId = '',
    String lang = '',
    String setCode = '',
    String collectorNumber = '',
    String finish = '',
  }) async {
    final displayName = name.trim().isEmpty ? '#sem-nome' : name.trim();
    debugPrint('[Scryfall] Buscando carta: $displayName');
    debugPrint('[Scryfall] Idioma: ${lang.isEmpty ? "?" : lang}');
    debugPrint(
        '[Scryfall] Impressão: ${setCode.isEmpty ? "?" : setCode.toUpperCase()} / ${collectorNumber.isEmpty ? "?" : collectorNumber}');

    final api = ScryfallService.instance;
    Map<String, dynamic>? exact;
    String effectiveOracle = oracleId.trim();

    // 1. Impressão exata via scryfall_id.
    if (scryfallId.trim().isNotEmpty) {
      try {
        exact = await api.getCardByScryfallId(scryfallId.trim());
      } catch (_) {
        exact = null;
      }
      if (exact != null) {
        if (effectiveOracle.isEmpty) {
          effectiveOracle = (exact['oracle_id'] ?? '').toString();
        }
        if (_hasUsablePrice(exact, finish)) {
          debugPrint('[Scryfall] Preço da impressão exata encontrado.');
          return _fromData(exact, source: 'exact', exactFound: true);
        }
        debugPrint(
            '[Scryfall] Preço da impressão exata não encontrado.');
      } else {
        debugPrint('[Scryfall] scryfall_id não retornou dados.');
      }
    }

    // Descobre oracle_id se ainda não temos (para os fallbacks).
    if (effectiveOracle.isEmpty && displayName != '#sem-nome') {
      for (final l in [if (lang.isNotEmpty) lang, 'pt', 'en']) {
        try {
          final byName = await api.getCardByName(displayName, lang: l);
          if (byName != null &&
              (byName['oracle_id'] ?? '').toString().isNotEmpty) {
            effectiveOracle = (byName['oracle_id'] ?? '').toString();
            // Se o fetch exato falhou mas o named retornou a mesma
            // impressão com preço, usa direto (ainda é exato por
            // set+coletor quando bater).
            if (exact == null &&
                _sameSetCollector(byName, setCode, collectorNumber) &&
                _hasUsablePrice(byName, finish)) {
              debugPrint(
                  '[Scryfall] Preço exato via named ($l) encontrado.');
              return _fromData(byName,
                  source: 'exact', exactFound: true);
            }
            break;
          }
        } catch (_) {
          // 404 / rede: tenta próximo idioma.
        }
      }
      if (effectiveOracle.isEmpty) {
        debugPrint('[Scryfall] oracle_id não identificado; '
            'fallback por nome será aproximado.');
      }
    }

    // 2. Mesma impressão em outro idioma (set + collector_number).
    if (effectiveOracle.isNotEmpty) {
      try {
        debugPrint('[Scryfall] Tentando fallback para outra língua '
            'da mesma impressão.');
        final prints =
            await api.getPrintings(effectiveOracle, setCode: setCode);
        final samePrint = prints.where((p) {
          final ps = (p['set'] ?? '').toString();
          final cn = (p['collector_number'] ?? '').toString();
          final setOk = setCode.trim().isEmpty ||
              ps.toLowerCase() == setCode.trim().toLowerCase();
          final cnOk = collectorNumber.trim().isEmpty ||
              _sameCollector(cn, collectorNumber);
          return setOk && cnOk;
        }).toList();

        if (samePrint.isNotEmpty) {
          samePrint.sort((a, b) =>
              _langRank((a['lang'] ?? '').toString(), preferEn: true)
                  .compareTo(
                      _langRank((b['lang'] ?? '').toString(), preferEn: true)));
          for (final p in samePrint) {
            if (_hasUsablePrice(p, finish)) {
              final pl = (p['lang'] ?? '').toString();
              debugPrint('[Scryfall] Preço encontrado via versão '
                  '${pl.isEmpty ? "?" : pl} da mesma impressão.');
              debugPrint('[Scryfall] Fonte do preço: fallback — '
                  'mesma impressão, idioma diferente.');
              return _fromData(p,
                  source: 'fallback-same-print', exactFound: false);
            }
          }
          debugPrint('[Scryfall] Mesma impressão encontrada, '
              'mas sem preço em nenhum idioma.');
        } else {
          debugPrint('[Scryfall] Mesma impressão (set+coletor) não '
              'localizada nos printings.');
        }

        // 3. Último recurso: outra impressão da mesma carta.
        for (final p in prints) {
          if (_hasUsablePrice(p, finish)) {
            debugPrint('[Scryfall] Usando outra impressão como valor '
                'APROXIMADO (não substitui a impressão correta).');
            debugPrint('[Scryfall] Fonte do preço: aproximado — '
                'outra impressão da mesma carta.');
            return _fromData(p,
                source: 'approx-other-print', exactFound: false);
          }
        }
      } catch (e) {
        debugPrint('[Scryfall] Falha no fallback de printings: $e');
      }
    }

    // 4. Nome exato em EN como referência aproximada (só se nada acima).
    if (displayName != '#sem-nome') {
      try {
        final en = await api.getCardByName(displayName, lang: 'en');
        if (en != null && _hasUsablePrice(en, finish)) {
          // Só considera aproximado: não garante mesmo set/coletor.
          debugPrint('[Scryfall] Preço EN por nome como APROXIMADO.');
          return _fromData(en,
              source: 'approx-other-print', exactFound: false);
        }
      } catch (_) {}
    }

    debugPrint('[Scryfall] Nenhum valor encontrado; mantendo sem preço.');
    return const PriceResolution(source: 'none', exactFound: false);
  }

  static bool _sameSetCollector(
      Map<String, dynamic> p, String setCode, String collectorNumber) {
    if (setCode.trim().isNotEmpty &&
        (p['set'] ?? '').toString().toLowerCase() !=
            setCode.trim().toLowerCase()) {
      return false;
    }
    if (collectorNumber.trim().isNotEmpty &&
        !_sameCollector(
            (p['collector_number'] ?? '').toString(), collectorNumber)) {
      return false;
    }
    return true;
  }

  static int _langRank(String lang, {bool preferEn = false}) {
    final l = lang.toLowerCase();
    if (preferEn) {
      if (l == 'en') return 0;
      if (l == 'pt') return 1;
      return 2;
    }
    if (l == 'pt') return 0;
    if (l == 'en') return 1;
    return 2;
  }
}
