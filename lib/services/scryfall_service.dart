import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// Espelha services/scryfall.py:
// BASE_URL, autocomplete, get_card_by_name, search, printings,
// throttle 250ms entre requests, timeout, retry simples.


class ScryfallRateLimitException implements Exception {
  const ScryfallRateLimitException(this.retryAfter);

  final Duration retryAfter;

  @override
  String toString() => 'Scryfall rate limit; retry after ${retryAfter.inSeconds}s';
}

class ScryfallService {
  ScryfallService._();
  static final ScryfallService instance = ScryfallService._();

  static const baseUrl = 'https://api.scryfall.com';

  /// O Scryfall rejeita (HTTP 400) qualquer request sem estes headers.
  static const _headers = {
    'User-Agent': 'MagicCollection/1.0 (Android)',
    'Accept': 'application/json',
  };
  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  // 10 línguas suportadas no desktop (collection_page.SCRYFALL_LANGUAGES)
  static const languages = [
    'en',
    'pt',
    'es',
    'fr',
    'de',
    'it',
    'ja',
    'ko',
    'zhs',
    'ru'
  ];

  /// Rótulos PT-BR para o seletor de idioma da busca.
  static const languageLabels = {
    'all': 'Todos',
    'en': 'Inglês',
    'pt': 'Português',
    'es': 'Espanhol',
    'fr': 'Francês',
    'de': 'Alemão',
    'it': 'Italiano',
    'ja': 'Japonês',
    'ko': 'Coreano',
    'zhs': 'Chinês S.',
    'ru': 'Russo',
  };

  Future<void> _throttle() async {
    final elapsed =
        DateTime.now().difference(_lastRequest).inMilliseconds;
    if (elapsed < 250) {
      await Future.delayed(Duration(milliseconds: 250 - elapsed));
    }
    _lastRequest = DateTime.now();
  }

  static String imageUrl(String scryfallId) {
    final id = scryfallId.trim();
    if (id.length < 2) return '';
    return 'https://cards.scryfall.io/large/front/${id[0]}/${id[1]}/$id.jpg';
  }

  /// Extrai image_url com a mesma prioridade do desktop:
  /// image_uris.png > large > normal > 1ª face > fallback por id.
  static String? extractImageUrl(Map<String, dynamic> data) {
    final uris = data['image_uris'] as Map<String, dynamic>?;
    final direct = uris?['png'] ?? uris?['large'] ?? uris?['normal'];
    if (direct is String && direct.isNotEmpty) return direct;
    final faces = data['card_faces'] as List?;
    if (faces != null) {
      for (final f in faces) {
        final fu = (f as Map)['image_uris'] as Map?;
        final u = fu?['png'] ?? fu?['large'] ?? fu?['normal'];
        if (u is String && u.isNotEmpty) return u;
      }
    }
    final id = data['id'] as String?;
    return id == null ? null : imageUrl(id);
  }

  static double? parsePrice(dynamic v) {
    if (v == null || v == '') return null;
    return double.tryParse(v.toString());
  }

  /// Achata o JSON do Scryfall para o formato da tabela `cards`.
  /// Preserva identidade da impressão (lang/set/coletor) e todos os
  /// campos de preço (USD/EUR/TIX + foils). Não inventa BRL.
  static Map<String, Object?> flatten(Map<String, dynamic> data) {
    final prices = (data['prices'] as Map?) ?? {};
    return {
      'scryfall_id': data['id'],
      'oracle_id': data['oracle_id'],
      'name': data['name'] ?? '',
      'printed_name': data['printed_name'],
      'lang': data['lang'],
      'set_code': data['set'],
      'set_name': data['set_name'],
      'collector_number': data['collector_number']?.toString(),
      'mana_cost': data['mana_cost'],
      'type_line':
          data['printed_type_line'] ?? data['type_line'],
      'oracle_text':
          data['printed_text'] ?? data['oracle_text'],
      'power': data['power']?.toString(),
      'toughness': data['toughness']?.toString(),
      'rarity': data['rarity'],
      'cmc': (data['cmc'] as num?)?.toDouble(),
      'colors': jsonEncode(data['colors'] ?? []),
      'color_identity': jsonEncode(data['color_identity'] ?? []),
      'image_url': extractImageUrl(data),
      'price_usd': parsePrice(prices['usd']),
      'price_usd_foil': parsePrice(prices['usd_foil']),
      'price_usd_etched': parsePrice(prices['usd_etched']),
      'price_eur': parsePrice(prices['eur']),
      'price_eur_foil': parsePrice(prices['eur_foil']),
      'price_tix': parsePrice(prices['tix']),
      'artist': data['artist'],
      'released_at': data['released_at'],
    };
  }

