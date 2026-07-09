# Анализ `client_error_reports` за 2026-07-07 - 2026-07-09

Дата анализа: 2026-07-09.

Источник: таблица `public.client_error_reports`, 108 записей. Сырой экспорт с `device_id`, `login`, `user_id` и payload не сохранялся в репозиторий; ниже только агрегаты и обезличенные симптомы.

## Короткий вывод

Это не 108 независимых ошибок. Если группировать события одного устройства, пришедшие в пределах 2 секунд, получается 36 временных кластеров. 93 из 108 строк лежат в мульти-кластерах, где один сбой порождает несколько отчетов: core-log, wrapper `ConnectionFailure`, listener stream error и иногда startup/disconnect watchdog.

Главные повторяющиеся группы:

| Группа | Строк | Кластеров | Где видно | Вывод |
| --- | ---: | ---: | --- | --- |
| gRPC/HTTP2 stream forcefully terminated | 48 | ~12 | Android 44, iOS 4 | Чаще всего вторичный шум после остановки/перезапуска core, а не самостоятельная причина. |
| `smart-active-auto` неизвестен core | 28 | 7 | Android, `1.3.0-dev.1` build `10300` | Каскад из 4 отчетов на одну попытку запуска. Вероятен рассинхрон app config и core binary/artifact. |
| Android TUN `permission denied` | 12 | 4 | Android, 1 устройство | Core не может настроить TUN; каждый случай дополнительно рождает gRPC listener errors. |
| iOS local gRPC `Connection refused` | 7 | 7 | iOS, 1 устройство | Похоже на гонку готовности/жизненного цикла Network Extension или stale port. Fingerprint раздут портом. |
| Windows tray init timeout | 4 | 4 | Windows, 1 устройство | Исправлено: tray init переведен в background best-effort, операции tray логируют elapsed/operation. |
| Startup/disconnect watchdog | 6 | 5 | Android/iOS/Windows | Часть событий вторична к TUN/config/tray, часть требует отдельной корреляции. |
| Одиночные UI/config/system-info ошибки | 3 | 3 | mixed | Низкий приоритет, но есть понятные точки проверки. |

## Срез данных

Период `occurred_at`: `2026-07-07 20:50:00 UTC` - `2026-07-09 17:57:43 UTC`.

Платформы:

| Platform | Строк |
| --- | ---: |
| android | 89 |
| ios | 14 |
| windows | 5 |

Версии:

| Version/build | Строк |
| --- | ---: |
| `1.3.0-dev.1 / 10300` | 61 |
| `1.3.0 / 10300` | 33 |
| `<redacted> / <redacted>` | 10 |
| `1.3.0 / 100300` | 4 |

Triggers:

| Trigger | Строк |
| --- | ---: |
| `log_error` | 93 |
| `connection_failure` | 8 |
| `vpn_not_running_on_startup` | 3 |
| `vpn_unexpected_disconnect` | 3 |
| `platform_error` | 1 |

## Повторяющиеся закономерности

### 1. gRPC/HTTP2 stream forcefully terminated

Симптомы:

- `Stream error: gRPC Error ... HTTP/2 error: Connection is being forcefully terminated`
- `Stream error in bgLogListener: ...`
- `Stream error in bgStatusListener: ...`
- errorCode чаще `10`, иногда `1`

Агрегаты:

| Метрика | Значение |
| --- | --- |
| Строк | 48 |
| Fingerprints | `1388454157f4bb` 22, `c7a9e60256327` 11, `af7b9a5511b43` 11, plus minor variants |
| Платформы | Android 44, iOS 4 |
| Устройств | 3 |
| Core status | в основном `Stopped alert=createService` или `Stopping` |

Почти всегда это идет пачкой: два обычных stream error, один `bgLogListener`, один `bgStatusListener`. В TUN-кластерах эти четыре строки появляются сразу после `permission denied`. В `smart-active-auto` сценарии похожие пачки идут после неудачных попыток старта core.

Куда копать:

- `lib/zeoncore/zeon_core_service.dart:1457`, `:1462`, `:1491`, `:1495`, `:1541` - listener reconnect и логирование stream errors.
- Проверить, надо ли логировать закрытие stream как `error`, когда `_CoreLifecycleState` уже `stopping/stopped` или когда только что был `start/restart` failure.
- Добавить suppression/dedupe для ожидаемого закрытия bg listeners при lifecycle transition. Иначе таблица ошибок будет доминироваться вторичными симптомами.

