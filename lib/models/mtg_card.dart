// Espelha a tabela `cards` de database.py (todas as colunas relevantes).
// Regra central preservada: quantity > 0 = pertence à coleção,
// quantity == 0 = só catálogo / carta usada em deck.

class MtgCard {
  final int? id;
  final String? scryfallId;
  final String name;
  final String? printedName;
  final String? lang;
  final String? setCode;
  final String? setName;
  final String? collectorNumber;
  final String? manaCost;
  final String? typeLine;
  final String? oracleText;
  final String? power;
  final String? toughness;
  final String? rarity;
  final double? cmc;
  final String? imageUrl;
  final String? imagePath;
  final int quantity;
  final int favorite;
  final double? priceUsd;
  final double? priceUsdFoil;
  final double? priceUsdEtched;
  final double? priceEur;
  final double? priceEurFoil;
  final double? priceTix;
  final double? priceRefUsd;
  final String? priceRefName;
  final String? priceSource;
  final String? artist;
  final String? releasedAt;

  const MtgCard({
    this.id,
    this.scryfallId,
    required this.name,
    this.printedName,
    this.lang,
    this.setCode,
    this.setName,
    this.collectorNumber,
    this.manaCost,
    this.typeLine,
    this.oracleText,
    this.power,
    this.toughness,
    this.rarity,
    this.cmc,
    this.imageUrl,
    this.imagePath,
    this.quantity = 0,
    this.favorite = 0,
    this.priceUsd,
    this.priceUsdFoil,
    this.priceUsdEtched,
    this.priceEur,
    this.priceEurFoil,
    this.priceTix,
    this.priceRefUsd,
    this.priceRefName,
    this.priceSource,
    this.artist,
    this.releasedAt,
  });

  bool get inCollection => quantity > 0;

  factory MtgCard.fromMap(Map<String, Object?> m) => MtgCard(
        id: m['id'] as int?,
        scryfallId: m['scryfall_id'] as String?,
        name: (m['name'] ?? '') as String,
        printedName: m['printed_name'] as String?,
        lang: m['lang'] as String?,
        setCode: m['set_code'] as String?,
        setName: m['set_name'] as String?,
        collectorNumber: m['collector_number'] as String?,
        manaCost: m['mana_cost'] as String?,
        typeLine: m['type_line'] as String?,
        oracleText: m['oracle_text'] as String?,
        power: m['power'] as String?,
        toughness: m['toughness'] as String?,
        rarity: m['rarity'] as String?,
        cmc: (m['cmc'] as num?)?.toDouble(),
        imageUrl: m['image_url'] as String?,
        imagePath: m['image_path'] as String?,
        quantity: (m['quantity'] as num?)?.toInt() ?? 0,
        favorite: (m['favorite'] as num?)?.toInt() ?? 0,
        priceUsd: (m['price_usd'] as num?)?.toDouble(),
        priceUsdFoil: (m['price_usd_foil'] as num?)?.toDouble(),
        priceUsdEtched: (m['price_usd_etched'] as num?)?.toDouble(),
        priceEur: (m['price_eur'] as num?)?.toDouble(),
        priceEurFoil: (m['price_eur_foil'] as num?)?.toDouble(),
        priceTix: (m['price_tix'] as num?)?.toDouble(),
        priceRefUsd: (m['price_ref_usd'] as num?)?.toDouble(),
        priceRefName: m['price_ref_name'] as String?,
        priceSource: m['price_source'] as String?,
        artist: m['artist'] as String?,
        releasedAt: m['released_at'] as String?,
      );

  /// Preço exibido conforme modo de preço (original x imprint).
  /// No desktop: services/price_reference.py decide a coluna.
  /// Com fallback: se o exato estiver nulo, usa a referência da mesma
  /// impressão (outro idioma) em vez de zerar.
  double priceFor({required bool imprint, double? refUsd}) {
    if (imprint && refUsd != null) return refUsd;
    if ((priceUsd ?? 0) > 0) return priceUsd!;
    if (refUsd != null) return refUsd;
    return (priceRefUsd ?? priceUsd) ?? 0.0;
  }
}
