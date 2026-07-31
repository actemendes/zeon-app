# ZEON VPN Stage 2 — техническая валидация на Android, 2026-07-29

## 1. Executive summary

Вердикт: **CONDITIONAL PASS для build/lifecycle baseline; допуск к production/data-plane не выдан**.

Stage 2 APK устанавливается и запускается на физическом OnePlus GM1901 с Android 16. Упакованный APK и AAR имеют ожидаемые SHA-256, `libhiddify-core.so` загружается на ARM64, cold start не дал Java/native crash, Go panic или ANR. Release-signed validation build прошёл на этом устройстве все 13 instrumented lifecycle/ownership tests, включая 100 циклов владения PFD и 20 быстрых ownership restart. Flutter suite прошёл 126/126. Immutable Stage 1 APK устанавливается поверх данных и затем Stage 2 восстанавливается тем же способом; device-side SHA обоих APK совпадает с локальными immutable artifacts.

Однако реальный VPN/data-plane не был запущен. До проверки ZEON на телефоне отсутствовал. После первой установки приложение открыло onboarding с предложением создать либо ввести аккаунт; сохранённых профилей не было. Создание внешней учётной записи или изменение credentials не было разрешено задачей. Поэтому DNS/HTTPS через VPN, Telegram, Speedtest, видео, TCP/UDP/QUIC, реальные протоколы, manual switch, Smart Active, Round Robin и emergency switch на Android нельзя считать пройденными.

Linux validation выявил реальный data race в ZEON Smart Active monitoring. Он воспроизводится тем же тестом и на точном Stage 1 source tree, а Stage 1 → Stage 2 diff затронутых директорий пуст. Это **предсуществующий ZEON defect, а не регрессия 1.13.14**, но он остаётся риском и не позволяет считать concurrency-поверхность полностью чистой.

## 2. Проверенное устройство

| Поле | Фактическое значение | Доказательство |
| --- | --- | --- |
| ADB serial | `18bfc103` | `preflight-redacted.txt` |
| Manufacturer | OnePlus | `preflight-redacted.txt` |
| Model | `GM1901` | `preflight-redacted.txt` |
| Android release | `16` | `preflight-redacted.txt` |
| SDK | `36` | `preflight-redacted.txt` |
| Экран | включён, keyguard не показывался | `preflight-redacted.txt` |
| Сеть | Wi-Fi, `INTERNET`, `NOT_VPN`, `VALIDATED`; SSID/IP/MAC удалены | `preflight-redacted.txt` |
| Питание | USB, battery 100% на preflight | `preflight-redacted.txt` |

Все ADB-команды выполнялись с явным `adb -s 18bfc103`. `adb uninstall` и `pm clear` не выполнялись.

## 3. APK, AAR и core provenance

| Variant | Artifact | Ожидаемый и фактический SHA-256 | Result |
| --- | --- | --- | --- |
| Stage 1 | AAR | `04453FE46DDEC27DB8A4B9F859FB084D19D5F9121E709D3457BD52BABD8359E5` | verifier PASS |
| Stage 1 | APK | `2FA51176B2A7536C66FA73403D0ADAB15756FDC0B602813F4D6DC34DF7A55AAF` | verifier PASS; device SHA совпал |
| Stage 2 | AAR | `EFB8EB73D0AE2878667A3B4E7A58E0D95E5FBA1FD37ABE045CB13642805EB222` | verifier PASS |
| Stage 2 | APK | `A1833DD86C0F4865496E24DABE3C0CADBC45FD6E343E72B65D9408C80CEC836A` | verifier PASS; device SHA совпал |

Stage 2 package: `com.zeon.hiddify`, `versionName=1.3.0`, `versionCode=103001`, `minSdk=24`, `targetSdk=36`. Установка: `adb install -r -d`, exit 0.

Проверенная embedded provenance Stage 2:

