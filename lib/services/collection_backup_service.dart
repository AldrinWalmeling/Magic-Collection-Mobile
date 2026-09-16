import 'dart:convert';
import 'package:file_picker/file_picker.dart';

import '../data/app_database.dart';

class CollectionBackupFile {
  const CollectionBackupFile({
    required this.fileName,
    required this.cards,
  });

  final String fileName;
  final List<Map<String, Object?>> cards;
}

class CollectionImportResult {
  const CollectionImportResult({
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
    this.errors = 0,
  });

  final int added;
  final int updated;
  final int skipped;
  final int errors;
}

class CollectionBackupService {
  static const _format = 'magic_collection_backup';
  static const _version = 1;

  static Future<CollectionBackupFile?> pickAndReadBackup() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const FormatException('Não foi possível ler o arquivo selecionado.');
    }

    final text = utf8.decode(bytes, allowMalformed: false);
    final decoded = jsonDecode(text);
    if (decoded is List) {
      final cards = <Map<String, Object?>>[];
      for (final raw in decoded) {
        if (raw is Map) {
          cards.add(Map<String, Object?>.from(raw));
        }
      }
      return CollectionBackupFile(fileName: file.name, cards: cards);
    }
    if (decoded is! Map) {
      throw const FormatException('Formato de coleção inválido.');
    }

    final isStructuredBackup = decoded['format'] == _format;
    final isLegacyCollection =
        decoded['cards'] is List || decoded['cartas'] is List;

    if (!isStructuredBackup && !isLegacyCollection) {
      throw const FormatException(
        'Este arquivo não contém uma coleção do Magic Collection.',
      );
    }

    if (isStructuredBackup) {
      final version = (decoded['version'] as num?)?.toInt();
      if (version != _version) {
        throw FormatException(
          'Versão de backup não suportada: ${decoded['version'] ?? 'desconhecida'}.',
        );
      }
    }

    final rawCards = decoded['cards'] ?? decoded['cartas'];
    if (rawCards is! List) {
      throw const FormatException('O arquivo não contém uma lista de cartas.');
    }

    final cards = <Map<String, Object?>>[];
    for (final raw in rawCards) {
      if (raw is! Map) continue;
      cards.add(Map<String, Object?>.from(raw));
    }

    return CollectionBackupFile(fileName: file.name, cards: cards);
  }

  static int _toInt(Object? value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '') ?? fallback;
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static Future<List<String>> _cardColumns() async {
    final rows = await AppDatabase.instance.db.rawQuery('PRAGMA table_info(cards)');
    return rows
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toList();
  }

  static Object? _databaseValue(Object? value) {
    if (value == null) return null;
    if (value is String || value is num || value is bool) return value;
    if (value is List || value is Map) return jsonEncode(value);
    return value.toString();
  }

  static Future<int?> _findExistingId(
    dynamic txn,
    Map<String, Object?> card,
  ) async {
    final scryfallId = _text(card['scryfall_id']);
    if (scryfallId.isNotEmpty) {
      final rows = await txn.query(
        'cards',
        columns: ['id'],
        where: 'scryfall_id = ?',
        whereArgs: [scryfallId],
        limit: 1,
      );
      if (rows.isNotEmpty) return (rows.first['id'] as num).toInt();
    }

    final name = _text(card['name']).isNotEmpty
        ? _text(card['name'])
        : _text(card['printed_name']);
    final setCode = _text(card['set_code']);
    final collector = _text(card['collector_number']);

    if (name.isEmpty || setCode.isEmpty || collector.isEmpty) return null;

    final rows = await txn.query(
      'cards',
      columns: ['id'],
      where: '((name = ?) OR (printed_name = ?)) AND set_code = ? AND collector_number = ?',
      whereArgs: [name, name, setCode, collector],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['id'] as num).toInt();
  }

  static Future<CollectionImportResult> importCards(
    List<Map<String, Object?>> cards,
  ) async {
    if (cards.isEmpty) return const CollectionImportResult();

    final db = AppDatabase.instance.db;
    final columns = (await _cardColumns()).toSet()..remove('id');

    var added = 0;
    var updated = 0;
    var skipped = 0;
    var errors = 0;

    await db.transaction((txn) async {
      for (final card in cards) {
        try {
          final scryfallId = _text(card['scryfall_id']);
          final name = _text(card['name']).isNotEmpty
              ? _text(card['name'])
              : _text(card['printed_name']);
          final setCode = _text(card['set_code']);
          final collector = _text(card['collector_number']);

          if (scryfallId.isEmpty &&
              (name.isEmpty || setCode.isEmpty || collector.isEmpty)) {
            skipped++;
            continue;
          }

          final existingId = await _findExistingId(txn, card);
          final values = <String, Object?>{};

          for (final entry in card.entries) {
            if (!columns.contains(entry.key)) continue;
            if (entry.key == 'id') continue;
            values[entry.key] = _databaseValue(entry.value);
          }

          if (columns.contains('quantity')) {
            final quantity = _toInt(card['quantity']);
            values['quantity'] = quantity < 0 ? 0 : quantity;
          }

          if (values.isEmpty) {
            skipped++;
            continue;
          }

          if (existingId != null) {
            await txn.update(
              'cards',
              values,
              where: 'id = ?',
              whereArgs: [existingId],
            );
            updated++;
          } else {
            await txn.insert('cards', values);
            added++;
          }
        } catch (_) {
          errors++;
        }
      }
    });

    return CollectionImportResult(
      added: added,
      updated: updated,
      skipped: skipped,
      errors: errors,
    );
  }
}
