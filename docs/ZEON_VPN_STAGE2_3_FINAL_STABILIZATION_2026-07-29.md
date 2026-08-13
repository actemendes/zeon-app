# ZEON VPN Stage 2.3 — финальная стабилизация

Дата проверки: 2026-07-29/30 (Europe/Moscow)  
Ветка: `stage2.3/final-stabilization`  
Production build source revision: `e8c06439e1864255d81f4ee89290d89cbb1b3a18`  
Последний commit с provenance: `ade8c712`  
Устройство: OnePlus GM1901, Android 16 / API 36, ADB `18bfc103`  
Пакет: `com.zeon.hiddify`  
Redacted evidence: `out/stage2-3-final-stabilization/20260729T201114Z/redacted/`  
Evidence manifest: `out/stage2-3-final-stabilization/20260729T201114Z/SHA256SUMS-redacted.txt`

## 1. Executive summary и verdict

**Verdict: FAIL для production-допуска Stage 2.3.**

Само ядро Stage 2.3 воспроизводимо собрано, содержит оба доказанных resource fix, не содержит audit-only API и прошло provenance/API/ABI verification. Доказанный Smart Active monitoring race исправлен copy-on-write snapshot model; исходный race test проходит 100 раз под Linux race detector.

Однако обязательные data-plane stop-критерии не выполнены:

- 20/20 core start, 20/20 Android VPN validation и 20/20 cleanup прошли, но реальный HTTPS прошёл только 14/20; отказы сгруппированы в циклах 12–16 и затем самопроизвольно исчезли;
- Cloudflare Speed полностью работает без VPN, но под VPN заканчивается `ERR_FAILED`; Fast.com под VPN заканчивается `ERR_CONNECTION_CLOSED`; три разных outbound из одной доступной подписки дали одинаковый результат;
- обычный HTTPS и контролируемая TCP-загрузка через VPN при этом работают, поэтому это не общий отказ TUN/DNS/TCP;
- точная серверная причина без server-side log не доказана; клиентский workaround не внесён;
- контролируемый Android HTTP/3 probe через активный VPN завершился `NetworkException error_code=1` до получения ALPN/bytes, поэтому QUIC/HTTP3 имеет статус `NOT PROVEN`;
- emergency switch не проверен: управляемого выделенного outbound не было;
- 10 restart именно на новом immutable production APK не завершены после блокировки экрана PIN;
- rollback-установка Stage 2.1 и возврат Stage 2.3 прошли, но интерактивный data-plane rollback после установки не выполнен из-за PIN lock.

Обновление sing-box, Go, gomobile, NDK, DNS/routing/MTU/IPv6 policy, Smart Active scoring, Round Robin и selector interruption policy в Stage 2.3 не выполнялось.

## 2. Production core и артефакты

| Поле | Значение |
|---|---|
| Fork | `sing-box 1.13.14-zeon.1` |
| Upstream | `SagerNet/sing-box v1.13.14` |
| Upstream commit | `25a600db24f7680ad9806ce5427bd0ab8afe1114` |
| ZEON/core build revision | `e8c06439e1864255d81f4ee89290d89cbb1b3a18` |
| hiddify-core revision | `7390740472f8e17abd281c0e10ab40eb77c971af` |
| hiddify-sing-box revision | `7f4930c76d7dbe9f08a6de01acaaca33db5bac9d` |
| Go | `go1.25.6` |
| gomobile | `v0.1.11` |
| NDK | `28.2.13676358` |
| Timestamp/build ID | `SOURCE_DATE_EPOCH=0`, empty Go build ID |

Production build tags:

```text
with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,
with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack
```

`zeon_resource_audit` отсутствует.

| Artifact | SHA-256 |
|---|---|
| `hiddify-core.aar` | `5BEC09E8AA72E385C0BB4950FE9970759725C6083F813E6DAB7BBFE436BECB00` |
| universal release APK | `F4D2C430E961024F4FA47C5292E53B5C17B4920961A5E1B85F9773596CEE53A5` |
| `classes.jar` | `959C71C4B641067BA96FA0D24BD23ADCC99F8DC063274FA4E99B2C0C07BE7B58` |

