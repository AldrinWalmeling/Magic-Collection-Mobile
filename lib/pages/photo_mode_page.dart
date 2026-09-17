import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../data/app_database.dart';
import '../services/app_events.dart';
import '../services/app_locale.dart';
import '../services/currency_service.dart';
import '../services/scryfall_service.dart';
import '../theme/app_theme.dart';

// Modo foto: aponta a câmera para a carta física, o OCR lê o nome,
// busca no Scryfall, mostra a arte + dados e adiciona com 1 toque.
// Depois de adicionar, volta sozinho para a câmera (fluxo rápido).

class PhotoModePage extends StatefulWidget {
  const PhotoModePage({super.key});

  @override
  State<PhotoModePage> createState() => _PhotoModePageState();
}

enum _Phase { preview, processing, result }

class _PhotoModePageState extends State<PhotoModePage>
    with SingleTickerProviderStateMixin {
  CameraController? _camera;
  late final TextRecognizer _recognizer;
  late final AnimationController _pop;
  late final Animation<double> _popScale;

  _Phase _phase = _Phase.preview;
  String? _initError;
  String _status = '';
  // Chave do status ('reading' | 'recognizing' | '') para retraduzir
  // ao trocar o idioma no meio do processamento.
  String _statusKey = '';

  void _setStatus(String key) {
    _statusKey = key;
    _status = switch (key) {
      'reading' => AppLocale.t('pm_reading'),
      'recognizing' => AppLocale.t('pm_recognizing'),
      _ => '',
    };
  }

  final _nameEdit = TextEditingController();
  // Correção manual: nº coletor, set, idioma e tipo básico.
  final _collectorEdit = TextEditingController();
  final _setEdit = TextEditingController();
  String _manualLang = 'all';
  bool _autoBasic = false;
  bool? _basicOverride;
  // Última query efetiva enviada (pode incluir t:basic).
  String _pendingQuery = '';
  List<String> _candidates = [];
  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic>? _picked;
  // Impressões da carta escolhida + seletor.
  List<Map<String, dynamic>> _prints = [];
  bool _printsLoading = false;
  // Pistas lidas na carta física: nº, código do set, idioma.
  String _ocrCollector = '';
  String _ocrSet = '';
  String _ocrLang = '';
  // Hint sem "/total" com 2+ impressões distintas? Não escolhe sozinho.
  bool _collectorAmbiguous = false;
  // O 1º da lista confere MESMO com nº+set lidos? Se não, o cabeçalho
  // não afirma "detectado" e pede escolha manual.
  bool _exactPrintMatch = false;
  // Filtros locais da lista de impressões (edição + idioma).
  String _printSetFilter = 'all';
  String _printLangFilter = 'all';
  bool _searching = false;
  bool _adding = false;
  String? _searchError;
  int _addedCount = 0;
  // Painel livre: fração da altura (0.14 recolhido – 0.92 aberto).
  // Segue o dedo no arrasto, sem pular de tudo p/ nada.
  static const _panelMin = 0.14;
  static const _panelRest = 0.62;
  static const _panelMax = 0.92;
  double _panelFrac = _panelRest;
  bool _panelDragging = false;
  Offset? _focusPoint;
  Timer? _focusIndicatorTimer;
  bool _torchOn = false;
  double _zoom = 1;
  double _maxZoom = 1;

  @override
  void initState() {
    super.initState();
    _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _pop = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _popScale = CurvedAnimation(parent: _pop, curve: Curves.elasticOut);
    _initCamera();
    AppLocale.current.addListener(_onLocale);
    AppEvents.topVisible.addListener(_onBars);
  }

  @override
  void dispose() {
    _focusIndicatorTimer?.cancel();
    _camera?.dispose();
    _recognizer.close();
    _pop.dispose();
    _nameEdit.dispose();
    _collectorEdit.dispose();
    _setEdit.dispose();
    AppLocale.current.removeListener(_onLocale);
    AppEvents.topVisible.removeListener(_onBars);
    super.dispose();
  }

  void _onLocale() {
    if (mounted) {
      // Retraduz o status em andamento; erros transitórios mantêm o texto.
      setState(() => _setStatus(_statusKey));
    }
  }

  void _onBars() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Tocou num campo de texto: abre o painel para o teclado não
  /// esconder o campo em edição.
  void _expandPanel() {
    if (_panelFrac < _panelRest && mounted) {
      setState(() => _panelFrac = _panelRest);
    }
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _initError = AppLocale.t('pm_perm'));
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _initError = AppLocale.t('pm_nocam'));
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        // A leitura de títulos pequenos se beneficia da imagem mais nítida.
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      try {
        await controller.setFocusMode(FocusMode.auto);
        await controller.setExposureMode(ExposureMode.auto);
        _maxZoom = (await controller.getMaxZoomLevel()).clamp(1.0, 3.0);
        await controller.setZoomLevel(_zoom);
      } catch (_) {
        // Controles manuais variam entre fabricantes; a câmera continua útil.
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (e) {
      if (mounted) {
        setState(() =>
            _initError = AppLocale.t('pm_camfail').replaceAll('{e}', '$e'));
      }
    }
  }

  // ============ captura + OCR ============

  Future<void> _focusAt(TapDownDetails details, Size size) async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    final point = Offset(
      (details.localPosition.dx / size.width).clamp(0.0, 1.0),
      (details.localPosition.dy / size.height).clamp(0.0, 1.0),
    );
    setState(() => _focusPoint = point);
    _focusIndicatorTimer?.cancel();
    _focusIndicatorTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    try {
      await cam.setFocusPoint(point);
      await cam.setExposurePoint(point);
    } catch (_) {
      // Alguns aparelhos mantêm apenas o foco automático central.
    }
  }

  Future<void> _toggleTorch() async {
    final cam = _camera;
    if (cam == null) return;
    final next = !_torchOn;
    try {
      await cam.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {
      // Lanterna não é disponibilizada por toda câmera.
    }
  }

  Future<void> _capture() async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;
    setState(() {
      _phase = _Phase.processing;
      _setStatus('reading');
      _candidates = [];
      _results = [];
      _picked = null;
      _prints = [];
      _ocrCollector = '';
      _ocrSet = '';
      _ocrLang = '';
      _collectorAmbiguous = false;
      _exactPrintMatch = false;
      _printSetFilter = 'all';
      _printLangFilter = 'all';
      _searchError = null;
      _panelFrac = _panelRest;
    });
    try {
      final photo = await cam.takePicture();
      setState(() => _setStatus('recognizing'));
      final input = InputImage.fromFilePath(photo.path);
      final recognized = await _recognizer.processImage(input);

      // Largura da foto p/ geometria (nº do coletor fica à esquerda,
      // poder/resistência como "5/4" fica à direita).
      var imgW = 0;
      try {
        final bytes = await photo.readAsBytes();
        final done = Completer<int>();
        ui.decodeImageFromList(bytes, (ui.Image img) {
          done.complete(img.width);
          img.dispose();
        });
        imgW = await done.future
            .timeout(const Duration(seconds: 3), onTimeout: () => 0);
      } catch (_) {}

      // Blocos de cima para baixo; o título fica no topo.
      final blocks = recognized.blocks.toList()
        ..sort((a, b) =>
            (a.boundingBox?.top ?? 0).compareTo(b.boundingBox?.top ?? 0));
      final cands = <String>[];
      var collector = '';
      var setCode = '';
      var lang = '';
      for (var bi = 0; bi < blocks.length; bi++) {
        final b = blocks[bi];
        for (final line in b.lines) {
          final t = line.text.trim();
          if (t.length < 2) continue;
          // Linha de coletor ("266/271 L") não é nome: fora dos chips
          // para nunca buscar "266/271 L" como se fosse carta.
          if (bi < 3 &&
              cands.length < 5 &&
              !cands.contains(t) &&
              !_looksCollectorLine(t)) {
            cands.add(t);
          }
          // ---- pistas com geometria + contexto ----
          final box = line.boundingBox;
          final leftSide =
              box == null || imgW == 0 ? true : box.center.dx < imgW * 0.6;
          final tokens = t.split(RegExp(r'[^A-Za-z0-9]+'));
          // Idioma primeiro: "PT"/"EN" nunca são código de set.
          var lineHasLang = false;
          for (final tk in tokens) {
            if (tk.length < 2 || tk.length > 4) continue;
            final up = tk.toUpperCase();
            if (tk != up) continue;
            if (_ocrLangs.containsKey(up)) {
              lineHasLang = true;
              if (lang.isEmpty) lang = _ocrLangs[up]!;
            }
          }
          final hasCollectorPat =
              RegExp(r'(\d+[a-zA-Z]?)\s*/\s*(\d+[a-zA-Z]?)')
                      .hasMatch(t) ||
                  RegExp(r'#\s*\d').hasMatch(t);
          var lineHasSetOrLang = lineHasLang;
          // Set/edição: EXATAMENTE 3 letras (ONE, WOE...). Fragmento de
          // número ("266L") ou palavra do texto ("THE", "ADD", "TAP")
          // nunca entra. Só vale na linha do rodapé (mesma linha do
          // nº/idioma), nunca no meio do texto de regras.
          for (final tk in tokens) {
            if (setCode.isNotEmpty) break;
            if (tk.length != 3) continue;
            final up = tk.toUpperCase();
            if (tk != up) continue; // só MAIÚSCULO
            if (!RegExp(r'^[A-Z]{3}$').hasMatch(up)) continue;
            if (_ocrLangs.containsKey(up)) continue;
            if (_setStoplist.contains(up)) continue;
            if (!(hasCollectorPat || lineHasLang)) continue;
            setCode = up;
            lineHasSetOrLang = true;
          }
          // Padrão N/M: coletor ("266/177") x poder/resistência ("5/4").
          // Vale se: lado esquerdo, OU tiragem >= 30 (P/T nunca chega
          // lá), OU mesma linha tem set/idioma.
          // O formato COMPLETO é preservado: "266/177" != "266/150".
          for (final m in RegExp(r'(\d+[a-zA-Z]?)\s*/\s*(\d+[a-zA-Z]?)')
              .allMatches(t)) {
            if (collector.isNotEmpty) break;
            final size = int.tryParse(
                    m.group(2)!.replaceAll(RegExp(r'[^0-9]'), '')) ??
                0;
            if (leftSide || size >= 30 || lineHasSetOrLang) {
              collector =
                  '${m.group(1)!.trim()}/${m.group(2)!.trim()}';
            }
          }
          // Nº sozinho com "#": "#266" (sem total). Só vale com "#"
          // para nunca confundir com P/T ou custo de mana.
          if (collector.isEmpty) {
            final lone = RegExp(r'#\s*(\d+[a-zA-Z]?)').firstMatch(t);
            if (lone != null && (leftSide || lineHasSetOrLang)) {
              collector = lone.group(1)!.trim();
            }
          }
        }
      }
      if (!mounted) return;
      if (cands.isEmpty) {
        setState(() {
          _phase = _Phase.preview;
          _setStatus('');
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppLocale.t('pm_noread'))));
        return;
      }
      setState(() {
        _candidates = cands;
        // A caixa mostra SÓ o título limpo ("Floresta").
        final title = _cleanTitle(cands.first);
        _nameEdit.text = title;
        // Pistas (nº, set, idioma) casam depois com as impressões.
        // O nº já sai com confusões do OCR corrigidas (27I -> 271).
        _ocrCollector = ScryfallService.ocrFixCollectorNumber(collector);
        _ocrSet = setCode;
        _ocrLang = lang;
        // Campos de correção manual começam com o detectado.
        _collectorEdit.text = _ocrCollector;
        _setEdit.text = setCode;
        _manualLang = lang.isEmpty ? 'all' : lang;
        _autoBasic = _looksBasicLand(cands);
        _basicOverride = null;
        _phase = _Phase.result;
        // Se a linha de tipo diz que é terreno básico, trava a
        // busca nos básicos: "Floresta" + "terreno básico" vira
        // !"Forest" t:basic (nunca mais "Floresta Flagelada").
        final basicOracle = _basicOracleName(title);
        if (basicOracle != null && _looksBasicLand(cands)) {
          _pendingQuery = '!"$basicOracle" t:basic';
        } else if (_looksBasicLand(cands)) {
          _pendingQuery = '$title t:basic';
        } else {
          _pendingQuery = title;
        }
      });
      await _searchName(_pendingQuery);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.preview;
        _setStatus('');
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocale.t('pm_readfail').replaceAll('{e}', '$e'))));
    }
  }

  /// Limpa título lido pelo OCR: "(Floresta)" -> "Floresta",
  /// "Zetalpa, Aurora Primordial 6&*" -> "Zetalpa, Aurora Primordial"
  /// (custo de mana grudado: dígitos e símbolos lidos errado como
  /// *, &, @, O, 0 — nunca palavras reais, então é seguro cortar
  /// esses tokens no fim/início sem nunca esvaziar o título).
  static final _manaJunk = RegExp(r'^[\d\*&@\{\}Oo0]+$');

  static String _cleanTitle(String s) {
    final t = s
        .replaceAll(RegExp(r'[\(\)\[\]\{\}"]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final parts = t.split(' ');
    while (parts.length > 1 && _manaJunk.hasMatch(parts.last)) {
      parts.removeLast();
    }
    while (parts.length > 1 && _manaJunk.hasMatch(parts.first)) {
      parts.removeAt(0);
    }
    return parts.join(' ').trim();
  }

  /// Códigos de idioma em MAIÚSCULAS como vêm na carta ("PT").
  static const _ocrLangs = {
    'PT': 'pt',
    'EN': 'en',
    'ES': 'es',
    'FR': 'fr',
    'DE': 'de',
    'IT': 'it',
    'JA': 'ja',
    'KO': 'ko',
    'RU': 'ru',
  };

  /// Palavras de 3 letras comuns no texto das cartas que NUNCA são
  /// código de edição (o set só é lido na linha do rodapé, mas a
  /// lista é uma segunda trava).
  static const _setStoplist = {
    'THE', 'AND', 'ADD', 'TAP', 'YOU', 'MAY', 'ALL', 'ANY', 'EACH',
    'CARD', 'LIFE', 'DRAW', 'DEAL', 'PUT', 'GET', 'HAS', 'ITS',
    'OWN', 'NEW', 'NOT', 'ARE', 'CAN', 'FOR', 'TARGET',
  };

  /// Linha de nº de coletor ("266/271", "#266")? Não serve como
  /// candidato a nome de carta.
  static bool _looksCollectorLine(String t) {
    if (RegExp(r'\d\s*/\s*\d').hasMatch(t)) return true;
    if (RegExp(r'^\s*#').hasMatch(t)) return true;
    return false;
  }

  /// Nomes dos terrenos básicos em vários idiomas (normalizados,
  /// sem acento) -> nome oráculo em inglês.
  static const _basicNames = {
    'Forest': [
      'floresta',
      'forest',
      'bosque',
      'foresta',
      'wald',
      'foret',
      'mori'
    ],
    'Island': ['ilha', 'island', 'isla', 'isola', 'insel', 'ile', 'shima'],
    'Mountain': [
      'montanha',
      'mountain',
      'montana',
      'montagna',
      'gebirge',
      'montagne',
      'yama'
    ],
    'Plains': [
      'planicie',
      'plains',
      'llanura',
      'pianura',
      'ebene',
      'plaine',
      'heichi'
    ],
    'Swamp': ['pantano', 'swamp', 'palude', 'sumpf', 'marais', 'numa'],
    'Wastes': ['ermo', 'wastes', 'yermo', 'landa', 'desolation'],
  };

  /// Linha de tipo indica terreno básico? ("terreno básico",
  /// "basic land", "tierra básica"...). O normalize tira acentos.
  static bool _looksBasicLand(List<String> cands) {
    final all = ScryfallService.normalize(cands.join(' '));
    return all.contains('basic') ||
        all.contains('basico') ||
        all.contains('basica');
  }

  /// Título é EXATAMENTE um terreno básico? Igualdade estrita para
  /// nunca confundir ("Floresta" sim, "Floresta Flagelada" não).
  static String? _basicOracleName(String title) {
    final n = ScryfallService.normalize(title.trim());
    for (final e in _basicNames.entries) {
      if (e.value.contains(n)) return e.key;
    }
    return null;
  }

  Future<void> _searchName(String name) async {
    final q = name.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _results = [];
      _picked = null;
      _prints = [];
      _printSetFilter = 'all';
      _printLangFilter = 'all';
    });
    try {
      final results = await ScryfallService.instance.search(q);
      if (!mounted) return;
      setState(() {
        _results = results.take(6).toList();
        _picked = _results.isNotEmpty ? _results.first : null;
        if (_results.isEmpty) {
          _searchError =
              'Nada encontrado para "$q". Toque num candidato ou edite o nome.';
        }
      });
      // Carrega as impressões da carta e casa o nº lido no OCR.
      final oracle = _picked?['oracle_id']?.toString();
      if (oracle != null && oracle.isNotEmpty) {
        await _loadPrints(oracle);
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            _searchError = 'Falha no Scryfall. Verifique sua internet. ($e)');
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Rebusca com os dados corrigidos manualmente (nome, nº, set,
  /// idioma, tipo básico). É o caminho quando o OCR leu algo errado:
  /// a busca por nome sozinha pode trazer a carta errada.
  Future<void> _applyManualHints() async {
    final title = _cleanTitle(_nameEdit.text.trim());
    if (title.isEmpty) return;
    setState(() {
      _ocrCollector =
          ScryfallService.ocrFixCollectorNumber(_collectorEdit.text);
      _ocrSet = _setEdit.text.trim().toUpperCase();
      _ocrLang = _manualLang == 'all' ? '' : _manualLang;
      final basic = _basicOverride ?? _autoBasic;
      final basicOracle = _basicOracleName(title);
      if (basic && basicOracle != null) {
        _pendingQuery = '!"$basicOracle" t:basic';
      } else if (basic) {
        _pendingQuery = '$title t:basic';
      } else {
        _pendingQuery = title;
      }
    });
    await _searchName(_pendingQuery);
  }

  /// Busca todos os printings e seleciona sozinho o que bate com
  /// as pistas lidas na carta física (nº + set + idioma).
  /// - Set lido errado filtra tudo para fora? Refaz sem o filtro.
  /// - Hint só-prefixo ("266") com "266/177" e "266/150": NÃO escolhe
  ///   sozinho, pede toque manual.
  /// - Topo da lista não confere com o nº lido: não afirma "detectado".
  Future<void> _loadPrints(String oracleId) async {
    setState(() {
      _printsLoading = true;
      _collectorAmbiguous = false;
      _exactPrintMatch = false;
      _printSetFilter = 'all';
      _printLangFilter = 'all';
      _exactPrintMatch = false;
    });
    try {
      var prints = await ScryfallService.instance
          .getPrintings(oracleId, setCode: _ocrSet);
      // Set do OCR pode ser lixo ("SOS" lido do texto): filtro zerou
      // tudo mas a carta existe -> tenta sem filtrar por set.
      if (prints.isEmpty && _ocrSet.trim().isNotEmpty) {
        prints = await ScryfallService.instance.getPrintings(oracleId);
      }
      if (!mounted) return;
      final sorted = ScryfallService.sortPrintings(
        prints,
        _ocrCollector,
        setCode: _ocrSet,
        langHint: _ocrLang,
      );
      final ambiguous = ScryfallService.isCollectorAmbiguous(
          prints, _ocrCollector);
      // O match exato pode não ser o 1º (ex. #266 PT perde para #276
      // PT no desempate): procura na lista TODA e traz para frente.
      // Vale exato ("266/271") ou base ("266" sem total + mesmo set:
      // ausência de total não é conflito de impressão).
      var exactIdx = -1;
      if (_ocrCollector.trim().isNotEmpty) {
        final setNeed = _ocrSet.trim().toLowerCase();
        for (var k = 0; k < sorted.length; k++) {
          final p = sorted[k];
          final pcn = (p['collector_number'] ?? '').toString();
          final full = ScryfallService.sameCollector(pcn, _ocrCollector);
          final base = !full &&
              !ScryfallService.normalizeCollector(pcn).contains('/') &&
              ScryfallService.sameCollectorBase(pcn, _ocrCollector);
          if (!full && !base) continue;
          if (setNeed.isNotEmpty &&
              (p['set'] ?? '').toString().toLowerCase() != setNeed) {
            continue;
          }
          exactIdx = k;
          break;
        }
      }
      if (exactIdx > 0) {
        final ex = sorted.removeAt(exactIdx);
        sorted.insert(0, ex);
        exactIdx = 0;
      }
      setState(() {
        _prints = sorted.take(30).toList();
        _collectorAmbiguous = ambiguous;
        _exactPrintMatch = exactIdx >= 0 && !ambiguous;
        if (_prints.isNotEmpty) {
          // Com match exato (em qualquer posição), pré-seleciona com
          // confiança; senão mantém o 1º como prévia e o aviso pede
          // a escolha manual.
          _picked = _prints.first;
        }
      });
    } catch (_) {
      // Mantém o resultado da busca como selecionado.
    } finally {
      if (mounted) setState(() => _printsLoading = false);
    }
  }

  Future<void> _addPicked() async {
    final data = _picked;
    if (data == null || _adding) return;
    setState(() => _adding = true);
    try {
      final flat = ScryfallService.flatten(data);
      flat['quantity'] = 1;
      await AppDatabase.instance.ensureCard(flat);
      AppEvents.notifyCollectionChanged();
      if (!mounted) return;
      setState(() {
        _addedCount++;
        _adding = false;
      });
      // Animação rápida de sucesso e volta para a câmera.
      await _pop.forward(from: 0);
      await Future.delayed(const Duration(milliseconds: 320));
      if (!mounted) return;
      setState(() {
        _phase = _Phase.preview;
        _setStatus('');
        _candidates = [];
        _results = [];
        _picked = null;
        _prints = [];
        _ocrCollector = '';
        _ocrSet = '';
        _ocrLang = '';
        _collectorAmbiguous = false;
      _exactPrintMatch = false;
        _printSetFilter = 'all';
        _printLangFilter = 'all';
        _panelFrac = _panelRest;
        _nameEdit.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _adding = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocale.t('cl_add_error').replaceAll('{e}', '$e'))));
      }
    }
  }

  // ============ UI ============

  /// Correção manual da detecção: nº coletor, set/coleção, idioma e
  /// se é terreno básico. "Buscar" refaz nome + impressões com esses
  /// dados (só o nome costuma trazer a carta errada).
  Widget _correctionCard() {
    const langOptions = [
      'all',
      'pt',
      'en',
      'es',
      'fr',
      'de',
      'it',
      'ja',
      'ko',
      'zhs',
      'ru'
    ];
    final basic = _basicOverride ?? _autoBasic;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune, size: 14, color: AppTheme.gold),
              SizedBox(width: 6),
              Text('Corrigir detecção',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _collectorEdit,
                  onTap: _expandPanel,
                  scrollPadding: const EdgeInsets.only(bottom: 160),
                  decoration: const InputDecoration(
                    labelText: 'Nº (ex. 266/271)',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _setEdit,
                  onTap: _expandPanel,
                  scrollPadding: const EdgeInsets.only(bottom: 160),
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Set (ex. WOE)',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _manualLang,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Idioma',
                    isDense: true,
                  ),
                  items: [
                    for (final l in langOptions)
                      DropdownMenuItem(
                        value: l,
                        child: Text(
                            ScryfallService.languageLabels[l] ?? l,
                            style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _manualLang = v ?? 'all'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Switch(
                      value: basic,
                      activeThumbColor: AppTheme.gold,
                      onChanged: (v) =>
                          setState(() => _basicOverride = v),
                    ),
                    const Expanded(
                      child: Text('Terreno básico',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _searching ? null : _applyManualHints,
              icon: const Icon(Icons.search, size: 16),
              label: const Text('Buscar com estes dados'),
            ),
          ),
        ],
      ),
    );
  }

  /// Impressões após os filtros locais de edição + idioma.
  List<Map<String, dynamic>> get _filteredPrints => _prints.where((p) {
        if (_printSetFilter != 'all' &&
            (p['set'] ?? '').toString().toLowerCase() != _printSetFilter) {
          return false;
        }
        if (_printLangFilter != 'all' &&
            (p['lang'] ?? '').toString().toLowerCase() !=
                _printLangFilter) {
          return false;
        }
        return true;
      }).toList();

  /// Filtros locais da lista: edição (sets presentes) + idioma.
  /// Não refazem rede — só recortam as impressões já carregadas.
  Widget _printFilters() {
    final sets = <String, String>{};
    final langs = <String>{};
    for (final p in _prints) {
      final code = (p['set'] ?? '').toString();
      if (code.isNotEmpty) {
        sets.putIfAbsent(code.toLowerCase(),
            () => (p['set_name'] ?? code).toString());
      }
      final lang = (p['lang'] ?? '').toString().toLowerCase();
      if (lang.isNotEmpty) langs.add(lang);
    }
    final setCodes = sets.keys.toList()..sort();
    final langCodes = langs.toList()..sort();
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            initialValue: _printSetFilter,
            isDense: true,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Edição',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(
                value: 'all',
                child: Text('Todas', style: TextStyle(fontSize: 12)),
              ),
              for (final c in setCodes)
                DropdownMenuItem(
                  value: c,
                  child: Text(
                      '${c.toUpperCase()} — ${sets[c] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
            onChanged: (v) =>
                setState(() => _printSetFilter = v ?? 'all'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            initialValue: _printLangFilter,
            isDense: true,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Idioma',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(
                value: 'all',
                child: Text('Todos', style: TextStyle(fontSize: 12)),
              ),
              for (final l in langCodes)
                DropdownMenuItem(
                  value: l,
                  child: Text(
                      ScryfallService.languageLabels[l] ?? l.toUpperCase(),
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
            onChanged: (v) =>
                setState(() => _printLangFilter = v ?? 'all'),
          ),
        ),
      ],
    );
  }

  /// Seletor de impressões: miniaturas com set • nº • idioma.
  /// O nº lido no OCR já vem pré-selecionado (borda dourada).
  /// Se o OCR leu só "266" mas há "266/177" e "266/150", mostra
  /// aviso e exige escolha manual em vez de chutar o primeiro.
  Widget _printsSelector() {
    if (_printsLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(AppLocale.t('pm_loading_prints'),
                style: const TextStyle(color: AppTheme.textMuted)),
          ],
        ),
      );
    }
    if (_prints.length <= 1) return const SizedBox.shrink();
    final hasHint = _ocrCollector.trim().isNotEmpty;
    final unconfirmed =
        hasHint && !_exactPrintMatch && !_collectorAmbiguous;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_collectorAmbiguous || unconfirmed)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_outlined,
                    size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _collectorAmbiguous
                        ? 'Foram encontradas várias impressões possíveis para esta carta (nº lido sem o total). Toque na versão correta abaixo.'
                        : 'O nº ${_ocrCollector.trim()} não foi confirmado nas impressões listadas. Corrija os campos abaixo ou toque na versão correta.',
                    style: const TextStyle(
                        color: Colors.orange, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        Text(
            _exactPrintMatch
                ? AppLocale.t('pm_prints_one')
                    .replaceAll('{n}', _ocrCollector)
                : AppLocale.t('pm_prints'),
            style: TextStyle(
                color: unconfirmed || _collectorAmbiguous
                    ? Colors.orange
                    : AppTheme.textMuted)),
        const SizedBox(height: 6),
        _printFilters(),
        const SizedBox(height: 6),
        SizedBox(
          height: 124,
          child: _filteredPrints.isEmpty
              ? const Center(
                  child: Text('Nada com estes filtros.',
                      style:
                          TextStyle(color: AppTheme.textMuted, fontSize: 12)))
              : ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in _filteredPrints)
                GestureDetector(
                  onTap: () => setState(() => _picked = p),
                  child: Container(
                    width: 76,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: identical(p, _picked)
                            ? AppTheme.gold
                            : AppTheme.border,
                        width: identical(p, _picked) ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(7)),
                            child: Builder(builder: (_) {
                              final u = ScryfallService.extractImageUrl(p);
                              if (u == null || u.isEmpty) {
                                return const Icon(Icons.style,
                                    color: AppTheme.textFaint);
                              }
                              return CachedNetworkImage(
                                imageUrl: u,
                                fit: BoxFit.cover,
                                memCacheWidth: 150,
                                errorWidget: (_, __, ___) =>
                                    const Icon(Icons.broken_image),
                              );
                            }),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(2),
                          child: Text(
                              '${((p['set'] ?? '').toString().toUpperCase())} #${p['collector_number'] ?? '—'} ${(p['lang'] ?? '').toString().toUpperCase()}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 10, fontWeight: FontWeight.bold)),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.only(left: 2, right: 2, bottom: 2),
                          child: Text(
                              (p['rarity'] ?? '').toString().isEmpty
                                  ? '—'
                                  : (p['rarity'] ?? '').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 9, color: AppTheme.textMuted)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = AppEvents.topVisible.value;
    return Scaffold(
      // Rota empilhada: sem a top, o voltar flutuante (longe do
      // botão central da câmera).
      floatingActionButton: top
          ? null
          : FloatingActionButton.small(
              heroTag: 'photo_bars',
              onPressed: AppEvents.showBars,
              tooltip: AppLocale.t('nav_show'),
              child: const Icon(Icons.fullscreen_exit),
            ),
      appBar: top
          ? AppBar(
              title: Text(_addedCount == 0
                  ? AppLocale.t('pm_title')
                  : AppLocale.t('pm_title_added')
                      .replaceAll('{n}', '$_addedCount')),
            )
          : null,
      body: _initError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_initError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.textMuted)),
              ),
            )
          : _phase == _Phase.result
              ? _resultView()
              : _cameraView(),
    );
  }

  Widget _cameraView() {
    final cam = _camera;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (cam != null && cam.value.isInitialized)
          LayoutBuilder(
            builder: (_, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => _focusAt(details, constraints.biggest),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CameraPreview(cam),
                  if (_focusPoint != null)
                    Positioned(
                      left: _focusPoint!.dx * constraints.maxWidth - 26,
                      top: _focusPoint!.dy * constraints.maxHeight - 26,
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          border: Border.all(color: AppTheme.gold, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          )
        else
          const Center(child: CircularProgressIndicator()),
        // Moldura-guia da carta.
        IgnorePointer(
          child: Center(
            child: AspectRatio(
              aspectRatio: 63 / 88,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 48),
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.gold, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          // Sem AppBar: desce o valor exato do status, sem exagero.
          top: 16 +
              (AppEvents.topVisible.value
                  ? 0
                  : MediaQuery.of(context).viewPadding.top),
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth:
                      MediaQuery.of(context).size.width - 120,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _phase == _Phase.processing
                      ? _status
                      : AppLocale.t('pm_focus_hint'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 58 +
              (AppEvents.topVisible.value
                  ? 0
                  : MediaQuery.of(context).viewPadding.top),
          right: 16,
          child: IconButton.filledTonal(
            onPressed: _phase == _Phase.processing ? null : _toggleTorch,
            tooltip: _torchOn
                ? AppLocale.t('pm_torch_on')
                : AppLocale.t('pm_torch_off'),
            icon: Icon(_torchOn ? Icons.flashlight_on : Icons.flashlight_off),
          ),
        ),
        if (_maxZoom > 1.01)
          Positioned(
            left: 32,
            right: 32,
            bottom: 108,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(children: [
                const Icon(Icons.zoom_out, color: Colors.white, size: 18),
                Expanded(
                  child: Slider(
                    value: _zoom.clamp(1.0, _maxZoom),
                    min: 1,
                    max: _maxZoom,
                    activeColor: AppTheme.gold,
                    onChanged: _phase == _Phase.processing
                        ? null
                        : (value) async {
                            setState(() => _zoom = value);
                            try {
                              await cam?.setZoomLevel(value);
                            } catch (_) {}
                          },
                  ),
                ),
                const Icon(Icons.zoom_in, color: Colors.white, size: 18),
              ]),
            ),
          ),
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Center(
            child: _phase == _Phase.processing
                ? const CircularProgressIndicator(color: AppTheme.gold)
                : FloatingActionButton.large(
                    heroTag: null,
                    onPressed: _capture,
                    child: const Icon(Icons.photo_camera, size: 36),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _resultView() {
    final data = _picked;
    final url = data == null ? null : ScryfallService.extractImageUrl(data);
    final printed = (data?['printed_name'] ?? '').toString();
    final name = (data?['name'] ?? '').toString();
    // Carta o maior possível SEM cortar, conforme a tela:
    // ocupa a largura toda (ou a altura livre acima do painel).
    return LayoutBuilder(
      builder: (ctx, cons) {
        final maxW = cons.maxWidth - 16;
        var cardW = maxW;
        var cardH = cardW * 88 / 63;
        final maxH = cons.maxHeight * 0.72;
        if (cardH > maxH) {
          cardH = maxH;
          cardW = cardH * 63 / 88;
        }
        // Teclado aberto: força o painel na altura de repouso para o
        // campo em edição ficar visível.
        final kb = MediaQuery.of(ctx).viewInsets.bottom;
        final frac =
            (kb > 0 && _panelFrac < _panelRest) ? _panelRest : _panelFrac;
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(color: AppTheme.bg),
            if (url != null && url.isNotEmpty)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                // Tocar na arte recolhe o painel para visualizar melhor;
                // a alça reabre.
                child: GestureDetector(
                  onTap: () {
                    if (_panelFrac > _panelMin && mounted) {
                      setState(() => _panelFrac = _panelMin);
                    }
                  },
                  child: Center(
                    child: SizedBox(
                    width: cardW,
                    height: cardH,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                            color: AppTheme.panel,
                            child: const Icon(Icons.broken_image)),
                      ),
                    ),
                      ),
                    ),
                  ),
                )
            else if (_searching)
              const Center(child: CircularProgressIndicator()),
            // Painel livre: segue o dedo (14%–92% da tela). Com teclado,
            // abre sozinho para o campo em edição ficar visível.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedContainer(
                duration: _panelDragging
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                constraints: BoxConstraints(
                  maxHeight: cons.maxHeight * frac,
                ),
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(20)),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      color: Colors.black.withOpacity(0.42),
                      // A alça fica FORA da área que rola. Antes ela era o
                      // primeiro item da ListView e desaparecia ao ler os dados.
                      child: Column(
                        children: [
                          // Alça livre (36px): arrastar move o painel junto
                          // com o dedo entre 14% e 92%. Toque alterna
                          // recolhido/descanso. A lista rola sem mexer.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _panelFrac =
                                _panelFrac > 0.35
                                    ? _panelMin
                                    : _panelRest),
                            onVerticalDragStart: (_) {
                              if (kb > 0) return;
                              setState(() => _panelDragging = true);
                            },
                            onVerticalDragUpdate: (d) {
                              // Com teclado aberto o painel fica fixo.
                              if (kb > 0) return;
                              setState(() {
                                _panelDragging = true;
                                _panelFrac = (_panelFrac -
                                        d.delta.dy / cons.maxHeight)
                                    .clamp(_panelMin, _panelMax);
                              });
                            },
                            onVerticalDragEnd: (_) {
                              if (mounted) {
                                setState(() => _panelDragging = false);
                              }
                            },
                            onVerticalDragCancel: () {
                              if (mounted) {
                                setState(() => _panelDragging = false);
                              }
                            },
                            child: SizedBox(
                              width: double.infinity,
                              height: 36,
                              child: Center(
                                child: Container(
                                  width: 48,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: Colors.white38,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: ListView(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 0, 16, 24),
                                children: [
                                  if (data != null) ...[
                                    Text(printed.isNotEmpty ? printed : name,
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold)),
                                    Text(
                                        '${data['set_name'] ?? ''} • #${data['collector_number'] ?? '—'} • ${CurrencyService.instance.formatUsd(double.tryParse((data['price_usd'] ?? '').toString()) ?? 0)}',
                                        style: const TextStyle(
                                            color: AppTheme.textMuted)),
                                    const SizedBox(height: 12),
                                    _printsSelector(),
                                  ] else ...[
                                    if (_searchError != null)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(_searchError!,
                                                style: const TextStyle(
                                                    color: Colors.orange)),
                                            TextButton.icon(
                                              onPressed: () => _searchName(
                                                  _pendingQuery.isNotEmpty
                                                      ? _pendingQuery
                                                      : _nameEdit.text),
                                              icon: const Icon(Icons.refresh),
                                              label: Text(
                                                  AppLocale.t('common_retry')),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                  if (_ocrCollector.isNotEmpty ||
                                      _ocrSet.isNotEmpty ||
                                      _ocrLang.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        '${AppLocale.t('pm_detected')}'
                                        '${[
                                          if (_ocrCollector.isNotEmpty)
                                            '#$_ocrCollector',
                                          if (_ocrSet.isNotEmpty) _ocrSet,
                                          if (_ocrLang.isNotEmpty)
                                            _ocrLang.toUpperCase(),
                                        ].join(' • ')}',
                                        style: const TextStyle(
                                            color: AppTheme.gold, fontSize: 12),
                                      ),
                                    ),
                                  Text(AppLocale.t('pm_name_read'),
                                      style: const TextStyle(
                                          color: AppTheme.textMuted)),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      for (final c in _candidates)
                                        ActionChip(
                                          label: Text(_cleanTitle(c),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                          onPressed: () {
                                            _nameEdit.text = _cleanTitle(c);
                                            _searchName(_cleanTitle(c));
                                          },
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _nameEdit,
                                          onTap: _expandPanel,
                                          scrollPadding:
                                              const EdgeInsets.only(
                                                  bottom: 160),
                                          textInputAction:
                                              TextInputAction.search,
                                          onSubmitted: (v) {
                                            // Busca manual usa o texto editado como está.
                                            _pendingQuery = v.trim();
                                            _searchName(v);
                                          },
                                          decoration: InputDecoration(
                                              hintText:
                                                  AppLocale.t('pm_name_hint')),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(Icons.search,
                                            color: AppTheme.gold),
                                        onPressed: () {
                                          _pendingQuery = _nameEdit.text.trim();
                                          _searchName(_nameEdit.text);
                                        },
                                      ),
                                    ],
                                  ),
                                  _correctionCard(),
                                  if (_results.length > 1) ...[                                    const SizedBox(height: 8),
                                    Text(AppLocale.t('pm_other'),
                                        style: const TextStyle(
                                            color: AppTheme.textMuted)),
                                    SizedBox(
                                      height: 64,
                                      child: ListView(
                                        scrollDirection: Axis.horizontal,
                                        children: [
                                          for (final r in _results)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  right: 8),
                                              child: ChoiceChip(
                                                label: Text(
                                                    ((r['printed_name'] ??
                                                                r['name']) ??
                                                            '')
                                                        .toString()),
                                                selected: identical(r, _picked),
                                                onSelected: (_) {
                                                  setState(() {
                                                    _picked = r;
                                                    _prints = [];
                                                  });
                                                  final oracle = r['oracle_id']
                                                          ?.toString() ??
                                                      '';
                                                  if (oracle.isNotEmpty) {
                                                    _loadPrints(oracle);
                                                  }
                                                },
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 16),
                                  // Botão adicionar + overlay de sucesso animado.
                                  Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton.icon(
                                          onPressed: (data == null || _adding)
                                              ? null
                                              : _addPicked,
                                          icon: _adding
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2))
                                              : const Icon(Icons.add),
                                          label: Text(
                                              AppLocale.t('pm_add_button')),
                                        ),
                                      ),
                                      ScaleTransition(
                                        scale: _popScale,
                                        child: const Icon(Icons.check_circle,
                                            color: AppTheme.gold, size: 72),
                                      ),
                                    ],
                                  ),
                                  TextButton.icon(
                                    onPressed: () => setState(() {
                                      _phase = _Phase.preview;
                                      _candidates = [];
                                      _results = [];
                                      _picked = null;
                                      _prints = [];
                                      _ocrCollector = '';
                                      _ocrSet = '';
                                      _ocrLang = '';
                                      _collectorAmbiguous = false;
                                      _exactPrintMatch = false;
                                      _printSetFilter = 'all';
                                      _printLangFilter = 'all';
                                      _searchError = null;
                                      _panelFrac = _panelRest;
                                    }),
                                    icon: const Icon(Icons.photo_camera),
                                    label: Text(AppLocale.t('pm_back')),
                                  ),
                                ],
                              ),
                            ),
                          ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
