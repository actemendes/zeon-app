# Технический аудит VPN и sing-box в ZEON

Дата аудита: 2026-07-28  
Ревизия ZEON: `51d6c5156431f46fc56a4b79f5571a1771ca6caf`  
Режим аудита: только чтение; код, зависимости, submodule, конфигурации и сборочные скрипты не изменялись; production APK не пересобирался.

## 1. Executive summary

Текущий `libbox` в ZEON — не «просто sing-box 1.13.0». Это локально собранный `hiddify-core`, который через `replace` использует встроенное дерево `hiddify-sing-box`. Логическая версия модуля — `v1.13.0`, фактический commit форка — `0a02b7729f6a211436bb8bdcd8696c283eb27767`, а встроенная в Android AAR библиотека собрана из изменённой рабочей копии ZEON (`vcs.revision=51d6c515…`, `vcs.modified=true`). AAR в `android/app/libs` совпадает с AAR в `hiddify-core/bin`, но текущая система не обеспечивает криптографическую проверку этого соответствия при каждой сборке APK.

Главный доказанный источник обрывов при выборе другого сервера находится не в Android и не в версии upstream: ZEON/Hiddify создаёт URLTest, balancer и selector с `InterruptExistConnections: true`. При смене выбранного outbound код вызывает `interruptGroup.Interrupt(true)`, после чего закрываются зарегистрированные TCP- и UDP-соединения. Это непосредственно соответствует обрывам Telegram, Speedtest, видео и QUIC во время manual reselect, Smart Active и emergency switch.

Вторая доказанная группа дефектов — несогласованность lifecycle:

- Android публикует `Status.Started` до успешного `Mobile.start()`;
- Flutter после restart переводит собственное состояние в `started` без DNS/HTTPS data-plane проверки;
- аварийный и обычный teardown не имеют одного идемпотентного владельца всех ресурсов;
- `ParcelFileDescriptor` может быть перезаписан новым TUN без явного закрытия старого;
- `stopAndAlert()` и `onDestroy()` не гарантируют полного закрытия core/TUN;
- предоставленные логи уже фиксируют `gRPC UNAVAILABLE / connection refused` одновременно с сообщением `core is already started!`.

Третья группа — physical-network recovery. При смене default interface sing-box вызывает `conntrack.Close()`, а ZEON собирает ядро с `with_conntrack`; поэтому существующие соединения закономерно закрываются при реальном handover. В Android-слое нет эквивалента ZapretKVN для `NET_CAPABILITY_NOT_VPN`, `setUnderlyingNetworks()`, ожидания validation/readiness, debounce и ограниченного retry. Это объясняет часть обрывов Wi‑Fi/mobile и состояния «VPN подключён, трафика нет», но частоту и вклад каждого механизма нужно подтвердить A/B device-тестами.

Обновление ядра само по себе не исправит жёстко заданный `InterruptExistConnections`, преждевременное `Started` и неполный teardown. Рекомендуемый основной путь: сохранить `hiddify-core`, создать контролируемый ZEON-форк `hiddify-sing-box` на официальной стабильной базе SagerNet `v1.13.14` (`25a600db24f7680ad9806ce5427bd0ab8afe1114`), вручную перенести Hiddify- и ZEON-патчи, затем отдельно внедрять lifecycle/recovery. Резервный путь — оставить текущую базу и точечно backport-ить доказанно релевантные исправления 1.13.x.

## 2. Фактическая версия и происхождение ядра ZEON

### 2.1. Цепочка происхождения

| Слой | Фактическая база | Commit/версия | Доказательство |
|---|---|---|---|
| ZEON Flutter/Android | форк Hiddify App | ZEON `51d6c5156431f46fc56a4b79f5571a1771ca6caf`; исходная база Hiddify App `4.1.2`, `54bc7eebe871c6b266d6b17dd21261fe96f040a6` | Git history и сравнение с временным clone upstream |
| `hiddify-core` | Hiddify Core `v4.1.0` | `c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0` | содержимое локального дерева совпадает с upstream commit; локальное сообщение «4.1.1» не является доказательством версии |
| `hiddify-sing-box` | Hiddify fork | `0a02b7729f6a211436bb8bdcd8696c283eb27767`; `git describe`: `v1.13.0.h5-21-g0a02b772` | `hiddify-core/hiddify-sing-box`, Git metadata |
| SagerNet API/base line | sing-box 1.13 API | `github.com/sagernet/sing-box v1.13.0` | `hiddify-core/go.mod:261,278` |
| Чистая upstream-основа | не совпадает с одним чистым tag 1.13.0 | merge-base с официальной `v1.13.14`: `aba8346bd6c533ffb144258118e1100ff31e2cb5` | сравнение истории Hiddify fork с SagerNet |
| Официальный stable на дату аудита | SagerNet sing-box `v1.13.14` | `25a600db24f7680ad9806ce5427bd0ab8afe1114`, release 2026-06-25 | официальный репозиторий и release/tag |

Вывод: отображение `1.13.0` описывает API-линию `go.mod`, но не полностью происхождение кода. Форк содержит Hiddify и ZEON изменения, локальные replacement-деревья WireGuard/Tailscale/Psiphon и изменения после Hiddify tag.

### 2.2. `go.mod` и `replace`

Основной модуль:

- `hiddify-core/go.mod:261` — `github.com/sagernet/sing-box v1.13.0`;
- `hiddify-core/go.mod:270` — `warp-plus` заменён на Hiddify fork;
- `hiddify-core/go.mod:272-274` — `sing-dns` и `dnscrypt` заменены на extended forks `github.com/shtorm-7/...`;
- `hiddify-core/go.mod:276` — `ray2sing => ./ray2sing`;
- `hiddify-core/go.mod:278` — `sing-box => ./hiddify-sing-box`;
- `hiddify-core/go.mod:280-286` — WireGuard, Tailscale, Psiphon QUIC и Psiphon TLS направлены в локальные replacement-деревья.

Внутри `hiddify-sing-box`:

- `hiddify-core/hiddify-sing-box/go.mod:246-248` — extended `sing-dns` и `dnscrypt`;
- `hiddify-core/hiddify-sing-box/go.mod:251-257` — локальные WireGuard, Tailscale, Psiphon QUIC и Psiphon TLS.

Следствие: обновлять только номер `github.com/sagernet/sing-box` нельзя. Фактически собирается локальная директория, а совместимость зависит от всего replacement-графа.

### 2.3. Сборочные параметры

