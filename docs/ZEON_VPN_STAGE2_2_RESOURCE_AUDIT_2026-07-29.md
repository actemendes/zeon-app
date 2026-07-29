# ZEON VPN Stage 2.2 — resource audit

Дата аудита: 2026-07-29  
Ветка: `stage2.2/resource-audit`  
Исходная реализация Stage 2.1: `afdceade173cbfe12f88757178bf3bb137b41ba6`  
Core: `sing-box 1.13.14-zeon.1`, revision `14b8022a7412c05faeee7eb3fc09843afa5e4446`  
Evidence root: `out/stage2-2-resource-audit/20260729T152709Z/`

## 1. Executive summary

Наблюдавшийся рост RSS сам по себе не был доказательством утечки. Аудит разделил два разных эффекта:

1. В исходном Stage 2.1 действительно утекали session-owned Go goroutines. После test-only GC их число росло с 66 до 73 после одного цикла, 136 после 10, 242 после 25 и 418 после 50 connect/stop. Профиль goroutines показал прирост ровно пяти `observable.Observer.process` и двух observable log factories на каждую сессию.
2. Большая часть дополнительного RSS в искусственном варианте с реально отключённым Go GC была high-water/reserve, а не растущим live heap: после 25 connect/stop + 10 restart live `HeapAlloc` составлял 5.47 MiB, но `Go Sys` — 312.60 MiB и `HeapIdle/HeapReleased` — 289.02/289.02 MiB.

Доказаны и исправлены два владельца:

- `hiddify-core/v2/hcore/stop.go:30-53`: `CloseService()` закрывал box instance, но не вызывал `StartedService.Close()`, поэтому пять observable subscribers/observers переживали session generation;
- `hiddify-core/v2/hcore/grpc_server.go:81-101,133-142`: каждый `Setup()` создавал новый observable `CoreLogFactory` и молча перезаписывал предыдущий. Два setup-level factory на цикл оставались живыми.

После обоих исправлений на одной process lifetime выполнено 20 connect/stop и 10 restart с реальным DNS/HTTPS. Все 30 запусков, 30 cleanup, 30 DNS, 30 HTTPS и 30 TUN checks прошли. После settling + test-only GC:

- goroutines: 22 baseline, 30 после всей серии — без ступенчатого роста по сессиям;
- `observable.Observer.process`: стабильно 1;
- log factories: `created=124`, `closed=123`; разница ровно 1 — текущий process-wide factory;
- platform log factories: `created=31`, `closed=31`;
- Go live heap: 5.29 → 5.93 MiB;
- `Go Sys`: 59.33 → 59.83 MiB;
- final PSS/RSS: 301,908/432,708 KiB, ниже промежуточного high-water 410,212/582,132 KiB.

`GOGC=off` и `GODEBUG=efence=1` в `BoxService.initialize()` являются Java system properties. На Android они не становятся process environment variables, которые читает Go runtime. Validation diagnostics подтвердили `os.Getenv("GOGC") == ""`, `os.Getenv("GODEBUG") == ""`; cold runtime имел `/gc/gogc:percent=100`. Следовательно, обе строки присутствуют в release, действуют на весь Java process и сохраняются между VPN sessions, но для встроенного Go runtime инертны. После старта core реальное значение дополнительно задаёт `libbox.SetMemoryLimit()` (`10` либо `100`, в зависимости от существующей настройки memory limit).

Verdict: **CONDITIONAL PASS**. Живые session-owned ресурсы в validation core после исправлений стабилизируются, crash/ANR/native panic не обнаружены, data plane работает. Условие: immutable production AAR намеренно не заменён и по-прежнему имеет SHA Stage 2. Поэтому два source commits должны пройти обычную воспроизводимую core-сборку и verifier перед production-допуском.

## 2. Scope и неизменённые области

Не изменялись:

- sing-box base, module graph и dependency versions;
- immutable `android/app/libs/hiddify-core.aar`;
- Stage 2.1 generation/readiness/permission gates;
- Smart Active scoring, Round Robin и правило смены режима только при отключённом VPN;
- selector interruption policy;
- DNS, routing, MTU, IPv6, UDP probe, protocol implementations;
- profiles, subscriptions, credentials и servers;
- physical-network recovery и Speedtest.

