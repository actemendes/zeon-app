# Android deep links для `com.zeon.zeon`

Документ фиксирует текущее поведение Android-приложения ZEON с package id
`com.zeon.zeon`.

Важно различать:

1. URI, которые Android передает приложению по внешнему `VIEW` intent.
2. URI, для которых в приложении реализован законченный бизнес-сценарий.
3. Ссылки, которые можно вставить вручную или отсканировать в интерфейсе импорта,
   но которые не зарегистрированы как Android App Links.

## 1. Зарегистрированные URI-схемы

`MainActivity` принимает `VIEW` intent с категориями `DEFAULT` и `BROWSABLE` для
следующих схем:

| Схема | Android открывает приложение |
| --- | --- |
| `zeon://` | да |
| `zeon://` | да |
| `v2ray://` | да |
| `v2rayn://` | да |
| `v2rayng://` | да |
| `clash://` | да |
| `clashmeta://` | да |
| `sing-box://` | да |

В Android manifest нет ограничений по `host` и `path`. Поэтому на уровне ОС
приложению передается любой URI с одной из этих схем.

В manifest также нет регистрации `http://` или `https://`. Следовательно,
обычная ссылка `https://zeon-vps.link/open/<openId>` не открывает приложение как
Android App Link автоматически.

Источник: `android/app/src/main/AndroidManifest.xml`.

## 2. Рабочий deep link оплаты

Канонический callback после оплаты:

```text
zeon://payment-result?sid=<payment_session_id>
```

Пример:

```text
zeon://payment-result?sid=pay_123456
```

Обязательный параметр:

| Параметр | Описание |
| --- | --- |
| `sid` | непустой идентификатор payment session |

После получения ссылки приложение:

1. извлекает `sid`;
2. перенаправляет пользователя на `/profile-payment?sid=<sid>`;
3. запускает проверку статуса оплаты и обновление managed-профиля.

Для обратной совместимости принимается legacy-вариант:

```text
zeon://payment-result?sid=<payment_session_id>
```

Парсер также технически допускает `payment-result` первым сегментом пути,
например `zeon://callback/payment-result?sid=...`. Для новых интеграций нужно
использовать только канонический формат `zeon://payment-result?sid=...`.

Источники:

- `lib/features/mobile/data/mobile_payment_deep_link.dart`
- `lib/core/router/go_router/routing_config_notifier.dart`
- `lib/core/router/go_router/refresh_listenable.dart`

## 3. Legacy-схемы импорта профилей

В коде сохранен парсер wrapper-ссылок импорта. Он понимает:

| Схема | Рекомендуемый payload |
| --- | --- |
| `zeon://` | query-параметр `url` |
| `zeon://` | query-параметр `url` |
| `v2ray://` | query-параметр `url` |
| `v2rayn://` | query-параметр `url` |
| `v2rayng://` | query-параметр `url` |
| `clash://` | query-параметр `url` |
| `clashmeta://` | query-параметр `url` |
| `sing-box://` | query-параметр `url` |

Примеры корректных payload:

```text
zeon://import?url=https%3A%2F%2Fexample.com%2Fsubscription
zeon://import?url=https%3A%2F%2Fexample.com%2Fsubscription&name=Office
clash://install-config?url=https%3A%2F%2Fexample.com%2Fsubscription
sing-box://import-remote-profile?url=https%3A%2F%2Fexample.com%2Fsubscription
```

Для `zeon://` и `zeon://` есть дополнительный legacy-формат, в котором URL
лежит в path:

```text
zeon://import/https://example.com/subscription#Office
```

Для новых интеграций следует использовать query-параметр `url` с
percent-encoding: он однозначнее для URL с query-параметрами.

Ограничение текущей реализации: внешний deep link с wrapper-ссылкой Android
передаст приложению, но автоматический импорт профиля по нему сейчас не
подключен end-to-end. Для уже настроенного пользователя router откроет `/home`.
При незавершенном onboarding router откроет `/intro?url=...`, однако Intro
сейчас также не запускает импорт из этого параметра.
Парсер этих wrapper-ссылок реально используется при ручном добавлении профиля:
из буфера обмена или QR-кода.

Источники:

- `lib/utils/link_parsers.dart`
- `lib/features/profile/notifier/profile_notifier.dart`
- `lib/core/router/go_router/routing_config_notifier.dart`

## 4. Ссылки аккаунта ZEON

Публичная ссылка аккаунта:

```text
https://zeon-vps.link/open/<openId>
```

Пример:

```text
https://zeon-vps.link/open/649669380
```

Это не Android deep link: приложение не зарегистрировано как обработчик
`https://zeon-vps.link`. Ссылку можно вставить вручную в диалоге привязки
аккаунта. Во время импорта она нормализуется во внутренний primary URL.

Также ручной импорт умеет извлекать `<openId>` из `/open/<openId>` и принимать
сам идентификатор.

Источник: `lib/features/mobile/data/mobile_conn_link_import_service.dart`.

## 5. Проверка через ADB

Проверка канонического callback оплаты:

```powershell
adb shell am start -a android.intent.action.VIEW `
  -d "zeon://payment-result?sid=test-session" `
  com.zeon.zeon
```

Проверка того, что Android передает зарегистрированную legacy-схему приложению:

```powershell
adb shell am start -a android.intent.action.VIEW `
  -d "clash://install-config?url=https%3A%2F%2Fexample.com%2Fsubscription" `
  com.zeon.zeon
```

Вторая команда проверяет доставку URI в приложение, но не автоматический импорт
профиля.

## 6. Source of truth

При изменении deep links нужно синхронно обновлять:

- `android/app/src/main/AndroidManifest.xml`
- `android/app/build.gradle`
- `lib/utils/link_parsers.dart`
- `lib/features/mobile/data/mobile_payment_deep_link.dart`
- этот документ