| Параметр | Значение | Доказательство |
|---|---|---|
| Go для фактического `.so` | `go1.25.6` | Go build info внутри `libhiddify-core.so` |
| Go directive core | `1.25.6` | `hiddify-core/go.mod:3` |
| Go directive sing-box | `1.24.7` | `hiddify-core/hiddify-sing-box/go.mod:3` |
| gomobile | `v0.1.11` | `hiddify-core/Makefile:41-42`, оба `go.mod` |
| Android API gomobile | `21` | `hiddify-core/Makefile:49` |
| NDK | `28.2.13676358` | `android/app/build.gradle:98` |
| compile/target SDK | `36/36` | `android/app/build.gradle:97,117` |
| AGP/Kotlin/Gradle/JDK | AGP `8.6`, Kotlin `2.1`, Gradle `8.7`, Java `17` | Android Gradle settings/wrapper и compile options |
| Build tags | `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack` | `hiddify-core/Makefile:15,49` и build info `.so` |

Не закреплены как воспроизводимые входы: дистрибутив JDK, версия Android Build Tools, checksum Go toolchain/gomobile и контейнер/образ сборки.

### 2.4. Фактически подключаемый AAR/SO

- Gradle подключает `android/app/libs/*.aar`: `android/app/build.gradle:190`.
- Фактический файл: `android/app/libs/hiddify-core.aar`.
- SHA-256: `7A94C004286875410D70D8CECF07D8813DAB33D27F7D76A23C7ABA3460E37600`.
- Размер: `103208049` байт.
- Он байт-в-байт совпадает с `hiddify-core/bin/hiddify-core.aar`.
- В AAR находятся ABI-specific `libhiddify-core.so`; build info указывает на `github.com/sagernet/sing-box v1.13.0 => ./hiddify-sing-box`, Go `1.25.6`, ZEON revision `51d6c515…`, `vcs.modified=true`.

В репозитории есть backup/cache артефакты, но `*.aar.bak_*` не совпадают с маской Gradle `*.aar`. Maven dependency на Hiddify AAR не обнаружена. Это снижает риск выбора `.bak`, но не исключает использование старого Gradle cache или старого APK на устройстве. Проверки SHA внутри APK сейчас нет.

### 2.5. Submodule

`git submodule status` не показывает активных submodule. Деревья `hiddify-core` и `hiddify-sing-box` фактически vendor/flattened, хотя в них остались stale `.git` pointer-файлы. Поэтому:

- commit происхождения нельзя надёжно восстановить через superproject gitlink;
- обычный `git submodule update` здесь не является корректным механизмом обновления;
- baseline следует фиксировать отдельным manifest с commit и tree hash.

## 3. Текущий lifecycle ZEON

```text
Flutter UI / ZeonCoreService
    │ start/restart/stop через platform/gRPC bridge
    ▼
Android BoxService / VPNService
    │ создаёт platform wrapper и service
    │ публикует Status.Started до завершения Mobile.start()
    ▼
Mobile.start() → hiddify-core
    │ создаёт sing-box/libbox service
    ▼
PlatformInterface.openTun()
    │ VPNService.Builder.establish()
    │ Kotlin хранит ParcelFileDescriptor
    │ fd передаётся в Go; Go делает dup(fd)
    ▼
TUN + route/DNS/outbounds

Отдельные контуры:
Flutter status listener ↔ local gRPC
Android connectivity callback → libbox default-interface update
Smart Active / manual selection → selector/balancer → interrupt group
```

Ключевые доказательства:

- `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt:230-234`: `Status.Started` публикуется перед `Mobile.start()`.
- `android/app/src/main/kotlin/com/zeon/zeon/bg/VPNService.kt:74-212`: создание TUN и сохранение PFD.
- `android/app/src/main/kotlin/com/zeon/zeon/bg/VPNService.kt:89`: прежнее закрытие PFD закомментировано.
- `hiddify-core/hiddify-sing-box/experimental/libbox/service.go:69-82`: Go дублирует переданный fd; исходный PFD остаётся отдельным ресурсом Android.
- `lib/zeoncore/zeon_core_service.dart:1092-1150`: restart сериализуется на Flutter-стороне, но после возврата вызова публикуется `started` без data-plane health gate.
- `android/app/src/main/kotlin/com/zeon/zeon/bg/ServiceConnection.kt:78-80`: disconnect не формирует полноценную терминальную смену состояния и не устраняет риск stale binder.

Текущая модель не доказывает единственного владельца всей сессии. Core, TUN PFD, Android service, platform adapter, gRPC listener и Flutter lifecycle управляются разными объектами, а общий объект `ActiveSession` отсутствует.

## 4. Lifecycle ZapretKVN

Проверенная ревизия ZapretKVN: `20794bfd2e4223c0d11dba73cab2a0f0fb354e07`. Проект клонировался только во внешнюю временную директорию и не добавлялся в ZEON.

```text
UI
  ▼
VpnController
  │ выдаёт монотонный generation
  ▼
ZapretVpnService (Mutex сериализует start/stop/recovery)
  │ строит и валидирует runtime config
  │ создаёт pending ActiveSession
  ├─ CommandServer
  ├─ CommandClient(ы)
  ├─ AndroidPlatformAdapter
  ├─ TUN ParcelFileDescriptor
  ├─ core service
  └─ network monitor / jobs
       │
       ├─ DNS health-check
       └─ HTTPS/data-plane health-check
  ▼
только после health-check:
pending session → active session → Connected(generation)

Любая ошибка:
close pending session в обратном порядке;
stale callback с другой generation игнорируется.
```

Доказательства по commit `20794bfd…`:

- `app/src/main/.../vpn/ZapretVpnService.kt` — service-level `Mutex`, pending/active session, единый start/stop/recovery.
- `app/src/main/.../vpn/VpnController.kt:167-193,226-230,453-579` — generation gate для state, selection, traffic и diagnostic callbacks.
- `app/src/main/.../vpn/AndroidPlatformAdapter.kt` — единственный `openTun`, проверка `protect(fd)`, закрытие PFD, `setUnderlyingNetworks()`.
- `network-bootstrap/src/main/.../UnderlyingNetworkMonitor.kt:249,274` — обязательный `NET_CAPABILITY_NOT_VPN`.
- `app/src/main/.../config/RuntimeConfigBuilder.kt:398-399,629-652` — выделенный health route.
- `app/src/androidTest/.../VpnServiceInstrumentedTest.kt:759-782` — health failure не публикует Connected и закрывает TUN.

Архитектура ZapretKVN ценна как эталон владения ресурсами и recovery, но её routing/DNS политика и `sing-box-extended` не являются drop-in заменой Hiddify.

## 5. Сравнение ZEON и ZapretKVN