- runtime fork version: `1.13.14-zeon.1-14b8022a7412c05faeee7eb3fc09843afa5e4446`;
- upstream: `SagerNet/sing-box v1.13.14`, commit `25a600db24f7680ad9806ce5427bd0ab8afe1114`;
- ZEON/core revision: `14b8022a7412c05faeee7eb3fc09843afa5e4446`;
- Hiddify compatibility tree: `c917889df67c1604b5e5bb82e70be7958d8ddc1b`;
- ZEON sing-box patch tree: `4381c26b40cd6be38845fe597bb9285fbc0999d6`;
- Go `1.25.6`, gomobile `v0.1.11`, NDK `28.2.13676358`;
- tags: `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack`;
- AAR ABI: `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`; APK ABI: `arm64-v8a`, `armeabi-v7a`, `x86_64`;
- `source_dirty_for_core_build=false`; reproducible timestamp policy `SOURCE_DATE_EPOCH=0`, empty build ID policy.

Verifier проверил AAR/APK hashes, ABI entries, packaged/post-strip native hashes и provenance strings. На телефоне `nativeloader` дважды сообщил успешную загрузку ARM64 `libhiddify-core.so`.

## 4. Состояние телефона до data-plane проверки

ZEON отсутствовал в списке сторонних пакетов до установки. У первой установки `firstInstallTime == lastUpdateTime == 2026-07-29 13:09:52`. Onboarding содержал действия «СТАРТУЕМ…» и «Я уже имею аккаунт», но не содержал профилей/серверов. Доказательство: `stage2-install.txt` и `device-onboarding-state.txt`.

Нажатие регистрации означало бы создание внешней учётной записи и credentials. Оно намеренно не выполнялось. Вход в существующий аккаунт также не выполнялся. Следовательно, отсутствовала безопасная возможность построить реальный config и вызвать VPN start.

Это ограничение состояния устройства, а не наблюдаемая ошибка Stage 2. Вместе с тем оно блокирует заявленный критерий «VPN реально передаёт трафик», поэтому PASS невозможен.

## 5. Установка, запуск, core/service/TUN

- Stage 2 cold start: `Status: ok`, `LaunchState: COLD`, `TotalTime=925 ms` для первой проверки; после rollback restore — `296 ms`; после финального relaunch — `277 ms`.
- Java/native crash, Go panic, SIGSEGV, SIGABRT и ANR не обнаружены.
- `ApplicationExitInfo` содержит только ожидаемые `PACKAGE UPDATED` и harness `FORCE STOP`, не crash.
- На onboarding UI связывается один `VPNService`; `startForegroundCount=0`.
- После `am force-stop` service record исчезает и PID отсутствует; после UI relaunch создаётся один bound service record снова.
- Активного platform VPN agent и TUN на onboarding нет. Это корректно и не засчитывается как VPN success.
- Реальные `Mobile.start`, command endpoint, session generation, Android PFD и post-TUN protect probe на production core не активировались из-за отсутствия профиля.

## 6. Android instrumented lifecycle tests

