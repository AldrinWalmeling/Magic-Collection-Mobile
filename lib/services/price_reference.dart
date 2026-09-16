import 'package:shared_preferences/shared_preferences.dart';

// Espelha services/price_reference.py (modo Imprint):
// - PRICING_MODE_ORIGINAL usa price_usd da própria carta.
// - PRICING_MODE_IMPRINT usa price_ref_usd (referência em inglês),
//   sem alterar idioma/quantidade/favoritos da carta original.

class PriceReference {
  static const original = 'original';
  static const imprint = 'imprint';
  static const labels = {
    original: 'Original',
    imprint: 'Inglês (Imprint)',
  };

  static Future<String> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('pricing_mode') ?? original;
  }

  static Future<void> setMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pricing_mode', mode);
  }

  static double effectivePrice(Map<String, Object?> card, String mode) {
    if (mode == imprint) {
      final ref = (card['price_ref_usd'] as num?)?.toDouble();
      if (ref != null && ref > 0) return ref;
    }
    final exact = (card['price_usd'] as num?)?.toDouble();
    if (exact != null && exact > 0) return exact;
    // Fallback válido: mesma impressão em outro idioma pode compor o
    // total em vez de zerar a carta PT sem preço exato.
    final ref = (card['price_ref_usd'] as num?)?.toDouble();
    return ref ?? 0.0;
  }

  /// Rótulo curto da origem do valor para a UI (badge).
  static String sourceLabel(Object? source) {
    switch ((source ?? '').toString()) {
      case 'exact':
        return 'Exata';
      case 'fallback-same-print':
        return 'Ref. mesma impressão';
      case 'approx-other-print':
        return 'Aproximado';
      case 'none':
        return 'Sem preço';
      default:
        return '';
    }
  }
}