  /// Mostra os primeiros 300 chars do corpo em caso de erro,
  /// para diagnosticar se o 400 veio do Scryfall ou de um
  /// intermediário (proxy/captive portal da rede).
  static Duration? _retryAfter(http.Response res) {
    final header = res.headers['retry-after'];
    final seconds = int.tryParse(header ?? '');
    if (seconds != null && seconds > 0) {
      return Duration(seconds: seconds);
    }
    return null;
  }

  static String _bodyPreview(http.Response res) {
    final b = res.body;
    return b.length <= 300 ? b : b.substring(0, 300);
  }

  Future<List<String>> autocomplete(String query) async {
    if (query.trim().length < 2) return [];
    await _throttle();
    final uri = Uri.parse(
        '$baseUrl/cards/autocomplete?q=${Uri.encodeQueryComponent(query)}');
    try {
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
      debugPrint('[Scryfall] autocomplete "$query" -> HTTP ${res.statusCode}');
      if (res.statusCode != 200) {
        debugPrint('[Scryfall] autocomplete body: ${_bodyPreview(res)}');
        return [];
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return ((body['data'] as List?) ?? []).cast<String>();
    } catch (e) {
      debugPrint('[Scryfall] autocomplete "$query" ERRO: $e');
      rethrow;
    }
  }

  /// Busca uma impressão diretamente pelo Scryfall ID.
  /// Ideal para atualização periódica de preços, pois preserva exatamente
  /// o printing que já está salvo na coleção.
  Future<Map<String, dynamic>?> getCardByScryfallId(String scryfallId) async {
    final id = scryfallId.trim();
    if (id.isEmpty) return null;
    await _throttle();
    final uri = Uri.parse('$baseUrl/cards/${Uri.encodeComponent(id)}');
    try {
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 15));
      debugPrint('[Scryfall] id "$id" -> HTTP ${res.statusCode}');
      if (res.statusCode == 429) {
        final retryAfter = _retryAfter(res) ?? const Duration(seconds: 60);
        debugPrint('[Scryfall] id rate-limited; Retry-After=${retryAfter.inSeconds}s');
        throw ScryfallRateLimitException(retryAfter);
      }
      if (res.statusCode != 200) {
        debugPrint('[Scryfall] id body: ${_bodyPreview(res)}');
        return null;
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[Scryfall] id "$id" ERRO: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getCardByName(String name,
      {String lang = 'pt'}) async {
    await _throttle();
    final uri = Uri.parse(
        '$baseUrl/cards/named?exact=${Uri.encodeQueryComponent(name)}&lang=$lang');
    try {
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      debugPrint('[Scryfall] named "$name" lang=$lang -> HTTP ${res.statusCode}');
      if (res.statusCode == 429) {
        final retryAfter = _retryAfter(res) ?? const Duration(seconds: 60);
        debugPrint('[Scryfall] named rate-limited; Retry-After=${retryAfter.inSeconds}s');
        throw ScryfallRateLimitException(retryAfter);
      }
      if (res.statusCode != 200) {
        debugPrint('[Scryfall] named body: ${_bodyPreview(res)}');
        return null;
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[Scryfall] named "$name" ERRO: $e');
      rethrow;
    }
  }

  /// Caracteres de sintaxe do Scryfall que o OCR (ou o teclado)
  /// pode trazer junto: parênteses/colchetes/chaves/aspas
  /// desbalanceados geram HTTP 400 ("unclosed parentheses").
  /// Nomes de carta não usam esses caracteres, então removemos
  /// antes de buscar. Mantemos letras (com acento), números,
  /// espaços, apóstrofos, vírgulas e hífens ("Aang's Iceberg",
  /// "Umaro, Raging Yeti" precisam deles).
  static String sanitizeQuery(String q) {
    return q
        .replaceAll(RegExp(r'[\(\)\[\]\{\}"]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Busca full-text que ENXERGA nomes em português.
  ///
  /// Descoberta empírica: a busca padrão (`unique=cards`) só indexa
  /// os dados em inglês — "relampago" retornava só 1 carta irrelevante.
  /// Com `unique=prints&include_multilingual=true` o Scryfall casa
  /// `printed_name` em todos os idiomas ("Relâmpago", "Relâmpago do
  /// Vale", "Voto do Relâmpago"...). Depois removemos duplicadas por
  /// `oracle_id` (preferindo PT > EN) e ordenamos por relevância.
  ///
  /// `lang`: filtra os printings pelo idioma ('all' = todos).
  /// `scoreCollector`: bônus p/ nº de coletor citado (modo foto, "266").
  /// Desligar na busca de arte: os dígitos vêm de `pow=`/`tou=` e o
  /// bônus elegia impressão inglesa só por ter "5" no número.
  /// `byLanguage`: separa variantes por idioma (escolha de arte mostra
  /// PT/EN/ES… em vez de colapsar tudo numa só).
  Future<List<Map<String, dynamic>>> search(String query,
      {String lang = 'all',
      bool scoreCollector = true,
      bool byLanguage = false}) async {
    final q = sanitizeQuery(query);
    if (q.isEmpty) return [];
    await _throttle();
    final uri = Uri.parse(
        '$baseUrl/cards/search?unique=prints&include_multilingual=true'
        '&q=${Uri.encodeQueryComponent(q)}');
    late final http.Response res;
    try {
      res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[Scryfall] search "$q" ERRO: $e');
      rethrow;
    }
    debugPrint('[Scryfall] search "$q" -> HTTP ${res.statusCode}');
    // 404 = busca válida, zero resultados. Qualquer outro não-200
    // (429 rate-limit, 500 etc.) vira exceção para a UI exibir.
    if (res.statusCode == 404) return [];
    if (res.statusCode != 200) {
      debugPrint('[Scryfall] search body: ${_bodyPreview(res)}');
      throw Exception('Scryfall respondeu HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    var data =
        ((body['data'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (lang != 'all') {
      data = data
          .where((c) => (c['lang'] ?? '').toString() == lang)
          .toList();
    }
    final result =
        dedupePrints(data, q, scoreCollector: scoreCollector, byLanguage: byLanguage && lang == 'all');
    debugPrint(
        '[Scryfall] search "$q" lang=$lang -> ${data.length} printings, ${result.length} únicas');
    return result;
  }

  /// Todas as impressões (printings) de uma carta pelo oracle_id,
  /// em todos os idiomas. Usado pelo modo foto para casar o número
  /// lido na carta física e para o seletor de impressões.
  /// Se `setCode` vier (ex. "one"), filtra direto no set.
  /// Segue `next_page` (até 3 páginas): cartas como Floresta têm
  /// centenas de impressões e a correta pode estar na página 2+.
  Future<List<Map<String, dynamic>>> getPrintings(String oracleId,
      {String setCode = ''}) async {
    final q = setCode.trim().isEmpty
        ? 'oracleid:$oracleId'
        : 'oracleid:$oracleId e:${setCode.trim().toLowerCase()}';
    final out = <Map<String, dynamic>>[];
    var url = '$baseUrl/cards/search?order=released&unique=prints'
        '&include_multilingual=true'
        '&q=${Uri.encodeQueryComponent(q)}';
    try {
      for (var page = 0; page < 3; page++) {
        await _throttle();
        final res = await http
            .get(Uri.parse(url), headers: _headers)
            .timeout(const Duration(seconds: 15));
        debugPrint('[Scryfall] printings $oracleId p${page + 1} '
            '-> HTTP ${res.statusCode}');
        if (res.statusCode != 200) break;
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        out.addAll(
            ((body['data'] as List?) ?? []).cast<Map<String, dynamic>>());
        final hasMore = body['has_more'] == true;
        final next = (body['next_page'] ?? '').toString();
        if (!hasMore || next.isEmpty) break;
        url = next;
      }
      return out;
    } catch (e) {
      debugPrint('[Scryfall] printings $oracleId ERRO: $e');
      if (out.isNotEmpty) return out;
      rethrow;
    }
  }

  /// Normaliza collector number preservando o formato completo:
  /// "266 / 177" -> "266/177", "#266" -> "266". A parte "/XXX" NUNCA
  /// é descartada: 266/177 != 266/150 (imprints diferentes).
  static String normalizeCollector(String s) {
    // Corrige o OCR ANTES de miniscular (I maiúsculo sumiria).
    var t = ocrFixCollectorNumber(s).toLowerCase();
    t = t.replaceAll(RegExp(r'\s+'), '');
    if (t.startsWith('#')) t = t.substring(1);
    return t;
  }

  /// Confusões típicas do OCR no número: "266/27I" -> "266/271".
  /// Letras grudadas em dígito são erro de leitura, não sufixo
  /// (sufixos reais usam a/b minúsculos ou símbolos).
  static const _ocrConfusions = {
    'I': '1',
    'i': '1',
    'l': '1',
    'L': '1',
    'O': '0',
    'o': '0',
  };

  static String _ocrFixCollector(String t) {
    if (t.isEmpty) return t;
    final sb = StringBuffer();
    for (var i = 0; i < t.length; i++) {
      final ch = t[i];
      if (_ocrConfusions.containsKey(ch)) {
        final prevDigit =
            i > 0 && RegExp(r'[0-9]').hasMatch(t[i - 1]);
        final nextDigit =
            i < t.length - 1 && RegExp(r'[0-9]').hasMatch(t[i + 1]);
        if (prevDigit || nextDigit) {
          sb.write(_ocrConfusions[ch]);
          continue;
        }
      }
      sb.write(ch);
    }
    return sb.toString();
  }

  /// Corrige o nº lido para exibição/uso ("266/27I" -> "266/271").
  static String ocrFixCollectorNumber(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), '');
    final noHash = t.startsWith('#') ? t.substring(1) : t;
    return _ocrFixCollector(noHash);
  }

  static bool sameCollector(String a, String b) {
    final na = normalizeCollector(a);
    final nb = normalizeCollector(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    // Compara sem zeros à esquerda em cada lado da barra.
    String strip(String v) => v
        .split('/')
        .map((p) => p.replaceFirst(RegExp(r'^0+(?=\d)'), ''))
        .join('/');
    return strip(na) == strip(nb);
  }

  /// Ordena impressões: nº do coletor + código do set + idioma
  /// (lidos na carta física) primeiro, depois PT > EN > demais.
  /// - hint "266/271" (completo): match exato ganha bônus cheio.
  ///   "266/150" não pontua (imprint diferente), mas "266" (mesmo
  ///   prefixo, sem total) ainda pontua forte — nunca pode perder
  ///   para "276" só por causa do idioma.
  /// - hint "266" (só prefixo): match exato "266" > "266/..." > contém.
  static List<Map<String, dynamic>> sortPrintings(
      List<Map<String, dynamic>> prints, String collectorHint,
      {String setCode = '', String langHint = ''}) {
    final hint = normalizeCollector(collectorHint);
    final hintFull = hint.contains('/');
    final hintBase = _collectorBase(hint);
    final set = setCode.trim().toLowerCase();
    final lh = langHint.trim().toLowerCase();
    final list = prints.toList();
    int score(Map<String, dynamic> p) {
      var s = 0;
      final cn = normalizeCollector((p['collector_number'] ?? '').toString());
      if (hint.isNotEmpty && cn.isNotEmpty) {
        if (hintFull) {
          if (sameCollector(cn, hint)) {
            s -= 200;
          } else if (hintBase.isNotEmpty &&
              _collectorBase(cn) == hintBase) {
            s -= 150;
          }
        } else {
          if (cn == hint) {
            s -= 150;
          } else if (cn.startsWith('$hint/')) {
            s -= 100;
          } else if (cn.contains(hint)) {
            s -= 50;
          }
        }
      }
      final ps = ((p['set'] ?? '').toString().toLowerCase());
      if (set.isNotEmpty && ps == set) s -= 50;
      final lang = ((p['lang'] ?? '').toString());
      if (lh.isNotEmpty && lang.toLowerCase() == lh) s -= 25;
      s += lang == 'pt'
          ? 0
          : lang == 'en'
              ? 1
              : 2;
      return s;
    }

    list.sort((a, b) => score(a).compareTo(score(b)));
    return list;
  }

  /// Primeiro componente do coletor sem zeros à esquerda ("266/271"
  /// -> "266"). Usado para aproximar quando o total diverge.
  static String _collectorBase(String normalized) {
    final base = normalized.split('/').first.trim();
    return base.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  }

  /// Mesma base numérica ("266" == "266/271")? Vale quando a impressão
  /// listada não traz o total — não é conflito de /177 x /150, é
  /// ausência de informação.
  static bool sameCollectorBase(String a, String b) {
    final ba = _collectorBase(normalizeCollector(a));
    final bb = _collectorBase(normalizeCollector(b));
    return ba.isNotEmpty && ba == bb;
  }

  /// Hint sem "/XXX" (ex. "266") com 2+ impressões "266/..." distintas?
  /// Se sim, NÃO escolher automaticamente: pedir seleção manual.
  static bool isCollectorAmbiguous(
      List<Map<String, dynamic>> prints, String collectorHint) {
    final hint = normalizeCollector(collectorHint);
    if (hint.isEmpty || hint.contains('/')) return false;
    final distinct = <String>{};
    for (final p in prints) {
      final cn = normalizeCollector((p['collector_number'] ?? '').toString());
      if (cn == hint || cn.startsWith('$hint/')) distinct.add(cn);
    }
    return distinct.length > 1;
  }
  /// Usa mapa (sem índice) para nunca estourar RangeError.
  static const _accentMap = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ã': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'í': 'i',
    'ï': 'i',
    'ó': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ú': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
    'ý': 'y',
  };

  static String normalize(String s) {
    var out = s.toLowerCase();
    _accentMap.forEach((accent, plain) {
      out = out.replaceAll(accent, plain);
    });
    return out;
  }

  /// Remove printings repetidas (mesmo oracle_id), preferindo:
  ///  1. o printing EXATO (nº de coletor / set citados na busca),
  ///  2. o idioma filtrado (PT > EN quando "Todos"),
  /// e ordena: nome que contém a busca primeiro.
  /// Ex.: "floresta 266" mostra a Floresta 266/271, não uma genérica.
  /// `scoreCollector: false` ignora dígitos (busca de arte: dígitos de
  /// `pow=`/`tou=` não são nº de coletor). `byLanguage: true` chaveia
  /// por (oracle_id, idioma) para exibir variantes PT/EN/ES….
  static List<Map<String, dynamic>> dedupePrints(
      List<Map<String, dynamic>> cards, String query,
      {bool scoreCollector = true, bool byLanguage = false}) {
    final nq = normalize(query.trim());
    final digits =
        RegExp(r'\d+').allMatches(nq).map((m) => m.group(0)!).toList();
    final tokens =
        nq.split(RegExp(r'\s+')).where((t) => t.length >= 2).toList();
    final best = <String, Map<String, dynamic>>{};
    final bestScore = <String, int>{};
    for (final c in cards) {
      final oracle = (c['oracle_id'] ?? c['id']).toString();
      final lang = (c['lang'] ?? '').toString();
      final key = byLanguage ? '$oracle|$lang' : oracle;
      final name = (c['name'] ?? '').toString();
      final printed = (c['printed_name'] ?? '').toString();
      var rel = 2; // 0 = nome casa com a busca, 2 = resto
      if (nq.isNotEmpty &&
          (normalize(name).contains(nq) ||
              (printed.isNotEmpty &&
                  normalize(printed).contains(nq)))) {
        rel = 0;
      }
      // Bônus: nº de coletor citado ("266" casa "266/271", "266a"...).
      // Desligado na busca de arte (dígitos de pow/tou não são coletor).
      var bonus = 0;
      if (scoreCollector) {
        final cn = normalize((c['collector_number'] ?? '').toString());
        for (final d in digits) {
          if (cn.isNotEmpty && cn.contains(d)) bonus -= 20;
        }
      }
      // Bônus: código/nome do set citado ("dom", "dominaria"...).
      final setCode = normalize((c['set'] ?? '').toString());
      final setName = normalize((c['set_name'] ?? '').toString());
      for (final t in tokens) {
        if (t == setCode || (t.length > 3 && setName.contains(t))) {
          bonus -= 10;
        }
      }
      final langScore = lang == 'pt'
          ? 0
          : lang == 'en'
              ? 1
              : 2;
      final total = rel * 10 + langScore + bonus;
      if (!best.containsKey(key) || total < bestScore[key]!) {
        best[key] = c;
        bestScore[key] = total;
      }
    }
    final list = best.values.toList();
    String scoreKey(Map<String, dynamic> m) {
      final oracle = (m['oracle_id'] ?? m['id']).toString();
      if (!byLanguage) return oracle;
      return '$oracle|${(m['lang'] ?? '').toString()}';
    }

    list.sort((a, b) =>
        (bestScore[scoreKey(a)] ?? 999).compareTo(bestScore[scoreKey(b)] ?? 999));
    return list;
  }
}
