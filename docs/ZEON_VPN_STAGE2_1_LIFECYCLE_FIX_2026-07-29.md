# ZEON VPN Stage 2.1 — Android lifecycle fix

Дата проверки: 2026-07-29
Ветка: `stage2.1/android-lifecycle-gates`
Implementation commit: `afdceade173cbfe12f88757178bf3bb137b41ba6`
Stage 2 parent: `502ad1bdfb3de5b509211b6c4be97fa8768a5620`
Core revision: `14b8022a7412c05faeee7eb3fc09843afa5e4446`

## 1. Executive summary и verdict

Оба заявленных lifecycle-дефекта воспроизведены по исходным evidence, локализованы и исправлены без изменения sing-box, Hiddify/ZEON core, Smart Active ranking, Round Robin algorithm, DNS, routing, MTU, UDP probe, профилей или протоколов.

Итоговый технический verdict: **CONDITIONAL PASS**.

Целевые результаты:

- false `Connected` после первого Android VPN permission устранён: на физическом OnePlus `Started` опубликован только после permission, command endpoint, `tun_open_success`, `protect_result success=true` и `core_start_success` одной generation;
- старая generation больше не может доставить terminal success/error в актуальный Flutter/UI;
- 20 обязательных и 2 контрольных Smart Active ↔ Round Robin переключения завершились на одной активной generation без stale dialog и без остановки новой сессии;
- 25/25 Android instrumentation tests и 133/133 Flutter tests прошли;
- финальная R2 APK сохраняет исходный Stage 2 AAR SHA и проходит core provenance verifier.

Причины условности допуска:

1. Полный config restart при смене Smart Active/Round Robin прерывает существующий TCP socket: браузерная загрузка `50MB.zip` завершилась ошибкой при серии переключений. Runtime API безопасной смены типа balancer без перестроения effective config в текущей архитектуре не найден.
2. После 22 mode switches и последующих start/stop RSS вырос с 409628 до 488472 KiB, threads — с 70 до 87. FD недоступны shell (`/proc/<pid>/fd: Permission denied`). Это короткий сигнал риска, а не доказанная долгосрочная утечка.
3. При немедленном DNS probe после `core_start_success` были отдельные transient misses; повторная проверка с двухсекундным data-plane settling прошла в обоих направлениях. DNS не входит в утверждённый Stage 2.1 Connected-gate и его policy не менялась.

## 2. Точная первопричина false Connected

Дефект был составным.

### 2.1 Permission attempt не имела единого владельца generation

До исправления Flutter preparation и последующий start могли создавать разные попытки, а Android хранил permission callbacks и флаг продолжения старта вне session-scoped объекта. Возврат из системного dialog поэтому не доказывал принадлежность результата актуальному start.

Исправление:

- generation теперь создаётся до permission в `ConnectionRepositoryImpl.connect/reconnect` и передаётся через весь путь: `lib/features/connection/data/connection_repository.dart:95-218`;
- Android coordinator допускает только одну pending permission attempt, коалесцирует duplicate callback и классифицирует старый результат как `Stale`: `android/app/src/main/kotlin/com/zeon/zeon/bg/VpnPermissionRequestCoordinator.kt:8-130`;
- `MainActivity.prepareVpn()` и `onActivityResult()` сохраняют/проверяют generation: `android/app/src/main/kotlin/com/zeon/zeon/MainActivity.kt:77-171`, `:244-250`;
- `MethodHandler` не принимает нулевую или несовпадающую generation: `android/app/src/main/kotlin/com/zeon/zeon/MethodHandler.kt:120-158`.

### 2.2 Command endpoint ошибочно трактовался как terminal readiness

`CoreInfo`/gRPC status мог вернуть `CoreStarted` после готовности command daemon, когда `Mobile.start()` ещё не завершил TUN startup. Этот status проходил прямо в Flutter status stream, обходя Android platform evidence.

Исправление:

- `CoreInterfaceMobile.setupBackground()` возвращает `CoreStarting`, а не `CoreStarted`: `lib/zeoncore/core_interface/core_interface_mobile.dart:131-166`;
- `_gateTerminalStatus()` блокирует любой `CoreStarted`, пока Android `mark_core_started` не подтвердил ту же generation: `lib/zeoncore/zeon_core_service.dart:295-326`;
- Android final gate реализован в `VpnConnectedGate.evaluate()`: `android/app/src/main/kotlin/com/zeon/zeon/bg/VpnConnectedGate.kt:4-45`;
- gate собирает evidence из session-owned command endpoint/TUN/protect state: `android/app/src/main/kotlin/com/zeon/zeon/bg/ActiveSession.kt:42-61`;
- единственная terminal publication находится в `BoxService.confirmCoreStarted()`: `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt:564-614`.

Gate требует одновременно:

```text
permissionGranted
mobileStartSucceeded
commandEndpointReady
tunOpened
postTunProtectSucceeded
generationCurrent
sessionAcceptingOperations
```

`CoreReady` остаётся промежуточным status и не превращается в Flutter `Connected`.

## 3. Точная первопричина stale UI propagation

Platform gate уже правильно отвергал старый `openTun`, но исключение продолжало завершать старый Dart Future как обычная актуальная ошибка. `ConnectionNotifier.restartForConfigChange()` получал `Left`, переводил актуальный state в `AsyncError` и показывал технический dialog. Параллельно новый restart уже мог поднять следующую generation.

Исправление:

- `SessionGenerationGate.classifyCompletion()` различает current/stale для success и exception: `lib/zeoncore/session_generation.dart:8-29`;
- `_isStaleOperation()` поглощает late success, exception, timeout, cancellation и transport completion старой generation: `lib/zeoncore/zeon_core_service.dart:278-293`;
- stale checks стоят после background setup, `Mobile.start`, `markCoreStarted`, gRPC error, transport recovery и перед terminal publication: `lib/zeoncore/zeon_core_service.dart:961-1123`, `:1247-1418`;
- Android `stopAndAlert()` не публикует alert и не закрывает новую session для старой generation: `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt:426-448`;
- `openTun()` проверяет generation до `Builder.establish()`: `android/app/src/main/kotlin/com/zeon/zeon/bg/VPNService.kt:102-113`;
- service status/alert EventChannel несёт generation: `android/app/src/main/kotlin/com/zeon/zeon/EventHandler.kt:16-43`, `MainActivity.kt:179-210`.

Техническая stale error не заменяется silent success для актуальной operation: подавляется только completion, чья generation уже superseded.

## 4. Фактический lifecycle смены режима

Путь настройки:

```text
RouteOptionsPage
  -> ConfigOptions.balancerStrategy
  -> ConfigOptionNotifier debounce
  -> ConnectionNotifier.restartForConfigChange(source=mode_switch)
  -> ConnectionRepository.reconnect
  -> ZeonCoreService.restart
```

Стратегия находится в effective sing-box config. Доказанного runtime API, который меняет реализацию balancer без config rebuild, нет. Поэтому restart сохранён, но сериализован:

```text
allocate new operation generation
  -> permission preparation for that generation
  -> lifecycle queue entry
  -> cancel old Flutter listeners
  -> bgClient.stop old core
  -> Android common stop/ActiveSession.close
  -> cancelAndJoin Android command polling
  -> close old TUN/PFD/platform/endpoint
  -> verify old generation closed
  -> setup one new Android session
  -> command endpoint CoreReady
  -> Mobile.start
  -> new TUN + protect probe
  -> Android final gate
  -> publish Started for new generation only
```

`SerialLifecycleQueue`: `lib/zeoncore/session_generation.dart:34-50`.
Mode restart implementation: `lib/zeoncore/zeon_core_service.dart:1247-1418`.

## 5. Дополнительный lifecycle-дефект, найденный на устройстве

На первой validation APK дважды возник `SIGSEGV`, оба раза в `DefaultDispatch` после старта Smart Active session. Logcat показал, что dynamic notification `GetSystemInfo` polling:

- запускался уже на `CoreReady`, до terminal start gate;
- жил в process-global coroutine scope;
- при restart получал только `cancel()`, без ожидания завершения blocking gRPC call;
- мог выполнить старый poll против закрытого или нового command endpoint.

Evidence:

- `mobile-process-exit-investigation.txt`;
- `mobile-exit-info.txt`: `reason=5 APP CRASH(NATIVE), status=11`;
- `mode-switch-02-native-crash.txt`.

Исправление остаётся в границах session/callback ownership:

- polling стартует только после final gate: `BoxService.kt:598-614`;
- каждый poll проверяет generation и session owner: `ServiceNotification.kt:254-303`;
- teardown выполняет `cancelAndJoin()` до `Mobile.close()` и TUN close: `ServiceNotification.kt:305-311`, `BoxService.kt:615-640`.

На R2 после 22 переключений и 15 суммарных start/stop новых native crash не было.

## 6. Новые lifecycle invariants

1. Permission callback относится к одной operation generation.
2. Duplicate/stale permission callback не продолжает start и не показывает terminal UI.
3. Command endpoint означает только `CoreReady`.
4. `Started` публикует только Android final gate одной актуальной generation.
5. Stale success/error/timeout/cancelled Future поглощается до UI/controller mutation.
6. Старый completion не вызывает stop/restart/cleanup новой session.
7. Mode restart выполняет не более одного lifecycle body одновременно.
8. Старый command poll полностью завершён до закрытия command endpoint/core.
9. Runtime config snapshot удаляется только актуальной operation.
10. Android notification polling принадлежит generation, а не process lifetime.

## 7. Изменённые файлы и назначение

| Файл | Ключевые функции | Изменение |
|---|---|---|
| `android/.../MainActivity.kt` | `prepareVpn`, `requestVpnPermission`, `completeVpnPermissionRequest` | generation-scoped permission flow |
| `android/.../MethodHandler.kt` | `prepare_vpn`, `mark_core_started` | проверка generation и final gate call |
| `android/.../EventHandler.kt` | status/alert sinks | generation в Android→Flutter событиях |
| `android/.../bg/VpnPermissionRequestCoordinator.kt` | `request`, `complete` | один pending request, duplicate/stale suppression |
| `android/.../bg/VpnConnectedGate.kt` | `evaluate` | полный terminal readiness predicate |
| `android/.../bg/ActiveSession.kt` | `markCommandEndpointReady`, `markTunReady`, `startEvidence`, `close` | session-owned evidence и teardown |
| `android/.../bg/BoxService.kt` | `startService`, `confirmCoreStarted`, `stopAndAlert`, `closeSession` | CoreReady/Started separation, stale error gate |
| `android/.../bg/VPNService.kt` | `openTun` | pre-establish generation check |
| `android/.../bg/ServiceNotification.kt` | `start`, `isPollingCurrent`, `stopListenSystemInfoAndJoin` | command polling ownership |
| `lib/.../connection_repository.dart` | `connect`, `reconnect`, `_prepareVpnBeforeCoreStart` | одна generation для permission→start/restart |
| `lib/.../connection_notifier.dart` | `toggleConnection`, `restartForConfigChange` | cancel pending start, explicit mode source |
| `lib/zeoncore/core_interface/core_interface_mobile.dart` | `setupBackground`, `prepareVpn`, `markCoreStarted` | CoreStarting и generation transport |
| `lib/zeoncore/session_generation.dart` | `SessionGenerationGate`, `SerialLifecycleQueue` | stale disposition и serialization |
| `lib/zeoncore/zeon_core_service.dart` | start/stop/restart/status listeners | terminal gates и stale exception swallowing |
| Android/Dart test files | 25 instrumentation + generation tests | deterministic regression coverage |

## 8. Regression tests

### Host