Validation AAR/APK собирались только в detached worktree с build tag `zeon_resource_audit`. Test-only API `runtime.GC()`, `debug.FreeOSMemory()`, `runtime.MemStats`, goroutine owner counters и `debug.SetGCPercent()` отсутствуют в production source tree.

## 3. Проверенное устройство и среда

| Поле | Значение |
|---|---|
| ADB serial | `18bfc103` |
| Manufacturer/model | OnePlus / GM1901 |
| Android | 16 / API 36 |
| Package | `com.zeon.hiddify` |
| Device transport | подключённая текущая сеть; во время основной серии Android VPN поверх cellular |
| Core | `1.13.14-zeon.1`, `14b8022a7412c05faeee7eb3fc09843afa5e4446` |
| Expected Go toolchain | Go 1.25.6 |

Использовались `adb install -r -d`, UIAutomator/UI input, `dumpsys meminfo`, `/proc/self/task`, `/proc/net/dev`, Android connectivity/service dumps и validation-only Go runtime snapshot. `adb uninstall` и `pm clear` не выполнялись; app data и профили не очищались.

## 4. Происхождение `GOGC=off`

### 4.1 Source provenance

Текущая строка: `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt:70-73`, функция `BoxService.initialize()`:

```kotlin
System.setProperty("GODEBUG", "efence=1,stacktraceback=2")
System.setProperty("GOGC", "off")
```

`git blame` ведёт обе строки к upstream Hiddify App commit `10bc427c21d1a1b037063d2a825f75487454902c` от 2024-10-20 (`v3`). Это не изменение ZEON, Stage 1, Stage 2 или Stage 2.1. В commit и коде нет комментария, issue reference или документации о предотвращаемом дефекте. Строки были частью большого перехода Hiddify на v3 architecture, поэтому их production-назначение по истории доказать невозможно.

### 4.2 Фактическая семантика

`System.setProperty` изменяет Java properties, а Go runtime читает `GOGC` из native process environment во время инициализации runtime. На release validation APK одновременно наблюдалось:

- Java `System.getProperty("GOGC") == "off"`;
- Go `os.Getenv("GOGC") == ""`;
- cold `/gc/gogc:percent == 100`;
- `NumGC` рос после запуска core.

Следовательно, текущая строка не отключает Go GC. Она устанавливается до `initializeOnce` guard, то есть повторяется при каждом вызове `initialize()`, действует process-wide как Java property и остаётся до завершения process, но не управляет Go runtime.

Фактический runtime control находится в:

- `hiddify-core/v2/hcore/start.go:129`, `libbox.SetMemoryLimit(C.IsIos || !in.DisableMemoryLimit)`;
- `hiddify-core/hiddify-sing-box/experimental/libbox/memory.go:11-25`, `debug.SetGCPercent(10)` при enabled и `100` при disabled.

В первой immutable A0-серии после `Mobile.start()` наблюдался реальный `GOGC=10`. В validation A/B variants значение менялось test-only setter после каждого успешного start.

## 5. Происхождение и влияние `efence=1`

`efence=1` добавлен тем же Hiddify commit `10bc427c...` в `BoxService.initialize()`. Репозиторий не содержит собственного reader этой Java property.

В Go 1.25 `efence` является runtime allocator debug option: каждый object allocation получает уникальную page и virtual addresses не переиспользуются. Это не настройка gVisor, Android allocator или ZEON native/cgo layer. Если бы она реально применялась, она могла бы резко увеличить virtual memory/high-water и предназначена для диагностики allocator bugs, а не для обычного Android release.

На проверенном APK Go snapshot показывал `godebug_env=""`; попытка изменить Java property после старта не меняла Go runtime. Поэтому текущая строка инертна для Go и не объясняет измеренный production RSS. В рамках Stage 2.2 она не удалялась: удаление не даёт runtime effect и не имеет доказанного stability benefit.

Отдельные B/D и A/C APK с разным manifest `efence` были построены, но runtime подтвердил отсутствие отдельного исполнимого фактора после инициализации Go. Их результаты нельзя честно выдавать за независимый efence A/B. Для реального efence-on потребовался бы process environment до загрузки Go runtime; запуск такого allocator diagnostic на production profile не нужен и потенциально опасен.