AAR per-ABI:

| ABI | AAR `.so` SHA-256 | Size |
|---|---|---:|
| arm64-v8a | `9525BD1AD7E7AA61B1C1FED190FEDF8C5533DDCD2CA591FFB49151F2F7A3A2F0` | 70,251,984 |
| armeabi-v7a | `89428B223825648FD86F45F807AA0FFD4A7F55E6DE7BE9C12FDDD7E4E745109C` | 63,275,552 |
| x86 | `8BA9FAA652E121B26888A52E8621B80D96D280DDFD5A3D6A87499FADDFDCE390` | 68,234,300 |
| x86_64 | `B3D72A10097F6CC45DDB0435AB8D59E5E44B9F5071B5A119989B0A94AFF43FD7` | 74,927,664 |

APK post-strip `.so` hashes:

| ABI | APK `.so` SHA-256 |
|---|---|
| arm64-v8a | `AF19876DD365A1C5EDE4CE804758A9A4C27E6C8A52747B9034D5A17E4109724D` |
| armeabi-v7a | `2C8317B80BA9DCD83498AF4AB7A948DBB2A9D8622650FF9FEDD3569993333997` |
| x86_64 | `FB00A7217705E6295F333A6B008EAA9FA5DDECC48114667E705890E99048FA59` |

Manifest: `baselines/android-core/2026-07-29-stage2-3.json`. `scripts/verify_android_core.ps1` прошёл полностью.

## 3. Resource fixes в production

### 3.1 `StartedService.Close`

Commit `54a28b4a` включён в ancestry production revision.

- `hiddify-core/v2/hcore/stop.go:15-42`, `Stop()`;
- `hiddify-core/v2/hcore/stop.go:45-54`, `closeStartedService()`;
- `hiddify-core/v2/hcore/stop_test.go`, success/error/order regression tests.

До fix `CloseService()` закрывал box, но не пять observable owners `StartedService`. Теперь `StartedService.Close()` выполняется через `defer` и на success, и на error path.

### 3.2 Replaced `CoreLogFactory`

Commit `ef50b5d3` включён в ancestry production revision.

- `hiddify-core/v2/hcore/grpc_server.go:99-101`, замена factory;
- `hiddify-core/v2/hcore/grpc_server.go:134-142`, `closePreviousCoreLogFactory()`;
- `hiddify-core/v2/hcore/stop_test.go:28-35`, regression test.

Прежний process-wide factory теперь закрывается до потери ссылки.

### 3.3 Доказательство владельцев

Stage 2.2 exact-source audit artifact доказал после fixes:

- `observable.Observer.process = 1`, без session-linear роста;
- setup log factories `created=124`, `closed=123`: bounded delta ровно 1 для текущего process-wide factory;
- platform factories `created=31`, `closed=31`;
- goroutines: 22 baseline, 30 после всей серии, без ступенчатого роста по session count.

В production AAR counters намеренно отсутствуют. Производственная проверка подтверждена внешними Android metrics:

| Snapshot | RSS KiB | PSS KiB | Threads |
|---|---:|---:|---:|
| cycle 1 stopped | 536,200 | 379,552 | 78 |
| cycle 5 stopped | 512,024 | 364,078 | 82 |
| cycle 20 stopped | 465,864 | 343,953 | 81 |
| final settling | 385,060 | 283,554 | 76 |

Линейного роста RSS/PSS/threads в этом коротком production run нет. FD count через `/proc/<pid>/fd` недоступен shell UID на этом Android build и не засчитывался как 0.

### 3.4 Audit API exclusion

По `strings`, `nm`, archive inspection отсутствуют:

```text
proxymobile__ResourceSnapshot
ResourceSetGCPercent
ZEON_RESOURCE_AUDIT
zeon_resource_audit
```

Java class list, `classes.jar` SHA и exported JNI symbols между Stage 2 и Stage 2.3 совпадают; diff lines = 0. ELF не имеет отдельного SONAME ни до, ни после Stage 2.3; native library name остался `libhiddify-core.so`.