| Область | Текущая реализация ZEON | ZapretKVN | Отличие и связь с обрывами | Переносимость | Риск |
|---|---|---|---|---|---|
| Владелец lifecycle | Flutter + BoxService + VPNService + core | один service/session owner | ZEON допускает рассогласование состояний | идея переносима | средний |
| Android process | app/service в архитектуре Hiddify | явно контролируемая service model | смерть UI в ZEON хуже отделена от VPN state | адаптация | средний |
| VPN service | `VPNService` делегирует `BoxService` | `ZapretVpnService` владеет сессией | размытое владение ZEON | идея | средний |
| TUN | PFD — поле VPNService, Go dup(fd) | PFD — ресурс ActiveSession | в ZEON возможен stale/leaked PFD | почти напрямую | низкий–средний |
| Core instance | нет единого session token | active/pending строго по generation | stale callbacks/restart race | идея | высокий |
| CommandServer | Hiddify lifecycle | ресурс сессии | закрытие не доказано на всех ветках | адаптация | средний |
| CommandClient | Flutter/gRPC listeners | clients закрываются с session | в ZEON подтверждён connection refused/stale state | адаптация | средний |
| Start | `Started` до `Mobile.start()` | Connected после startup и health | ложный Connected/Started | напрямую исправимо | низкий |
| Reload/restart | Flutter queue, возможен full restart | сериализован Mutex | конкурирующие источники решений остаются | идея | высокий |
| Stop | несколько разнесённых путей | один idempotent close | partial teardown в ZEON | идея | средний |
| `openTun` | повторный вызов явно не запрещён | double-open блокируется | риск двух TUN/PFD | напрямую | средний |
| PFD close | не гарантирован на всех путях | session close | доказанный дефект владения | напрямую | низкий |
| `protect(fd)` | результат `false` игнорируется | `false` — ошибка | невозможна точная диагностика loop/protect | напрямую | низкий |
| Default interface | activeNetwork callback | NOT_VPN + readiness | ZEON может выбрать VPN network/сырой network | адаптация | средний |
| `setUnderlyingNetworks` | не вызывается | вызывается | OS не получает явную основу VPN | напрямую после API-check | средний |
| Network recovery | reset/restart без bounded policy | debounce, settled network, retry budget | flapping и преждевременный restart | идея | средний–высокий |
| Generation | нет сквозного token Android→Go→Flutter | есть во всех callbacks | старые результаты могут менять новую сессию | идея | высокий |
| Startup deadline | нет единого дедлайна | ограничен | возможен вечный Connecting | идея | низкий–средний |
| Startup health | статус процесса | DNS + HTTPS data plane | VPN может быть «подключён» без трафика | адаптация | средний |
| Config validation | Hiddify builder/парсинг | explicit pre-TUN validation | ZEON может открыть TUN до поздней ошибки | адаптация | средний |
| DNS fallback | Hiddify policy | собственная Android policy | прямое копирование несовместимо | только идея | высокий |
| DNS cache reset | не привязан строго к handover | часть recovery | stale DNS требует device proof | идея | средний |
| IPv6 | зависит от config/TUN | явно тестируется | недостаточное покрытие ZEON | тесты | низкий |
| MTU | dynamic, но interface MTU имеет приоритет | контролируемый runtime overlay | cellular может фактически получить 1500 | адаптация | средний |
| Selector switch | interrupt existing = true | иной selector policy | ZEON гарантированно рвёт sessions | изменить в ZEON, не копировать fork | средний |
| TCP/UDP preservation | закрытие через interrupt group/conntrack | тестируемая policy | непосредственная связь с симптомами | собственное решение | средний |
| Diagnostics | разрозненные Flutter/Android/Go logs | generation-scoped timeline | трудно восстановить cause/effect | идея | низкий |
| Crash reporting | Sentry/логи, но нет полного exit bundle | structured export | app/native/process death не различены | идея | средний |
| Stress tests | отдельные Go/Flutter тесты, слабый Android lifecycle stress | 42 unit + 21 androidTest файлов | гонки ZEON не защищены регрессией | тесты переносимы как сценарии | низкий |

### 5.1. Что можно взять почти без изменений

- проверку `protect(fd) == false`;
- запрет повторного `openTun()` в одной session;
- явное владение и идемпотентное закрытие PFD;
- `NET_CAPABILITY_NOT_VPN` в network request/filter;
- generation check перед публикацией callback;
- правило «Connected только после startup health»;
- sanitization diagnostic events;
- lifecycle stress-сценарии.

### 5.2. Что полезно только как идея

- единый `ActiveSession` — нужно обернуть Hiddify `Mobile.start/stop`, gRPC и Flutter bridge;
- DNS/HTTPS health route — нужно строить через Hiddify config builder и не нарушать ZEON routing;
- bounded recovery из commit `938405d…` — нужен ZEON failure classifier, учитывающий Smart Active;
- `setUnderlyingNetworks()` — нужно проверить Android API, multipath и текущую модель исключения UID;
- config validation до TUN — адаптировать под Hiddify JSON options и generated config.

### 5.3. Что нельзя переносить автоматически

- полный runtime config builder ZapretKVN;
- его DNS policy/fallback;
- `sing-box-extended` и patchset целиком;
- WireGuard-specific split-data-plane решения без подтверждения, что проблема ZEON относится к WireGuard;
- переписывание Flutter/Hiddify lifecycle на архитектуру ZapretKVN одним изменением.

## 6. Наиболее вероятные причины обрывов

| Причина | Уверенность | Техническое объяснение | Доказательство |
|---|---|---|---|
| Selector/URLTest закрывает активные TCP/UDP при switch | высокая, доказано | `InterruptExistConnections=true` → `Interrupt(true)` → close tracked TCP/UDP | `hiddify-core/v2/config/builder.go:348-417`; `hiddify-core/hiddify-sing-box/outbound/balancer.go:219-227`; `common/interrupt/group.go:47-59` |
| Ложное состояние Started/Connected | высокая, доказано | Android публикует Started до успешного core start; Flutter не ждёт data plane | `BoxService.kt:230-249`; `zeon_core_service.dart:1092-1150`; log `tmp_vpn_start_logcat_pid_only.txt:224-283` |
| Неполный teardown и stale TUN/core | высокая для дефекта, средняя для частоты | PFD/core/monitor не закрываются одним путём; повторный TUN перезаписывает поле | `BoxService.kt:352-365,401-405`; `VPNService.kt:39-42,74-92,210-212` |
| Смена physical network закрывает conntrack | высокая для поведения, средняя для пользовательской частоты | `ResetNetwork()` вызывает `conntrack.Close()` при `with_conntrack` | `hiddify-sing-box/route/network.go`, `hiddify-core/Makefile:15` |
| Нет bounded readiness recovery | средне-высокая | restart возможен до validation/settle, одинаковые callbacks не дебаунсятся | Android network monitor/platform code; отсутствие аналога commit `938405d…` |
| Dynamic MTU фактически переопределён physical MTU | средняя гипотеза | 1380/1460 выбирается, затем `NetworkInterfaceMTU` заменяет результат | `hiddify-core/v2/config/builder.go:543-593` |
| DNS transport/cache остаётся stale после handover | средняя гипотеза | нет end-to-end DNS health gate и generation-scoped reset | config/lifecycle анализ; требуется device evidence |
| `protect()`/routing loop | низко-средняя | `false` игнорируется, но обычный protect выключен при Android AutoDetectInterface=false; app UID исключён из TUN | `VPNService.kt:50-53`; `builder.go:1335`; `platform_interface.go:27-38` |
| Native crash/OOM/ANR/Go panic | не установлено | предоставленных app tombstone/exit records недостаточно | имеющийся `hs_err_pid3773.log` относится к Gradle/JDK build process |
| Серверная деградация | возможно, не доказано | может инициировать Smart switch, но не объясняет lifecycle defects | нужны коррелированные server/client metrics |

