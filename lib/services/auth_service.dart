import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_events.dart';

// Conta Firebase do app (Auth nativo, sem sistema paralelo).
//
// Estados: sem usuário (tela de login) | anônimo = visitante |
// permanente (Google/Email). O UID anônimo é a identidade social
// atual; ao vincular Google/Email o UID É PRESERVADO via
// linkWithCredential (coleção/decks/sociais não mudam de dono).
// Logout = signOut: dados locais (sqlite) intactos, volta ao login.
//
// CONTA TEMPORÁRIA PAUSADA (detalhe técnico importante): uma conta
// anônima após signOut REAL é irrecuperável (sem credencial salva, o
// UID se perde para sempre). Por isso "Sair" do visitante NÃO faz
// signOut Firebase: marca guestPaused e o gate volta ao login,
// mantendo a sessão. "Conta deste dispositivo" retoma o MESMO UID.
// Só virar conta permanente ou entrar em outra conta abandona o UID
// temporário (avisado nos diálogos).
class AuthService {
  AuthService._();

  static const _pausedKey = 'auth_guest_paused';

  /// Visitante pausado (tela de login, sessão preservada).
  static final ValueNotifier<bool> guestPaused = ValueNotifier(false);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      guestPaused.value = prefs.getBool(_pausedKey) ?? false;
    } catch (_) {}
  }

  static Future<void> _setPaused(bool v) async {
    guestPaused.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_pausedKey, v);
    } catch (_) {}
  }

  /// Pode entrar no app? Permanente sempre; anônimo só se NÃO pausado.
  /// Nenhum caminho do app cria sessão sozinho: logout nunca chama
  /// signIn, então "sem usuário" sempre cai no login.
  static bool canEnterApp(User? u) {
    if (u == null) return false;
    if (!u.isAnonymous) return true;
    return !guestPaused.value;
  }

  /// Há conta temporária pausada neste aparelho para retomar
  /// (mesma sessão Firebase, mesmo UID, mesmos dados).
  static bool get hasPausedGuest =>
      guestPaused.value &&
      current != null &&
      current!.isAnonymous;

  static FirebaseAuth get _auth => FirebaseAuth.instance;

  static Stream<User?> authChanges() => _auth.authStateChanges();

  static User? get current => _auth.currentUser;

  static bool get isSignedIn => _auth.currentUser != null;

  static bool get isAnonymous =>
      _auth.currentUser == null || _auth.currentUser!.isAnonymous;

  static bool get isPermanent =>
      _auth.currentUser != null && !_auth.currentUser!.isAnonymous;

  /// Tipo da conta ativa p/ exibição e roteamento de banco:
  /// 'guest' | 'google' | 'email' | 'none'.
  static String get accountKind {
    final u = _auth.currentUser;
    if (u == null) return 'none';
    if (u.isAnonymous) return 'guest';
    if (u.providerData.any((p) => p.providerId == 'google.com')) {
      return 'google';
    }
    return 'email';
  }

  static String get displayEmail =>
      _auth.currentUser?.email ?? '';

  static Future<User>? _guestInflight;

  /// Visitante: retoma a sessão pausada (MESMO UID) ou cria a
  /// temporária do aparelho se não houver sessão. Nunca chamado
  /// sozinho pelo app: só no botão explícito. Single-flight.
  static Future<User> signInGuest() {
    final cur = _auth.currentUser;
    if (cur != null && cur.isAnonymous) {
      _setPaused(false);
      return Future.value(cur);
    }
    return _guestInflight ??= () async {
      try {
        final again = _auth.currentUser;
        if (again != null && again.isAnonymous) {
          await _setPaused(false);
          return again;
        }
        final cred = await _auth.signInAnonymously();
        final user = cred.user;
        if (user == null) throw StateError('auth_no_identity');
        await _setPaused(false);
        return user;
      } finally {
        _guestInflight = null;
      }
    }();
  }

  /// Credencial Google (retorna null se o usuário cancelar).
  /// Exige configuração nativa (SHA-1/google-services + iOS plist);
  /// sem ela, lança erro tratado como auth_google_config.
  static Future<AuthCredential?> _googleCredential() async {
    try {
      await GoogleSignIn.instance.initialize();
    } catch (_) {}
    late final GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } catch (e) {
      if (e.toString().toLowerCase().contains('cancel')) return null;
      rethrow;
    }
    final authn = account.authentication;
    // v6: Future, v7: sync — aceita ambos.
    final tokens =
        authn is Future ? await authn : authn;
    final idToken = (tokens as GoogleSignInAuthentication).idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError('auth_google_config');
    }
    return GoogleAuthProvider.credential(idToken: idToken);
  }

  /// Google: vincula (preserva UID/dados) se visitante, senão entra.
  /// Com link=false e sessão anônima ativa, entrar em outra conta
  /// ABANDONA a temporária (irrecuperável): exige forceAbandon.
  /// Retorna null se cancelado.
  static Future<User?> signInWithGoogle(
      {bool link = true, bool forceAbandon = false}) async {
    final cred = await _googleCredential();
    if (cred == null) return null;
    try {
      User? user;
      if (link && isAnonymous && current != null) {
        user = (await current!.linkWithCredential(cred)).user;
      } else {
        if (isAnonymous && current != null && !forceAbandon) {
          throw StateError('auth_abandon_guest');
        }
        if (current != null) {
          AppEvents.notifyAuthStopping();
          await _auth.signOut();
        }
        user = (await _auth.signInWithCredential(cred)).user;
      }
      await _adoptPermanent(user);
      return user;
    } on FirebaseAuthException catch (e) {
      throw StateError(_code(e));
    }
  }

  /// Email/senha: cria conta ou entra.
  /// Com link=true e visitante, vincula (preserva tudo). Se a
  /// credencial já pertence a outra conta, ERRO explícito
  /// (auth_email_in_use): o usuário deve sair antes e entrar direto
  /// — nunca vinculação silenciosa nem troca automática.
  static Future<User> signInWithEmail({
    required String email,
    required String password,
    required bool create,
    bool link = true,
    bool forceAbandon = false,
  }) async {
    final mail = email.trim();
    if (mail.isEmpty || !mail.contains('@')) {
      throw StateError('auth_bad_email');
    }
    if (password.length < 6) {
      throw StateError('auth_weak_password');
    }
    final cred =
        EmailAuthProvider.credential(email: mail, password: password);
    if (!link && isAnonymous && current != null && !forceAbandon) {
      throw StateError('auth_abandon_guest');
    }
    try {
      User? user;
      if (create) {
        if (link && isAnonymous && current != null) {
          user = (await current!.linkWithCredential(cred)).user ??
              await _fallbackCreate(mail, password);
        } else {
          if (current != null) {
            AppEvents.notifyAuthStopping();
            await _auth.signOut();
          }
          user = (await _auth.createUserWithEmailAndPassword(
                  email: mail, password: password))
              .user!;
        }
        await _adoptPermanent(user);
        return user;
      }
      if (link && isAnonymous && current != null) {
        try {
          user = (await current!.linkWithCredential(cred)).user ??
              await _fallbackSignIn(mail, password);
        } on FirebaseAuthException catch (e) {
          if (e.code == 'credential-already-in-use' ||
              e.code == 'email-already-in-use') {
            throw StateError('auth_email_in_use');
          }
          rethrow;
        }
        await _adoptPermanent(user);
        return user;
      }
      if (current != null) {
        AppEvents.notifyAuthStopping();
        await _auth.signOut();
      }
      user = (await _auth.signInWithEmailAndPassword(
              email: mail, password: password))
          .user!;
      await _adoptPermanent(user);
      return user;
    } on FirebaseAuthException catch (e) {
      throw StateError(_code(e));
    }
  }

  static Future<User> _fallbackCreate(String mail, String pw) async =>
      (await _auth.createUserWithEmailAndPassword(
              email: mail, password: pw))
          .user!;

  static Future<User> _fallbackSignIn(String mail, String pw) async =>
      (await _auth.signInWithEmailAndPassword(
              email: mail, password: pw))
          .user!;

  /// Conta permanente assumida: limpa pausa de visitante.
  static Future<void> _adoptPermanent(User? user) async {
    if (user == null || user.isAnonymous) return;
    await _setPaused(false);
  }

  /// Pausa o visitante (SEM signOut Firebase: a sessão anônima é
  /// irrecuperável após signOut real). O gate volta ao login.
  static Future<void> pauseGuest() async {
    await _setPaused(true);
  }

  /// Sai: encerra sessão (Google + Firebase), mantém dados locais.
  /// Conta permanente ou troca real de identidade. Nunca cria nada:
  /// o gate cai no login e só sai de lá por escolha explícita.
  /// As escutas RTDB são derrubadas ANTES (authStopping), para não
  /// lerem o UID velho sem permissão durante a transição.
  static Future<void> signOut() async {
    AppEvents.notifyAuthStopping();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    await _auth.signOut();
    await _setPaused(false);
  }

  static String _code(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
      case 'user-disabled':
        return 'auth_user_not_found';
      case 'wrong-password':
      case 'invalid-credential':
        return 'auth_wrong_password';
      case 'email-already-in-use':
      case 'credential-already-in-use':
        return 'auth_email_in_use';
      case 'invalid-email':
        return 'auth_bad_email';
      case 'weak-password':
        return 'auth_weak_password';
      case 'network-request-failed':
        return 'auth_network';
      case 'provider-already-linked':
        return 'auth_provider_linked';
      case 'too-many-requests':
        return 'auth_too_many';
      default:
        return 'auth_generic';
    }
  }

  /// Mensagem em PT a partir de código interno ou exceção.
  static String message(Object e, String Function(String) t) {
    final code = e is StateError ? e.message : '$e';
    const known = {
      'auth_no_identity',
      'auth_google_config',
      'auth_bad_email',
      'auth_weak_password',
      'auth_user_not_found',
      'auth_wrong_password',
      'auth_email_in_use',
      'auth_abandon_guest',
      'auth_network',
      'auth_provider_linked',
      'auth_too_many',
      'auth_generic',
    };
    if (known.contains(code)) return t(code);
    if (e is FirebaseAuthException) return t(_code(e));
    return t('auth_generic');
  }
}