## 4. Smart Active monitoring race

### 4.1 Root cause

Исходный failing test: `TestActiveProbePresentationCannotOverwriteNewerFullStorage`.

- writer: `hiddify-core/hiddify-sing-box/common/urltest/urltest.go`, `mergeURLTestHistory()`;
- caller/write path: `HistoryStorage.StoreURLTestHistory()`;
- reader: `hiddify-core/hiddify-sing-box/common/monitoring/active_probe.go:164`, `PublishActiveProbePresentation()`;
- shared object: опубликованный `*adapter.URLTestHistory`.

Storage возвращал и затем повторно мутировал тот же pointer. Presentation reader мог читать этот pointer одновременно с merge full result.

### 4.2 Fix

Commit `e8c06439e1864255d81f4ee89290d89cbb1b3a18`.

- `common/urltest/urltest.go:42-48`: `LoadURLTestHistory()` возвращает snapshot;
- `common/urltest/urltest.go:66-82`: store/merge выполняется на новом object;
- `common/urltest/urltest.go:84-103`: `cloneURLTestHistory()`, включая deep copy `IpInfo`;
- `common/urltest/urltest.go:133-148`: `AddOnlyIpToHistory()` переведён на copy-on-write;
- `common/urltest/history_storage_test.go`: immutable snapshot, caller mutation, detached load, 8 readers/1 writer, close during publish.

Lock не удерживается во время URLTest, network I/O, Flutter callback или disk operation. Scoring, TTL, readiness, generation, ordering и Smart Active state machine не менялись.

### 4.3 Race results

Linux, `go1.25.6`:

```text
go test -race ./common/interrupt/... ./common/urltest/... \
  ./common/monitoring/... ./protocol/group/... \
  ./protocol/group/balancer/... ./route/... ./dns/... \
  ./experimental/libbox/...
PASS

go test -race -count=100 ./common/monitoring \
  -run TestActiveProbePresentationCannotOverwriteNewerFullStorage
PASS (11.834s)
```

На телефоне Smart Active запущен в отдельной VPN session, выполнено пять refresh после readiness. Crash, stale generation dialog и hang не наблюдались; active mode во время VPN не менялся.

## 5. Root cause → fix/result mapping

| Дефект | Доказательство | Исправление/результат |
|---|---|---|
| 5 `StartedService` observable owners переживают stop | Stage 2.2 goroutine profile | `54a28b4a`, включён в production |
| заменяемый `CoreLogFactory` не закрывается | Stage 2.2 counters/profile | `ef50b5d3`, включён в production |
| mutable `URLTestHistory` читается во время merge | Linux race detector | COW snapshot, `e8c06439`, race PASS x100 |
| Speedtest закрывается под VPN | direct PASS, VPN FAIL, 3 outbound | точный client root cause не доказан; code не изменён |
| shell `unknown host` | ранее один transient case | сейчас не воспроизводится; DNS policy не изменена |
| HTTP/3 | Android HttpEngine error code 1 | `NOT PROVEN`; production QUIC code не менялся |
| emergency switch | нет управляемого outbound | `NOT RUN`; policy не менялась |

## 6. Первый permission flow и lifecycle invariants

После onboarding системный notification permission dialog вклинился в первый VPN permission flow. Первый attempt не дошёл до core start и **не** показал false Connected. После выдачи notification permission первый retry получил command/start timeout и также не показал Connected. Второй retry без process restart успешно прошёл одной generation:

```text
permission granted
Starting
command endpoint ready
TUN open
protect=true
core_start_success
Started
Android VPN VALIDATED
```

Таким образом исходный false Connected не воспроизведён. Но необходимость второго retry после двух системных permission dialogs остаётся подтверждённым onboarding/lifecycle UX defect и отдельной причиной не выдавать PASS.

Android deterministic suite: 25/25, включая permission granted/denied/closed/delayed/duplicate/stale, stop/restart pending, endpoint-without-TUN, TUN-without-core и stale core success.