## 7. Отдельно доказанные ошибки

### 7.1. Принудительное закрытие соединений при выборе outbound

`hiddify-core/v2/config/builder.go:358,379,416` задаёт `InterruptExistConnections: true`. В `hiddify-core/hiddify-sing-box/outbound/balancer.go:219-227` смена выбранного outbound приводит к `interruptGroup.Interrupt(true)`. В `hiddify-core/hiddify-sing-box/common/interrupt/group.go:47-59` это закрывает зарегистрированные TCP и UDP.

Это не корреляция и не предположение: текущая реализация намеренно прерывает существующие потоки. Для Speedtest это может оборвать control/data sockets до получения финального результата; для QUIC — уничтожить UDP flow; для Telegram/видео — сбросить долгоживущие соединения.

### 7.2. Started публикуется до успешного старта

В `BoxService.kt:230` выполняется `status.postValue(Status.Started)`, а только в `BoxService.kt:233` вызывается `Mobile.start()`. Исключение ловится позднее (`:249`). Между этими событиями UI и другие клиенты могут наблюдать ложное состояние.

### 7.3. Неполное аварийное закрытие

- `BoxService.stopAndAlert():352-365` публикует alert/stop state, но не доказывает закрытие PFD, core, monitor и service во всех ветках.
- `BoxService.onDestroy():401-405` закрывает binder/coroutine scopes, но не является полным session close.
- `VPNService.onDestroy():39-42` не вызывает `super.onDestroy()`.
- `VPNService.openTun():89` содержит закомментированное закрытие прежнего PFD; `:210-212` записывает новый PFD.

Поскольку Go делает `dup(fd)`, закрытие Go duplicate не освобождает автоматически Kotlin PFD.

### 7.4. gRPC и UI уже расходятся с фактическим core state

`tmp_vpn_start_logcat_pid_only.txt:224-243,246-283` содержит повторные `gRPC Error code 14 UNAVAILABLE`, `Connection refused` на localhost. Между ними строки `:245,277` сообщают `core is already started!`. Это прямое свидетельство, что process/control-plane state не гарантирует живой command endpoint.

В том же диагностическом наборе фиксировалась Flutter ошибка `setState() or markNeedsBuild() called during build`; она может объяснять отдельные UI freeze/absence, но сама по себе не доказывает остановку VPN data plane.

### 7.5. Смена interface закрывает conntrack

В `route/network.go` текущего fork функция `ResetNetwork()` закрывает conntrack. Сборка включает `with_conntrack`. Поэтому handover может обрывать существующие соединения даже при корректной работе Android lifecycle.

## 8. Гипотезы, требующие device-тестов

1. Старый PFD действительно остаётся открытым после нескольких быстрых restart. Проверка: `/proc/<pid>/fd`, TUN inode/identity и counters до/после 100 циклов.
2. `activeNetwork` callback иногда возвращает VPN network или сеть без `VALIDATED`. Проверка: capabilities и network handle на каждом callback.
3. Dynamic MTU на cellular превращается в 1500 из-за `NetworkInterfaceMTU`. Проверка: runtime options, TUN MTU, packet capture и PMTU symptoms.
4. DNS transport/goroutine остаётся зависшим после Wi‑Fi→mobile. Проверка: generation-scoped DNS query timeline и goroutine profile.
5. Private DNS strict конфликтует с выбранной схемой hijack/bootstrap. Проверка: matrix Off/Automatic/Strict.
6. UDP probe Smart Active создаёт ложную деградацию при NAT rebinding или конкурирует с пользовательским QUIC. Проверка: разнести probe sockets и user flows по событиям/generation.
7. Foreground service убивается OEM/Android из-за notification/startForeground timing. Проверка: `ApplicationExitInfo`, `dumpsys activity services`, process importance.
8. Наблюдаемые вылеты — app native crash, Go panic, OOM или ANR. Нужны tombstone, exit reason, logcat buffer crash, traces и memory stats.
9. Часть failures серверная. Нужны одинаковый сервер, контрольный клиент и timestamps без секретных profile data.

## 9. Inventory собственных изменений ZEON

Ниже перечислены функциональные группы изменений, которые нельзя потерять при миграции. «Авто» означает, что patch может примениться текстово; это не означает, что семантическая совместимость гарантирована.

