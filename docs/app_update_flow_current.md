# ZEON: текущая схема обновлений приложения

Дата актуализации: 2026-05-13

## 1) Архитектура (без изменений)

Цепочка обновлений остается прежней:

`About -> AppUpdateNotifier -> AppUpdateRepository -> UpgradeAlert`

Отдельный update-сервер не используется. Источник версии и файлов обновления: GitHub Releases + GitHub Appcast.

## 2) Канал обновлений `stable` / `beta`

Канал задается через `dart-define`:

- `--dart-define=update_channel=stable`
- `--dart-define=update_channel=beta`

Поведение по умолчанию: `stable`.

Чтение канала реализовано через `UpdateChannel.read()` (`String.fromEnvironment("update_channel")`).

## 3) Используемые URL

- `ZEON_RELEASES_API_URL=https://api.github.com/repos/actemendes/zeon-app/releases`
- `ZEON_LATEST_RELEASE_URL=https://github.com/actemendes/zeon-app/releases/latest`
- `ZEON_APPCAST_STABLE_URL=https://raw.githubusercontent.com/actemendes/zeon-app/main/appcast-stable.xml`
- `ZEON_APPCAST_BETA_URL=https://raw.githubusercontent.com/actemendes/zeon-app/main/appcast-beta.xml`

## 4) Ручная проверка из About (`checkForUpdate`)

`AppUpdateNotifier.check()` передает в `AppUpdateRepository.getLatestVersion()`:

- `stable` -> `includePreReleases=false`
- `beta` -> `includePreReleases=true`

State-machine не меняется.

### Выбор ссылки `Update now` (из одного Release -> Assets)

При разборе GitHub Release ссылка теперь выбирается так:

- Android: приоритет `*.apk`
- Windows: приоритет `*.exe`, fallback `*.msi`, затем `*.zip`
- macOS: приоритет `*.dmg`, fallback `*.pkg`, затем `*.zip`

Если подходящий asset не найден, используется fallback на `html_url` страницы релиза.

## 5) Авто-проверка (`UpgradeAlert`)

Источник обновлений по платформе:

- Android: только `UpgraderAppcastStore` (ветка Play Store убрана)
- iOS: `UpgraderAppStore` (fallback, iOS-канал фактически не используется)
- Linux/Windows/macOS/Web: `UpgraderAppcastStore`

URL appcast выбирается по `update_channel`:

- `stable` -> `appcast-stable.xml`
- `beta` -> `appcast-beta.xml`

## 6) Appcast файлы в корне репозитория

- `appcast-stable.xml`
- `appcast-beta.xml`

В каждом файле оставлены записи только для:

- `android`
- `windows`
- `macos`

iOS item отсутствует.

## 7) Нейминг ассетов (ожидаемый)

Сборочный и релизный процесс должен публиковать (в одном GitHub Release -> Assets):

- `Zeon-Android-universal.apk`
- `Zeon-Windows-Setup-x64.exe`
- `Zeon-MacOS.dmg`

Если фактические имена отличаются, парсер поддерживает поиск по regex/contains и расширениям файлов с указанными приоритетами.

## 8) Примеры запуска

- Stable:
  - `flutter run --dart-define=update_channel=stable`
  - `flutter build apk --dart-define=update_channel=stable`
- Beta:
  - `flutter run --dart-define=update_channel=beta`
  - `flutter build apk --dart-define=update_channel=beta`

## 9) Smoke-check после релиза

1. `stable`: prerelease не предлагается в ручной проверке.
2. `beta`: prerelease предлагается в ручной проверке.
3. `Update now`: ведет на прямой asset (`browser_download_url`) для текущей платформы; если asset не найден, открывается страница релиза (`html_url`).