## 7. Production Android lifecycle/data-plane run

### 7.1 Connect/stop

Итоговый automation принудительно возвращал Main tab перед каждым действием и проверял именно новый `core_start_success`, новый Android `VALIDATED VPN`, real HTTPS и отсутствие VPN agent после stop.

| Assertion | Result |
|---|---:|
| Core start | 20/20 |
| Android validated VPN/TUN | 20/20 |
| Full cleanup | 20/20 |
| HTTPS | **14/20** |

Отказы HTTPS были в циклах 12–16; cycle 17–20 снова прошли без process restart. Это исключает постоянную неправильную config, но не позволяет считать data plane стабильным.

После stop orphan VPN NetworkAgent/TUN/core service не найден. Ложный Connected в этой серии не зарегистрирован.

### 7.2 Restart

10 restart на exact production AAR **NOT COMPLETED**. Stage 2.2 exact resource source без COW-only изменения прошёл 10/10, но переносить тот результат на новый immutable APK как отдельный device PASS нельзя. После возврата Stage 2.3 экран потребовал PIN и автоматический interactive restart был остановлен.

### 7.3 Telegram, YouTube, TCP и UDP

- Telegram foreground → background → foreground через VPN: приложение сохранило data plane; app/network errors не обнаружены. Сообщения и файл не отправлялись, чтобы не читать/трогать личные чаты.
- публичное короткое YouTube video завершилось естественно; более длинное public video оставалось `PLAYING` после background/foreground;
- screen-off 25 секунд: VPN NetworkAgent остался active/validated;
- контролируемая TCP download 100 KiB завершилась; это подтверждает TCP, но не заменяет large sustained download;
- raw UDP DNS через TUN прошёл;
- пользовательский UDP/QUIC flow с доказанным transport не получен.

## 8. Speedtest isolation

### 8.1 Наблюдения

На одном телефоне и одной Wi-Fi сети:

| Scenario | Direct | ZEON VPN |
|---|---|---|
| обычный HTTPS | PASS | PASS, но 14/20 lifecycle cycles |
| 100 KiB TCP download | не требовался | PASS |
| Cloudflare Speed | полный download/upload PASS | `ERR_FAILED` |
| Fast.com | доступен direct | `ERR_CONNECTION_CLOSED` |
| три outbound одной подписки | n/a | одинаковый failure |

Пять ранее полученных UI runs были отброшены: Flutter восстановил Settings route, и automation coordinate не включила VPN. Они не используются как PASS/FAIL evidence.

### 8.2 Классификация

Дефект не является общим отказом Android TUN, DNS или TCP: validated VPN, обычный HTTPS и TCP download работают. Он также воспроизводился на immutable Stage 1 по предыдущему device report, поэтому не является regression sing-box 1.13.14.

Наиболее узкая доказанная граница: **throughput endpoint traffic ломается внутри доступного profile/subscription/server path**. Различить server policy, upstream reset, mux/PMTU/QUIC или monitoring hook без packet/server-side evidence не удалось. Поэтому:

- production MTU/DNS/QUIC/mux не менялись случайно;
- Speedtest root-cause fix commit отсутствует;
- требуются server-side timestamped close reason и controlled one-factor validation build;
- production verdict остаётся FAIL.

## 9. QUIC/HTTP3

Добавлен только `androidTest` validation client:

- `android/app/src/androidTest/java/test/com/zeon/zeon/bg/Http3ValidationActivity.java`;
- `android/app/src/androidTest/AndroidManifest.xml`;
- commit `d37f61ed`.

Android `HttpEngine` включал QUIC и передавал negotiated protocol, status и bytes только в validation log. Через активный validated VPN получено:

```text
result=failure type=NetworkExceptionWrapper error_code=1 retryable=false
```

ALPN `h3` и transferred bytes отсутствуют. Итог: **NOT PROVEN**. YouTube не засчитывался как QUIC evidence. Hook не входит в production APK/AAR.

## 10. Emergency switch

