# Привязка данных из импорта к UI (Home + Profile)

Этот документ нужен, чтобы бэкенд и Codex могли без догадок прокинуть данные импортированного профиля в текущий дизайн.

Область: `HomePage`, `HomePremiumAccessButton`, `ProfileMenuPage`.

## 1. Сквозной поток данных

1. Импорт конфигурации/подписки парсится в `ProfileParser.parse(...)`.
2. Поля сохраняются в таблицу `ProfileEntries`.
3. `activeProfileProvider` отдает активный профиль (`ProfileEntity?`).
4. Виджеты Home/Profile читают `activeProfileProvider` и рендерят состояния.

Ключевые файлы:
- `lib/features/profile/data/profile_parser.dart`
- `lib/features/profile/data/profile_data_mapper.dart`
- `lib/core/db/db.dart`
- `lib/features/profile/notifier/active_profile_notifier.dart`
- `lib/features/home/widget/home_page.dart`
- `lib/features/home/widget/home_premium_access_button.dart`
- `lib/features/profile/overview/profile_menu_page.dart`

## 2. Контракт импорта: какие поля нужны

### 2.1 Имя профиля (`profile.name`)

Источник имени при импорте (по приоритету):
1. `UserOverride.name`
2. header `profile-title`
3. header `content-disposition` (filename)
4. fragment URL (`https://host/path#NAME`)
5. имя файла в URL
6. fallback: `Remote Profile` или protocol local-профиля

После выбора имя проходит `parseProfileName(...)`:
- отрезается префикс до `|` (пример: `ZEON | Ivan` -> `Ivan`)
- `|` заменяется на пробел
- `_` заменяется на пробел
- лишние пробелы схлопываются

Файл: `lib/features/profile/data/profile_name_parser.dart`.

### 2.2 Данные подписки (`subInfo`)

Парсятся из `subscription-userinfo`:
- `upload`
- `download`
- `total`
- `expire` (unix seconds)

Дополнительно:
- `profile-web-page-url` -> `subInfo.webPageUrl`
- `support-url` -> `subInfo.supportUrl`

Важно:
- если `total == 0` или отсутствует, подставляется "бесконечный" порог
- если `expire == 0` или отсутствует, подставляется "бесконечный" порог

Файл: `lib/features/profile/data/profile_parser.dart`.

### 2.3 Какие поля должны оказаться в БД

Таблица `ProfileEntries` (минимум для корректного UI):
- `active` (должен быть `true` у текущего профиля)
- `name`
- `upload`
- `download`
- `total`
- `expire`

Опционально:
- `webPageUrl`
- `supportUrl`

Файл: `lib/core/db/db.dart`.

## 3. Точки привязки в UI

## 3.1 Главный экран (Home)

### A) Шапка: `_HomeAppBarTitle` -> `subscriptionUpper`

Файл: `lib/features/home/widget/home_page.dart`

Привязка:
- `subscriptionName` берется из `activeProfileProvider`:
  - если есть активный профиль и `profile.name` не пустой -> `profile.name`
  - иначе -> `"anonymous"`
- в UI выводится `subscriptionName.toUpperCase()`.

Итого для бэкенда:
- чтобы в шапке было имя профиля, нужно заполнить `profile.name` у активного профиля.
- дополнительный парсинг в `HomePage` не делается.

### B) Счетчик/CTA premium: `HomePremiumAccessButton`

Файл: `lib/features/home/widget/home_premium_access_button.dart`

Берется:
- только `RemoteProfileEntity.subInfo` (для local-профиля `subInfo = null`)
- `rawRemainingDays = subInfo?.remaining.inDays` (или debug override)

Состояния:
1. `active` (виджет `_ActivePremiumState`), если `rawRemainingDays >= 1`
2. `inactive` (виджет `_InactivePremiumState`), если `rawRemainingDays == null` или `< 1`

Что показывается в `active`:
- фон: `count-days-{N}.png`, где `N = clamp(days, 0..10)`
- текст:
  - если `days > 10` -> локализованное "You are premium"
  - если `days <= 10` -> локализованная строка remaining duration

Что показывается в `inactive`:
- заголовок special servers (`t.pages.profileDetails.specialServers.headerLineOne`)
- подзаголовок "internet everywhere" (локализованный)

Переход по тапу в обоих состояниях: `profilePayment`.

