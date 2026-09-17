import 'package:path/path.dart' as p;

import 'package:path_provider/path_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:sqflite/sqflite.dart';

import 'package:uuid/uuid.dart';

/// Camada SQLite mobile — une database.py + services/decks_database.py

/// + profile_manager.py em um único banco por perfil.

///

/// Tabelas (mesmos nomes/conceitos do desktop):

/// - cards (quantity>0 = coleção; =0 = catálogo/deck-only)

/// - decks / deck_cards

/// - collection_snapshots / collection_snapshot_items (retrato diário)

/// - profiles (controle de perfis; cada perfil = 1 arquivo .db)

class AppDatabase {

  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Database get db => _db!;

  /// Banco principal (save.db): mora o REGISTRO global de perfis.

  /// Cada perfil tem seus dados (cartas/decks/coleção) no próprio arquivo,

  /// mas a LISTA é global — trocar de perfil nunca mais some com ninguém.

  String? _mainPath;

  String? _currentPath;

  Future<void> init() async {

    final prefs = await SharedPreferences.getInstance();

    final activePath = prefs.getString('active_db_path');

    final dir = await getApplicationDocumentsDirectory();

    final defaultPath = p.join(dir.path, 'save.db');

    _mainPath = defaultPath;

    await openDb(activePath ?? defaultPath);

    // Primeira abertura: cria o perfil convidado automaticamente.

    await _ensureDefaultProfile();

  }

  Future<void> openDb(String fullPath) async {

    _currentPath = fullPath;

    _db = await openDatabase(

      fullPath,

      version: 7,

      onCreate: _onCreateDb,

      onUpgrade: _onUpgradeDb,

    );

  }

  static Future<void> _onCreateDb(Database db, int v) async {

    await _createCards(db);

    await _createDecks(db);

    await _createSnapshots(db);

    await _createProfiles(db);

    await _createSocial(db);

    await _createCustom(db);

  }

  static Future<void> _onUpgradeDb(Database db, int oldV, int newV) async {

    // Migração idempotente como migrate_database() do desktop.

    await _createCards(db);

    await _createDecks(db);

    await _createSnapshots(db);

    await _createProfiles(db);

    await _createSocial(db);

    await _createCustom(db);

    for (final col in _cardExtraColumns) {

      try {

        await db.execute('ALTER TABLE cards ADD COLUMN $col');

      } catch (_) {}

    }

    // Código de convite (amigos) em instalações antigas.

    try {

      await db.execute('ALTER TABLE profiles ADD COLUMN code TEXT');

    } catch (_) {}

    // Capa escolhida para o deck (instalações antigas podem não ter).

    try {

      await db.execute('ALTER TABLE decks ADD COLUMN preview_card_id INTEGER');

    } catch (_) {}

    // Preços multilíngues (v6): eur_foil faltava (crash silencioso no
    // update), price_source/price_updated_at registram a origem do valor
    // (exact x fallback mesma impressão x aproximado x none) para cache
    // e para não reconsultar a API à toa.
    for (final col in _cardPriceColumns) {
      try {
        await db.execute('ALTER TABLE cards ADD COLUMN $col');
      } catch (_) {}
    }

  }

  Future<String> mainDbPath() async {

    if (_mainPath != null && _mainPath!.isNotEmpty) return _mainPath!;

    final dir = await getApplicationDocumentsDirectory();

    _mainPath = p.join(dir.path, 'save.db');

    return _mainPath!;

  }

  /// Handle do banco principal (o sqflite reaproveita a conexão

  /// quando o caminho já está aberto — sem lock duplo).

  Future<Database> mainDb() async {

    final m = await mainDbPath();

    return openDatabase(

      m,

      version: 7,

      onCreate: _onCreateDb,

      onUpgrade: _onUpgradeDb,

    );

  }

  /// Lista global de perfis (registro principal).

  Future<List<Map<String, Object?>>> registryProfiles() async {

    final mdb = await mainDb();

    return mdb.query('profiles', orderBy: 'last_opened_at DESC');

  }

  /// Insere ou atualiza um perfil no registro global.

  Future<void> registryUpsert(Map<String, Object?> values) async {

    final mdb = await mainDb();

    final id = (values['id'] ?? '').toString();

    if (id.isEmpty) return;

    final row = Map<String, Object?>.of(values);

    if ((row['code'] ?? '').toString().isEmpty) {

      row['code'] = newInviteCode();

    }

    final found = await mdb.query('profiles',

        columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);

    if (found.isEmpty) {

      await mdb.insert('profiles', row);

    } else {

      await mdb.update('profiles', row, where: 'id = ?', whereArgs: [id]);

    }

  }