**NOT RUN.** На телефоне нет отдельного управляемого test outbound/server. Отключать всю Wi-Fi/LTE сеть или ломать production server запрещено. Emergency predicate и `interrupt_external` policy не изменялись.

## 11. Shell DNS classification

Повторная проверка при active VPN:

- shell UID = 2000;
- UID 2000 входит в Android VPN UID ranges;
- `adb shell ping` успешно разрешил публичное имя;
- raw IPv4 connectivity и raw UDP DNS через TUN работали;
- Edge, Telegram и YouTube разрешали имена.

Ранее наблюдавшийся единичный `unknown host` не воспроизведён. Итог: **TRANSIENT SHELL-UID/ANDROID RESOLVER OBSERVATION; PRODUCTION DNS DEFECT NOT PROVEN**. DNS policy не менялась.

## 12. Реальные протоколы

После validation-harness incident пользовательские app data были потеряны непрямым действием Gradle `connectedDebugAndroidTest`, который удалил target package во время cleanup. Прямая команда `adb uninstall`/`pm clear` не выполнялась, но результат нарушил требование сохранить данные; это явно фиксируется как дефект процедуры. Onboarding был повторно завершён и default subscription появилась снова.

Endpoint/credentials/config не извлекались. Безопасная UI диагностика не позволила доказать protocol type каждого outbound. Поэтому:

| Protocol | Result |
|---|---|
| VLESS | NOT IDENTIFIED |
| VMess | NOT IDENTIFIED |
| Trojan | NOT IDENTIFIED |
| Shadowsocks | NOT IDENTIFIED |
| Hysteria2 | NOT IDENTIFIED |
| TUIC | NOT IDENTIFIED |
| WireGuard | NOT IDENTIFIED |
| AmneziaWG | NOT IDENTIFIED |
| Psiphon | NOT AVAILABLE / NOT RUN |

Ни один из этих пунктов не объявляется PASS.

## 13. Host tests

| Test | Result | Notes |
|---|---|---|
| Flutter | PASS 133/133 | exact workspace |
| Android JVM | PASS / NO-SOURCE | Gradle build successful |
| Android instrumentation | PASS 25/25 | debug validation target, затем production APK возвращён |
| sing-box `go test ./...` | PASS | Linux, Go 1.25.6 |
| required race suite | PASS | Linux, Go 1.25.6 |
| original race x100 | PASS | 11.834s |
| config corpus | PASS | production-compatible tags excluding host-incompatible Naive/Cronet link |
| hiddify-core `go test ./...` no tags | NOT ALL PASS | corpus needs protocol tags; pre-existing warp profile/vet limitations |
| hiddify-core full production tags | ENVIRONMENT FAIL | WSL system linker cannot read Cronet `.crel.text`; not a Stage 2.3 compile regression |
| release AAR/APK | PASS | immutable hashes above |
| API/ABI diff | PASS | Java/JNI diff 0 |
| provenance verifier | PASS | manifest schema 2 |
| rollback install | PARTIAL PASS | both installs succeed, data preserved; rollback data-plane blocked by PIN |
| `git diff --check` | PASS | before report commit |

Два validation-harness crashes появились в `ApplicationExitInfo`: standalone test APK не содержал Kotlin runtime (`NoClassDefFoundError: kotlin.jvm.internal.Intrinsics`). Это не production path. Тот же suite был повторён через полный debug validation target и прошёл 25/25; после этого immutable production APK возвращён. В production lifecycle/media run crash, ANR, SIGSEGV, native panic и Go panic не обнаружены.

## 14. Commits

| Commit | Назначение | Revert scope |
|---|---|---|
| `54a28b4a` | закрытие StartedService observables | resource owner only |
| `ef50b5d3` | закрытие заменяемого CoreLogFactory | log factory owner only |
| `e8c06439` | immutable URLTestHistory snapshots | Smart monitoring race only |
| `d37f61ed` | isolated androidTest HTTP/3 probe | validation only |
| `ade8c712` | Stage 2.3 immutable provenance | manifest only |

Speedtest fix и DNS fix commits отсутствуют: точный client root cause не доказан. Misleading Java properties не очищались.