### 3. Android TUN `permission denied`

Симптомы:

- `manager start inbound/tun[tun-in]: configure tun interface: permission denied`
- `failed to restart bg core: ... configure tun interface: permission denied`

Агрегаты:

| Метрика | Значение |
| --- | --- |
| Строк root-события | 12 |
| Кластеров | 4 |
| Платформа | Android only |
| Устройств | 1 |
| Версии | `1.3.0-dev.1 / 10300` - 3 строки, `1.3.0 / 10300` - 9 строк |
| Вторичный шум | в каждом кластере еще 4 gRPC stream/listener errors |

Точки в коде:

- `lib/features/connection/data/connection_repository.dart:133` - recovery loop для `isTunInterfacePermissionDenied`.
- `lib/features/connection/data/connection_repository.dart:145` - `singbox.stop(force: true)`.
- `lib/features/connection/data/connection_repository.dart:155` - повторный `singbox.start`.
- `lib/zeoncore/zeon_core_service.dart:911` - message с `denied` мапится в `CoreAlert.requestVPNPermission`.
- `android/app/src/main/kotlin/com/zeon/zeon/MainActivity.kt` и `android/app/src/main/kotlin/com/zeon/zeon/bg/VPNService.kt` - Android VPN permission / service path.

Куда копать:

- Проверить сценарий revoke VPN permission / Always-on VPN / другой активный VPN / быстрый reconnect.
- Убедиться, что перед start/restart вызывается `prepare_vpn` и корректно обрабатывается результат `VpnService.prepare`.
- Если `permission denied` уже классифицируется как `missingVpnPermission`, не отправлять параллельно несколько `log_error` одного и того же core failure.
- В recovery добавить cooldown и единый report на попытку, иначе один TUN failure превращается в 7-8 строк.

### 4. iOS gRPC `Connection refused` на локальный порт

Симптом:

- `gRPC Error (code: 14, codeName: UNAVAILABLE, message: Error connecting: SocketException: Connection refused ..., port = <dynamic>)`

Агрегаты:

| Метрика | Значение |
| --- | --- |
| Строк | 7 |
| Платформа | iOS only |
| Устройств | 1 |
| Core status в payload | `Started` |
| Service mode | `vpn` |
| Fingerprint | 7 разных fingerprints из-за разных портов |

Куда копать:

- `lib/zeoncore/core_interface/core_interface_mobile.dart:28` - `mobile_grpc_port_back/front`.
- `ios/Runner/Handlers/MethodHandler.swift` и `ios/Runner/VPN/VPNManager.swift` - передача/хранение `grpcServiceModePort`.
- Проверить гонку: Dart считает core `Started`, но gRPC listener/client уже или еще не слушает нужный порт.
- Проверить, не остается ли stale `grpcServiceModePort` в `VPNConfig.shared` после restart/prepare.
- Нормализовать fingerprint: удалять `address = ..., port = N` из gRPC transport messages. Сейчас один симптом распадается на 7 fingerprint.

### 5. Windows system tray timeout

Симптом:

- `[system tray] error initializing`

Агрегаты:

| Метрика | Значение |
| --- | --- |
| Строк | 4 |
| Платформа | Windows only |
| Устройств | 1 |
| Version/build | `1.3.0 / 10300` |
| Core status | `Stopped message=` |

Точки в коде:

- `lib/bootstrap.dart:272` - `_safeInit("system tray", ..., timeout: 1000)`.
- `lib/bootstrap.dart:413` - `_init` пишет `[$name] error initializing`.
- `lib/features/system_tray/notifier/system_tray_notifier.dart:116`, `:121`, `:128` - setIcon/setToolTip/setContextMenu.

Куда копать:

- 1000 ms для Windows tray выглядит слишком агрессивно, особенно на холодном старте.
- Либо увеличить timeout, либо перевести tray init в fully background best-effort без error-level report.
- В report добавить elapsed time и concrete operation (`setIcon`, `setToolTip`, `setContextMenu`), чтобы отличить timeout от tray_manager exception.

Что сделано:

- `lib/bootstrap.dart`: desktop tray init переведен в background best-effort через `_initSystemTrayInBackground`; bootstrap больше не ждет 1000 ms и не пишет `[system tray] error initializing` как error-level событие при медленном tray на Windows.
- `lib/features/system_tray/notifier/system_tray_notifier.dart`: операции `setIcon`, `setToolTip`, `setContextMenu` обернуты в `_tryTrayOperation`, warning теперь содержит concrete operation и elapsed time (`system tray <operation> failed after <N>ms`).
- При ошибке одного tray шага остальные шаги продолжают выполняться, а локальный кеш (`_lastIconPath`, `_lastTooltip`, `_lastMenuSignature`) обновляется только после успешной операции.