  Future<void> registryDelete(String id) async {

    if (id.isEmpty) return;

    final mdb = await mainDb();

    await mdb.delete('profiles', where: 'id = ?', whereArgs: [id]);

  }

  static Future<void> _createCards(DatabaseExecutor db) async {

    await db.execute('''

      CREATE TABLE IF NOT EXISTS cards (

        id INTEGER PRIMARY KEY AUTOINCREMENT,

        scryfall_id TEXT,

        oracle_id TEXT,

        name TEXT NOT NULL,

        printed_name TEXT,

        lang TEXT,

        set_code TEXT,

        set_name TEXT,

        collector_number TEXT,

        mana_cost TEXT,

        type_line TEXT,

        oracle_text TEXT,

        power TEXT,

        toughness TEXT,

        rarity TEXT,

        cmc REAL,

        colors TEXT,

        color_identity TEXT,

        image_url TEXT,

        image_path TEXT,

        card_faces TEXT,

        quantity INTEGER NOT NULL DEFAULT 0,

        favorite INTEGER NOT NULL DEFAULT 0,

        preferred_finish TEXT,

        price_usd REAL,

        price_usd_foil REAL,

        price_usd_etched REAL,

        price_eur REAL,

        price_eur_foil REAL,

        price_tix REAL,

        price_ref_usd REAL,

        price_ref_name TEXT,

        price_source TEXT,

        price_updated_at TEXT,

        artist TEXT,

        released_at TEXT,

        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP

      )''');

    await db.execute('''

      CREATE UNIQUE INDEX IF NOT EXISTS idx_cards_scryfall_id

      ON cards(scryfall_id) WHERE scryfall_id IS NOT NULL''');

    await db

        .execute('CREATE INDEX IF NOT EXISTS idx_cards_name ON cards(name)');

    await db

        .execute('CREATE INDEX IF NOT EXISTS idx_cards_set ON cards(set_name)');

  }

  static const _cardExtraColumns = <String>[

    'keywords TEXT',

    'games TEXT',

    'legalities TEXT',

    'custom_tags TEXT',

  ];

  static const _cardPriceColumns = <String>[
    'price_eur_foil REAL',
    'price_source TEXT',
    'price_updated_at TEXT',
  ];

  static Future<void> _createDecks(DatabaseExecutor db) async {

    await db.execute('''

      CREATE TABLE IF NOT EXISTS decks (

        id INTEGER PRIMARY KEY AUTOINCREMENT,

        name TEXT NOT NULL,

        format TEXT NOT NULL DEFAULT 'livre',

        favorite INTEGER NOT NULL DEFAULT 0,

        commander_card_id INTEGER,

        preview_card_id INTEGER,

        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP

      )''');

    await db.execute('''

      CREATE TABLE IF NOT EXISTS deck_cards (

        deck_id INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,

        card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,

        quantity INTEGER NOT NULL DEFAULT 1,

        PRIMARY KEY (deck_id, card_id)

      )''');

  }

  /// Modelos de cartas/fichas personalizadas (v7): salvos no Play
  /// para reutilizar sem redigitar (nome, P/T, custo, tipo,
  /// habilidades em JSON, descrição e arte).
  static Future<void> _createCustom(DatabaseExecutor db) async {

    await db.execute('''

      CREATE TABLE IF NOT EXISTS custom_templates (

        id INTEGER PRIMARY KEY AUTOINCREMENT,

        name TEXT NOT NULL,

        power INTEGER NOT NULL DEFAULT 1,

        toughness INTEGER NOT NULL DEFAULT 1,

        cost TEXT NOT NULL DEFAULT '',

        type TEXT NOT NULL DEFAULT '',

        keywords TEXT NOT NULL DEFAULT '[]',

        description TEXT NOT NULL DEFAULT '',

        art TEXT NOT NULL DEFAULT '',

        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP

      )''');

  }

  static Future<void> _createSnapshots(DatabaseExecutor db) async {    await db.execute('''

      CREATE TABLE IF NOT EXISTS collection_snapshots (

        id INTEGER PRIMARY KEY AUTOINCREMENT,

        snapshot_date TEXT NOT NULL UNIQUE,

        total_cards INTEGER NOT NULL DEFAULT 0,

        unique_cards INTEGER NOT NULL DEFAULT 0,

        total_sets INTEGER NOT NULL DEFAULT 0,

        value_usd REAL NOT NULL DEFAULT 0,

        usd_brl REAL,

        value_brl REAL NOT NULL DEFAULT 0,

        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP

      )''');

    await db.execute('''

      CREATE TABLE IF NOT EXISTS collection_snapshot_items (

        id INTEGER PRIMARY KEY AUTOINCREMENT,

        snapshot_id INTEGER NOT NULL REFERENCES collection_snapshots(id) ON DELETE CASCADE,

        card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,

        quantity INTEGER NOT NULL DEFAULT 0,

        unit_price_usd REAL,

        total_value_usd REAL NOT NULL DEFAULT 0,

        total_value_brl REAL NOT NULL DEFAULT 0

      )''');

  }