## 6. Методика измерения

Validation-only `platform/mobile/resource_audit.go` собирал:

- полный `runtime.MemStats`;
- `/gc/gogc:percent` через `runtime/metrics`;
- `runtime.NumGoroutine()` и top owner functions из `runtime.GoroutineProfile`;
- created/closed counters observable log factories;
- test-only `runtime.GC()` + `debug.FreeOSMemory()` только после полного stop.

Android receiver дополнительно собирал `dumpsys meminfo`, `/proc/self/task/*/comm`, services, connectivity и TUN counters. Для каждого connect реальная readiness означала одновременно:

- `core_start_success`;
- активный `tunN`;
- DNS check;
- HTTPS load в Edge с положительным RX/TX delta на TUN;
- последующий `session_close_completed` и исчезновение TUN после Stop.

## 7. Исходное воспроизведение

### 7.1 A0 — immutable Stage 2.1 behavior

Выполнены 50 connect/traffic/stop и 25 restart (18 в основной серии и 7 в продолжении после ограничения времени harness). Во всех завершённых циклах data plane проверялся DNS и HTTPS. Fatal scan пуст.

| Snapshot после stop + settling + forced test GC | RSS KiB | PSS KiB | Go HeapAlloc MiB | Go Sys MiB | Goroutines |
|---|---:|---:|---:|---:|---:|
| cold process baseline | 441,956 | 314,354 | 6.98 | 75.40 | 66 |
| 1 cycle | — | — | 6.52 | 75.40 | 73 |
| 10 cycles | 445,328 | 317,020 | 5.78 | 75.40 | 136 |
| 25 cycles | 448,096 | 319,447 | 6.12 | 75.90 | 242 |
| 50 cycles | 451,924 | 322,745 | 7.63 | 75.90 | 418 |
| после последующих restart | 451,296 | 322,086 | 7.62 | 75.90 | 488 |

RSS вырос умеренно, а live heap оставался малым. Но goroutine count рос почти линейно и не уменьшался после GC/settling — это уже соответствует критерию настоящей утечки.

### 7.2 Owner profile

Top goroutine owner показал:

```text
baseline observable.Observer.process = 7
after 1 session                     = 14
after 10 sessions                   = 77
```

То есть утекало семь observers на session. Пять создавались в `daemon.NewStartedService()`:

- service status;
- log;
- URLTest;
- clash mode;
- connection events.

Ещё два приходились на setup-level observable log factories. Validation counters подтвердили четыре factory creations и только два closes на цикл до второго исправления.

## 8. Доказанные владельцы

### 8.1 `StartedService` observers

`hiddify-core/hiddify-sing-box/daemon/started_service.go:82-110` создаёт пять subscribers и пять observers. `StartedService.Close()` на строках 232-238 закрывает все subscribers, после чего observer goroutines могут завершиться.

До исправления `hiddify-core/v2/hcore/stop.go` вызывал только `CloseService()`; вызов общего `Close()` был закомментирован. `CloseService()` закрывает active box instance, но не owner subscribers. Поэтому каждый stop оставлял пять goroutines.

Исправление `54a28b4a` вводит `closeStartedService()`: `CloseService()` выполняется первым, а `Close()` гарантирован через `defer` и на success, и на error path. Unit test проверяет порядок и error path.

### 8.2 Replaced `CoreLogFactory`

`hiddify-core/v2/hcore/grpc_server.go:81-101` создаёт observable factory при каждом `Setup()`. До исправления `static.CoreLogFactory = factory` терял ссылку на прежний factory без `Close()`.

Validation counters отделили platform-created factory от setup factories:

- platform factory: created/closed `1/1` на session — не владелец утечки;
- всего setup/platform factories: четыре creations на session, но до fix два setup factories не закрывались;
- constructor failure hypothesis не подтвердилась: factories были успешно созданы, а не оставлены на error path `box.New`.

Исправление `ef50b5d3` сначала успешно создаёт новый factory, затем atomically заменяет ссылку под существующим setup mutex и закрывает previous factory. Ошибка close не подменяет успешный setup. Один текущий process-wide factory остаётся ожидаемо живым.

## 9. Внесённые изменения