### 6. Startup/disconnect watchdog

Симптомы:

- `VPN was expected to be running but core is stopped on app startup`
- `VPN disconnected without an expected stop command`

Агрегаты:

| Группа | Строк | Платформы |
| --- | ---: | --- |
| `vpn_not_running_on_startup` | 3 | iOS 1, Android 1, Windows 1 |
| `vpn_unexpected_disconnect` | 3 | Android 2, iOS 1 |

Точки в коде:

- `lib/features/diagnostics/data/error_report_controller.dart:184` - startup watchdog.
- `lib/features/connection/notifier/connection_notifier.dart:107` - unexpected disconnect detection.
- `lib/features/diagnostics/data/error_report_controller.dart:140` - report context для unexpected disconnect.

Часть этих событий явно вторична: один Android unexpected disconnect находится в том же кластере, что TUN `permission denied`, а Windows startup-stopped идет рядом с tray init timeout. Их стоит анализировать вместе с lifecycle context, а не как отдельные root cause.

Куда копать:

- Добавить `lifecycle_transition_id` или `connection_attempt_id`, чтобы startup/disconnect watchdog можно было связать с предыдущим start/restart failure.
- Включить в context `last_expected_stop_reason`, `last_core_failure_fingerprint`, `started_by_user` already есть, но не хватает causal id.

### 7. Одиночные ошибки

| Симптом | Строк | Куда смотреть |
| --- | ---: | --- |
| `ConnectionFailure.invalidConfig(message: null)` | 1 | `ConnectionNotifier._connectThrottled`, `ConnectionRepository.applyConfigOption`, profile config repair. |
| `send System Info failed rpc error: code = Canceled` | 1 | iOS/core shutdown path; вероятно harmless при `Stopping`. |
| `setState() or markNeedsBuild() called during build` в `ConnectionButton` | 1 | `lib/features/home/widget/connection_button.dart:228` и `:240`; проверить animation controller updates/post-frame при смене enabled/visualState. |

## Улучшения диагностики

1. Нормализовать fingerprint до вычисления hash:
   - убрать `address = ..., port = N`;
   - схлопывать `bgLogListener/bgStatusListener/Stream error` в общий transport-close symptom;
   - убрать volatile gRPC wrapper, оставляя `code`, canonical message и первый app/core frame.

2. Добавить causal grouping:
   - `connection_attempt_id`;
   - `core_lifecycle_transition_id`;
   - `last_core_failure_fingerprint`;
   - `was_expected_shutdown` для listener closures.

3. Расширить `vpn.config_options`:
   - `balancer_strategy`;
   - `service_mode` уже есть отдельно, но полезно дублировать config snapshot;
   - `enable_tun`, `network_mtu_mode`, `profile_dns_strategy`;
   - `core_version`/`core_commit`/capabilities.

4. Rate-limit `log_error` для одинаковых listener transport failures внутри 1-2 секунд на одном устройстве.

5. Для отчетов core startup failure отправлять один агрегированный report на попытку старта, а не отдельные отчеты на core log, gRPC wrapper и connection failure.

## Приоритеты исправления

1. **P0: совместимость `smart-active-auto` и core artifacts.** Проверить конкретные APK/AAB/IPA/dev builds, добавить core capability/version в report, обеспечить fallback на `round-robin`.
2. **P1: убрать вторичный gRPC listener noise.** Это почти половина таблицы и сильно мешает видеть реальные root cause.
3. **P1: Android TUN permission denied.** Отдельно воспроизвести revoke permission/Always-on VPN/быстрый reconnect и улучшить recovery/report dedupe.
4. **P2: iOS gRPC connection refused.** Проверить lifecycle/port readiness Network Extension и нормализацию fingerprint.
5. **P3: Windows tray timeout и одиночные UI/config ошибки.** Низкий объем, но понятные небольшие улучшения.

## Отчет о выполненной работе: Android TUN `permission denied`

Дата выполнения: 2026-07-09.

Цель: закрыть P1-пункт по Android TUN `permission denied`, чтобы при revoke VPN permission / Always-on VPN / другом активном VPN / быстром reconnect приложение сначала проходило Android VPN permission flow, а один TUN failure не превращался в пачку `log_error`-отчетов.