  static Future<void> _createProfiles(DatabaseExecutor db) async {

    await db.execute('''

      CREATE TABLE IF NOT EXISTS profiles (

        id TEXT PRIMARY KEY,

        name TEXT NOT NULL UNIQUE,

        database_path TEXT NOT NULL,

        avatar_path TEXT,

        code TEXT,

        last_opened_at TIMESTAMP

      )''');

  }

  /// Amigos (contatos locais por código de convite).

  /// O código do amigo serve para montar a mesa no "Jogar".

  /// (Login Gmail / sync online = próxima fase, com servidor.)

  static Future<void> _createSocial(DatabaseExecutor db) async {

    await db.execute('''

      CREATE TABLE IF NOT EXISTS friends (

        id TEXT PRIMARY KEY,

        name TEXT NOT NULL,

        code TEXT NOT NULL,

        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP

      )''');

  }

  /// Gera código de convite curto (6 letras/números).

  static String newInviteCode() {

    return const Uuid().v4().replaceAll('-', '').substring(0, 6).toUpperCase();

  }

  /// Nome do perfil ativo (mesa online usa sem digitar).

  Future<String> activeProfileName() async {

    try {

      final prefs = await SharedPreferences.getInstance();

      final active = prefs.getString('active_db_path') ?? '';

      if (active.isNotEmpty) {

        final rows = await db.query('profiles',

            columns: ['name'],

            where: 'database_path = ?',

            whereArgs: [active],

            limit: 1);

        if (rows.isNotEmpty) {

          final n = (rows.first['name'] ?? '').toString().trim();

          if (n.isNotEmpty) return n;

        }

      }

      final first = await db.query('profiles',

          columns: ['name'], orderBy: 'last_opened_at DESC', limit: 1);

      if (first.isNotEmpty) {

        final n = (first.first['name'] ?? '').toString().trim();

        if (n.isNotEmpty) return n;

      }

    } catch (_) {}

    return 'Convidado';

  }

  /// O primeiro perfil usa o banco local já aberto. Assim, coleção, decks

  /// e preferências ficam vinculados ao nome escolhido neste aparelho.

  Future<bool> needsProfileSetup() async {

    final prefs = await SharedPreferences.getInstance();

    final active = prefs.getString('active_db_path') ?? '';

    if (active.isEmpty) return true;

    final rows = await db.query('profiles',

        columns: ['name'],

        where: 'database_path = ?',

        whereArgs: [active],

        limit: 1);

    return rows.isEmpty ||

        (rows.first['name'] ?? '').toString().trim().isEmpty ||

        (rows.first['name'] ?? '').toString().trim() == 'Convidado';

  }

  /// Define o nome do perfil ativo e mantém o mesmo perfil sincronizado
  /// entre o banco do perfil e o registro global (save.db).
  ///
  /// O ID do perfil é a identidade real; o apelido é apenas um atributo.
  Future<void> nameActiveProfile(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError('Nome vazio');

    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getString('active_db_path') ?? '';
    if (active.isEmpty) throw StateError('Nenhum perfil ativo');

    final found = await db.query(
      'profiles',
      columns: ['id', 'name', 'database_path', 'avatar_path', 'code', 'last_opened_at'],
      where: 'database_path = ?',
      whereArgs: [active],
      limit: 1,
    );

    late final Map<String, Object?> profile;
    final now = DateTime.now().toIso8601String();

    if (found.isEmpty) {
      profile = {
        'id': const Uuid().v4().substring(0, 8),
        'name': clean,
        'database_path': active,
        'avatar_path': null,
        'code': newInviteCode(),
        'last_opened_at': now,
      };
      await db.insert('profiles', profile);
    } else {
      profile = Map<String, Object?>.from(found.first);
      profile['name'] = clean;
      profile['last_opened_at'] = now;
      await db.update(
        'profiles',
        {'name': clean, 'last_opened_at': now},
        where: 'id = ?',
        whereArgs: [profile['id']],
      );
    }

    // O mesmo ID/nome é persistido também no registro global.
    await registryUpsert(profile);
  }