| Commit | Файлы | Назначение |
|---|---|---|
| `54a28b4a` | `hiddify-core/v2/hcore/stop.go`, `stop_test.go` | гарантированно закрыть пять StartedService observable owners на обоих stop paths |
| `ef50b5d3` | `hiddify-core/v2/hcore/grpc_server.go`, `stop_test.go` | закрыть заменяемый setup-level CoreLogFactory |

Изменений в Android lifecycle, Flutter, selection modes и sing-box fork нет. Оба commits независимо revertable.

## 10. A/B runtime settings

Из-за доказанной инертности Java properties фактически исполнимых Go вариантов два, а не четыре. Test-only setter применялся после каждого `Mobile.start()`; production lifecycle не содержит forced GC или GC override.

| Запрошенный вариант | Фактический Go runtime | 25 connect/stop + 10 restart | Settled PSS/RSS KiB | HeapAlloc MiB | HeapInuse MiB | HeapIdle/Released MiB | Go Sys MiB | Итог |
|---|---|---:|---:|---:|---:|---:|---:|---|
| A: current Java `GOGC=off`, Java `efence=1` | Java properties inert; core управляет GC | A0: 50 + 25 | 322,745/451,924 после 50 | 7.63 | — | — | 75.90 | actual production behavior, GC не off |
| B: standard GC, current Java efence | `GOGC=100`, efence inert | 25 + 10 | 312,073/442,336 | 5.68 | 9.82 | 48.27/47.27 | 68.08 | stable live heap |
| C: real GC off, efence off | `GOGC=off`, efence absent | 25 + 10 | 555,177/686,036 | 5.47 | 12.91 | 289.02/289.02 | 312.60 | large reserve/high-water, live heap stable |
| D: standard GC, efence off | semantic equivalent B | covered by same isolated run | same as B | same | same | same | same | no independent efence factor |

В C `NumGC` не равен нулю, потому что каждый новый `Mobile.start()` сначала снова применяет core policy, а каждый forced snapshot вызывает test-only GC. Непосредственно после validation override metric `/gc/gogc:percent` имел disabled sentinel, и между explicit events GC не запускался. Поэтому C доказывает memory impact настоящего GC-off, но не означает, что production Java property его включает.

### 10.1 Разделение final memory

| Категория, KiB | Real GC off | GOGC=100 | Final source fixes |
|---|---:|---:|---:|
| Total PSS | 555,177 | 312,073 | 301,908 |
| Total RSS | 686,036 | 442,336 | 432,708 |
| Java heap PSS | 7,380 | 7,964 | 7,340 |
| Native heap PSS | 46,232 | 46,108 | 47,280 |
| Code PSS | 84,264 | 84,448 | 84,552 |
| Stack PSS | 1,976 | 1,912 | 1,940 |
| Graphics PSS | 60,532 | 60,392 | 60,284 |
| Private Other PSS | 340,656 | 97,364 | 86,540 |
| System PSS | 14,137 | 13,885 | 13,972 |

Главный A/B разрыв — `Private Other`, согласованный с Go heap reserve/mmap high-water. Java, native heap, code, stack и graphics практически одинаковы. Это отличает reserve от утечки живых Java/native объектов.

## 11. Threads, goroutines и session owners после fix

Финальная exact-source серия:

| Snapshot | RSS KiB | PSS KiB | Go HeapAlloc MiB | Go HeapInuse MiB | Go Sys MiB | NumGC | Goroutines | Threads | Log factory created/closed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fresh baseline | 350,304 | 226,563 | 5.75 | — | 17.02 | 1 | 32 | 58 | 1/0 |
| after first 10 + settled | 425,264 | 295,100 | 5.33 | 8.98 | 59.33 | 527 | 28 | 68 | 41/40 |
| next-series baseline | 444,228 | 313,931 | 5.29 | — | 59.33 | 597 | 22 | 67 | 44/43 |
| +10 connect/stop | 582,132 | 410,212 | 5.78 | 9.62 | 59.83 | 1,120 | 30 | 73 | 84/83 |
| +10 restart | 432,488 | 301,688 | 5.93 | 9.84 | 59.83 | 1,644 | 30 | 73 | 124/123 |
| final 30 s settling | 432,708 | 301,908 | 5.93 | 9.84 | 59.83 | 1,646 | 30 | 72 | 124/123 |

