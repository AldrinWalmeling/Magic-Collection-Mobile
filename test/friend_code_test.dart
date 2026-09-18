import 'package:flutter_test/flutter_test.dart';
import 'package:magic_collection/services/online_friends.dart';

// Códigos de amigo personalizados (#MEUCODIGO): sanitização e lookup.
// Sem rede, sem banco (lógica pura).

void main() {
  group('sanitizeCode', () {
    test('nome vira código', () {
      expect(OnlineFriends.sanitizeCode('João Silva'), 'JOAO_SILVA');
    });
    test('remove # e minúsculas', () {
      expect(OnlineFriends.sanitizeCode('#meucodigo'), 'MEUCODIGO');
    });
    test('hífens e símbolos', () {
      expect(OnlineFriends.sanitizeCode('a-b c!'), 'A-B_C');
    });
    test('colapsa underscores', () {
      expect(OnlineFriends.sanitizeCode('__X__'), 'X');
    });
    test('vazio continua vazio', () {
      expect(OnlineFriends.sanitizeCode('!!!'), isEmpty);
    });
    test('legado MC- preservado', () {
      expect(OnlineFriends.sanitizeCode('MC-AB12C'), 'MC-AB12C');
      expect(OnlineFriends.normalizeLookup('mc-ab12c'), 'MC-AB12C');
    });
  });

  group('normalizeLookup', () {
    test('acha com # e espaços', () {
      expect(OnlineFriends.normalizeLookup('#meu codigo'),
          'MEU_CODIGO');
    });
  });
}