  /// Primeira abertura sem perfil: cria o convidado automaticamente.

  /// O registro usa o banco ATUALMENTE aberto (pode ser outro perfil

  /// após trocas) — nunca o save.db fixo.

  Future<void> _ensureDefaultProfile() async {

    final rows = await db.query('profiles', limit: 1);

    if (rows.isNotEmpty) {

      // Garante código em perfis antigos.

      for (final r in rows) {

        if ((r['code'] ?? '').toString().isEmpty) {

          await db.update('profiles', {'code': newInviteCode()},

              where: 'id = ?', whereArgs: [r['id']]);

        }

      }

      // Corrige instalações antigas em que o perfil existia apenas no
      // arquivo atualmente aberto. O registro global passa a usar o mesmo ID.
      for (final r in rows) {
        try {
          final current = await db.query(
            'profiles',
            where: 'id = ?',
            whereArgs: [r['id']],
            limit: 1,
          );
          if (current.isNotEmpty) {
            await registryUpsert(Map<String, Object?>.from(current.first));
          }
        } catch (_) {}
      }
      return;

    }

    final prefs = await SharedPreferences.getInstance();

    final dir = await getApplicationDocumentsDirectory();

    final id = const Uuid().v4().substring(0, 8);

    final path = _currentPath ?? p.join(dir.path, 'save.db');

    await db.insert('profiles', {

      'id': id,

      'name': 'Convidado',

      'database_path': path,

      'code': newInviteCode(),

      'last_opened_at': DateTime.now().toIso8601String(),

    });

    await prefs.setString('active_db_path', path);

  }

  // ---------- cards ----------

  /// Upsert por scryfall_id — equivale a ensure_card_exists().

  Future<int> ensureCard(Map<String, Object?> values) async {

    final scryfallId = values['scryfall_id'] as String?;

    if (scryfallId != null) {

      final found = await db.query('cards',

          columns: ['id'],

          where: 'scryfall_id = ?',

          whereArgs: [scryfallId],

          limit: 1);

      if (found.isNotEmpty) {

        await db.update('cards', values,

            where: 'id = ?', whereArgs: [found.first['id']]);

        return found.first['id'] as int;

      }

    }

    return await db.insert('cards', values);

  }

  /// Busca na coleção com filtros (equivale aos filtros do desktop:

  /// cor, tipo, set, raridade, favoritas + texto).

  /// *\`color\`*: all/W/U/B/R/G/multi/colorless.

  Future<List<Map<String, Object?>>> searchCollection(

      {String query = '',

      String orderBy = 'name ASC',

      int limit = 300,

      int offset = 0,

      String rarity = 'all',

      String setName = 'all',

      String color = 'all',

      String typeQuery = '',

      bool favoritesOnly = false}) async {

    final clauses = <String>['quantity > 0'];

    final args = <Object?>[];

    if (query.isNotEmpty) {

      clauses.add('(name LIKE ? OR printed_name LIKE ?)');

      args.addAll(['%$query%', '%$query%']);

    }

    if (rarity != 'all') {

      clauses.add('rarity = ?');

      args.add(rarity);

    }

    if (setName != 'all') {

      clauses.add('set_name = ?');

      args.add(setName);

    }

    if (favoritesOnly) {

      clauses.add('favorite = 1');

    }

    if (typeQuery.trim().isNotEmpty) {

      clauses.add('type_line LIKE ?');

      args.add('%${typeQuery.trim()}%');

    }

    // colors é JSON: [] | ["W"] | ["W","U"] ...

    switch (color) {

      case 'colorless':

        clauses.add("(colors IS NULL OR colors = '' OR colors = '[]')");

        break;

      case 'multi':

        clauses.add("(colors LIKE '%,%')");

        break;

      case 'W':

      case 'U':

      case 'B':

      case 'R':

      case 'G':

        clauses.add("(colors LIKE ? AND colors NOT LIKE '%,%')");

        args.add('%"$color"%');

        break;

    }

    return db.query('cards',

        where: clauses.join(' AND '),

        whereArgs: args,

        orderBy: orderBy,

        limit: limit,

        offset: offset,);

  }