Наблюдаемый high-water после активной серии вернулся с 582,132 RSS к 432,708 KiB. Goroutines и owner counters не растут на четыре factory creations за цикл: закрываются все заменённые factories, остаётся ровно один process-wide current factory. Linux/Android process threads колеблются из-за Flutter, Binder, Chromium/Okio workers, но не растут ступенчато на каждый lifecycle cycle.

Проверенные потенциальные владельцы:

| Owner | Результат |
|---|---|
| `StartedService` five observables | доказанная утечка; исправлена |
| setup `CoreLogFactory` | доказанная утечка; исправлена |
| platform log factory | стабильно created=closed на session |
| ActiveSession/TUN/PFD | TUN исчезал после каждого успешного stop в финальной automated серии |
| command endpoint/gRPC | нет линейного остатка в goroutine owner profile; final control-buffer/keepalive workers process-wide и стабильны |
| ServiceNotification/status polling | не показал session-linear growth после fix |
| EventChannel/Flutter subscriptions | thread/goroutine counts стабилизировались; отдельного duplicate owner не найдено |
| network callbacks | нет session-linear goroutine/thread signature |
| URLTest/Smart Active/UDP probe | session workers больше не остаются через StartedService observables; ranking/algorithms не менялись |
| gVisor/KCP timers | process-wide KCP schedulers стабильны в final profile |

## 12. Android device results

### 12.1 Automated lifecycle/data-plane

Финальный validation APK с обоими source fixes:

- первая серия: 10/10 connect, cleanup, DNS, HTTPS, TUN;
- вторая серия: 10/10 connect/stop и 10/10 restart, все DNS/HTTPS/TUN checks успешны;
- итог: 30/30 starts, 30/30 cleanup, 30/30 DNS, 30/30 HTTPS, 30/30 active VPN agent;
- app-scoped fatal scan в automated lifecycle blocks: нет `FATAL EXCEPTION`, `SIGSEGV`, `SIGABRT`, Go panic, ANR или fatal signal для `com.zeon.hiddify`.

ADB transport несколько раз кратковременно уходил offline и получал новый transport id. Устройство восстанавливалось через `adb reconnect`; app crash events при этом отсутствовали. Неполные harness runs с transport failure не использованы как PASS evidence.

После screen-off в общесистемном crash buffer повторялся `SIGABRT` процесса `/vendor/bin/hw/android.hardware.nfc-service.nxp` (`phNxpNciHal_write_unlocked`). PID/uid/executable не относятся к ZEON. Это отдельный дефект NFC HAL/ROM; его нельзя приписывать core и нельзя скрывать как пустой system-wide fatal scan.

### 12.2 App traffic regression

После установки exact final validation APK:

- startup gates: `command_endpoint_ready`, `tun_open_success`, successful post-TUN protect, `start_gate_completed`, `core_start_success` для одной generation;
- Edge HTTPS: TUN RX/TX `7,593/5,553` → `38,010/17,034` bytes;
- Telegram foreground/background: RX `132,873` → `5,858,722`, TX `46,644` → `435,640` bytes; личные сообщения не читались и не сохранялись;
- YouTube short playback: RX `6,327,285` → `12,137,781`, TX `619,679` → `1,089,067` bytes;
- TCP browser download attempt: RX `13,581,808` → `15,055,733`, TX `1,114,172` → `1,187,288`; flow продолжал работать, но удалённый endpoint не передал весь заявленный файл за окно наблюдения;
- raw UDP DNS request к public resolver получил валидный response с matching transaction id `0x1234` через активный TUN;
- screen-off 15 s / wake / Telegram resume: TUN сохранился и counters выросли RX `16,987,346` → `17,163,378`, TX `1,246,591` → `1,357,399`.

Первый `adb shell ping www.google.com` непосредственно после TUN readiness вернул `unknown host`, хотя Edge/Telegram/YouTube и raw UDP DNS реально передавали данные через TUN. Это shell-UID/resolver observation, а не false Connected: app data plane и TUN deltas доказаны. Причина требует отдельной DNS shell-path проверки и не исправлялась в resource audit.

## 13. Regression tests

