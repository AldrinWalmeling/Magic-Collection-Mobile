import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../services/app_events.dart';

/// Camada SQLite mobile â€” une database.py + services/decks_database.py

/// + profile_manager.py em um Ãºnico banco por perfil.

///

/// Tabelas (mesmos nomes/conceitos do desktop):

/// - cards (quantity>0 = coleÃ§Ã£o; =0 = catÃ¡logo/deck-only)

/// - decks / deck_cards

/// - collection_snapshots / collection_snapshot_items (retrato diÃ¡rio)

/// - profiles (controle de perfis; cada perfil = 1 arquivo .db)

class AppDatabase {

  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Database get db => _db!;

  /// Banco principal (save.db): mora o REGISTRO global de perfis.

  /// Cada perfil tem seus dados (cartas/decks/coleÃ§Ã£o) no prÃ³prio arquivo,

  /// mas a LISTA Ã© global â€” trocar de perfil nunca mais some com ninguÃ©m.

  String? _mainPath;

  String? _currentPath;

  /// UID Firebase dono do arquivo aberto (AccountContext local).
  /// null = sem conta (tela de login) ou arquivo legado manual.
  /// Invariante: com usuário permanente, o arquivo aberto SEMPRE é o
  /// da conta (account_<uid>.db). Ver switchToAccount/openProfileRow.
  String? _openUid;

  String? get openUid => _openUid;

  String? get currentPath => _currentPath;

  /// Nome de arquivo por conta (só [A-Za-z0-9], resto vira _).
  /// Puro e testado.
  static String accountFileName(String uid) {
    final clean = uid.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    final base = clean.isEmpty ? 'noid' : clean;
    return 'account_$base.db';
  }

  /// Gate de abertura de perfil/conta (puro, testado).
  /// - sem usuário -> 'need_login';
  /// - linha legada (sem uid) -> 'legacy' (fluxo explícito de adoção);
  /// - uid igual -> 'open';
  /// - outro uid -> 'need_login' (trocar de conta primeiro).
  static String gateOpen({
    required String rowUid,
    required String? currentUid,
    required bool signedIn,
  }) {
    if (!signedIn || currentUid == null || currentUid.isEmpty) {
      return 'need_login';
    }
    if (rowUid.isEmpty) return 'legacy';
    if (rowUid == currentUid) return 'open';
    return 'need_login';
  }

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

    await _db?.close();

    _currentPath = fullPath;

    // Abertura manual (legado): dono desconhecido até switchToAccount.
    // push() pula e syncNow() corrige sozinho.
    _openUid = null;