Что сделано:

1. Добавлен нативный Android handler `prepare_vpn`:
   - `android/app/src/main/kotlin/com/zeon/zeon/MethodHandler.kt` теперь принимает `prepare_vpn`;
   - `android/app/src/main/kotlin/com/zeon/zeon/MainActivity.kt` вызывает `VpnService.prepare`, возвращает результат во Flutter и не стартует service при подготовительном вызове;
   - обычный `startService()` сохранил прежнюю семантику: после grant VPN permission сервис стартует.

2. Включен `prepareVpnConfiguration` перед core start/restart:
   - `lib/zeoncore/zeon_core_service.dart` больше не пропускает Android TUN mode;
   - `lib/features/connection/data/connection_repository.dart` вызывает prepare перед `connect`, перед первичным `reconnect` и перед recovery `start`;
   - отказ Android VPN permission мапится в `ConnectionFailure.missingVpnPermission`, а не в generic unexpected failure.

3. Уточнена классификация VPN permission denied:
   - `lib/features/connection/model/connection_failure.dart` добавляет общий `isVpnPermissionDenied`;
   - классификатор покрывает `manager start inbound/tun`, `missing vpn permission`, `application is not prepared` и `not prepared or is revoked`.

4. Снижен вторичный diagnostic noise:
   - `start` с VPN permission denied больше не пишет параллельный `loggy.error`, а сразу возвращает `missingVpnPermission`;
   - `restart` с TUN permission denied не отправляет финальный alert до recovery, а дает repository возможность выполнить stop/start recovery;
   - ожидаемые gRPC listener closures во время `starting/stopping/stopped` логируются как warning вместо error.

5. В recovery добавлен cooldown:
   - `ConnectionRepositoryImpl` получил `_tunRecoveryCooldown = 2s`;
   - recovery loop пишет один warning на попытку и выдерживает cooldown перед forced stop/start.

Ожидаемый эффект:

- Перед Android TUN start/restart вызывается `prepare_vpn`.
- Отказ или revoke VPN permission виден как `missingVpnPermission`.
- Один TUN failure больше не должен порождать отдельные error-level reports для core failure и ожидаемых listener stream closures.
- Recovery остается, но становится менее шумным и не запускает быстрые повторные stop/start без паузы.

Проверки:

- `dart analyze lib/features/connection/model/connection_failure.dart lib/features/connection/data/connection_repository.dart lib/zeoncore/zeon_core_service.dart` - без issues.
- `.\gradlew.bat :app:compileDebugKotlin --no-daemon` - успешно.
- `flutter analyze --no-fatal-infos --no-fatal-warnings` - успешно; в проекте остаются существующие non-fatal warnings/infos, не связанные с этой правкой.

## Отчет о выполненной работе: Windows system tray timeout

Дата выполнения: 2026-07-09.

Цель: убрать ложный error-level report `[system tray] error initializing` на Windows, где 1000 ms timeout в bootstrap был слишком агрессивен для cold start, и добавить диагностику конкретного tray operation.

Что сделано:

1. `lib/bootstrap.dart`:
   - desktop tray init больше не идет через `_safeInit("system tray", timeout: 1000)`;
   - добавлен `_initSystemTrayInBackground`, который запускает `systemTrayNotifierProvider.future` как background best-effort;
   - успешная инициализация логирует elapsed time, а ошибка уходит в warning (`background initialization failed after <N>ms`), не в error-level report.

2. `lib/features/system_tray/notifier/system_tray_notifier.dart`:
   - `setIcon`, `setToolTip`, `setContextMenu` обернуты в `_tryTrayOperation`;
   - warning теперь содержит concrete operation и elapsed time: `system tray <operation> failed after <N>ms`;
   - при сбое одного tray шага остальные шаги продолжают выполняться, а кеш последнего состояния обновляется только после успешной операции.

Ожидаемый эффект:

- Медленный Windows tray на cold start больше не блокирует bootstrap и не создает `[system tray] error initializing`.
- Если проблема окажется exception внутри `tray_manager`, в логах будет видно, на какой операции и через сколько миллисекунд это произошло.

Проверки:

- `dart format lib/bootstrap.dart lib/features/system_tray/notifier/system_tray_notifier.dart` - успешно, изменений форматтер не внес.
- `dart analyze lib/bootstrap.dart lib/features/system_tray/notifier/system_tray_notifier.dart` - без errors; остались существующие info по deprecated/redundant/directive ordering.