| Test | Result | Evidence/классификация |
|---|---|---|
| New Go unit tests | PASS | `go test ./v2/hcore`, Go 1.25.6 |
| Go targeted with host-compatible production tags | PASS | `v2/config`, `v2/hcore`, `platform/mobile` |
| `go test ./...`, Go 1.25.6, no tags | NOT ALL PASS | pre-existing vet diagnostics; config corpus requires `with_quic/with_wireguard/with_awg`; profile test requires warp tag/module |
| full production Android tags on Windows | ENV LIMITATION | `with_naive_outbound` excludes cronet files on Windows; `tfogo_checklinkname0` linkname incompatible on this host |
| Flutter tests | PASS 133/133 | `flutter-test.txt` |
| Android compile androidTest | PASS | `:app:assembleDebugAndroidTest` |
| Android instrumentation | PASS 25/25 | deterministic Stage 2.1 lifecycle/permission/TUN suite on the unchanged Android bridge; `failures=0` |
| 20 real connect/stop after fix | PASS | two exact-source blocks, DNS/HTTPS each cycle |
| 10 real restart after fix | PASS | DNS/HTTPS each cycle |
| Telegram/TCP/UDP/YouTube | PASS with TCP scope note | short device regression above |
| ZEON crash/ANR/native panic | PASS in tested window | app-scoped fatal scans empty; отдельно зафиксирован unrelated vendor NFC HAL SIGABRT |

Windows host default Go had become 1.26.3 and reproduced the known Psiphon TLS layout panic. Tests relevant to this audit were rerun with explicit `GOTOOLCHAIN=go1.25.6`; dependency/toolchain was not updated. `go test ./...` failures listed above existed independently of the two resource patches and were not suppressed.

## 14. Artifact hashes

| Artifact | SHA-256 | Status |
|---|---|---|
| immutable production `android/app/libs/hiddify-core.aar` | `EFB8EB73D0AE2878667A3B4E7A58E0D95E5FBA1FD37ABE045CB13642805EB222` | unchanged Stage 2/2.1 AAR |
| validation-only AAR with diagnostics + two fixes | `3F9F33542FC8401EDB306F88D8876A945BF1ED2FAAA5BB44C297AD8FABAE5928` | not production |
| final arm64 validation APK | `0422B30F16766899A174B7E9C192C1B1387BC69B630A05EC03F539DCEA09A8A7` | device evidence only |
| Stage 2.1 rollback arm64 APK | `C787900C9D47327E93D6E435D549FE6B1F1EB068B61209F48E95D28E544CE2A9` | immutable rollback |
| Stage 2.1 rollback universal APK | `B1D47F7A57685B2947121D638148F548937AE17F0B9B77373146A6CCC1A5D5ED` | instrumentation/rollback |

## 15. Evidence index

Основные доказательства:

- `A0_actual_current_full/`, `A0_actual_current_restart_tail/` — исходные 50 connect/stop + 25 restart;
- `A0_enhanced_owner_localization2/` — goroutine owner localization;
- `OWNER_COUNTER_3/`, `PLATFORM_COUNTER_2/` — factory ownership counters;
- `C_GOGC_OFF_EFENCE_INERT/` — real test-only GOGC off;
- `D_GOGC_100_EFENCE_INERT/` — GOGC 100;
- `FINAL_SETUP_FIX_10/`, `FINAL_SETUP_FIX_TAIL2_10_10/` — exact final source validation;
- `FINAL_APP_REGRESSION/` — Telegram, YouTube, TCP, UDP, screen-off/on и startup evidence;
- `resource-summary.csv` — нормализованная memory/resource table;
- `flutter-test.txt`, `go-test-*.txt`, `android-assemble-debug-androidtest.txt` — host regression logs.

Manifest содержит 875 evidence files (detached source/build worktree намеренно исключён):

- `evidence-sha256.csv`: `F1101FF4B02AE4F29EF5EFCFEEC295D8BFFB1AFE7D809749BBBFBFDE8201F0E3`;
- `evidence-sha256.json`: `40ED8FE17DBD3181ECFC1BA929DAEADF72974AAFD431F6174A42AF0FACB2ADA7`.