| Файл/область | Функции/назначение | Зависимость от sing-box internals | Конфликт | Перенос | Текущее покрытие |
|---|---|---|---|---|---|
| `hiddify-core/v2/config/builder.go:348-417` | URLTest, balancer, selector, interrupt policy | option structs и outbound group API | высокий | ручной rebase | builder tests частично |
| `hiddify-core/v2/config/builder.go:543-593,726-730` | dynamic MTU | TUN options/config schema | средний | ручной | `builder_parser_test.go:16-43` |
| `hiddify-core/v2/config/builder.go:1335` | Android default-interface policy | route auto-detect API | высокий | ручной | недостаточно |
| `hiddify-core/v2/config/hiddify_option.go:48,83,153-180` | ZEON/Hiddify runtime options, MTU/network metadata | config JSON | средний | частично auto | parser tests |
| `hiddify-core/v2/hcore/buildconfighelper.go:157-161` | перенос network/MTU options в generated config | Hiddify options | средний | auto + review | частично |
| `hiddify-core/v2/hcore/platform_interface.go:27-38` | Android platform interface control | libbox platform API | высокий | ручной | нет Android stress |
| `hiddify-core/hiddify-sing-box/outbound/balancer.go` | Round Robin/active selection, interrupt behavior | outbound manager, interrupt group | очень высокий | ручной | Go tests, не long-lived sessions |
| `hiddify-core/hiddify-sing-box/common/interrupt/group.go` | закрытие TCP/UDP при switch | internal connection tracking | высокий | ручной | unit semantics |
| Smart Active/quality/speed pipeline в `hiddify-core` и `hiddify-sing-box` | real-user health, scoring, emergency selection | selector/urltest/router/conntrack | очень высокий | только ручной | специализированные tests/logs, нет полной A/B matrix |
| UDP probe в core/fork | проверка UDP readiness/quality | packet conn, NAT, selector results | высокий | ручной | unit/diagnostic, нужны device tests |
| generation/session readiness в `lib/zeoncore/zeon_core_service.dart` | сериализация Flutter start/restart, listener recovery | gRPC/mobile API | высокий | отдельный Flutter port | Dart tests частично |
| `lib/zeoncore/zeon_core_service.dart:736-880` | ZEON option payload, route rules, network runtime info | Hiddify JSON builder | высокий | ручной | config tests частично |
| `lib/zeoncore/zeon_core_service.dart:1092-1150` | lifecycle queue/restart | background gRPC API | высокий | ручной | mock tests, нет data-plane gate |
| `lib/singbox/model/singbox_config_option.dart:70-107` | ZEON options/Smart debug defines | JSON schema | средний | ручной schema review | serialization tests |
| `android/.../bg/BoxService.kt` | Android service/core lifecycle | Mobile/libbox bridge | высокий | ручной | недостаточно |
| `android/.../bg/VPNService.kt` | TUN, protect, network callbacks | Android VpnService + libbox platform | очень высокий | ручной | недостаточно |
| `android/.../bg/PlatformInterfaceWrapper.kt:40+` | делегация `openTun()` | libbox generated interfaces | высокий | regenerate + manual | compile-only |
| `android/.../bg/ServiceConnection.kt` | Flutter/UI binding к service | Android binder | средний | ручной | нет death/rebind stress |
| `android/.../MethodHandler.kt:139-174` | status/platform calls | Android lifecycle state | средний | ручной | UI/integration частично |
| `lib/features/...Smart Active UI/repositories` | manual reselect, background tests, status display | ZEON core events | средний–высокий | независимо от core после API shim | Flutter tests частично |

Дополнительно в fork находятся Hiddify-специфичные протоколы и replacement-деревья: AmneziaWG, Hysteria/QUIC, Psiphon, Tailscale, custom DNS forks, balancer/URLTest. Их нельзя классифицировать как «обычный upstream 1.13.0».

Перед реальным обновлением inventory должен быть материализован машинно:

```powershell
git diff --binary <hiddify-core-upstream-commit> -- hiddify-core > out\patches\hiddify-core-zeon.patch
git -C hiddify-core/hiddify-sing-box diff --binary <hiddify-fork-baseline> > out\patches\sing-box-zeon.patch
git diff --name-status <hiddify-app-base> -- android lib test > out\patches\app-name-status.txt
```

Эти команды приведены как следующий этап; в рамках аудита файлы не создавались.

## 10. Аудит вариантов обновления

### Стратегия A — оставить fork и backport-ить selected fixes

Плюсы:

- минимальная смена ABI/config semantics;
- проще сохранить Smart Active, URLTest, UDP probe и Hiddify protocols;
- самый простой rollback.

Минусы:

- нужно вручную анализировать зависимости каждого upstream commit;
- fork продолжает расходиться;
- можно пропустить связанное исправление;
- lifecycle Android всё равно исправляется отдельно.

Объём: средний. Риск потери функций: низкий–средний. Риск скрытых merge errors: средний. Рекомендуемый риск: умеренный, как резервный путь.

### Стратегия B — rebase Hiddify/ZEON fork на официальный stable 1.13.14

Плюсы:

- получает полный набор исправлений stable 1.13.x;
- остаётся в той же major/minor API-линии;
- создаёт понятную базу и дальнейший update path;
- можно сохранить Hiddify Core и Flutter bridge на первом этапе.

Минусы:

- история fork не является линейным чистым `v1.13.0`, потребуется ручной port;
- конфликты в route/DNS/TUN/selector/WireGuard/QUIC;
- replacement modules должны обновляться согласованно;
- нужен regenerate AAR и полный A/B.

Объём: высокий. Риск потери функций: средний без inventory, низко-средний при поэтапном port. Совместимость: ожидаемо достижима, но должна доказываться compile/config/device tests. Рекомендуемый риск: умеренно высокий, контролируемый. Это основной вариант.

Целевой fork: ZEON-maintained `v1.13.14-zeon.1` на commit SagerNet `25a600db…`, с отдельными слоями:

1. чистый upstream;
2. Hiddify compatibility;
3. ZEON features;
4. отдельно lifecycle/bug fixes.

### Стратегия C — перейти на новый официальный Hiddify Core/fork

Плюсы: потенциально меньше собственного сопровождения Hiddify API.  
Минусы: актуальная Hiddify main на момент аудита указывает на sing-box commit `170d8315…`, включающий большую testing/1.14-alpha линию, а core HEAD — `db74dfc…`. Это не эквивалент стабильного обновления 1.13.x. Высокий риск JSON/API/deprecation, selector и protocol regressions.

Объём: очень высокий. Flutter/Android bridge: возможны изменения. Smart Active/UDP probe: повторный ручной port. Rollback: сложнее. Рекомендуемый риск: высокий; не основной вариант.

### Стратегия D — перейти на `sing-box-extended` ZapretKVN

Проверенная версия ZapretKVN: `v1.13.14-extended-2.5.2`, commit `ff11f007ec798136a5de258f947a4f34011a37ea`; `core.properties` закрепляет Go `1.26.4`, gomobile `0.1.12` и иной build pipeline.

Плюсы: содержит patchset и metadata checks ZapretKVN.  
Минусы:

- разница с official 1.13.14 — сотни файлов и десятки тысяч строк;
- отсутствуют Hiddify balancer/Smart/monitoring/UDP probe в совместимом виде;
- libbox API/build tags и patch assumptions отличаются;
- DNS/routing/WireGuard policy принадлежит другой архитектуре;
- необходимо отдельно проверить лицензии каждого extended patch и replacement;
- нет доказательства, что extended fixes устраняют найденные ZEON дефекты.

Объём: экстремальный. Вероятность потери функциональности: высокая. ABI/config compatibility: не доказана. Рекомендуемый риск: очень высокий; не рекомендуется.

### 10.1. Сводная таблица