## 3.2 Профиль (ProfileMenuPage)

Файл: `lib/features/profile/overview/profile_menu_page.dart`

### A) `ProfileSummaryBlock.profileName`

Привязка:
- `rawProfileName = profile?.name?.trim() ?? ''`
- если пусто -> `t.common.unknown`
- иначе -> `rawProfileName`

### B) `ProfileSummaryBlock.daysLabel`

Привязка:
- `normalizedDays = max(subInfo.remaining.inDays, 0)`; если `subInfo == null` -> `0`
- `effectiveDays` = `normalizedDays` (или debug override)

Текст:
- если `effectiveDays == 0` -> `t.components.subscriptionInfo.premiumInactive`
- иначе -> `"{remainingUsage} {day(n: effectiveDays)}"`

### C) Пункт меню "Привязать аккаунт"

Привязка:
- пункт `bindAccount` показывается только если `remainingDays > 0`
- иначе пункт не добавляется в список секций

### D) Нижняя CTA-панель

Привязка:
- если `remainingDays > 0` -> `t.pages.profileDetails.cta.renew`
- иначе -> `t.pages.profileDetails.cta.updatePlan`
- тап -> `profilePayment`

### E) Аватар-эмодзи (детерминированный)

Привязка к имени:
- seed берется из `profile.name` (или debug seed)
- при нормализации seed тоже отбрасывается префикс до `|`
- дальше FNV-1a hash -> индекс эмодзи

Это только визуальный аватар, на бизнес-логику подписки не влияет.

## 4. Матрица состояний (что увидит пользователь)

1. Нет активного профиля:
- Home title: `ANONYMOUS`
- Home premium CTA: inactive/special servers
- Profile summary: `UNKNOWN`, `premiumInactive`

2. Есть активный remote профиль, но `subInfo` отсутствует:
- Home premium CTA: inactive/special servers
- Profile: `daysLabel = premiumInactive`
- `bindAccount` скрыт

3. Есть `subInfo`, но `expire` в прошлом или осталось < 1 суток:
- Home premium CTA: inactive/special servers (`remaining.inDays < 1`)
- Profile: `daysLabel = premiumInactive` (дни клампятся до 0)
- `bindAccount` скрыт

4. Есть `subInfo` и `remaining.inDays >= 1`:
- Home premium CTA: active
- Profile: `daysLabel` с количеством дней
- `bindAccount` показан
- CTA внизу: `renew`

## 5. Важные нюансы для бэкенда

1. Имя лучше отдавать уже в формате без префикса (`ZEON |`), но если импорт идет через `ProfileParser`, это уже будет очищено `parseProfileName(...)`.
2. Для корректной отрисовки дней достаточно валидного `expire` (UTC timestamp в секундах при парсинге header).
3. `remaining.inDays` округляется вниз. Если осталось 23:59, UI уже считает как `0` дней.
4. `HomePremiumAccessButton` смотрит только на `remainingDays >= 1` и не проверяет `ratio`/`isExpired` напрямую.
5. В `_ProfileSummaryBlock` переменная `isPremiumActive` вычисляется, но сейчас не влияет на UI (правый crown-сегмент закомментирован).
6. Если активный профиль local-типа, `subInfo` там нет -> UI ведет себя как inactive.

## 6. Минимальный чеклист интеграции

1. После импорта в БД есть 1 активный профиль (`active = true`).
2. У активного профиля заполнен `name` (не пустой).
3. Для remote-профиля заполнены `upload/download/total/expire`.
4. `expire` корректно парсится из `subscription-userinfo` как unix seconds.
5. В debug-сборках выключены seed-переопределения, если проверяется реальная интеграция.

Debug-флаги, которые могут маскировать реальные данные:
- `debug_seed_profile_enabled`
- `debug_seed_profile_name`
- `debug_seed_profile_remaining_days`

## 7. Пример данных (если писать напрямую, минуя parser)

```json
{
  "type": "remote",
  "active": true,
  "name": "Ivan",
  "subInfo": {
    "upload": 123456,
    "download": 654321,
    "total": 107374182400,
    "expire": "2026-12-31T00:00:00Z",
    "webPageUrl": "https://example.com/account",
    "supportUrl": "https://t.me/example_support"
  }
}
```

Или в виде subscription header:

```text
subscription-userinfo: upload=123456; download=654321; total=107374182400; expire=1798675200
```
