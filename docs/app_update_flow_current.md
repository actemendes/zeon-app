# ZEON: текущая схема обновлений приложения

Дата актуализации: 2026-06-02

## 1) Архитектура по типу релиза

Для обычных сборок (`Release.general`) используется единый источник данных:

`App startup -> AppUpdateNotifier -> AppUpdateRepository -> GitHub Releases`

Ручная проверка использует тот же путь:

`Settings -> AppUpdateNotifier -> AppUpdateRepository -> GitHub Releases`

Для Android-сборки Google Play (`Release.googlePlay`) сохранен отдельный магазинный путь:

`App startup -> UpgradeAlert -> UpgraderPlayStore -> Google Play`

Отдельный update-сервер не используется.

## 2) Канал обновлений `stable` / `beta`

Канал задается через `dart-define`:

- `--dart-define=update_channel=stable`
- `--dart-define=update_channel=beta`

Поведение по умолчанию: `stable`.

Чтение канала реализовано через `UpdateChannel.read()` (`String.fromEnvironment("update_channel")`).

Для обычных сборок канал влияет на выбор релиза из GitHub Releases:

- `stable` -> `includePreReleases=false`
- `beta` -> `includePreReleases=true`

## 3) Используемые URL

- `ZEON_RELEASES_API_URL=https://api.github.com/repos/actemendes/zeon-app/releases`
- `ZEON_LATEST_RELEASE_URL=https://github.com/actemendes/zeon-app/releases/latest`

## 4) Автоматическая проверка обычной сборки

После первого отображения интерфейса `App` один раз за запуск процесса вызывает
`AppUpdateNotifier.checkAutomatically()`.

Поведение:

1. Выполняется невидимый запрос к GitHub Releases.
2. Если обновления нет или запрос завершился ошибкой, пользователь не получает уведомление.
3. Если новая версия найдена, проверяется preference:
   - `last_auto_notified_release_stable`
   - `last_auto_notified_release_beta`
4. Если `releaseTag` уже сохранен, повторное уведомление не показывается.
5. Если `releaseTag` новый, он сохраняется и пользователю показывается диалог обновления.

Нажатие `Позже` не приводит к повторному показу для той же версии. При появлении
следующего `releaseTag` пользователь получит одно новое уведомление.

Возврат приложения из фона не считается новым заходом и не запускает повторную проверку.

## 5) Ручная проверка из Settings

Кнопка `Проверить обновления` находится на первом экране настроек перед пунктом
`О программе`. В подзаголовке отображается текущая версия приложения.

Ручная проверка:

- всегда выполняет новый запрос к GitHub Releases;
- не блокируется маркером автоматического уведомления;
- показывает диалог обновления, если новая версия найдена;
- показывает toast, если установлена последняя версия или запрос завершился ошибкой.

В Google Play-сборке кнопка скрыта: обновления обрабатываются магазинным flow.

## 6) Выбор ссылки `Обновить сейчас`

При разборе одного GitHub Release ссылка выбирается из `Assets`:

- Android: приоритет `*.apk`
- Windows: приоритет `*.exe`, fallback `*.msi`, затем `*.zip`
- macOS: приоритет `*.dmg`, fallback `*.pkg`, затем `*.zip`

Если подходящий asset не найден, используется fallback на `html_url` страницы релиза.

## 7) Google Play

`UpgradeAlert` не удален. Он создается только для `Release.googlePlay`.

Для Android стандартный `UpgraderStoreController` использует `UpgraderPlayStore`.
Собственный GitHub checker для этого типа релиза отключен через
`allowCustomUpdateChecker=false`.

## 8) Appcast-файлы

Файлы остаются в корне репозитория как legacy-артефакты:

- `appcast-stable.xml`
- `appcast-beta.xml`

Текущая runtime-логика приложения их не запрашивает. Поддерживать appcast при обычном
релизе больше не требуется.

## 9) Нейминг ассетов обычного релиза

Сборочный и релизный процесс должен публиковать в одном GitHub Release:

- `Zeon-Android-universal.apk`
- `Zeon-Windows-Setup-x64.exe`
- `Zeon-MacOS.dmg`

Если фактические имена отличаются, парсер поддерживает поиск по regex/contains и
расширениям файлов с указанными приоритетами.

## 10) Примеры запуска

- Stable:
  - `flutter run --dart-define=update_channel=stable`
  - `flutter build apk --dart-define=update_channel=stable`
- Beta:
  - `flutter run --dart-define=update_channel=beta`
  - `flutter build apk --dart-define=update_channel=beta`
- Google Play:
  - `flutter build appbundle --dart-define=release=google-play`

## 11) Smoke-check после релиза

1. `stable`: prerelease не предлагается.
2. `beta`: prerelease предлагается.
3. При первом запуске с новым `releaseTag` появляется один диалог обновления.
4. При повторном запуске с тем же `releaseTag` диалог не появляется.
5. Кнопка в Settings вручную находит тот же релиз и открывает диалог повторно.
6. `Обновить сейчас` ведет на прямой asset текущей платформы; если asset не найден,
   открывается страница релиза.
7. В `google-play` сборке GitHub checker не запускается, используется Google Play.
