import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic_collection/services/auth_service.dart';

// Mapeamento de erros de auth (lógica pura, sem Firebase ativo).

String _t(String code) => 'MSG:$code';

void main() {
  group('AuthService.message', () {
    test('StateError com código conhecido', () {
      expect(AuthService.message(StateError('auth_bad_email'), _t),
          'MSG:auth_bad_email');
      expect(AuthService.message(StateError('auth_email_in_use'), _t),
          'MSG:auth_email_in_use');
    });
    test('FirebaseAuthException mapeada', () {
      expect(
          AuthService.message(
              FirebaseAuthException(code: 'user-not-found'), _t),
          'MSG:auth_user_not_found');
      expect(
          AuthService.message(
              FirebaseAuthException(code: 'wrong-password'), _t),
          'MSG:auth_wrong_password');
      expect(
          AuthService.message(
              FirebaseAuthException(code: 'network-request-failed'),
              _t),
          'MSG:auth_network');
    });
    test('desconhecido vira genérico', () {
      expect(AuthService.message(StateError('x'), _t),
          'MSG:auth_generic');
      expect(
          AuthService.message(
              FirebaseAuthException(code: 'weird-code'), _t),
          'MSG:auth_generic');
    });
  });
  group('canEnterApp', () {
    test('sem usuário nunca entra', () {
      expect(AuthService.canEnterApp(null), isFalse);
    });
  });
}