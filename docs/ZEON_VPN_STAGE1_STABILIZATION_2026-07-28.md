# ZEON VPN — результат первого этапа стабилизации

Дата: 2026-07-28  
Ветка: `dev-ios`  
Baseline исходников: `51d6c5156431f46fc56a4b79f5571a1771ca6caf`  
Последний implementation commit до manifest/report: `f6650c782c72d7e7260827b2f8f1eb9d3d95cd76`  
Core build revision: `31c5987477d3cd02a099c2c0c01c3a07da05ce69`

## 1. Краткое резюме

Первый этап стабилизации реализован на существующей базе `sing-box v1.13.0` и существующих версиях Hiddify/Go/gomobile/NDK. Версии ядра и зависимости не обновлялись.

Исправлены доказанные дефекты:

- Android больше не публикует `Started` до успешного завершения `Mobile.start()` и готовности command endpoint;
- start/restart/stop, Android callbacks, Flutter listeners, TUN и selector связаны общей монотонной VPN generation;
- Android `ParcelFileDescriptor` получил единственного session-scoped владельца;
- teardown сведён к одному идемпотентному порядку освобождения ресурсов;
- manual, regular Smart Active и better-score switch сохраняют существующие внешние TCP/UDP-сессии;
- emergency interruption разрешается только по повторному, свежему и outbound-specific доказательству;
- `VpnService.protect(fd) == false` является terminal startup error;
- после открытия TUN выполняется контрольный `protect()` тестового UDP socket;
- Android-конфигурации, которые доказанно отключают platform protect, отклоняются до запуска;
- добавлены generation-scoped диагностические события без адресов, UUID, ключей и содержимого профилей;
- создана воспроизводимая сборка AAR с embedded provenance;
- baseline и stage-1 AAR/APK сохранены и проверяются одним скриптом.

Это не является утверждением, что все наблюдаемые обрывы устранены. Реальные data-plane сценарии с профилем, сервером, Telegram, Speedtest, QUIC и сменой physical network ещё не выполнены.

## 2. Root cause → fix mapping

| Доказанный дефект | Доказательство до исправления | Исправление | Основной commit |
|---|---|---|---|
| `Started` публиковался до результата native start | прежний порядок в `BoxService.startService()` выставлял Started до подтверждения `Mobile.start()` | `CoreStartupGate.awaitReady()` требует успешный start, актуальную generation и готовность endpoint; `CoreReady` в Dart остаётся `CoreStarting` | `93270d7f` |
| Старый callback мог изменить новую сессию | callbacks/status не имели общего session token | `VpnSessionCoordinator`, AIDL generation, `SessionGenerationGate`, проверки всех lifecycle/listener/selector результатов | `f7c33851` |
| Android PFD мог быть перезаписан и утечь | прежнее поле PFD не обеспечивало single-open/session invariant | `TunDescriptorOwner.open()/close()`: один descriptor на generation, duplicate rejection, close-on-validation-error, opaque identity | `572295aa` |
| Разные stop/error paths освобождали ресурсы в разном порядке | stop, failed start, restart, revoke и destroy имели собственные ветки | `ActiveSession.close()` с AtomicBoolean/CompletableDeferred и общим порядком teardown | `afcabb10` |
| Selector мог обрывать пользовательские TCP/UDP при обычном switch | builder включал `InterruptExistConnections` для Smart Active без точной причины switch | явная `switchInterruptionPolicy`; external sessions сохраняются вне confirmed emergency | `1aeca27b` |
| Один timeout/UDP/DNS сбой мог участвовать в разрушительном решении | причина switch не классифицировалась по силе доказательства | timeout, DNS, QUIC/UDP, cache, stale generation и physical-network-подобные ошибки исключены из emergency predicate | `1aeca27b` |
| Результат `VpnService.protect(fd)` игнорировался | `VPNService.autoDetectInterfaceControl()` продолжал работу независимо от false | false логируется как `protect_result` и выбрасывает ошибку, startup переходит в общий teardown | `572295aa` |
| Некоторые DialerOptions отключают обычный platform protect | `common/dialer/default.go` не добавляет ProtectFunc при bind interface/address; route/default-interface также принудительно маршрутизирует socket | Android-only validation блокирует доказанно опасные combinations, остальные платформы и поля не удалены | `37ee9943` |
| Нельзя было доказать происхождение упакованного core | AAR имел неустойчивую VCS metadata и не было APK verifier | pinned offline build, `Mobile.getBuildMetadata()`, stage manifest, ABI/SHA/build-info verifier | `edf35fa7`, `31c59874`, `0a30bed3` |