| Критерий | A | B | C | D |
|---|---:|---:|---:|---:|
| Сохранение Flutter bridge | высокое | высокое после адаптации | среднее | низкое |
| Hiddify config builder | высокое | высокое после port | неизвестно/среднее | низкое |
| Smart Active | высокое | средне-высокое | среднее-низкое | низкое |
| URLTest/selector | высокое | среднее | среднее | низкое |
| UDP probe | высокое | среднее | низко-среднее | низкое |
| Изменение libbox API | низкое | низко-среднее | среднее-высокое | высокое |
| JSON/deprecations | точечные | средние | высокие | высокие |
| Route/DNS/TUN/gVisor | точечные | ручной audit | большой audit | архитектурно другие |
| WireGuard/QUIC | backport-specific | merge replacement trees | высокая неопределённость | extended policy |
| Rollback | простой | простой при dual AAR | средний | сложный |
| Общий риск | умеренный | умеренно высокий | высокий | очень высокий |

## 11. Changelog-аудит sing-box 1.13.x

Это не полный release notes, а только изменения, которые могут пересечься с ZEON.

| Релиз | Релевантные изменения | Влияние на ZEON |
|---|---|---|
| 1.13.1 | UDP resolved destination/FakeIP, legacy config removal | высокий config conflict; тестировать DNS/UDP и migration |
| 1.13.2 | исправление DNS recursion deadlock | релевантно потенциальному DNS hang; не исправляет Android lifecycle |
| 1.13.3 | cleanup отменённого dial, kTLS crash, Clash goroutine leak, local DNS CNAME, fd leak | полезно для stability/memory; проверить Hiddify backports |
| 1.13.4 | TUN system stack, AAAA, `CloseService` stale instance | прямо релевантно TUN/DNS/stale service |
| 1.13.5 | QUIC close, Hysteria BBR, WireGuard shutdown crash | релевантно QUIC/WG; не исправляет selector interrupt |
| 1.13.6 | vector `readv` fixes | data path correctness/performance |
| 1.13.7 | Android local DNS, EDNS cache, TCP keepalive, TUN fixes | высоко релевантно Android/DNS/long-lived TCP |
| 1.13.8 | FakeIP address-family fixes | релевантно dual-stack/IPv6 |
| 1.13.9 | UoT connect race, interface finder, UDP NAT timeout | релевантно UDP/handover |
| 1.13.10 | UoT write race | релевантно UDP-over-TCP paths |
| 1.13.11 | Android process search | ограниченно релевантно per-app routing |
| 1.13.12 | DNS pool leak/deadline/memory | релевантно многочасовой работе и DNS bursts |
| 1.13.13 | TUN loopback | релевантно маршрутизации edge cases |
| 1.13.14 | DNS shared-dedup deadlock, UDP sniff fragment fatal, mux UDP write, QUIC ALPN race, TUN TCP NAT collision | наиболее релевантный cumulative target |

Ни один из этих релизов не меняет автоматически ZEON hardcode `InterruptExistConnections=true`, порядок `Status.Started`, Android PFD ownership или Flutter data-plane readiness. Поэтому утверждение «1.13.14 исправит обрывы» без отдельных изменений неверно.

Основные migration hazards:

- удалённые/устаревшие legacy DNS/route options;
- изменения FakeIP/resolved destination;
- TUN stack defaults и gVisor API;
- WireGuard endpoint/outbound evolution;
- selector/urltest option structs;
- libbox generated interfaces;
- JSON validation и default values.

## 12. Commit ZapretKVN `938405d937cabac8aa1692fa224ee12625b12cef`

Commit решает конкретный класс временных ошибок:

- `NET-101`, `NET-102`, `DNS-101`, `DNS-105` считаются recoverable;
- recovery ожидает usable и settled underlying network;
- применяется debounce, чтобы одинаковые/частые callbacks не запускали restart storm;
- используется ограниченный exponential backoff;
- лимиты: до 3 попыток на той же сети и до 8 total attempts;
- persistent network monitor продолжает наблюдение между попытками;
- callbacks старой generation не должны завершить новую сессию.

Механизм помогает при Wi‑Fi↔mobile, DHCP/IP change, кратком исчезновении сети и ситуации, когда Android уже выдал Network, но DNS/data plane ещё не готовы.

Он не решает:

- закрытие соединений при Smart/selector switch;
- server failure;
- native crash/Go panic/OOM;
- неверный MTU;
- protocol incompatibility;
- дефекты Flutter UI.

В ZEON аналогичной сквозной корректной логики нет: есть отдельные network callbacks и restart/lifecycle queue, но нет единого failure classifier + readiness + generation + bounded retry + terminal cleanup.

## 13. Рекомендуемый безопасный план миграции

Команды ниже — план следующего этапа, а не выполненные действия.

| Этап | Файлы/команды | Ожидаемый результат и success | Stop-критерий | Rollback |
|---|---|---|---|---|
| 1. Baseline build | зафиксировать APK/AAB/AAR, `git status`, `sha256sum`/`Get-FileHash` | повторяемая текущая сборка и installable APK | checksum меняется без source change | сохранить baseline artifacts read-only |
| 2. Commit manifest | новый `core-lock.json` или `docs/core-baseline.md`; `git rev-parse`, tree hashes | точные ZEON/core/fork/replacement revisions | любой unknown tree | вернуться к manifest baseline |
| 3. Patch inventory | `git diff --binary`, `git range-diff`, name-status | каждый ZEON/Hiddify patch имеет owner/test | orphan functional diff | не начинать rebase |
| 4. Reproducible core build | `hiddify-core/Makefile`, CI/container; pin Go/gomobile/NDK/JDK | два clean build дают одинаковый или объяснимо нормализованный output | ABI/SHA/build info различаются | использовать baseline AAR |
| 5. Embedded metadata | libbox build vars, Android BuildConfig, diagnostics | version, core commit, fork commit, tags, dirty flag доступны runtime | metadata отсутствует/ложна | не публиковать new core |
| 6. APK verification | script распаковывает APK/AAR, проверяет ABI/SHA/Go build info | APK содержит ожидаемый `.so` для каждой ABI | хотя бы одна ABI не совпадает | reject build |
| 7. Update branch | отдельная ветка; база official `v1.13.14` `25a600db…` | чистый upstream layer + Hiddify commits + ZEON commits | невозможно объяснить diff | удалить ветку, baseline нетронут |
| 8. Compile/API conflicts only | `go test`, `gomobile bind`, Flutter/Gradle compile | нет функционального рефакторинга вместе с port | требуется изменить policy/behavior | отдельный commit/decision |
| 9. Unit/Go tests | `go test ./...`, race tests на host-supported packages | все существующие и новые selector/TUN/DNS tests green | panic/race/regression | revert offending port commit |
| 10. Config compatibility | corpus реальных обезличенных configs; old/new parse/build diff | все поддерживаемые профили валидны, semantic diff объяснён | silent option loss | остановить migration |
| 11. Android instrumented | lifecycle, PFD, permission, process, network tests | нет leaked fd, duplicate core, stale generation | flaky lifecycle invariant | old AAR |
| 12. A/B | одинаковые device/network/server/profile/route/MTU/IPv6 | статистически сравнимые результаты old/new | условия отличаются или regression | feature flag/old AAR |
| 13. Lifecycle/recovery port | только после core A/B; отдельные commits | влияние core update отделено от Android fixes | mixed untraceable change | revert lifecycle commit independently |
| 14. Small commits | metadata → build → core port → selector policy → lifecycle → recovery | каждый commit independently testable | «mega commit» | cherry-pick/revert |
| 15. Simple rollback | old/new AAR artifacts и lock manifests | возврат к old core одной config/commit operation | rollback требует переписывания app | release block |