  /// Total de cartas na coleção COM os mesmos filtros da busca.
  /// A lista é paginada (sem teto de 300): o total alimenta o
  /// "Exibindo X de Y" e o scroll infinito.
  Future<int> countCollection(

      {String query = '',

      String rarity = 'all',

      String setName = 'all',

      String color = 'all',

      String typeQuery = '',

      bool favoritesOnly = false}) async {

    final clauses = <String>['quantity > 0'];

    final args = <Object?>[];

    if (query.isNotEmpty) {

      clauses.add('(name LIKE ? OR printed_name LIKE ?)');

      args.addAll(['%$query%', '%$query%']);

    }

    if (rarity != 'all') {

      clauses.add('rarity = ?');

      args.add(rarity);

    }

    if (setName != 'all') {

      clauses.add('set_name = ?');

      args.add(setName);

    }

    if (favoritesOnly) {

      clauses.add('favorite = 1');

    }

    if (typeQuery.trim().isNotEmpty) {

      clauses.add('type_line LIKE ?');

      args.add('%${typeQuery.trim()}%');

    }

    switch (color) {

      case 'colorless':

        clauses.add("(colors IS NULL OR colors = '' OR colors = '[]')");

        break;

      case 'multi':

        clauses.add("(colors LIKE '%,%')");

        break;

      case 'W':

      case 'U':

      case 'B':

      case 'R':

      case 'G':

        clauses.add("(colors LIKE ? AND colors NOT LIKE '%,%')");

        args.add('%"$color"%');

        break;

    }

    final r = await db.rawQuery(

        'SELECT COUNT(*) AS n FROM cards WHERE ${clauses.join(' AND ')}',

        args);

    return (r.first['n'] as num?)?.toInt() ?? 0;

  }

  /// Sets distintos da coleção (para o filtro de set).

  Future<List<String>> distinctSets() async {

    final rows = await db.rawQuery(

        "SELECT DISTINCT set_name FROM cards WHERE quantity > 0 AND set_name IS NOT NULL AND TRIM(set_name) != '' ORDER BY set_name");

    return rows.map((r) => (r['set_name'] ?? '').toString()).toList();

  }

  /// Busca no catálogo LOCAL inteiro (coleção + cartas só-de-deck),

  /// sem filtro de quantity. Usada para adicionar cartas da coleção

  /// aos decks — funciona offline, sem Scryfall.

  Future<List<Map<String, Object?>>> searchCatalog(

      {String query = '', int limit = 50}) async {

    final q = query.trim();

    if (q.isEmpty) return [];

    return db.query('cards',

        where: 'name LIKE ? OR printed_name LIKE ?',

        whereArgs: ['%$q%', '%$q%'],

        orderBy: 'name ASC',

        limit: limit);

  }

  Future<Map<String, Object?>> collectionStats() async {

    final r = await db.rawQuery('''

      SELECT COUNT(*) AS unique_cards,

             COALESCE(SUM(quantity),0) AS total_cards,

             COUNT(DISTINCT set_name) AS total_sets,

             COALESCE(SUM(quantity * COALESCE(price_usd, price_ref_usd, 0)),0) AS value_usd

      FROM cards WHERE quantity > 0''');

    return r.first;

  }

  // ---------- snapshots (retrato diário congelado) ----------

  Future<void> createSnapshot(String date, double? usdBrl) async {

    final exists = await db.query('collection_snapshots',

        where: 'snapshot_date = ?', whereArgs: [date], limit: 1);

    if (exists.isNotEmpty) return;

    final cards = await db.query('cards', where: 'quantity > 0');

    double totalUsd = 0;

    int totalCards = 0;

    for (final c in cards) {

      final q = (c['quantity'] as num?)?.toInt() ?? 0;

      final price = (c['price_usd'] as num?)?.toDouble() ??
          (c['price_ref_usd'] as num?)?.toDouble() ??
          0;

      totalCards += q;

      totalUsd += q * price;

    }

    final sets = await db.rawQuery(

        "SELECT COUNT(DISTINCT set_name) AS n FROM cards WHERE quantity > 0 AND set_name IS NOT NULL AND TRIM(set_name) != ''");

    final id = await db.insert('collection_snapshots', {

      'snapshot_date': date,

      'total_cards': totalCards,

      'unique_cards': cards.length,

      'total_sets': (sets.first['n'] as num?)?.toInt() ?? 0,

      'value_usd': totalUsd,

      'usd_brl': usdBrl,

      'value_brl': usdBrl == null ? 0 : totalUsd * usdBrl,

    });

    for (final c in cards) {

      final q = (c['quantity'] as num?)?.toInt() ?? 0;

      final price = (c['price_usd'] as num?)?.toDouble() ??
          (c['price_ref_usd'] as num?)?.toDouble() ??
          0;

      await db.insert('collection_snapshot_items', {

        'snapshot_id': id,

        'card_id': c['id'],

        'quantity': q,

        'unit_price_usd': price,

        'total_value_usd': q * price,

        'total_value_brl': usdBrl == null ? 0 : q * price * usdBrl,

      });

    }

  }

}