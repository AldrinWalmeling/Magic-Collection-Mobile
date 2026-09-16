import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ExportService {
  static const fields = [
    'name',
    'printed_name',
    'lang',
    'set_name',
    'collector_number',
    'quantity',
    'price_usd',
    'rarity',
  ];

  static const backupVersion = 1;

  static Future<File> _write(String filename, String content) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    return file.writeAsString(content, encoding: utf8);
  }

  static Future<void> exportCsv(List<Map<String, Object?>> cards) async {
    final rows = [
      fields,
      for (final c in cards)
        [for (final f in fields) (c[f] ?? '').toString()],
    ];
    final csv = const ListToCsvConverter().convert(rows);
    final file = await _write('minha_colecao.csv', csv);
    await Share.shareXFiles([XFile(file.path)], text: 'Minha coleção MTG');
  }

  static Future<void> exportJson(List<Map<String, Object?>> cards) async {
    final file = await _write(
      'minha_colecao.json',
      const JsonEncoder.withIndent('  ').convert(cards),
    );
    await Share.shareXFiles([XFile(file.path)], text: 'Minha coleção MTG');
  }

  static Future<void> exportTxt(List<Map<String, Object?>> cards) async {
    final buf = StringBuffer();
    for (final c in cards) {
      buf.writeln('${c['quantity'] ?? 0}x ${c['name'] ?? ''} [${c['set_code'] ?? ''}]');
    }
    final file = await _write('minha_colecao.txt', buf.toString());
    await Share.shareXFiles([XFile(file.path)], text: 'Minha coleção MTG');
  }

  static Future<void> exportCompleteBackup(
    List<Map<String, Object?>> cards,
  ) async {
    final payload = <String, Object?>{
      'format': 'magic_collection_backup',
      'version': backupVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'card_count': cards.length,
      'cards': cards,
    };

    final file = await _write(
      'magic_collection_backup.json',
      const JsonEncoder.withIndent('  ').convert(payload),
    );

    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Backup completo da minha coleção MTG',
    );
  }

  static Future<void> exportDeckTxt(
    String deckName,
    List<Map<String, Object?>> items,
  ) async {
    final buf = StringBuffer();
    for (final c in items) {
      final qty = (c['deck_qty'] ?? c['quantity'] ?? 1).toString();
      buf.writeln('${qty}x ${c['name'] ?? ''} [${c['set_code'] ?? ''}]');
    }
    final safe = deckName.replaceAll(RegExp(r'[^\\w\\- ]+'), '').trim();
    final file = await _write(
      '${safe.isEmpty ? 'deck' : safe}.txt',
      buf.toString(),
    );
    await Share.shareXFiles([XFile(file.path)], text: 'Deck $deckName');
  }
}
