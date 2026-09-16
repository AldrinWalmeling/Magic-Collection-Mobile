class Deck {
  final int? id;
  final String name;
  final String format;
  final int favorite;
  final int? commanderCardId;
  final int? previewCardId;
  final int totalCards;
  final double valueUsd;

  const Deck({
    this.id,
    required this.name,
    this.format = 'livre',
    this.favorite = 0,
    this.commanderCardId,
    this.previewCardId,
    this.totalCards = 0,
    this.valueUsd = 0,
  });

  factory Deck.fromMap(Map<String, Object?> m) => Deck(
        id: m['id'] as int?,
        name: (m['name'] ?? '') as String,
        format: (m['format'] ?? 'livre') as String,
        favorite: (m['favorite'] as num?)?.toInt() ?? 0,
        commanderCardId: m['commander_card_id'] as int?,
        previewCardId: m['preview_card_id'] as int?,
        totalCards: (m['total_cards'] as num?)?.toInt() ?? 0,
        valueUsd: (m['value_usd'] as num?)?.toDouble() ?? 0,
      );
}

class Profile {
  final String id;
  final String name;
  final String databasePath;
  final String? avatarPath;

  const Profile({
    required this.id,
    required this.name,
    required this.databasePath,
    this.avatarPath,
  });

  factory Profile.fromMap(Map<String, Object?> m) => Profile(
        id: (m['id'] ?? '') as String,
        name: (m['name'] ?? '') as String,
        databasePath: (m['database_path'] ?? '') as String,
        avatarPath: m['avatar_path'] as String?,
      );
}
