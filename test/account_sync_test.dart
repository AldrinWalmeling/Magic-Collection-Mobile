import 'package:flutter_test/flutter_test.dart';
import 'package:magic_collection/data/app_database.dart';
import 'package:magic_collection/services/account_sync.dart';

// Lógica pura do backup da conta (sem Firebase, sem banco).

void main() {
  group('decide', () {
    test('nada dos dois lados', () {
      expect(
          AccountSync.decide(localEmpty: true, remoteEmpty: true),
          'nothing');
    });
    test('login com backup: servidor vence (mesmo com local)', () {
      expect(
          AccountSync.decide(localEmpty: true, remoteEmpty: false),
          'restored');
      expect(
          AccountSync.decide(localEmpty: false, remoteEmpty: false),
          'restored');
    });
    test('só local: primeiro backup', () {
      expect(
          AccountSync.decide(localEmpty: false, remoteEmpty: true),
          'pushed');
    });
    test('vinculação: locais preservados, envia', () {
      expect(
          AccountSync.decide(
              localEmpty: false,
              remoteEmpty: false,
              preferPush: true),
          'pushed');
      expect(
          AccountSync.decide(
              localEmpty: true, remoteEmpty: false, preferPush: true),
          'restored');
    });
  });

  group('localOnlyFields', () {    test('id e image_path nunca sobem', () {
      expect(AccountSync.localOnlyFields, contains('id'));
      expect(AccountSync.localOnlyFields, contains('image_path'));
      expect(AccountSync.localOnlyFields, isNot(contains('quantity')));
      expect(AccountSync.localOnlyFields, isNot(contains('favorite')));
    });
  });

  group('accountFileName', () {
    test('UID vira arquivo estável', () {
      expect(AppDatabase.accountFileName('ABC123xyz'),
          'account_ABC123xyz.db');
    });
    test('saneia caracteres', () {
      expect(AppDatabase.accountFileName('a/b:c@d'),
          'account_a_b_c_d.db');
    });
  });

  group('gateOpen', () {
    test('sem usuário: precisa login', () {
      expect(
          AppDatabase.gateOpen(
              rowUid: 'A', currentUid: null, signedIn: false),
          'need_login');
    });
    test('linha legada: fluxo explícito', () {
      expect(
          AppDatabase.gateOpen(
              rowUid: '', currentUid: 'A', signedIn: true),
          'legacy');
    });
    test('mesmo uid: abre', () {
      expect(
          AppDatabase.gateOpen(
              rowUid: 'A', currentUid: 'A', signedIn: true),
          'open');
    });
    test('outro uid: precisa login', () {
      expect(
          AppDatabase.gateOpen(
              rowUid: 'B', currentUid: 'A', signedIn: true),
          'need_login');
    });
  });
}