Реальные profile contents, endpoints, UUID, passwords, keys, subscription URLs и DNS query history в evidence не сохранялись. Перед manifest generation все text/XML/JSON/CSV evidence прошли redaction IPv4/MAC/URL/SSID/BSSID/profile label. Созданный во время foreground check Telegram UI dump был удалён, потому что UI hierarchy потенциально могла содержать личные chat labels; traffic proof сохранён только как TUN counters.

## 16. Rollback

Source rollback без destructive reset:

```text
git revert ef50b5d3
git revert 54a28b4a
```

Artifact rollback:

```text
adb -s 18bfc103 install -r -d out/stage2-1-device-validation/20260729T140800Z/zeon-1.3.0-stage2.1-validation-r2-arm64-release.apk
```

Production AAR rollback фактически не требуется: `android/app/libs/hiddify-core.aar` не заменялся и его SHA остаётся `EFB8...222`.

## 17. Оставшиеся риски и verdict

Оставшиеся риски:

1. Два исправления находятся в source commits, но ещё не упакованы в immutable production AAR. До controlled rebuild установленный production artifact сохраняет исходную goroutine leak.
2. Короткая серия не доказывает отсутствие долгосрочной native/Flutter leak; нужен 6–12 h soak после production AAR rebuild.
3. Один process-wide current `CoreLogFactory` остаётся до следующего Setup/process exit. Counters доказывают bounded delta=1; если architecture потребует явный process shutdown, нужен отдельный owner contract.
4. ADB USB transport был нестабилен; это ограничило некоторые непрерывные harness runs, но не совпало с app crash evidence.
5. Shell-UID DNS `unknown host` при рабочем app data plane требует отдельной DNS-path диагностики.
6. `GOGC`/`GODEBUG` Java properties являются misleading dead settings. Их cleanup можно сделать отдельным non-functional commit, но текущий audit не доказал production runtime effect и потому их не удалял.
7. Full host `go test ./...` всё ещё содержит существующие tag/platform/vet ограничения; они не вызваны resource patches.

Вердикт: **CONDITIONAL PASS**.

Условие перехода в PASS: воспроизводимо пересобрать production AAR с commits `54a28b4a` и `ef50b5d3`, проверить embedded provenance/SHA verifier, повторить 20 connect/stop + 10 restart и Android instrumentation на этой immutable AAR. В пределах validation artifact доказано, что число живых session-owned Go resources после повторных lifecycle cycles стабилизируется; PASS не основан только на отсутствии crash.

## 18. Final device addendum

После screen-off Android показал PIN keypad. Обходить lock, читать или менять PIN запрещено. Поэтому последний foreground regression session нельзя было остановить UI-кнопкой. Это не подменяет cleanup result: до него exact-source harness уже выполнил 30/30 graceful stops. Для безопасного завершения test-only process и возврата immutable artifact выполнен package update `adb install -r -d`, который сохраняет app data и уничтожает старый process/VpnService. После update `tunN` отсутствовал.

Android instrumentation потребовал debug target, содержащий Kotlin runtime. Попытка запустить test runner против minified release target закономерно завершилась harness-only `NoClassDefFoundError: kotlin.jvm.internal.Intrinsics`; это не production core crash. После установки ранее подготовленного release-signed debug target suite выполнил 25/25 tests, `failures=0`, включая:

- monotonic/stale generation;
- startup success, exception, timeout, stop/restart during start;
- duplicate/stale TUN ownership и repeated ownership cycles;
- idempotent teardown;
- permission granted, denied, dialog closed, delayed/duplicate/stale result;
- command endpoint without TUN, TUN without core success, stale core success;
- reconnect after permission failure without process restart.

Физический reset permission и повторное нажатие системного Allow после resource-only Go fixes не выполнялись из-за PIN lock. Android lifecycle files не менялись, deterministic permission suite прошёл, а physical permission flow был доказан Stage 2.1 report. Это остаётся одной из причин `CONDITIONAL PASS`, а не объявляется новым physical PASS.

После instrumentation на телефон повторно установлен immutable Stage 2.1 rollback APK. Pulled installed `base.apk` имеет SHA-256 `C787900C9D47327E93D6E435D549FE6B1F1EB068B61209F48E95D28E544CE2A9`, точно совпадающий с rollback source artifact; активного TUN после установки нет. `adb uninstall`/`pm clear` не выполнялись.