Ключевые места:

- `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt`: `startService()` строки 223–318, `openTun()` строки 516–528, `closeSession()` строки 530–559;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/CoreStartupGate.kt`: `awaitReady()`;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/VpnSessionCoordinator.kt`: generation и safe event envelope;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/TunDescriptorOwner.kt`: `open()` строки 25–66, `close()` строки 68–91;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/ActiveSession.kt`: `close()` строки 35–75;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/VPNService.kt`: protect строки 68–82 и post-TUN probe строки 242–263;
- `hiddify-core/v2/config/builder.go`: `validateAndroidProtectCompatibility()` строки 185–212;
- `hiddify-core/hiddify-sing-box/protocol/group/balancer/switch_policy.go`;
- `hiddify-core/hiddify-sing-box/common/interrupt/group.go`: `Interrupt()` и TCP/UDP counters.

## 3. Новая lifecycle-схема

```text
Flutter start/restart
  │
  ├─ SessionGenerationGate.next()
  ├─ setSessionGeneration(generation)
  └─ MethodChannel/AIDL(generation)
        │
        ▼
Android VpnSessionCoordinator.accept(generation)
        │
        ├─ status = Starting
        ├─ ActiveSession(generation)
        ├─ platform/TUN setup
        ├─ Mobile.start()
        ├─ wait command endpoint
        │
        ├─ failure/timeout/stale
        │    └─ ActiveSession.close(reason)
        │         1. reject new operations
        │         2. cancel jobs/callbacks
        │         3. close clients/listeners
        │         4. stop core
        │         5. close command server
        │         6. close platform
        │         7. close Android PFD
        │         8. clear network/session refs
        │         9. publish terminal state only if generation is current
        │
        └─ success + command endpoint ready
             ├─ CoreReady (Flutter maps it to Starting)
             └─ after Flutter/native start confirmation: Started