| Проверка | Результат |
|---|---|
| `flutter test` | PASS, 133/133 |
| targeted `session_generation_test.dart` | PASS, 13/13 |
| `dart analyze` targeted | 0 errors/warnings; 2 pre-existing info hints |
| `:app:compileDebugKotlin` | PASS |
| `:app:compileDebugAndroidTestKotlin` | PASS |
| `:app:assembleDebugAndroidTest` | PASS |
| `flutter build apk --release --split-per-abi` | PASS |
| `flutter build apk --release` universal | PASS |
| `git diff --check` | PASS |

### Android instrumentation

`VpnTestInstrumentation` выполнил 25/25 tests, failures=0 на OnePlus. Permission suite включает granted, denied, closed dialog, delayed result с latch, stop/restart pending, duplicate callback, stale result, incomplete gates и reconnect after denial. Evidence: `instrumented-tests-r2-final.txt`.

Mode-switch concurrency проверяется deterministic barriers/Completer без случайных sleeps в `test/zeoncore/session_generation_test.dart:70-166`.

## 9. Android device results

Устройство:

```text
serial: 18bfc103
manufacturer: OnePlus
model: GM1901
Android: 16 / API 36
transport: CELLULAR / LTE
package: com.zeon.hiddify
```

### Первый permission flow

На финальной R2 APK permission был сброшен штатным Android `VPN settings -> ZEON -> Удалить VPN`; app data/profile не очищались.

Generation `1785335769353470`:

```text
permission_request_started
permission_result_received reason=granted
vpn_session_start
command_endpoint_ready
start_gate_waiting
tun_open_requested
protect_result success=true
tun_open_success identity=tun-41
start_gate_completed reason=all_required_evidence
core_start_success
vpn_status Started
```

Android NetworkAgent: `VPN CONNECTED`, `VALIDATED`, `InterfaceName=tun0`, underlying cellular. DNS probe: 2/2 replies. До подтверждения permission VPN NetworkAgent отсутствовал.

Evidence: `permission-dialog-r2.xml`, `permission-success-r2-lifecycle.txt`, `permission-success-r2-connectivity.txt`, `permission-success-r2-dns.txt`.

### Smart Active ↔ Round Robin

- 20/20 обязательных switch: `core_start_success=1`, VPN agent=1, PID неизменен (`1862`), stale exception=0, fatal=0;
- DNS сразу после start: 19/20; переход 19 имел один transient miss;
- два settled rechecks: 2/2 PASS;
- stale technical dialog не появился;
- после каждого restart старый `tun-N` закрывался до открытия нового;
- первоначальный R1 `SIGSEGV` после Round Robin→Smart больше не воспроизвёлся.

Evidence: `mode-switch-20-results.csv`, `mode-switch-20-lifecycle.txt`, `mode-switch-settled-recheck.txt`.

### TCP continuity

Edge начал загрузку `50MB.zip` размером 52,43 MB. Во время пяти mode switches загрузка завершилась браузерной ошибкой. Это подтверждает, что текущая обязательная полная замена core/TUN не сохраняет уже открытый TCP socket. После каждого switch новая session и DNS восстанавливались. Evidence: `edge-download3-ui.xml`, `edge-after-switch-ui.xml`.

### Start/stop и cleanup

В десяти corrected cycles:

- start gate: 10/10;
- VPN NetworkAgent во время session: 10/10;
- `session_close_completed`: 10/10;
- crash: 0;
- NetworkAgent удалялся асинхронно; в двух снимках через 5 секунд ещё присутствовал, но последующая проверка подтверждала удаление;
- немедленный DNS probe был нестабилен на части циклов мобильной сети, при этом VPN NetworkAgent был `VALIDATED`.

Evidence: `start-stop-10-corrected-results.csv`, `start-stop-10-corrected-lifecycle.txt`, `pre-cycles-stop-vpn-agent.txt`.

## 10. Resource cleanup

| Снимок | TOTAL PSS KiB | TOTAL RSS KiB | Threads |
|---|---:|---:|---:|
| до 22 mode switches | 261126 | 409628 | 70 |
| после 22 mode switches | 311508 | 460976 | 85 |
| после последующих start/stop, core stopped | 338668 | 488472 | 87 |

