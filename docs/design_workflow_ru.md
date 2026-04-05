# Дизайн-воркфлоу для Flutter (ZEON)

Этот файл для режима работы: `редактирую UI -> сразу вижу изменение`.

## 1) Что важно про этот проект

- UI в основном общий для всех платформ (Flutter/Material 3).
- Отличия между платформами делаются точечно через `PlatformUtils` и брейкпоинты.
- Основной фокус дизайнера: экраны в `lib/features/**` + тема в `lib/core/theme/**`.

## 2) Быстрый запуск для дизайна (Windows)

### Разовая подготовка

1. Установить Flutter-менеджер:
   - `winget install --id pingbird.Puro --accept-source-agreements --accept-package-agreements --silent`
2. Создать окружение Flutter под версию проекта:
   - `puro create zeon 3.38.5`
3. Привязать проект к окружению:
   - `puro use zeon`
4. Скачать зависимости:
   - `puro flutter pub get`
5. Сгенерировать код:
   - `puro flutter pub run build_runner build --delete-conflicting-outputs`
   - `puro flutter pub run slang`
6. Подготовить desktop-библиотеки ядра:
   - `mkdir hiddify-core\bin`
   - `curl -L https://github.com/hiddify/hiddify-core/releases/download/v4.1.0/hiddify-lib-windows-amd64.tar.gz -o hiddify-core\bin\hiddify-lib-windows-amd64.tar.gz`
   - `tar -xzf hiddify-core\bin\hiddify-lib-windows-amd64.tar.gz -C hiddify-core\bin`

### Важно: путь проекта без спецсимволов

Flutter на Windows может падать, если путь содержит символы вроде `!`.

Если проект лежит в `D:\YandexDisk\! CODING\zeon-app`, используйте junction:

- `mklink /J D:\zeon-app "D:\YandexDisk\! CODING\zeon-app"`

И работайте из `D:\zeon-app`.

### Важно: Developer Mode

Для Windows-сборки с плагинами нужен Developer Mode (symlink support):

- `start ms-settings:developers`

Включите **Developer Mode**, затем:

- `puro flutter run -d windows --target lib/main.dart`

## 3) Цикл работы дизайнера

1. Запустить приложение (`flutter run`).
2. Открыть нужный файл UI.
3. Сохранить файл.
4. Смотреть hot reload результат сразу в окне приложения.

Горячие команды в консоли Flutter:

- `r` -> hot reload (быстро).
- `R` -> hot restart (если изменения не подхватились).

## 4) Где что лежит (карта UI)

## Точка входа и навигация

- Запуск: `lib/main.dart`
- Bootstrap: `lib/bootstrap.dart`
- Корневой виджет приложения: `lib/features/app/widget/app.dart`
- Роутер: `lib/core/router/go_router/go_router_notifier.dart`
- Конфиг роутов: `lib/core/router/go_router/routing_config_notifier.dart`
- Адаптивная оболочка (mobile/desktop): `lib/core/router/adaptive_layout/my_adaptive_layout.dart`
- Брейкпоинты: `lib/core/router/go_router/helper/active_breakpoint_notifier.dart`

## Тема и дизайн-токены

- Главная тема: `lib/core/theme/app_theme.dart`
- Режимы темы (system/light/dark/black): `lib/core/theme/app_theme_mode.dart`
- Кастомные theme extensions: `lib/core/theme/theme_extensions.dart`
- Константы размеров (диалоги, bottom sheet и т.д.): `lib/core/model/constants.dart`

## Экраны и кнопки (быстрый ориентир)

- Главный экран: `lib/features/home/widget/home_page.dart`
- Главная кнопка подключения: `lib/features/home/widget/connection_button.dart`
- Карточка профиля и меню действий: `lib/features/profile/widget/profile_tile.dart`
- Страница настроек (разделы): `lib/features/settings/overview/settings_page.dart`
- Плитки общих настроек: `lib/features/common/general_pref_tiles.dart`
- Базовые preference-контролы: `lib/features/settings/widget/preference_tile.dart`
- Список прокси: `lib/features/proxy/overview/proxies_overview_page.dart`

## 5) Как понять, что к чему подключено

Практическое правило:

1. Ищите `onTap`, `onPressed`, `onChanged`.
2. Смотрите, что вызывается:
   - `context.goNamed(...)` -> переход на роут.
   - `ref.read(...).show...()` -> модалка/диалог.
   - `ref.read(...notifier).update/toggle/...` -> изменение состояния.
3. Идите в целевой notifier/provider и смотрите логику.

Пример:

- В `home_page.dart` кнопка `+` вызывает `showAddProfile()`.
- Реализация модалки: `lib/core/router/bottom_sheets/bottom_sheets_notifier.dart`.

## 6) Что чаще всего менять дизайнеру

- Цвета/тема: `lib/core/theme/app_theme.dart`, `theme_extensions.dart`
- Радиусы/отступы/ограничения: `lib/core/model/constants.dart`
- Конкретный компонент-кнопка: файл соответствующего экрана (`features/.../widget/...`)
- Поведение mobile vs desktop: `my_adaptive_layout.dart` + проверки `Breakpoint(...)`
- Платформенные исключения: проверки `PlatformUtils.isAndroid/isIOS/isDesktop`

