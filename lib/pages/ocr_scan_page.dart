import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/app_locale.dart';
import '../theme/app_theme.dart';

// Scanner rápido de carta física para o "Buscar carta" do Play:
// fotografa, o OCR lê as linhas do topo e devolve o título limpo.
// (O Modo Foto faz o fluxo completo com impressões; aqui é só o nome.)
// Devolve via Navigator.pop o título escolhido, ou null ao cancelar.

class OcrScanPage extends StatefulWidget {
  const OcrScanPage({super.key});

  @override
  State<OcrScanPage> createState() => _OcrScanPageState();
}

class _OcrScanPageState extends State<OcrScanPage> {
  CameraController? _camera;
  late final TextRecognizer _recognizer;
  String? _initError;
  bool _busy = false;
  bool _torchOn = false;
  List<String> _candidates = [];

  @override
  void initState() {
    super.initState();
    _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _initCamera();
  }

  @override
  void dispose() {
    _camera?.dispose();
    _recognizer.close();
    super.dispose();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _initError = AppLocale.t('pm_perm'));
      return;
    }
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _initError = AppLocale.t('pm_nocam'));
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      try {
        await controller.setFocusMode(FocusMode.auto);
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}
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

  Future<void> _toggleTorch() async {
    final cam = _camera;
    if (cam == null) return;
    final next = !_torchOn;
    try {
      await cam.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {}
  }

  Future<void> _capture() async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized || _busy) return;
    setState(() {
      _busy = true;
      _candidates = [];
    });
    try {
      final photo = await cam.takePicture();
      final input = InputImage.fromFilePath(photo.path);
      final recognized = await _recognizer.processImage(input);
      if (!mounted) return;
      final blocks = recognized.blocks.toList()
        ..sort((a, b) =>
            a.boundingBox.top.compareTo(b.boundingBox.top));
      final cands = <String>[];
      for (var bi = 0; bi < blocks.length && cands.length < 5; bi++) {
        for (final line in blocks[bi].lines) {
          final t = line.text.trim();
          if (t.length < 2 || cands.contains(t)) continue;
          if (_looksCollectorLine(t)) continue;
          cands.add(t);
          if (cands.length >= 5) break;
        }
      }
      setState(() {
        _busy = false;
        _candidates = [
          for (final c in cands) _cleanTitle(c)
        ].where((t) => t.isNotEmpty).toList();
      });
      if (_candidates.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocale.t('ocr_noread'))));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocale.t('ocr_fail'))));
    }
  }

  /// Linha de nº de coletor ("266/271", "#266")? Não serve como nome.
  static bool _looksCollectorLine(String t) {
    if (RegExp(r'\d\s*/\s*\d').hasMatch(t)) return true;
    if (RegExp(r'^\s*#').hasMatch(t)) return true;
    return false;
  }

  /// Limpa título lido (custo de mana grudado, parênteses): mesma
  /// regra do Modo Foto, simplificada.
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

  @override
  Widget build(BuildContext context) {
    final cam = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(AppLocale.t('ocr_title')),
        actions: [
          IconButton(
            icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
            onPressed: _toggleTorch,
          ),
        ],
      ),
      body: _initError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_initError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ),
            )
          : cam == null || !cam.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CameraPreview(cam),
                          // Mira: título fica no topo da carta.
                          Positioned(
                            left: 24,
                            right: 24,
                            top: 24,
                            child: Container(
                              height: 72,
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: AppTheme.gold, width: 2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                          if (_busy)
                            const Center(
                                child: CircularProgressIndicator()),
                        ],
                      ),
                    ),
                    if (_candidates.isNotEmpty)
                      Container(
                        color: const Color(0xFF14161D),
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        width: double.infinity,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final c in _candidates)
                              ActionChip(
                                label: Text(c),
                                onPressed: () => Navigator.pop(context, c),
                              ),
                          ],
                        ),
                      ),
                    Container(
                      color: const Color(0xFF14161D),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _candidates.isEmpty
                                  ? AppLocale.t('ocr_hint')
                                  : AppLocale.t('ocr_pick'),
                              style: const TextStyle(
                                  color: AppTheme.textMuted, fontSize: 12),
                            ),
                          ),
                          FloatingActionButton(
                            heroTag: 'ocr_capture',
                            onPressed: _busy ? null : _capture,
                            child: const Icon(Icons.camera_alt),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