PID оставался одним. Одновременно активных VPN NetworkAgent/TUN не наблюдалось. Но рост памяти и threads заметен и требует отдельного soak/profile investigation. В `BoxService.initialize()` остаются pre-existing `GOGC=off` и `efence=1`; в рамках Stage 2.1 они не менялись.

## 11. Artifacts, SHA и provenance

Core/AAR не менялся:

```text
android/app/libs/hiddify-core.aar
SHA-256 EFB8EB73D0AE2878667A3B4E7A58E0D95E5FBA1FD37ABE045CB13642805EB222
sing-box 1.13.14-zeon.1
core revision 14b8022a7412c05faeee7eb3fc09843afa5e4446
```

Validation APK:

```text
arm64 installed:
C787900C9D47327E93D6E435D549FE6B1F1EB068B61209F48E95D28E544CE2A9

universal verifier artifact:
B1D47F7A57685B2947121D638148F548937AE17F0B9B77373146A6CCC1A5D5ED
```

`verify_android_core.ps1` подтвердил ABI `arm64-v8a`, `armeabi-v7a`, `x86_64`, packaged SO hashes и Stage 2 provenance. Evidence: `verify-stage2.1-r2-universal.txt`.

Evidence root:

```text
out/stage2-1-device-validation/20260729T140800Z/
```

Manifest: `SHA256SUMS.csv` (manifest SHA at финальной генерации хранится в terminal evidence; сам manifest содержит SHA всех остальных файлов).

## 12. Rollback

Source rollback:

```powershell
git revert afdceade173cbfe12f88757178bf3bb137b41ba6
```

Не использовать `git reset --hard`.

Immutable Stage 2 rollback APK:

```text
out/stabilization/14b8022a7412c05faeee7eb3fc09843afa5e4446/zeon-1.3.0-stage2-release.apk
SHA-256 A1833DD86C0F4865496E24DABE3C0CADBC45FD6E343E72B65D9408C80CEC836A
```

Установка без удаления данных:

```powershell
adb -s 18bfc103 install -r -d out/stabilization/14b8022a7412c05faeee7eb3fc09843afa5e4446/zeon-1.3.0-stage2-release.apk
```

Stage 1 artifacts также сохранены и их SHA повторно проверены. `adb uninstall` и `pm clear` не использовались.

## 13. Оставшиеся риски и ограничения

1. Mode strategy остаётся config-level изменением; полный restart прерывает существующие TCP/UDP flows. Отдельный runtime balancer API потребует core design work и не относится к Stage 2.1.
2. Рост RSS/threads требует отдельного profiler/soak аудита; текущий тест не доказывает долгосрочную утечку, но и не позволяет заявить её отсутствие.
3. Android VPN NetworkAgent может исчезать через несколько секунд после `session_close_completed`; PFD закрывается раньше. Нужен отдельный instrumentation hook, если cleanup SLA должен проверяться синхронно.
4. Data-plane health gate намеренно не добавлен: explicit Stage 2.1 predicate завершает readiness на core/TUN/protect. DNS policy и health semantics не менялись.
5. Physical denial/closed-dialog не нажимались повторно на production profile; они покрыты deterministic device instrumentation.
6. Speedtest не исправлялся и не использовался как критерий Stage 2.1.
7. `adi-registration.properties` не изменён, не staged и не включён в commit.

## 14. Подтверждение границ

Не обновлялись и не менялись:

- sing-box `1.13.14-zeon.1`;
- `hiddify-core` / `hiddify-sing-box`;
- Go, gomobile, NDK, Gradle/AGP/Kotlin/JDK dependencies;
- Smart Active scoring/ranking;
- Round Robin distribution;
- selector interruption policy;
- DNS, routing, MTU, IPv6, UDP probe;
- серверы, профили, credentials, subscriptions и protocol implementations;
- physical-network recovery;
- Speedtest behavior.