### 13.1. Рекомендуемый порядок функциональных исправлений

После baseline и тестов:

1. Убрать ложный `Started`: публиковать только после успешного `Mobile.start()` и command/data-plane readiness.
2. Ввести `SessionOwner/ActiveSession` и идемпотентный close.
3. Запретить double TUN, логировать identity PFD/dup fd, проверять `protect(false)`.
4. Сделать сквозной generation token.
5. Разделить причины: server, physical network, DNS, core, selector.
6. Изменить interrupt policy selector отдельно и измерить preservation TCP/UDP.
7. Добавить `NOT_VPN`, readiness/debounce и только затем bounded recovery.
8. Исправить dynamic MTU policy после device measurement.

## 14. Обязательная тестовая матрица

Для каждого A/B запуска неизменны: устройство, OS build, сеть, сервер, профиль, routing, MTU, IPv6 settings, сценарий и длительность. Порядок old/new следует чередовать, чтобы не смешивать результат со временем суток/нагрузкой сервера.

| Сценарий | Выполнение | Основные assertions |
|---|---|---|
| Cold start | очистить process, старт VPN | одна generation, один core, один TUN, DNS+HTTPS healthy до Connected |
| 50–100 start/stop | автоматизированный цикл | fd/core/goroutine/memory не растут; финал Stopped |
| Быстрый restart | 10–20 restart с малым интервалом | не более одной active session; stale callback ignored |
| Profile switch | переключать A↔B | fingerprint соответствует generation; old profile не публикуется |
| Manual reselect | при long-lived TCP/UDP | policy явно фиксирует preserve/interrupt; нет случайного full restart |
| Smart Active switch | искусственно изменить metrics | decision только current generation; причина записана |
| Emergency switch | отключить текущий server | bounded action, без конкуренции manual/background |
| Foreground/background | 20 переходов | service/core сохраняются, UI resync |
| Закрыть Flutter UI | VPN работает 30 мин | data plane жив; reopen показывает фактический server |
| Kill UI process | `am kill`/swipe согласно сценарию | service behavior соответствует policy; state восстанавливается |
| VPN permission revoke | отозвать permission | TUN/core полностью закрыты, terminal reason |
| Wi‑Fi→mobile | active traffic + switch | NOT_VPN network, settled, recovery bounded |
| Mobile→Wi‑Fi | аналогично | underlying handle обновлён один раз |
| Отключение Wi‑Fi | без mobile и с mobile | корректное различие no-network/handover |
| Airplane mode | 30–60 s, затем off | нет retry storm; recovery budget соблюдён |
| Network restore | после полного loss | новая generation или documented in-session recovery |
| IP/DHCP change | renew/reconnect AP | DNS/interface обновлены, stale callbacks ignored |
| Strict Private DNS | hostname provider | DNS startup/health отдельно диагностированы |
| Captive portal | сеть без validation | Connected не публикуется до usable data plane |
| IPv4-only | отключить IPv6 | DNS/route/health не требуют AAAA |
| Dual-stack | v4+v6 | обе семьи работают, Happy Eyeballs не зависает |
| IPv6/NAT64 | NAT64 network | DNS64/route/MTU/UDP проверены |
| MTU Wi‑Fi 1500 | зафиксировать mode | фактический TUN MTU и PMTU без blackhole |
| MTU mobile 1380 | зафиксировать 1380 | runtime не переопределяет 1500 |
| Telegram long-lived | 1–2 h + switch/handover | timestamps reconnect коррелируют с selector/network |
| Speedtest | ≥20 повторов | тест завершается; switch reason не возникает без необходимости |
| Длительная загрузка | ≥10 GB/30–60 min | checksum, no reset, stable memory |
| Streaming video | 1–2 h | no unexplained stall/rebuffer around events |
| UDP | echo/iperf3 UDP | loss/jitter/NAT timeout измерены |
| QUIC/HTTP3 | sustained h3 transfer | нет ALPN/race/session drop вне declared switch |
| DNS bursts | параллельные A/AAAA/NXDOMAIN | нет deadlock/leak, deadlines соблюдены |
| Screen sleep | 30–60 min | VPN/FGS остаётся, wake reconnect объясним |
| Doze | `dumpsys deviceidle force-idle` | policy/recovery не создаёт storm |
| Несколько часов | 6–12 h | RSS, fd, goroutines, DNS latency bounded |
| Server failure | firewall/stop endpoint | классифицирован server failure, physical network не restart |
| DNS failure | block DNS/DoH target | DNS-specific reason, no false Connected |
| Physical failure | disable underlying | network-specific reason и bounded recovery |
| Core failure | controlled crash/close | UI не остаётся Connected; TUN закрыт |

### 14.1. Метрики A/B

- success rate запуска;
- time to core-ready, DNS-ready, data-plane-ready;
- число selector switches и их причины;
- TCP resets/reconnects;
- UDP/QUIC flow survival;
- DNS p50/p95/error/deadline;
- network callback count и deduplicated count;
- recovery attempts/success/terminal;
- PFD/fd count;
- RSS/heap/goroutines;
- process exits/ANR/native tombstones;
- завершённость Speedtest;
- bytes transferred до/после events.

## 15. Минимальная диагностика lifecycle

Каждая запись должна иметь monotonic timestamp, wall timestamp, process id, thread/coroutine context и `session_generation`.

| Event | Минимальные безопасные поля |
|---|---|
| `process_start` | app version, build id, process role |
| `service_create/start/destroy` | generation, intent action, startId |
| `command_server_create/start/close` | generation, instance id, result |
| `command_client_create/connect/close/error` | generation, client role, sanitized error class |
| `core_start/success/failure/close` | core version, core commit, tags, duration |
| `tun_request/open/close` | generation, opaque fd identity, MTU, address families |
| `protect_result` | generation, opaque fd identity, boolean, error class |
| `underlying_network` | opaque network handle, interface index, transports, NOT_VPN/VALIDATED/captive flags |
| `dns_start/health` | transport class, duration, result category; без query/profile secrets |
| `data_plane_health` | target class/hash, HTTP category, duration |
| `selector_switch` | group hash, old/new opaque id, reason, interrupt policy |
| `network_change` | previous/new opaque id, debounce/readiness |
| `recovery_attempt` | failure category/code, attempt same/total, delay |
| `terminal_failure` | category, stage, sanitized cause chain |
| `go_panic/native_crash` | build id, signal/panic hash, tombstone id |
| `resource_sample` | RSS, Go heap, goroutines, open fd count |

