import 'package:flutter_test/flutter_test.dart';
import 'package:magic_collection/services/price_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Portão de 24h do refresh de preços (lógica pura + prefs mock).
// Sem ele travado no "sempre atualizar", cada abertura do app
// rodava o ciclo inteiro de novo (o loop de requisições).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldUpdate', () {
    test('sem registro: atualiza', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
          await PriceUpdateService.instance
              .shouldUpdate(force: false),
          isTrue);
    });

    test('force sempre atualiza', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
          await PriceUpdateService.instance
              .shouldUpdate(force: true),
          isTrue);
    });
  });
}
