import 'dart:async';

import 'package:flutter/material.dart';

// Letreiro infinito: texto que anda sozinho quando não cabe na caixa.
// Mede com TextPainter; se couber, mostra parado. Se estourar, rola
// até o fim, pausa e volta ao início, em loop. O usuário também pode
// arrastar (o automático pausa 3s e retoma sozinho).
class Marquee extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  // Pixels por segundo do rolamento.
  final double velocity;
  // Pausa no fim (antes de voltar) e no início.
  final Duration endPause;

  const Marquee(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.center,
    this.velocity = 28,
    this.endPause = const Duration(milliseconds: 900),
  });

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> {
  final _ctrl = ScrollController();
  bool _running = false;
  bool _userHold = false;
  Timer? _resumeTimer;

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  double _textWidth() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    return tp.width;
  }

  void _maybeStart(double maxW) {
    if (_running || !mounted) return;
    if (_textWidth() <= maxW) return;
    _running = true;
    _loop();
  }

  Future<void> _loop() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    while (mounted && _running) {
      if (_userHold || !_ctrl.hasClients) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      final max = _ctrl.position.maxScrollExtent;
      if (max <= 0) {
        // Encolheu (texto trocou e agora cabe): dorme até mudar.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      final dur = Duration(
          milliseconds:
              (max / widget.velocity * 1000).round().clamp(800, 8000));
      try {
        await _ctrl.animateTo(max, duration: dur, curve: Curves.linear);
      } catch (_) {
        break;
      }
      if (!mounted || !_running) break;
      await Future<void>.delayed(widget.endPause);
      if (!mounted || !_running || !_ctrl.hasClients) break;
      _ctrl.jumpTo(0);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, cons) {
      // Sem teto (medindo p/ FittedBox...): ancora em 200px para o
      // cálculo; o scroll interno nunca estoura o layout.
      final maxW = cons.maxWidth.isFinite ? cons.maxWidth : 200.0;
      final txt = Text(
        widget.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        textAlign: widget.textAlign,
        style: widget.style,
      );
      if (_textWidth() <= maxW) return txt;
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart(maxW));
      return Listener(
        onPointerDown: (_) {
          _userHold = true;
          _resumeTimer?.cancel();
        },
        onPointerUp: (_) {
          _resumeTimer?.cancel();
          _resumeTimer = Timer(const Duration(seconds: 3), () {
            _userHold = false;
          });
        },
        child: SingleChildScrollView(
          controller: _ctrl,
          scrollDirection: Axis.horizontal,
          child: txt,
        ),
      );
    });
  }
}