    _db = await openDatabase(

      fullPath,

      version: 9,

      onCreate: _onCreateDb,

      onUpgrade: _onUpgradeDb,

    );

  }

  /// Caminho do arquivo da conta (criado sob demanda).
  Future<String> accountDbPath(String uid) async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, accountFileName(uid));
  }

  /// Troca transacional de conta (login): resolve a linha do UID
  /// (criando com displayName se nova) e abre o arquivo DELA.
  /// uid null (logout) só limpa o contexto — o arquivo fica como está
  /// (a tela de login não lê nada relevante e o próximo login abre o
  /// arquivo certo). Nunca mistura: arquivo aberto sempre casa com UID.
  Future<void> switchToAccount({
    required String? uid,
    String kind = 'guest',
    String displayName = '',
  }) async {
    if (uid == null || uid.isEmpty) {
      _openUid = null;
      return;
    }
    if (uid == _openUid && _db != null) return;
    Map<String, Object?>? row;
    try {
      row = await findRowByUid(uid);
    } catch (_) {
      row = null;
    }
    row ??= await _createBoundRow(
        uid: uid, authType: kind, displayName: displayName);
    if (row == null) return;
    await openProfileRow(row);
  }

  /// Linha do registro para o UID (qualquer arquivo). Null se a conta
  /// nunca passou por este aparelho.
  Future<Map<String, Object?>?> findRowByUid(String uid) async {
    try {
      final mdb = await mainDb();
      final rows = await mdb.query('profiles',
          where: 'firebase_uid = ?', whereArgs: [uid], limit: 1);
      if (rows.isEmpty) return null;
      return Map<String, Object?>.of(rows.first);
    } catch (_) {
      return null;
    }
  }

  /// Cria a linha vinculada (arquivo account_<uid>.db, nasce na hora
  /// de abrir). Nome UNIQUE colidiu: sufixa em vez de falhar.
  Future<Map<String, Object?>?> _createBoundRow({
    required String uid,
    required String authType,
    required String displayName,
  }) async {
    try {
      var name = displayName.trim();
      if (name.isEmpty || name == 'Convidado') name = 'Convidado';
      final path = await accountDbPath(uid);
      final now = DateTime.now().toIso8601String();
      Map<String, Object?> row = <String, Object?>{
        'id': const Uuid().v4().substring(0, 8),
        'name': name,
        'database_path': path,
        'avatar_path': null,
        'code': newInviteCode(),
        'firebase_uid': uid,
        'auth_type': authType,
        'last_opened_at': now,
      };
      final mdb = await mainDb();
      try {
        await mdb.insert('profiles', row);
      } catch (_) {
        row = Map<String, Object?>.of(row);
        row['name'] = '$name • ${uid.substring(0, 4)}';
        try {
          await mdb.insert('profiles', row);
        } catch (_) {
          return null;
        }
      }
      return row;
    } catch (_) {
      return null;
    }
  }

  /// Abre a linha de perfil/conta: o arquivo DELA vira o ativo e
  /// _openUid acompanha o dono. Com bindUid, vincula linha legada
  /// (sem dono) à sessão atual — o toque na linha É o ato explícito.
  Future<void> openProfileRow(Map<String, Object?> pr,
      {String? bindUid}) async {
    final path = (pr['database_path'] ?? '').toString();
    if (path.isEmpty) throw StateError('Perfil sem arquivo');
    final rowUid = (pr['firebase_uid'] ?? '').toString();
    final id = (pr['id'] ?? '').toString();
    final owner = rowUid.isNotEmpty
        ? rowUid
        : (bindUid ?? '').isNotEmpty
            ? bindUid!
            : null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_db_path', path);
    await _db?.close();
    _currentPath = path;
    _db = await openDatabase(
      path,
      version: 9,
      onCreate: _onCreateDb,
      onUpgrade: _onUpgradeDb,
    );
    _openUid = owner;
    if (owner != null && rowUid.isEmpty && id.isNotEmpty) {
      try {
        await (await mainDb()).update('profiles',
            {'firebase_uid': owner},
            where: 'id = ?', whereArgs: [id]);
      } catch (_) {}
      try {
        await _db!.update('profiles', {'firebase_uid': owner},
            where: 'id = ?', whereArgs: [id]);
      } catch (_) {}
    }
    // A linha do registro também mora no arquivo (diálogo de nome e
    // lookups por caminho dependem dela). Sem duplicar.
    if (id.isNotEmpty) {
      try {
        final inFile = await _db!.query('profiles',
            where: 'id = ?', whereArgs: [id], limit: 1);
        if (inFile.isEmpty) {
          await _db!
              .insert('profiles', Map<String, Object?>.of(pr));
        }
      } catch (_) {}
    }
    // Auto-cura da duplicata "Convidado / Convidado • XXXX": se o
    // arquivo tem a linha vinculada do dono, as órfãs NULL somem
    // (dados intactos — só o índice de perfis). Vale para o arquivo
    // e para o registro que aponta para ele.
    if (owner != null) {
      try {
        final mine = await _db!.query('profiles',
            where: 'firebase_uid = ?', whereArgs: [owner], limit: 1);
        if (mine.isNotEmpty) {
          final myId = (mine.first['id'] ?? '').toString();
          await _db!.delete('profiles',
              where:
                  '(firebase_uid IS NULL OR TRIM(firebase_uid) = ?) AND id != ?',
              whereArgs: ['', myId]);
          try {
            final mdb = await mainDb();
            await mdb.delete('profiles',
                where: 'database_path = ? AND (firebase_uid IS NULL OR TRIM(firebase_uid) = ?)',
                whereArgs: [_currentPath, '']);
          } catch (_) {}
        }
      } catch (_) {}
    }
    try {
      final now = DateTime.now().toIso8601String();
      await (await mainDb()).update('profiles',
          {'last_opened_at': now},
          where: 'id = ?', whereArgs: [id]);
    } catch (_) {}
    AppEvents.notifyProfileChanged();
  }

  /// Cria linha de convidado (nome escolhido) com arquivo próprio.
  /// Com firebaseUid, já nasce vinculada (sem duplicata depois).
  /// Não abre nem entra: quem chama abre em seguida.
  Future<Map<String, Object?>> createGuestRow(String name,
      {String? firebaseUid}) async {
    final clean = name.trim().isEmpty ? 'Convidado' : name.trim();
    final dir = await getApplicationDocumentsDirectory();
    final id = const Uuid().v4().substring(0, 8);
    final safe = clean.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final path =
        p.join(dir.path, '${safe.isEmpty ? 'perfil' : safe}_$id.db');
    Map<String, Object?> row = <String, Object?>{
      'id': id,
      'name': clean,
      'database_path': path,
      'avatar_path': null,
      'code': newInviteCode(),
      'firebase_uid': firebaseUid,
      'auth_type': 'guest',
      'last_opened_at': DateTime.now().toIso8601String(),
    };
    try {
      await (await mainDb())
          .insert('profiles', Map<String, Object?>.of(row));
    } catch (_) {
      row = Map<String, Object?>.of(row);
      row['name'] = '$clean • ${id.substring(0, 4)}';
      try {
        await (await mainDb())
            .insert('profiles', Map<String, Object?>.of(row));
      } catch (_) {}
    }
    return row;
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

    // MigraÃ§Ã£o idempotente como migrate_database() do desktop.

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

    // CÃ³digo de convite (amigos) em instalaÃ§Ãµes antigas.

    try {

      await db.execute('ALTER TABLE profiles ADD COLUMN code TEXT');

    } catch (_) {}

    // Capa escolhida para o deck (instalaÃ§Ãµes antigas podem nÃ£o ter).

    try {

      await db.execute('ALTER TABLE decks ADD COLUMN preview_card_id INTEGER');

    } catch (_) {}

    // PreÃ§os multilÃ­ngues (v6): eur_foil faltava (crash silencioso no
    // update), price_source/price_updated_at registram a origem do valor
    // (exact x fallback mesma impressÃ£o x aproximado x none) para cache
    // e para nÃ£o reconsultar a API Ã  toa.
    for (final col in _cardPriceColumns) {
      try {
        await db.execute('ALTER TABLE cards ADD COLUMN $col');
      } catch (_) {}
    }

    // Stats de deck (v8): garante mana_cost/type_line/cmc/cores em
    // bancos antigos; linhas com cmc nulo são preenchidas pelo
    // ManaRepairService a partir do mana_cost.
    for (final col in _cardStatColumns) {
      try {
        await db.execute('ALTER TABLE cards ADD COLUMN $col');
      } catch (_) {}
    }

    // Contas (v9): dono e tipo da identidade em profiles.
    for (final col in _profileAccountColumns) {
      try {
        await db.execute('ALTER TABLE profiles ADD COLUMN $col');
      } catch (_) {}
    }

  }

  Future<String> mainDbPath() async {

    if (_mainPath != null && _mainPath!.isNotEmpty) return _mainPath!;

    final dir = await getApplicationDocumentsDirectory();

    _mainPath = p.join(dir.path, 'save.db');

    return _mainPath!;

  }

  /// Handle do banco principal (o sqflite reaproveita a conexÃ£o

  /// quando o caminho jÃ¡ estÃ¡ aberto â€” sem lock duplo).

  Future<Database> mainDb() async {

    final m = await mainDbPath();

    return openDatabase(

      m,

      version: 9,

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

  /// Dono da linha (v9): qual conta Firebase usa este arquivo/linha.
  /// NULL = legado (pré-contas). Idempotente via try/catch.
  static const _profileAccountColumns = <String>[
    'firebase_uid TEXT',
    'auth_type TEXT',
  ];

  /// Colunas usadas por stats/disponibilidade que podem faltar em
  /// bancos criados por versões antigas (sintoma: curva zerada e
  /// MV 0 mesmo com o deck cheio). Idempotente via try/catch.
  static const _cardStatColumns = <String>[
    'oracle_id TEXT',
    'mana_cost TEXT',
    'type_line TEXT',
    'rarity TEXT',
    'cmc REAL',
    'colors TEXT',
    'color_identity TEXT',
    'set_code TEXT',
    'set_name TEXT',
    'power TEXT',
    'toughness TEXT',
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
  /// habilidades em JSON, descriÃ§Ã£o e arte).
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

        firebase_uid TEXT,

        auth_type TEXT,

        last_opened_at TIMESTAMP

      )''');

  }

  /// Amigos (contatos locais por cÃ³digo de convite).

  /// O cÃ³digo do amigo serve para montar a mesa no "Jogar".

  /// (Login Gmail / sync online = prÃ³xima fase, com servidor.)
  static Future<void> _createSocial(DatabaseExecutor db) async {

    await db.execute('''

      CREATE TABLE IF NOT EXISTS friends (

        id TEXT PRIMARY KEY,

        name TEXT NOT NULL,

        code TEXT NOT NULL,

        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP

      )''');

  }

  /// Gera cÃ³digo de convite curto (6 letras/nÃºmeros).

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

  /// O primeiro perfil usa o banco local jÃ¡ aberto. Assim, coleÃ§Ã£o, decks

  /// e preferÃªncias ficam vinculados ao nome escolhido neste aparelho.

  Future<bool> needsProfileSetup() async {

    final prefs = await SharedPreferences.getInstance();

    final active = prefs.getString('active_db_path') ?? '';

    if (active.isEmpty) return true;

    final rows = await db.query('profiles',

        columns: ['name', 'firebase_uid'],

        where: 'database_path = ?',

        whereArgs: [active]);

    // Prefere a linha vinculada à conta; a órfã não decide sozinha.
    Map<String, Object?>? row;
    for (final r in rows) {
      row ??= r;
      if ((r['firebase_uid'] ?? '').toString().isNotEmpty) {
        row = r;
        break;
      }
    }
    if (row == null) return true;

    return (row['name'] ?? '').toString().trim().isEmpty ||

        (row['name'] ?? '').toString().trim() == 'Convidado';

  }

  /// Define o nome do perfil ativo e mantÃ©m o mesmo perfil sincronizado
  /// entre o banco do perfil e o registro global (save.db).
  ///
  /// O ID do perfil Ã© a identidade real; o apelido Ã© apenas um atributo.
  Future<void> nameActiveProfile(String name,
      {String? firebaseUid, String? authType}) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError('Nome vazio');

    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getString('active_db_path') ?? '';
    if (active.isEmpty) throw StateError('Nenhum perfil ativo');

    final found = await db.query(
      'profiles',
      columns: [
        'id',
        'name',
        'database_path',
        'avatar_path',
        'code',
        'firebase_uid',
        'auth_type',
        'last_opened_at'
      ],
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
        if (firebaseUid != null && firebaseUid.isNotEmpty)
          'firebase_uid': firebaseUid,
        if (authType != null && authType.isNotEmpty)
          'auth_type': authType,
        'last_opened_at': now,
      };
      try {
        await db.insert('profiles', profile);
      } catch (_) {
        // Colunas novas ainda não migradas: tenta sem elas.
        final fallback = Map<String, Object?>.of(profile)
          ..remove('firebase_uid')
          ..remove('auth_type');
        await db.insert('profiles', fallback);
      }
    } else {
      profile = Map<String, Object?>.from(found.first);
      profile['name'] = clean;
      profile['last_opened_at'] = now;
      if (firebaseUid != null && firebaseUid.isNotEmpty) {
        profile['firebase_uid'] = firebaseUid;
      }
      if (authType != null && authType.isNotEmpty) {
        profile['auth_type'] = authType;
      }
      final patch = <String, Object?>{
        'name': clean,
        'last_opened_at': now,
      };
      if (profile.containsKey('firebase_uid')) {
        patch['firebase_uid'] = profile['firebase_uid'];
      }
      if (profile.containsKey('auth_type')) {
        patch['auth_type'] = profile['auth_type'];
      }
      try {
        await db.update(
          'profiles',
          patch,
          where: 'id = ?',
          whereArgs: [profile['id']],
        );
      } catch (_) {
        await db.update(
          'profiles',
          {'name': clean, 'last_opened_at': now},
          where: 'id = ?',
          whereArgs: [profile['id']],
        );
      }
    }

    // O mesmo ID/nome é persistido também no registro global.
    await registryUpsert(profile);
  }

  /// Primeira abertura sem perfil: cria o convidado automaticamente.

  /// O registro usa o banco ATUALMENTE aberto (pode ser outro perfil

  /// apÃ³s trocas) â€” nunca o save.db fixo.

  Future<void> _ensureDefaultProfile() async {

    // Arquivos de conta (account_<uid>.db) ganham a linha pelo fluxo
    // de conta (switch/nomeação), nunca um 'Convidado' órfão aqui —
    // era isso que duplicava ("Convidado" + "Convidado • XXXX").
    final cur = _currentPath ?? '';
    if (p.basename(cur).startsWith('account_')) return;

    final rows = await db.query('profiles', limit: 1);

    if (rows.isNotEmpty) {

      // Garante cÃ³digo em perfis antigos.

      for (final r in rows) {

        if ((r['code'] ?? '').toString().isEmpty) {

          await db.update('profiles', {'code': newInviteCode()},

              where: 'id = ?', whereArgs: [r['id']]);

        }

      }

      // Corrige instalaÃ§Ãµes antigas em que o perfil existia apenas no
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

  /// Upsert por scryfall_id â€” equivale a ensure_card_exists().

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

  /// Busca na coleÃ§Ã£o com filtros (equivale aos filtros do desktop:

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

    // colors Ã© JSON: [] | ["W"] | ["W","U"] ...

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

  /// Total de cartas na coleÃ§Ã£o COM os mesmos filtros da busca.
  /// A lista Ã© paginada (sem teto de 300): o total alimenta o
  /// "Exibindo X de Y" e o scroll infinito.
  /// Shared WHERE clauses for the collection (quantity > 0 + filters).
  /// Used by [countCollection] and [collectionTotals] so they never diverge.
  ({String where, List<Object?> args}) _collectionClauses(
      {String query = '',
      String rarity = 'all',
      String setName = 'all',
      String color = 'all',
      String typeQuery = '',
      bool favoritesOnly = false}) {
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
    return (where: clauses.join(' AND '), args: args);
  }

  /// Collection totals with the same filters: unique cards (rows)
  /// and total copies (sum of quantity).
  Future<({int unique, int copies})> collectionTotals(
      {String query = '',
      String rarity = 'all',
      String setName = 'all',
      String color = 'all',
      String typeQuery = '',
      bool favoritesOnly = false}) async {
    final c = _collectionClauses(
        query: query,
        rarity: rarity,
        setName: setName,
        color: color,
        typeQuery: typeQuery,
        favoritesOnly: favoritesOnly);
    final r = await db.rawQuery(
        'SELECT COUNT(*) AS u, COALESCE(SUM(quantity),0) AS t FROM cards WHERE ${c.where}',
        c.args);
    return (
      unique: (r.first['u'] as num?)?.toInt() ?? 0,
      copies: (r.first['t'] as num?)?.toInt() ?? 0,
    );
  }

  Future<int> countCollection(

      {String query = '',

      String rarity = 'all',

      String setName = 'all',

      String color = 'all',

      String typeQuery = '',

      bool favoritesOnly = false}) async {

    final cc = _collectionClauses(
        query: query,
        rarity: rarity,
        setName: setName,
        color: color,
        typeQuery: typeQuery,
        favoritesOnly: favoritesOnly);

    final r = await db.rawQuery(

        'SELECT COUNT(*) AS n FROM cards WHERE ${cc.where}',

        cc.args);

    return (r.first['n'] as num?)?.toInt() ?? 0;

  }

  /// Sets distintos da coleÃ§Ã£o (para o filtro de set).

  Future<List<String>> distinctSets() async {

    final rows = await db.rawQuery(

        "SELECT DISTINCT set_name FROM cards WHERE quantity > 0 AND set_name IS NOT NULL AND TRIM(set_name) != '' ORDER BY set_name");

    return rows.map((r) => (r['set_name'] ?? '').toString()).toList();

  }

  /// Busca no catÃ¡logo LOCAL inteiro (coleÃ§Ã£o + cartas sÃ³-de-deck),

  /// sem filtro de quantity. Usada para adicionar cartas da coleÃ§Ã£o

  /// aos decks â€” funciona offline, sem Scryfall.

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

  // ---------- snapshots (retrato diÃ¡rio congelado) ----------

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