```

`Started` теперь означает, что core и control-plane готовы. Оно не считается доказательством работоспособности data-plane. Отдельная HTTPS/DNS data-plane readiness gate в этот этап не добавлялась.

## 4. Session generation

Generation проходит через:

- Flutter `start`, `restart`, `stop`, listener registration, URLTest и manual selector;
- MethodChannel, AIDL `IService` и `IServiceCallback`;
- `ServiceConnection`, `ServiceBinder`, `BoxService`, `VPNService`;
- `ActiveSession`, `TunDescriptorOwner`, status publication;
- Smart Active/selector через `ZEON_SESSION_GENERATION`;
- Go monitoring update и active-probe callbacks;
- Flutter parser событий selector.

Устаревший callback:

1. не изменяет status;
2. не выбирает outbound;
3. не публикует terminal state;
4. логируется как `stale_callback_ignored` или `[SelectorStaleResult]`.

Существующая внутренняя Smart Active generation не удалена. Общая VPN generation добавлена как внешний session boundary.

## 5. Selector interrupt policy

| Switch | Existing external TCP/UDP | Условие |
|---|---|---|
| Manual reselect | сохраняются | всегда selector-only |
| Regular Smart Active | сохраняются | обычное решение monitor |
| Better-score / preventive | сохраняются | улучшение score, batch result, user refresh |
| Suspect/degraded | сохраняются | текущий outbound ещё не доказанно мёртв |
| Confirmed emergency | могут быть прерваны | только predicate ниже |
| Stale generation | switch отклоняется | captured generation не совпадает с текущей |

Confirmed emergency требует одновременно:

1. решение действительно является switch;
2. есть либо `active_probe_confirmed_connection_failure`, либо состояние `CRITICAL` с failure streak не меньше двух;
3. URLTest history не nil, не cache, не success;
4. `CheckGeneration != 0`, timestamp не zero;
5. `CombinedReady == true`;
6. status равен failed;
7. error type — только `refused`, `tls_handshake_failed` или `unsupported_curve`.

Не являются emergency evidence:

- один timeout/deadline;
- DNS error;
- QUIC/UDP error;
- временная потеря UDP probe;
- отсутствие speed metric;
- cached result;
- stale generation;
- смена physical network;
- фоновый URLTest другого сервера.

Каждый switch пишет `generation`, type, reason, SHA-256-derived opaque old/new id, interrupt flag, closed TCP/UDP/external counters и `full_core_restart=false`.

## 6. Protect и TUN ownership

`TunDescriptorOwner` обеспечивает:

- один успешный `openTun()` на generation;
- закрытие нового PFD при duplicate open;
- запрет молчаливой замены старого PFD;
- close-on-error после `Builder.establish()`;
- идемпотентный close;
- stale-generation rejection;
- opaque `tun-N` вместо fd/profile/network data.

Kotlin PFD закрывается независимо от Go duplicate. Закрытие Go `dup(fd)` не считается заменой закрытию исходного Android PFD.

Android startup блокируется, если:

- platform `protect(fd)` вернул false;
- post-TUN UDP socket protect check вернул false;
- generated Android config содержит `route.default_interface`;
- outbound содержит `bind_interface`, `inet4_bind_address`, `inet6_bind_address`, `routing_mark` или `netns`.

Поля не удалены из schema и не блокируются на других платформах.

## 7. Диагностика

Добавлены события:

- `vpn_session_start`;
- `core_start_requested`;
- `core_start_success`;
- `core_start_failure`;
- `command_endpoint_ready`;
- `tun_open_requested`;
- `tun_open_success`;
- `tun_open_rejected_duplicate`;
- `tun_close`;
- `protect_result`;
- `selector_switch`;
- `selector_interrupt`;
- `session_close_requested`;
- `session_close_completed`;
- `stale_callback_ignored`;
- `grpc_disconnect`;
- `core_already_started_conflict`;
- `terminal_failure`;
- `runtime_indicators`.

Каждый новый lifecycle event содержит monotonic timestamp, PID и generation. Selector details проходят allowlist. Новые события не содержат server address, UUID, password, key, subscription URL, profile JSON или DNS query.

`ALREADY_STARTED` больше не принимается как успешный start: это single-core conflict, после которого выполняется fail-closed stop/teardown.

## 8. Изменённые файлы

### Android lifecycle

- `android/app/src/main/aidl/com/zeon/zeon/IService.aidl`
- `android/app/src/main/aidl/com/zeon/zeon/IServiceCallback.aidl`
- `android/app/src/main/kotlin/com/zeon/zeon/EventHandler.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/MainActivity.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/MethodHandler.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/ShortcutActivity.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/ActiveSession.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/CoreStartupGate.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/ProxyService.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/ServiceBinder.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/ServiceConnection.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/TileService.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/TunDescriptorOwner.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/VPNService.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/bg/VpnSessionCoordinator.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/constant/Action.kt`
- `android/app/src/main/kotlin/com/zeon/zeon/constant/Status.kt`

### Flutter/Dart

- `lib/singbox/model/core_status.dart`
- `lib/zeoncore/core_interface/core_interface.dart`
- `lib/zeoncore/core_interface/core_interface_desktop.dart`
- `lib/zeoncore/core_interface/core_interface_mobile.dart`
- `lib/zeoncore/session_generation.dart`
- `lib/zeoncore/vpn_diagnostics.dart`
- `lib/zeoncore/zeon_core_service.dart`

### Current Hiddify/sing-box fork

- `hiddify-core/v2/config/builder.go`
- `hiddify-core/v2/config/android_protect_test.go`
- `hiddify-core/platform/mobile/build_metadata.go`
- `hiddify-core/platform/mobile/build_metadata_test.go`
- `hiddify-core/hiddify-sing-box/common/interrupt/group.go`
- `hiddify-core/hiddify-sing-box/common/interrupt/group_test.go`
- `hiddify-core/hiddify-sing-box/protocol/group/selector.go`
- `hiddify-core/hiddify-sing-box/protocol/group/balancer/active_monitor.go`
- `hiddify-core/hiddify-sing-box/protocol/group/balancer/balancer.go`
- `hiddify-core/hiddify-sing-box/protocol/group/balancer/switch_policy.go`
- `hiddify-core/hiddify-sing-box/protocol/group/balancer/switch_policy_test.go`

### Tests и provenance

- `android/app/build.gradle`
- `android/app/src/androidTest/kotlin/test/com/zeon/zeon/bg/*InstrumentedTest.kt`
- `android/app/src/androidTest/kotlin/test/com/zeon/zeon/bg/VpnTestInstrumentation.kt`
- `test/zeoncore/session_generation_test.dart`
- `test/zeoncore/vpn_diagnostics_test.dart`
- `scripts/rebuild_hiddify_core.ps1`
- `scripts/verify_android_core.ps1`
- `baselines/android-core/2026-07-28-baseline.json`
- `baselines/android-core/2026-07-28-stage1.json`

Предсуществующий `android/app/src/main/assets/adi-registration.properties` не изменялся и не попадал в commits.

## 9. Отдельные commits

| Commit | Назначение |
|---|---|
| `edf35fa7` | baseline manifest, rollback artifacts и исходный audit |
| `f7c33851` | общая session generation и stale callback gating |
| `93270d7f` | readiness gate и запрет premature Started |
| `572295aa` | session-scoped PFD owner и fail-closed protect |
| `afcabb10` | единый идемпотентный `ActiveSession.close()` |
| `1aeca27b` | selector interruption policy и TCP/UDP counters |
| `37ee9943` | Android config guard для protect-bypass options |
| `eb638241` | generation-scoped lifecycle diagnostics |
| `31c59874` | pinned reproducible AAR build и embedded metadata |
| `37421c5e` | analyzer-clean diagnostic parser |
| `f6650c78` | запуск dependency-free instrumentation runner |
| `0a30bed3` | stage-1 manifest и проверка нового/старого APK |

## 10. Результаты тестов

### Пройдено

| Проверка | Команда/доказательство | Результат |
|---|---|---|
| Flutter/Dart suite | `flutter test` | 126/126 passed |
| Targeted analyzer | `flutter analyze lib/zeoncore/vpn_diagnostics.dart lib/zeoncore/zeon_core_service.dart test/zeoncore/vpn_diagnostics_test.dart` | No issues found |
| Core packages under pinned Go | `GOTOOLCHAIN=go1.25.6 go test ./platform/mobile`, full root run for `v2/config` and `v2/hcore` | passed |
| Selector/interrupt tests | `go test ./common/interrupt ./protocol/group/balancer ./protocol/group` | passed |
| Android Kotlin/main/test compilation | `:app:assembleDebug :app:assembleDebugAndroidTest` | passed |
| Android unit task | `:app:testDebugUnitTest` | task passed, `NO-SOURCE` |
| Instrumented suite on OnePlus GM1901 / Android 16 | `:app:connectedDebugAndroidTest` | 13/13 passed |
| Generation tests | same suite | monotonic/stale gating passed |
| Startup tests | same suite | success, exception, timeout, stop-during-start, restart-during-start passed |
| TUN/PFD stress | same suite | duplicate, validation error, stale open, 100 owner cycles, 20 restart cycles passed |
| Teardown | same suite | order and concurrent idempotent close passed |
| Clean app build | `:app:clean` then `flutter build apk --release` | signed release APK built |
| New APK provenance | `verify_android_core.ps1` + stage manifest | passed for 3 packaged ABI |
| Baseline rollback provenance | same script + baseline manifest/AAR/APK | passed |
| Baseline AAR source compatibility | временная подстановка baseline AAR, `:app:clean :app:compileDebugKotlin`, затем guaranteed restore stage AAR | passed; working AAR restored to SHA `04453F…` |

### Выполнено, но не принято как green

| Проверка | Результат |
|---|---|
| `flutter analyze` всего проекта | 466 существующих warning/info; добавленный новым parser lint устранён; targeted changed Dart files clean |
| `go test ./...` в hiddify-core | relevant packages passed, общий exit non-zero из-за существующих `go vet` warnings в tunnelservice и network-dependent `v2/profile/test`, который получил пустой outbound list и упал на существующей строке `builder.go:428` |
| `go test ./...` в hiddify-sing-box с `GOPROXY=off` | relevant selector/interrupt packages passed; многие unrelated packages не стартовали из-за отсутствующих в локальном cache modules. Сеть не включалась, чтобы не менять зависимости |
| global Gradle `clean` | root clean не смог удалить запущенный Windows build, файлы которого были открыты. Android-scoped `:app:clean` прошёл и использован перед release APK |

### Не проверено как реальный VPN/data-plane

На устройстве не было подготовленного контролируемого ZEON profile/server fixture и согласованной VPN permission/state. Поэтому не объявлены пройденными:

- cold VPN start с реальным профилем;
- failed native start на реальном invalid profile;
- 100 полных `VpnService` start/stop;
- 20 полных core restart;
- manual reselect при активной загрузке;
- Smart Active switch при активной загрузке;
- реальный UDP/QUIC поток при switch;
- Telegram long-lived connection;
- Speedtest до завершения;
- video/download;
- UI close/reopen при работающем VPN;
- UI process kill;
- реальный gRPC disconnect;
- реальный `core is already started`;
- `onRevoke` после отзыва VPN permission;
- service/process destroy с активным TUN;
- Wi-Fi ↔ mobile, airplane mode, captive portal, strict Private DNS, IPv6/NAT64;
- server/DNS/physical-network/core failure classification;
- несколько часов VPN/Doze/FD/memory/goroutine trend.

Команды для следующего device-прогона:

```powershell
adb logcat -c
adb shell am start -n com.zeon.hiddify/com.zeon.zeon.MainActivity
adb shell dumpsys connectivity
adb shell dumpsys netstats
adb shell dumpsys activity services com.zeon.hiddify
adb shell pidof com.zeon.hiddify
adb logcat -v threadtime | Select-String "vpn_session_|core_start_|tun_|protect_result|selector_|session_close_|grpc_disconnect|terminal_failure"
```

Для каждого сценария assertions:

1. одна актуальная generation;
2. не более одного успешного TUN open;
3. каждый PFD имеет ровно один terminal close;
4. stale callback не меняет state/outbound;
5. regular/manual switch имеет `interrupt_external=false`;
6. emergency interrupt содержит все подтверждающие признаки;
7. после failure нет Started/Connected;
8. после stop/revoke/destroy нет core, command endpoint, monitor jobs и открытого PFD;
9. fd, memory и goroutine count возвращаются к baseline;
10. одинаковые device/network/server/profile/routing/MTU/IPv6 для A/B.

## 11. SHA и provenance

### Baseline rollback

- AAR SHA-256: `7A94C004286875410D70D8CECF07D8813DAB33D27F7D76A23C7ABA3460E37600`
- APK SHA-256: `C89EAFDB7824A1AFF95B166939A14F8CA424563E007DF26E1D78E2C4D59531DF`
- Manifest: `baselines/android-core/2026-07-28-baseline.json`
- AAR: `out/baseline/51d6c5156431f46fc56a4b79f5571a1771ca6caf/hiddify-core.aar`
- APK: `out/baseline/51d6c5156431f46fc56a4b79f5571a1771ca6caf/zeon-1.3.0+103001-arm64-v8a-release.apk`

### Stage 1

- AAR SHA-256: `04453FE46DDEC27DB8A4B9F859FB084D19D5F9121E709D3457BD52BABD8359E5`
- APK SHA-256: `2FA51176B2A7536C66FA73403D0ADAB15756FDC0B602813F4D6DC34DF7A55AAF`
- Manifest: `baselines/android-core/2026-07-28-stage1.json`
- AAR: `out/stabilization/31c5987477d3cd02a099c2c0c01c3a07da05ce69/hiddify-core.aar`
- APK: `out/stabilization/31c5987477d3cd02a099c2c0c01c3a07da05ce69/zeon-1.3.0+103001-stage1-release.apk`

Stage AAR содержит четыре ABI; release APK — `arm64-v8a`, `armeabi-v7a`, `x86_64`. Все APK `.so` сверены по post-strip SHA.

Embedded metadata:

- Go `go1.25.6`;
- sing-box `v1.13.0`;
- ZEON core build revision `31c5987477d3cd02a099c2c0c01c3a07da05ce69`;
- hiddify-core tree `2c50fe96981ba2e3bb6e2a2b71ddbe97b1ed354d`;
- hiddify-sing-box tree `70dc263d60846a4fc66f357b7b227941d4d54d2c`;
- build tags из manifest;
- Java API `com.hiddify.core.mobile.Mobile.getBuildMetadata()`.

## 12. Rollback

Проверка baseline без изменения working AAR:

```powershell
$base = "out/baseline/51d6c5156431f46fc56a4b79f5571a1771ca6caf"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_android_core.ps1 `
  -ManifestPath baselines/android-core/2026-07-28-baseline.json `
  -AarPath "$base/hiddify-core.aar" `
  -ApkPath "$base/zeon-1.3.0+103001-arm64-v8a-release.apk"
```

Возврат AAR для локальной сборки:

```powershell
Copy-Item -LiteralPath `
  "out/baseline/51d6c5156431f46fc56a4b79f5571a1771ca6caf/hiddify-core.aar" `
  -Destination "android/app/libs/hiddify-core.aar" -Force
```

Возврат приложения:

- использовать сохранённый baseline APK с тем же signing key;
- при одинаковом versionCode: `adb install -r <baseline-apk>`;
- если на устройстве уже более высокий versionCode, не удалять приложение автоматически: сначала сохранить данные и использовать контролируемый release rollback. `adb uninstall` стирает данные;
- для возврата source changes использовать `git revert` отдельных stage commits в обратном порядке, а не `git reset --hard`.

## 13. Оставшиеся риски

1. Реальная причина части обрывов может оставаться в physical-network recovery, DNS/data-plane, сервере или протоколе.
2. `Started` теперь доказывает control-plane readiness, но не HTTPS/DNS data-plane.
3. Общая generation передаётся в Go через process environment; это безопасный текущий bridge, но при будущем multi-core/process дизайне нужен явный API field.
4. Emergency predicate консервативен и требует device A/B tuning на реальных отказах.
5. Android protect config guard может отклонить редкие пользовательские full-config профили с опасными bind options; формат профиля не изменён, ошибка диагностическая.
6. Full Go suite пока не hermetic: есть network-dependent test, старые vet failures и неполный offline module cache.
7. Instrumented stress проверяет ownership/lifecycle primitives, а не 100 реальных VPN sessions.
8. Physical network debounce/recovery из ZapretKVN в этот этап не переносился.
9. sing-box `1.13.14` не применялся; миграция остаётся отдельным следующим этапом после device baseline.

## 14. Подтверждение ограничений

В рамках этапа не менялись:

- версия `sing-box` (`v1.13.0`);
- исходный hiddify-core upstream commit;
- исходный hiddify-sing-box commit;
- `go.mod`, `go.sum`, `pubspec.yaml`, `pubspec.lock`;
- Go baseline (`1.25.6`);
- gomobile (`0.1.11`);
- NDK (`28.2.13676358`);
- Android SDK levels;
- формат профилей и подписок;
- пользовательские настройки;
- Smart Active Auto, Round Robin, URLTest, quality/speed pipeline, UDP probe и real-user health.

`sing-box-extended` не добавлялся. Архитектура ZapretKVN целиком не копировалась. Обновление на sing-box `1.13.14` не выполнялось.
