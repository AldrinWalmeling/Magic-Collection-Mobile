# Magic Collection — Mobile (Flutter → APK)

Migração do app desktop **PySide6** (`main.py`, `database.py`, `pages/`,
`services/`, `ui/theme.qss`) para **Android (APK)** em Flutter,
mantendo estética dark+ouro e todas as lógicas.

## O que foi preservado ponto a ponto

| Desktop | Mobile |
|---|---|
| `main.py` → init DB + decks + `MainWindow` + câmbio background | `lib/main.dart` → `AppDatabase.init()` + `CurrencyService.startBackgroundRefresh()` + `AppShell` |
| `ui/main_window.py` sidebar 200px | `AppShell` + `NavigationBar` (Painel/Coleção/Decks/Perfis/Ajustes) |
| `ui/theme.qss` bg `#0f1117`, painel `#1a1d27`, ouro `#d4a84b` | `lib/theme/app_theme.dart` (mesmos hex) |
| `database.py` tabela `cards` + `quantity>0=coleção` | `lib/data/app_database.dart` + `lib/models/mtg_card.dart` |
| `collection_snapshots` (retrato diário congelado) | `createSnapshot()` no dashboard |
| `services/scryfall.py` throttle 250ms, autocomplete PT, fallback imagem | `lib/services/scryfall_service.dart` |
| `services/currency_service.py` AwesomeAPI, TTL 1h | `lib/services/currency_service.dart` |
| `services/price_reference.py` modo Original x Imprint | `lib/services/price_reference.dart` |
| `services/collection_export.py` CSV/JSON/TXT | `lib/services/export_service.dart` (share) |
| `services/decks_database.py` + `pages/decks_page.py` | `lib/pages/decks_page.dart` + `deck_detail_page.dart` |
| `profile_manager.py` + `pages/profiles_page.py` | `lib/pages/profiles_page.dart` (1 .db por perfil) |
| `pages/settings_page.py` moeda + modo preço | `lib/pages/settings_page.dart` |
| `assets/icons/*` | `mobile/assets/icons/*` (copiados) |

## Pré-requisitos (no seu PC)

1. Instale o Flutter SDK 3.3+: https://docs.flutter.dev/get-started/install/windows
2. Instale o Android Studio + Android SDK + aceite as licenças:
   ```
   flutter doctor --android-licenses
   flutter doctor
   ```
3. Java 21 já está instalado nesta máquina (verificado).

## Gerar o APK

```powershell
cd C:\Users\aldri\Desktop\MagicCollection-main\mobile
flutter create . --project-name magic_collection --org com.magic.collection
flutter pub get
flutter build apk --release
```

O APK sai em:
`build\app\outputs\flutter-apk\app-release.apk`

Copie para o celular e instale (permita "fontes desconhecidas").

## Permissões Android

Ao rodar `flutter create .`, o `AndroidManifest.xml` é gerado.
Garanta estas permissões (internet é obrigatória p/ Scryfall + câmbio):

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

Pacotes que já pedem o necessário: `share_plus`,
`path_provider`, `cached_network_image`.

## Notas

- `statistics_page.py` do desktop estava vazia — estatísticas vivem no Painel.
- `models/` e `repositories/` do desktop estavam vazios — lógica real foi
  migrada para `lib/data/app_database.dart`.
- Banco mobile é SQLite via `sqflite`, mesmo esquema, então dá para
  importar seu `save.db` do desktop copiando o arquivo para o app.