`profile_fingerprint`, server id и outbound id должны быть необратимыми keyed hashes с ключом конкретной установки или короткоживущей diagnostic session. Нельзя писать:

- адреса/домены серверов;
- UUID/user IDs;
- пароли;
- private/public keys, preshared keys;
- subscription URLs/tokens;
- полный JSON профиля;
- raw DNS names пользователя;
- содержимое трафика.

## 16. Rollback plan

1. Хранить baseline AAR/APK и manifest checksums вне Gradle cache.
2. Old и new core должны иметь разные immutable build IDs.
3. App bridge до release должен уметь работать с old API; breaking API включать только после compatibility shim.
4. Core switch выполняется отдельным маленьким commit, не смешанным с lifecycle.
5. Release criteria включают установку old build поверх test build и восстановление VPN/profile state.
6. При regression вернуть:
   - `android/app/libs/hiddify-core.aar`;
   - core lock manifest;
   - generated bindings, если они менялись;
   - не откатывать пользовательские данные destructive migration.
7. Если JSON migration неизбежна, хранить исходный profile/config и версионировать schema; downgrade должен читать старый формат либо восстановить backup.

Стоп-релиз условия: неизвестная `.so` в APK, несовпадение ABI/SHA, потеря ZEON protocol/Smart features, рост crash/ANR, ухудшение start success, fd/goroutine leak, больше обрывов long-lived TCP/UDP или невозможность downgrade.

## 17. Файлы, которые потребуется менять на следующем этапе

Это список предполагаемой области; в рамках аудита они не менялись.

### Build/provenance

- `hiddify-core/go.mod`, `hiddify-core/go.sum`;
- `hiddify-core/Makefile`;
- `hiddify-core/hiddify-sing-box/go.mod`, `go.sum`;
- Android Gradle files и новый verification script;
- CI workflow для reproducible AAR;
- новый core lock/metadata manifest.

### Android lifecycle/TUN/network

- `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt`;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/VPNService.kt`;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/PlatformInterfaceWrapper.kt`;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/ServiceConnection.kt`;
- `android/app/src/main/kotlin/com/zeon/zeon/MethodHandler.kt`;
- новые `ActiveSession`, `DefaultNetworkMonitor`, recovery policy и diagnostics classes;
- Android unit/instrumented tests.

### Core/config/selector

- `hiddify-core/v2/config/builder.go`;
- `hiddify-core/v2/config/hiddify_option.go`;
- `hiddify-core/v2/hcore/buildconfighelper.go`;
- `hiddify-core/v2/hcore/platform_interface.go`;
- `hiddify-core/hiddify-sing-box/outbound/balancer.go`;
- Smart Active, URLTest, UDP probe и monitoring файлы, выявленные patch inventory;
- config/selector/connection-preservation tests.

### Flutter

- `lib/zeoncore/zeon_core_service.dart`;
- `lib/singbox/model/singbox_config_option.dart`;
- providers/notifiers, публикующие connection/server state;
- diagnostic export/UI;
- lifecycle и stale-generation tests.

## 18. Вопросы, на которые нельзя ответить без логов или устройства

1. Каков реальный `ApplicationExitInfo.reason/status/importance` для каждого «самовылета»?
2. Есть ли app-process tombstone, Go panic, SIGSEGV/SIGABRT, OOM или ANR?
3. Убивает ли OEM foreground service и при каком notification state?
4. Сколько TUN/PFD/fd реально остаётся после 100 restart?
5. Какой network handle и capabilities получает ZEON при каждом handover?
6. Возвращает ли `protect(fd)` false на проблемных устройствах?
7. Какой фактический MTU установлен на TUN и physical interface?
8. Происходит ли обрыв одновременно с selector switch, `ResetNetwork/conntrack.Close`, DNS failure или process death?
9. Какие protocol/outbound используются в проблемных профилях?
10. Проблема повторяется на одном сервере, на всех серверах или только при Smart Active?
11. Есть ли server-side disconnect/timeout в тот же monotonic interval?
12. Как ведут себя IPv4-only, dual-stack и NAT64 на тех же устройствах?
13. Возникает ли DNS hang при Off/Automatic/Strict Private DNS?
14. Как изменяются RSS, Go heap, goroutines и fd за 6–12 часов?
15. Содержит ли установленный на устройстве APK именно ожидаемый SHA `.so`, а не старую сборку?

## 19. Итоговая рекомендация

Основная стратегия — B: controlled ZEON fork на официальной стабильной базе `SagerNet/sing-box v1.13.14` (`25a600db…`), с сохранением текущего `hiddify-core` на первом migration этапе и ручным послойным переносом Hiddify/ZEON patches. Резервная — A: текущий fork плюс строго выбранные backports.

До обновления ядра необходимо зафиксировать baseline и устранить диагностическую неопределённость. Первые функциональные исправления должны касаться:

1. ложного `Started/Connected`;
2. единого владения core/TUN/PFD/clients;
3. generation;
4. selector interrupt policy;
5. physical network readiness и bounded recovery.

`sing-box-extended` ZapretKVN не рекомендуется как replacement: он полезен как архитектурный референс, но не совместим с набором Hiddify/ZEON функций без большого и рискованного переноса.

## 20. Проверяемые ревизии и источники

- ZEON audit HEAD: `51d6c5156431f46fc56a4b79f5571a1771ca6caf`.
- Hiddify App base: `54bc7eebe871c6b266d6b17dd21261fe96f040a6`.
- Hiddify Core baseline: `c9d6f0f00b2eda34e4fb71863e4e0a62b3e931a0`.
- Hiddify sing-box fork: `0a02b7729f6a211436bb8bdcd8696c283eb27767`.
- SagerNet stable target: `25a600db24f7680ad9806ce5427bd0ab8afe1114` (`v1.13.14`).
- ZapretKVN audited HEAD: `20794bfd2e4223c0d11dba73cab2a0f0fb354e07`.
- ZapretKVN recovery commit: `938405d937cabac8aa1692fa224ee12625b12cef`.
- sing-box-extended audited commit: `ff11f007ec798136a5de258f947a4f34011a37ea`.
- AAR SHA-256: `7A94C004286875410D70D8CECF07D8813DAB33D27F7D76A23C7ABA3460E37600`.

Внешний ZapretKVN использовался только из временного clone. В dependency/submodule ZEON он не добавлялся.