## 15. Rollback

Проверенная последовательность без `git reset --hard`, uninstall и clear:

1. `adb install -r -d` Stage 2.1 validation release APK — `Success`.
2. `versionCode=103001`, `versionName=1.3.0`, `firstInstallTime` не изменился.
3. `adb install -r -d` Stage 2.3 immutable release APK — `Success`.
4. Финально на телефоне установлен Stage 2.3 APK SHA `F4D2...53A5`.

Stage 2.1 rollback APK SHA:

```text
B1D47F7A57685B2947121D638148F548937AE17F0B9B77373146A6CCC1A5D5ED
```

Для source rollback необходимо отдельно revert `ade8c712`, `d37f61ed`, `e8c06439`; resource fixes `54a28b4a`/`ef50b5d3` нельзя удалять из production baseline без сознательного возврата доказанной goroutine leak.

## 16. Evidence

Redacted evidence SHA manifest:

```text
out/stage2-3-final-stabilization/20260729T201114Z/SHA256SUMS-redacted.txt
```

Основные файлы:

- `connect-stop-20-results.tsv` — 20-cycle assertions/resources;
- `connect-stop-20-logcat-redacted.txt` — generation-scoped lifecycle excerpt;
- `go-race-required.txt` и `go-race-monitoring-count100.txt`;
- `aar-api-abi-diff.txt`;
- `aar-buildinfo-soname-audit-absence.txt`;
- `provenance-verifier.txt`;
- `http3-vpn-result.txt`;
- `android-instrumentation-debug-target.txt`;
- `rollback-install-result.txt`.

Raw UI/logcat/connectivity files, которые могли содержать SSID, IP, display names или другие идентификаторы, удалены после формирования redacted evidence и не включены в manifest.

## 17. Изменённые production files

Production behavior change Stage 2.3:

- `hiddify-core/hiddify-sing-box/common/urltest/urltest.go`;
- `hiddify-core/hiddify-sing-box/common/urltest/history_storage_test.go`.

Resource production changes уже находились в исходной Stage 2.2 source ancestry:

- `hiddify-core/v2/hcore/stop.go`;
- `hiddify-core/v2/hcore/grpc_server.go`;
- `hiddify-core/v2/hcore/stop_test.go`.

Validation/provenance only:

- `android/app/src/androidTest/AndroidManifest.xml`;
- `android/app/src/androidTest/java/test/com/zeon/zeon/bg/Http3ValidationActivity.java`;
- `baselines/android-core/2026-07-29-stage2-3.json`;
- этот отчёт.

## 18. Оставшиеся риски и обязательные следующие действия

До нового production-допуска нужны не многочасовые городские тесты, а короткие блокирующие технические проверки:

1. Получить timestamped server-side close reason для Cloudflare/Fast/Ookla и выполнить one-factor A/B (mux, QUIC, MTU, monitoring hook) только validation builds.
2. Добиться 5/5 завершённых Speedtest и минимум трёх завершённых throughput web scenarios.
3. Повторить 20-cycle run до 20/20 HTTPS, затем 10/10 restart на exact production APK.
4. Доказать HTTP/3 через ALPN `h3` и bytes либо классифицировать DNS error code 1 внутри Android HttpEngine path.
5. Проверить emergency policy только на управляемом test outbound.
6. Выполнить interactive rollback connect/data-plane после разблокировки телефона.
7. Повторить first-install permission flow без interposed notification retry либо исправить его отдельным минимальным lifecycle commit.
8. Восстановить/подготовить обезличенные protocol-specific test profiles и проверить каждый доступный protocol.

## 19. Итог

Stage 2.3 успешно поставляет resource fixes и исправляет доказанный Smart Active data race без API/ABI и policy изменений. Но production-допуск отклонён: стабильность data plane не достигла обязательного порога, Speedtest root cause остаётся не полностью локализован, а QUIC/emergency/rollback data plane не доказаны. Длительный 6–12-часовой soak не является причиной этого FAIL и не включён в текущий блокирующий список.