Первый обычный `connectedDebugAndroidTest` не установился поверх release: `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, потому что стандартный debug signer отличался. Приложение не удалялось. Без изменения production-кода был собран validation APK, подписанный тем же локальным release certificate через injected Gradle signing properties. SHA certificate immutable release APK, validation APK и androidTest APK совпал: `8c767dc4657bb13ccfee900b4b7cacc8f794027e6544650ef85d006bdc9f8ee7`.

Результат на `GM1901 - 16`: **13/13 completed, 0 skipped, 0 failed**. После suite immutable Stage 2 APK немедленно восстановлен и его device SHA проверен.

Покрытие 13 тестов:

1. `CoreStartupGate`: successful start требует endpoint readiness; start exception; timeout; stop-during-start; restart-during-start.
2. `VpnSessionCoordinator`: generation строго монотонна; stale external generation не заменяет текущую.
3. `TunDescriptorOwner`: duplicate open отклоняется и новый PFD закрывается; validation/protect failure закрывает PFD; stop-during-open отклоняет stale PFD; 100 open/close ownership cycles не дают роста `/proc/self/fd` больше `+2`; 20 rapid restart ownership cycles идемпотентны.
4. `ActiveSession`: два конкурентных `close()` дают один стабильный teardown order `clients → core → server → platform → network`, PFD закрыт, новые операции запрещены.

Ограничение: это реальные Android/PFD/process tests, но с test descriptors/fakes; они не равны 20 реальным VPN start/stop и 10 реальным core restart.

## 7. Запрошенные ADB/data-plane сценарии

| Сценарий | Result | Что доказано / почему не выполнено |
| --- | --- | --- |
| Install/cold launch | PASS | real device, immutable APK, native SO load, no immediate crash/ANR |
| 20 VPN start/stop | NOT RUN | нет аккаунта/профиля; 100 PFD ownership cycles прошли instrumented |
| 10 real restart | NOT RUN | нет core session; 20 ownership restart cycles прошли instrumented |
| Stop/restart during start | PARTIAL PASS | instrumented gate passed; production `Mobile.start` не запускался |
| Telegram Saved Messages/file | NOT RUN | без активного VPN тест не валидирует Stage 2; личные чаты не открывались |
| Speedtest ×5 | NOT RUN | отдельный Speedtest не установлен; browser run без VPN бессмысленен |
| Видео/seek/quality/background | NOT RUN | нет активного VPN |
| Большая TCP-загрузка/checksum | NOT RUN | нет активного VPN |
| UDP/DNS burst/QUIC/HTTP3 | NOT RUN | нет активного VPN |
| Manual selector switch | NOT RUN on device | Go selector/interrupt tests passed; established flow не создавался |
| Round Robin | NOT RUN on device | `protocol/group` и balancer Go tests passed |
| Smart Active Auto | NOT RUN on device | Go functional tests passed без race; race run выявил defect ниже |
| Emergency switch | NOT RUN | нет тестового profile/server; безопасная targeted injection невозможна |
| Screen off/short idle | NOT RUN as VPN test | без core/TUN не проверяет требуемое поведение |
| False Connected | NOT OBSERVED, NOT FULLY PROVEN | UI оставался на onboarding и VPN не объявлял Connected; path после real start не выполнялся |

Telegram установлен (`org.telegram.messenger`), Edge/YouTube/Rutube доступны, но запускать их без реального VPN и выдавать direct-network traffic за Stage 2 traffic было бы ложной проверкой.

## 8. Resource snapshots

Onboarding Stage 2 process snapshot:

- PID `6311` на снимке;
- threads `53`;
- `VmRSS=300068 kB`, `VmSize=23415920 kB`;
- `dumpsys meminfo`: `TOTAL PSS=218863 kB`, `TOTAL RSS=357776 kB`;
- один bound `VPNService`, `startForegroundCount=0`;
- ноль active `NetworkAgentInfo` с VPN transport и ноль TUN-like links.

ADB shell не имеет права читать `/proc/<app-pid>/fd`, поэтому значение FD для production process не выдумывалось. Own-process FD/PFD проверен instrumented stress: 100 циклов, assertion `after <= before + 2`. Реальный trend RSS/FD/threads после 20 VPN start/stop и 10 core restart не измерен, поскольку core не запускался.

## 9. Linux host и race validation

WSL host по умолчанию имел другой Go, поэтому каждый обязательный запуск выполнялся с `GOTOOLCHAIN=go1.25.6` и отдельными GOPATH/GOMODCACHE/GOCACHE/GOTMPDIR. Фактически: `go version go1.25.6 linux/amd64`. Go/gomobile/NDK проекта не обновлялись.

### 9.1 sing-box full suite

`go test -ldflags=-checklinkname=0 ./...` в Stage 2 `hiddify-sing-box`: **PASS, exit 0**. Прошли тестируемые DNS, route/rule, selector, balancer, monitoring, libbox и другие пакеты; UoT, mux, QUIC/Hysteria, WireGuard/AWG в части пакетов имеют только compile/no-test coverage. Psiphon replacement не обновлялся.

### 9.2 Обязательные race scopes

| Scope | Result |
| --- | --- |
| `./common/interrupt/...` | PASS |
| `./common/urltest/...` | PASS |
| `./common/monitoring/...` | **FAIL: DATA RACE** |
| `./protocol/group/...` | PASS |
| `./protocol/group/balancer/...` | PASS |
| `./route/...` | PASS |
| `./dns/...` | PASS |
| `./experimental/libbox/...` | PASS |

Race локализован тестом `TestActiveProbePresentationCannotOverwriteNewerFullStorage`:

- writer: `common/urltest/mergeURLTestHistory`, `urltest.go:80-104`, вызван из `OutboundMonitoring.applyResult`, `outbound_monitoring.go:2160`;
- reader: `OutboundMonitoring.PublishActiveProbePresentation`, `active_probe.go:205-209`;
- параллельные goroutine созданы в `active_probe_test.go:397-424`;
- race detector сообщил несколько конфликтов полей `URLTestHistory`, затем тест упал с `race detected during execution of test`.

Classification: **pre-existing Stage 1 ZEON defect**.

Доказательства классификации:

1. Тот же exact-Go race command над архивом root commit `f6650c782c72d7e7260827b2f8f1eb9d3d95cd76`, sing-box tree `70dc263d60846a4fc66f357b7b227941d4d54d2c`, воспроизвёл те же стеки и exit 1.
2. `git diff --exit-code f6650c... HEAD -- common/monitoring common/urltest` вернул 0.
3. В чистом official `v1.13.14` директории `common/monitoring` нет; код относится к ZEON layer.

Это не новая Stage 2 regression, но race потенциально затрагивает одновременную публикацию active probe и full-generation результата. Реальное влияние на Android Smart Active требует отдельного исправления и device regression test; в этой задаче production-код не менялся.

### 9.3 hiddify-core и config corpus

Нетегированный `hiddify-core go test ./...` дал non-zero:

- старые `go vet` diagnostics в `v2/hcore/tunnelservice`;
- Hysteria2/WireGuard/AWG fixtures ожидаемо не зарегистрированы без production tags;
- `v2/profile/test` не нашёл WARP outbound в минимальном host build.

Targeted config corpus с `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_conntrack` прошёл: **PASS, exit 0**. Единственный исключённый tag — `with_naive_outbound`: bundled Linux Cronet archive использует `.crel.text`, которую GNU `ld 2.38` в Ubuntu 22.04 не понимает. Full production-tag host linking поэтому классифицирован как environment/linker limitation; Android AAR с этим tag уже прошёл verifier и загрузился на ARM64.

### 9.4 Flutter

`flutter test`: **126/126 PASS**, exit 0. В том числе шесть `SessionGenerationGate` сценариев и safe diagnostic envelope tests.

## 10. Реальные config semantic diff и протоколы

Реальных ZEON profiles на телефоне не было. Поэтому запрещённые данные не извлекались и в evidence отсутствуют. Следующие действия не выполнены и не считаются успешными:

- redacted fingerprint реального профиля;
- Stage 1/Stage 2 effective-config generation и semantic diff;
- `CheckConfig` обоими core для реальных VLESS/VMess/Trojan/Shadowsocks/Hysteria2/TUIC/WireGuard/AmneziaWG/Psiphon;
- сравнение selector membership, selected/default outbound, route/DNS final, MTU, IPv6, UDP/QUIC и extended fields;
- Android connect/restart/stop по каждому протоколу.

Обезличенный committed Stage 2 corpus проверен и проходит с нужными feature tags. Он покрывает структуру VLESS, VMess, Trojan, Shadowsocks, Hysteria2, WireGuard, AmneziaWG, selector, URLTest, Round Robin, Smart Active, routing/DNS/MTU, но не заменяет реальный Stage 1 ↔ Stage 2 diff.

## 11. Manual switch, Smart Active и emergency policy

Go tests в `common/interrupt`, `protocol/group` и `protocol/group/balancer` прошли, включая сохранение external TCP/UDP при обычном selector switch и emergency predicate semantics. Race-free scope `common/urltest` также прошёл. Это подтверждает unit-level port Stage 1 policy.

Не доказано на Android data plane:

- `switch_type=manual interrupt_external=false` при живом TCP/UDP;
- selector-only switch без full core restart;
- использование нового outbound новым соединением при сохранении старого;
- regular/better-score Smart switch без external interruption;
- защита от stale session generation в реальном callback stream;
- confirmed emergency после свежего outbound-specific evidence;
- отсутствие switch loop и конфликтов UDP probe с пользовательским QUIC.

Обнаруженный monitoring race непосредственно повышает важность этих будущих тестов.

## 12. Psiphon TLS

Текущий `replace/psiphon-tls/unsafe.go:41-45` содержит init guard, сравнивающий layout собственной и стандартной `tls.ConnectionState`. Stage 1 → Stage 2 diff всего replacement равен нулю.

Ранее написанный Stage 2 migration report утверждал Windows panic. В текущей воспроизводимой проверке это **не подтвердилось**:

- exact Go `1.25.6 windows/amd64`, parent dependency graph, `go test -run '^$' ./experimental/libbox`: PASS;
- exact Go `1.25.6 linux/amd64`, тот же graph: PASS;
- полный Windows `go test ./...` дошёл до единственного `dns/transport/hosts.TestHosts` failure; `protocol/psiphon` собрался, init panic отсутствовал;
- `go list -deps ./protocol/psiphon` подтверждает наличие `github.com/Psiphon-Labs/psiphon-tls` в closure;
- полный Linux sing-box suite прошёл.

Standalone запуск nested replacement без parent graph неприменим: его минимальный `go.mod` не содержит зависимостей, предоставляемых parent module, и оба host остановились на missing modules до init. Этот запуск не использован для вывода.

Технический вывод: **доказательств host-layout panic на текущих зафиксированных Stage 1/Stage 2 sources и Go 1.25.6 нет; сам guard не представляет подтверждённую Android-опасность**. Но реальный Psiphon profile/server на телефоне отсутствовал, поэтому Android connect/DNS/HTTPS/restart/stop и cleanup Psiphon остаются непроверенными. Это residual compatibility risk, а не подтверждённый crash.

## 13. Найденные дефекты и ограничения

### Доказанный дефект

**D1 — concurrent mutation/read `URLTestHistory` при active-probe publication и full result commit.**

- Severity: medium/high для Smart Active correctness; фактическая Android частота неизвестна.
- Stage 2 regression: нет, идентично Stage 1.
- Evidence: `linux-race-tests.txt`, `linux-stage1-monitoring-race.txt`.
- Production fix в рамках validation не вносился.

### Environment/pre-existing failures

- Windows `dns/transport/hosts.TestHosts`: пустой host result; ранее классифицирован как upstream/environment, не Android regression.
- `hiddify-core` старые vet warnings в tunnelservice.
- Full production-tag WSL link с `with_naive_outbound`: GNU ld 2.38 не поддерживает секцию Cronet `.crel.text`.
- Standard debug androidTest signer несовместим с release; решено совместимо подписанным validation APK без uninstall/data clear.

### Не проверено из-за состояния телефона

Весь реальный data plane, live core/TUN/PFD lifecycle, реальные profiles, selector switching, Smart/Round Robin UI, Telegram/Speedtest/video/TCP/UDP/QUIC и Android Psiphon.

## 14. Rollback

Rollback фактически выполнен:

1. `adb -s 18bfc103 install -r -d <Stage1 APK>` — success.
2. Device SHA Stage 1 — `2fa51176...55aaf`, совпал с immutable artifact.
3. Stage 1 cold launch — status ok, PID создан, immediate crash/ANR/panic отсутствовал.
4. `adb -s 18bfc103 install -r -d <Stage2 APK>` — success.
5. Device SHA Stage 2 — `a1833dd8...836a`, совпал.
6. Stage 2 cold launch повторно прошёл; immutable Stage 2 оставлен установленным.

Данные приложения не очищались, uninstall не применялся. Поскольку это была fresh install без профилей, сохранность существующих профилей на этом конкретном телефоне проверить было невозможно.

Для будущего rollback AAR без `git reset --hard`: восстановить immutable Stage 1 `hiddify-core.aar` в `android/app/libs`, пересобрать APK, проверить `2026-07-28-stage1.json`, затем установить через `adb install -r -d`. Generated bridge contract в Stage 2 сохранён совместимым со Stage 1.

## 15. Основание вердикта

### Почему не FAIL

- Stage 2 не показал crash/ANR/panic на физическом ARM64 устройстве.
- APK/AAR provenance и device hashes точны.
- Android instrumented suite 13/13, Flutter 126/126.
- Full Linux sing-box suite прошёл.
- Семь из восьми обязательных race scopes прошли.
- Единственный race строго воспроизведён на Stage 1 и отсутствует в Stage 1 → Stage 2 diff, то есть не является новым defect порта 1.13.14.
- Rollback и обратный restore работают.

### Почему не PASS

- Нет ни одного доказанного байта, прошедшего через Stage 2 VPN на телефоне.
- Не запускались real core/TUN/command endpoint/protect probe.
- Не проверены основные протоколы, Telegram, Speedtest, video, TCP, UDP и QUIC.
- Не проверены manual/Smart/emergency selector transitions на live sessions.
- Не выполнен semantic A/B реальных profiles.
- Предсуществующий Smart Active race остаётся неисправленным.

Итог: **CONDITIONAL PASS означает, что artifact и baseline механизмы технически жизнеспособны, но Stage 2 нельзя продвигать как проверенный VPN build до data-plane прогона с разрешённым аккаунтом/профилями и до отдельного решения по race D1.**

## 16. Evidence

Каталог: `out/stage2-validation/20260729T100807Z/`.

Основные файлы:

- `preflight-redacted.txt` — устройство, battery, connectivity и storage, сеть обезличена;
- `artifact-verification.txt` — Stage 1/2 verifier;
- `stage2-install.txt`, `stage2-startup-redacted.txt` — установка/cold start/native load;
- `device-onboarding-state.txt` — отсутствие profiles и onboarding gate;
- `instrumented-tests.txt` — отклонённая debug-signature попытка;
- `release-signed-validation-build.txt` — совместимо подписанный validation build;
- `instrumented-tests-release-signed.txt` — 13/13 device tests;
- `rollback-device-install-corrected.txt` — Stage 1 rollback и Stage 2 restore;
- `device-resource-current-state.txt`, `device-ui-service-cleanup.txt`, `device-final-crash-scan.txt`;
- `linux-go-test-all.txt` — полный Linux sing-box suite;
- `linux-race-tests.txt` — восемь race scopes;
- `linux-stage1-monitoring-race.txt` — контрольный Stage 1 race;
- `linux-hiddify-core-go-test-all.txt`, `linux-hiddify-core-tagged-tests.txt`, `linux-config-corpus-feature-tags.txt`;
- `windows-sing-box-go-test-all.txt`, `psiphon-tls-parent-graph-host-layout.txt`, `psiphon-tls-host-layout.txt`;
- `flutter-tests.txt`.

Per-file SHA-256 записаны в `evidence-sha256-manifest.json`. SHA-256 самого manifest: `98524658A1D5175D0B70F61458C029D022B92DBA67A3E70AF8E966A54D09459A`.

Evidence не содержит UUID, passwords, private keys, subscription URL, profile JSON, server endpoints, DNS queries или Telegram messages. SSID, IP и MAC в preflight обезличены.

## 17. Что владелец должен проверить позже

Сначала нужен разрешённый тестовый аккаунт/набор обезличенных профилей на этом устройстве. В одинаковых условиях Stage 1/Stage 2 выполнить:

1. 20–100 реальных VPN start/stop и минимум 10–20 real core restart с generation/TUN/PFD/FD/RSS/thread snapshots.
2. DNS, HTTPS и transferred-byte assertions после каждого connect; запрет считать UI `Connected` достаточным.
3. Telegram Saved Messages/file, 5 Speedtest на одном сервере, video seek/quality/background, sustained TCP download с checksum.
4. UDP, DNS bursts и HTTP/3/QUIC; проверить, что UDP probe не прерывает пользовательский flow.
5. Manual, regular Smart, better-score и confirmed emergency switch при живых TCP/UDP; проверить `interrupt_external` и отсутствие full core restart.
6. Round Robin и Smart Active readiness/stale-generation UI на нескольких серверах.
7. Read-only Stage 1/Stage 2 effective-config semantic diff для каждого реально доступного protocol, отдельно Psiphon.
8. Короткий screen-off/idle, затем отдельный длительный Doze и 6–12-hour soak.
9. Позднее вне лабораторной проверки: Wi-Fi ↔ mobile, разные вышки/операторы, смена IP, городская поездка, IPv6-only/NAT64 и OEM matrix.

До этих проверок Stage 2 должен оставаться validation candidate, а не считаться доказанно более стабильным production core.
