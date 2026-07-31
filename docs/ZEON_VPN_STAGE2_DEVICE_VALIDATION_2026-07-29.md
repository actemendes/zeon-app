# ZEON VPN Stage 2 — техническая проверка на физическом Android-устройстве, 2026-07-29

## 1. Вердикт

**FAIL.**

Stage 2 действительно запускает core и передаёт пользовательский трафик на OnePlus GM1901 как через Wi‑Fi, так и через LTE. Подтверждены Android VPN transport, активный TUN, `Mobile.start()`/command endpoint, DNS, браузерный HTTPS, Telegram, YouTube, TCP-загрузки и UDP. Выполнен 21 полный connect/traffic/stop и 10 быстрых restart. Java/Flutter/native crash, Go panic и ANR процесса ZEON не обнаружены; короткие серии не показали монотонного роста RSS или threads.

Технический допуск не выдан из-за трёх воспроизводимых результатов:

1. При первом системном запросе VPN permission UI опубликовал визуальное `Подключено/CoreReady`, хотя `Mobile.start()` не дошёл до `core_start_success`, Android VPN NetworkAgent и активного TUN не было. Это доказанный false Connected.
2. Смена `Smart Active Auto ↔ Round Robin` воспроизводимо запускает callback старой generation. Platform gate правильно пишет `stale_callback_ignored`, но Flutter/UI всё равно показывает terminal dialog `stale VPN session attempted to open TUN`; при обратном переключении VPN оставался остановленным до восстановления. Это нарушение Stage 1-инварианта «stale result не меняет актуальную сессию/UI».
3. Ни один браузерный Speedtest endpoint не дошёл до результата: `speed.cloudflare.com`, `fast.com` и `speedtest.net` завершились connection-closed/error. Тот же Cloudflare-сценарий воспроизведён на immutable Stage 1, поэтому это не новая регрессия 1.13.14, но текущий production-сценарий всё равно не удовлетворяет обязательному критерию Speedtest.

## 2. Устройство и chain of custody

| Поле | Фактическое значение |
| --- | --- |
| ADB serial | `18bfc103` |
| Manufacturer / model | OnePlus / `GM1901` |
| Android | `16`, API `36` |
| Package | `com.zeon.hiddify` |
| App | `versionName=1.3.0`, `versionCode=103001`, target SDK 36 |
| Финальная сеть | validated LTE, Wi‑Fi отключён владельцем во время проверки |
| Финально установленный вариант | immutable Stage 2; device APK SHA совпал с локальным |

Все ADB-вызовы выполнялись с `-s 18bfc103`. `adb uninstall`, `pm clear`, удаление профилей/данных и изменение credentials не выполнялись. Stage 1 и Stage 2 ставились только через `adb install -r -d`; профиль сохранился.

Evidence: [preflight-redacted.txt](../out/stage2-device-validation/20260729T112449Z/preflight-redacted.txt), [final-device-state.txt](../out/stage2-device-validation/20260729T112449Z/final-device-state.txt).

## 3. Проверенные артефакты и core metadata

| Вариант | Артефакт | SHA-256 |
| --- | --- | --- |
| Stage 2 | APK, локальный и извлечённый с телефона | `A1833DD86C0F4865496E24DABE3C0CADBC45FD6E343E72B65D9408C80CEC836A` |
| Stage 2 | AAR | `EFB8EB73D0AE2878667A3B4E7A58E0D95E5FBA1FD37ABE045CB13642805EB222` |
| Stage 1 control | APK | `2FA51176B2A7536C66FA73403D0ADAB15756FDC0B602813F4D6DC34DF7A55AAF` |
| Stage 1 control | AAR | `04453FE46DDEC27DB8A4B9F859FB084D19D5F9121E709D3457BD52BABD8359E5` |

Проверенная provenance Stage 2:

- fork version: `1.13.14-zeon.1-14b8022a7412c05faeee7eb3fc09843afa5e4446`;
- upstream: `SagerNet/sing-box v1.13.14`, commit `25a600db24f7680ad9806ce5427bd0ab8afe1114`;
- core revision: `14b8022a7412c05faeee7eb3fc09843afa5e4446`;
- Hiddify compatibility tree: `c917889df67c1604b5e5bb82e70be7958d8ddc1b`;
- ZEON sing-box patch tree: `4381c26b40cd6be38845fe597bb9285fbc0999d6`;
- Go `1.25.6`, gomobile `v0.1.11`, NDK `28.2.13676358`;
- tags: `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack`.

Точная связь device package с этой provenance доказана совпадением полного SHA извлечённого `base.apk` и immutable Stage 2 APK.

## 4. Первое реальное подключение и false Connected

### 4.1 Первый permission flow — FAIL

После нажатия Connect были подтверждены Android VPN permission и notification permission. UI показал `Подключено`; command endpoint успел опубликовать `CoreReady`, но одновременно:

- `core_start_requested owner=android starts_core=false`;
- отсутствовал `core_start_success`;
- отсутствовал активный `tun0`/другой `tunN`;
- отсутствовал Android `ni{VPN CONNECTED}` NetworkAgent;
- DNS-проверка шла по обычной physical network, поэтому не была засчитана как VPN traffic.

Generation ложной попытки: `1785322979697824`. Это не «медленный старт»: состояние сохранялось до принудительного завершения процесса, а повторное нажатие визуального `Подключено` инициировало новый `prepare_vpn`, а не stop актуальной core-сессии.

Evidence: [first-connect-logcat-redacted.txt](../out/stage2-device-validation/20260729T112449Z/first-connect-logcat-redacted.txt), [first-connect-state.txt](../out/stage2-device-validation/20260729T112449Z/first-connect-state.txt), [false-connected-cleanup.txt](../out/stage2-device-validation/20260729T112449Z/false-connected-cleanup.txt), [false-connected-forced-service-stop.txt](../out/stage2-device-validation/20260729T112449Z/false-connected-forced-service-stop.txt).

### 4.2 Чистый повтор после выдачи permissions — PASS

После `am force-stop` без очистки данных и cold relaunch повторное подключение прошло примерно за секунду:

```text
generation=1785325352788842
tun_open_requested
protect_result source=post_tun_probe success=true
tun_open_success identity=tun-1
core_start_success
command_endpoint_ready
vpn_status Started source=flutter_core_start_confirmed
```

Android создал один VPN NetworkAgent и активный TUN. Google по HTTPS загрузился в Edge; DNS отвечал, TUN имел двусторонний прирост. `example.com` дал site-specific `ERR_EMPTY_RESPONSE`, но независимый Google endpoint работал.

Evidence: [clean-connect-logcat-redacted.txt](../out/stage2-device-validation/20260729T112449Z/clean-connect-logcat-redacted.txt), [clean-connect-state.txt](../out/stage2-device-validation/20260729T112449Z/clean-connect-state.txt), [https-google.png](../out/stage2-device-validation/20260729T112449Z/https-google.png).

### 4.3 LTE connect — PASS

После отключения Wi‑Fi подтверждена validated `MOBILE[LTE]` physical network. Чистая LTE-сессия generation `1785326662386268` прошла `Starting → CoreReady → tun_open/protect → core_start_success → Started`. Edge загрузил Google; активный TUN вырос на `121669` RX / `50331` TX байт.

Evidence: [mobile-network-transition-state.txt](../out/stage2-device-validation/20260729T112449Z/mobile-network-transition-state.txt), [mobile-first-connect-logcat-redacted.txt](../out/stage2-device-validation/20260729T112449Z/mobile-first-connect-logcat-redacted.txt), [mobile-first-data-plane.txt](../out/stage2-device-validation/20260729T112449Z/mobile-first-data-plane.txt), [mobile-google.png](../out/stage2-device-validation/20260729T112449Z/mobile-google.png).

Живой Wi‑Fi → LTE handover не засчитывался: пользователь сменил сеть посреди серии, после чего серия была остановлена и LTE проверялся с чистого connect. Новая recovery policy не добавлялась и не имитировалась.

## 5. Start/stop — 21/21 data-plane cycles

Выполнено 12 циклов на Wi‑Fi и 9 на LTE. Каждый цикл включал штатный UI connect, ожидание active VPN/TUN, DNS, HTTPS в Edge с двусторонним TUN delta, штатный UI stop и проверку отсутствия active VPN/foreground service.

| Серия | Циклы | TUN up | DNS | HTTPS | Cleanup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Wi‑Fi | 12 | 12/12 | 12/12 | 12/12 | 12/12 после завершения teardown |
| LTE | 9 | 9/9 | 9/9 | 9/9 | 9/9 |

В одном Wi‑Fi цикле `isForeground` ещё был true на раннем снимке через ~0,5 с после перехода TUN в DOWN, но последующий снимок и следующий цикл подтвердили завершившийся `session_close_completed` и отсутствие active service. Это классифицировано как transient teardown window, не orphan.

Android может оставлять объект `tun0` в состоянии `DOWN`; это не считалось active TUN. Проверялся VPN NetworkAgent и `state UP/UNKNOWN`, а после появления `tun1` — фактическое `InterfaceName` активного NetworkAgent.

Evidence: [start-stop-cycles.csv](../out/stage2-device-validation/20260729T112449Z/start-stop-cycles.csv), [mobile-start-stop-cycles.csv](../out/stage2-device-validation/20260729T112449Z/mobile-start-stop-cycles.csv).

## 6. Restart — 10/10 core/VPN restarts

Десять быстрых stop/start restart дали:

- старый VPN NetworkAgent ушёл: 10/10;
- новый VPN/TUN поднялся: 10/10;
- stale failure dialog: 0/10;
- DNS сразу после старта: 9/10; в десятом прогоне самый первый probe был слишком ранним, повтор через несколько секунд прошёл без переподключения при том же VPN.

Попытка создать параллельные `nc`/`ping` процессы через PowerShell `Start-Process` не запустилась: дочерний процесс не нашёл `adb` в PATH. Поэтому строки, помеченные `tcp_open`/`dns` в CSV, доказывают restart и последующий DNS, но **не считаются** доказательством restart-during-active-load. Активная TCP-сессия отдельно проверена при manual selector switch, см. раздел 11.

Evidence: [mobile-restarts.csv](../out/stage2-device-validation/20260729T112449Z/mobile-restarts.csv).

## 7. Telegram

Результат: **PARTIAL PASS**.

- Telegram `org.telegram.messenger` запустился через LTE VPN без `Connecting`.
- Через штатный поиск открыты «Избранное» без чтения/сохранения личных чатов.
- Отправлено одно объединённое тестовое сообщение `ZEON_stage2_mobile_test_1...3`; input очистился, сообщение появилось в chat history, pending/connecting indicator отсутствовал.
- Telegram сворачивался; после 25 секунд screen-off VPN NetworkAgent и TUN оставались активны. После разблокировки Telegram открылся без `Connecting`.
- Не требовалось открывать ZEON для восстановления data plane.

Отправка/скачивание файла не выполнены: безопасная UIAutomation последовательность файлового picker не была завершена. Это `NOT RUN`, а не PASS.

Evidence: [mobile-screen-idle.txt](../out/stage2-device-validation/20260729T112449Z/mobile-screen-idle.txt).

## 8. Speedtest — FAIL, но не Stage 2 regression

Отдельное Speedtest-приложение не установлено. Через Edge проверены три независимых web endpoint:

| Endpoint | Stage 2 result |
| --- | --- |
| Cloudflare Speed | `ERR_CONNECTION_CLOSED`, тест не начался/не завершился |
| Fast.com | error page, результата нет |
| Speedtest.net | error page, GO/result отсутствует |

Пять полных результата получить невозможно: все три реализации закрывались до результата. Это удовлетворяет пользовательскому FAIL-критерию «Speedtest регулярно не завершается».

Контроль: immutable Stage 1 установлен поверх тех же данных, на том же LTE и профиле; Cloudflare Speed воспроизвёл тот же error. Следовательно, ошибка не внесена переходом 1.13.0 → 1.13.14, но может находиться в общем Hiddify/ZEON слое, текущем outbound/server policy или маршрутизации класса Speedtest-трафика.

Evidence: [speedtest-start.png](../out/stage2-device-validation/20260729T112449Z/speedtest-start.png), [fast-result.png](../out/stage2-device-validation/20260729T112449Z/fast-result.png), [ookla-web.png](../out/stage2-device-validation/20260729T112449Z/ookla-web.png), [stage1-speed-cloudflare.png](../out/stage2-device-validation/20260729T112449Z/stage1-speed-cloudflare.png), [mobile-speedtest-logcat-redacted.txt](../out/stage2-device-validation/20260729T112449Z/mobile-speedtest-logcat-redacted.txt).

## 9. Видео

Результат: **PASS для короткой playback-проверки**.

- Публичное YouTube-видео `Me at the zoo` стартовало и полностью дошло до конца (`0:19`), без player error; за 25-секундное окно TUN получил `1129444` RX и `95291` TX байт.
- Второе публичное видео было запущено на 15 секунд без UI player error.
- Полная остановка загрузки, необходимость перезапуска ZEON и VPN disconnect не наблюдались.
- Длительный playback, многократное ручное изменение качества и часовой streaming не выполнялись.

Evidence: [mobile-youtube.txt](../out/stage2-device-validation/20260729T112449Z/mobile-youtube.txt), [youtube-play.png](../out/stage2-device-validation/20260729T112449Z/youtube-play.png).

## 10. TCP, UDP и QUIC

### TCP — PASS

Три загрузки одного 10-МБ файла завершились за `13,37`, `24,81` и `13,19` с. Размер каждого результата `10485760`; SHA каждого одинаков: `e5b844cc57f57094ea4585e235f36c78c1cd222262bb89d53c94dcb4d6b3e55d`.

Дополнительная 50-МБ ranged download во время manual selector switch завершилась с размером `52428800` и SHA `8565a714dca840f8652c5bae9249ab05f5fb5a4f9f13fbe23304b10f68252da2`.

Evidence: [mobile-tcp-downloads.csv](../out/stage2-device-validation/20260729T112449Z/mobile-tcp-downloads.csv).

### UDP — PASS

Сформирован реальный DNS query по UDP/53 к публичному тестовому resolver. Получено `83` байта ответа; одновременно активный TUN вырос на `30071` RX / `25147` TX. NTP endpoint не ответил в timeout и не засчитывался.

### QUIC/HTTP3 — NOT PROVEN

YouTube работал, но считать его transport QUIC без socket evidence нельзя. Android shell не имеет права открыть netlink для `ss -uapn`, а системный curl собран без `--http3`. Поэтому отдельный QUIC/UDP-443 flow помечен `NOT PROVEN`, не PASS.

## 11. Manual selector switch

Результат: **behavioral PASS, telemetry PARTIAL**.

Во время активной 50-МБ TCP-загрузки через UI выбран другой сервер:

- UI после возврата показал новый selected outbound с opaque fingerprint `3A088AFD52C7`;
- Android VPN NetworkAgent и active TUN не исчезли;
- после предварительной очистки Logcat не появилось `core_start_requested`, `core_start_success`, `session_close_requested` или `tun_close`: full core restart не выполнялся;
- существующая TCP-загрузка не получила early close и завершилась с ожидаемыми размером/SHA;
- после проверки возвращён `Автовыбор`.

Release build не вывел `selector_switch/switch_type=manual/interrupt_external` telemetry. Поэтому точное значение `interrupt_external=false` нельзя подтвердить строкой лога; непрерывно завершившийся TCP flow является поведенческим доказательством отсутствия принудительного закрытия в этом прогоне. Использование нового outbound новым соединением отдельно не доказано без server-side observation.

## 12. Round Robin

Результат: **PARTIAL PASS + lifecycle FAIL**.

- В настройках подтверждён исходный Smart Active; Round Robin присутствует как отдельный режим.
- После выбора Round Robin настройка отображалась как активная.
- После восстановления VPN браузерный HTTPS работал через активный `tun1`.
- Per-connection распределение между outbound нельзя доказать: release telemetry не содержит выбранный opaque outbound для каждого нового flow, а server-side observation недоступен.
- Сам переход режима вызвал restart и stale-TUN UI defect, описанный ниже. Поэтому режим нельзя признать безопасно переключаемым.

## 13. Smart Active Auto

Результат: **PARTIAL PASS + lifecycle FAIL при смене режима**.

- Smart Active был исходным режимом и восстановлен в конце теста.
- Ручной запуск проверки дал 10 видимых latency results; VPN и HTTPS остались активны.
- После возврата на `Автовыбор` UI показывал актуальный выбранный сервер.
- Не наблюдалось частого switch loop.

Release Logcat не содержит требуемые `SmartActiveSessionStart`, `SmartActiveCandidate`, `SmartActiveFirstConfirmed`, `SmartActiveSwitch`, `RealUserHealth` и selector-interrupt events. Поэтому device run не доказывает freshness generation, partial-readiness gating, emergency predicate и `interrupt_external=false` обычного Smart switch. UDP probe не был виден как отдельное событие.

## 14. Доказанный stale-generation/TUN дефект при смене режима

Smart Active → Round Robin и обратный переход воспроизвели dialog:

```text
manager start inbound/tun[tun-in]:
configure tun interface: stale VPN session attempted to open TUN
```

Ключевое доказательство обратного перехода:

```text
current generation = 1785327673704677
tun_open_requested generation = 1785327673704676
stale_callback_ignored source=tun_open
current_generation=1785327673704677
```

То есть Android/platform gate корректно отклонил старый `openTun`, но ошибка старой generation всё равно дошла до актуального Flutter dialog. В одном направлении новая VPN-сессия уже существовала на `tun1` под ошибочным dialog; в обратном переходе system VPN был остановлен. Это не duplicate active TUN leak, а неправильная propagation stale failure в UI/start orchestration.

Evidence: [round-robin-after.png](../out/stage2-device-validation/20260729T112449Z/round-robin-after.png), [round-robin-stale-tun-failure-logcat-redacted.txt](../out/stage2-device-validation/20260729T112449Z/round-robin-stale-tun-failure-logcat-redacted.txt), [smart-restore-stale-error.png](../out/stage2-device-validation/20260729T112449Z/smart-restore-stale-error.png), [smart-restore-stale-error-logcat-redacted.txt](../out/stage2-device-validation/20260729T112449Z/smart-restore-stale-error-logcat-redacted.txt).

## 15. Emergency switch

**NOT RUN.**

Безопасно сделать недоступным только текущий production server, не раскрывая/не меняя endpoint и не отключая весь интернет телефона, было невозможно. Ни DNS failure, ни physical-network loss, ни единичный timeout не выдавались за emergency evidence. Поэтому `interrupt_external=true`, confirmed-outbound evidence и отсутствие emergency loop не объявляются проверенными.

## 16. Screen-off / краткий idle

25 секунд screen-off на LTE:

- VPN NetworkAgent оставался connected;
- active TUN сохранялся;
- после разблокировки Telegram запустился без `Connecting`;
- ручное открытие ZEON для восстановления не понадобилось.

Длительный Doze не выполнялся.

## 17. Ресурсы, TUN/PFD/service

| Серия | Connected RSS, kB | Threads | Stopped RSS, kB |
| --- | ---: | ---: | ---: |
| 12 Wi‑Fi cycles | `338060..386032` | `71..74` | `449576..473836` |
| 9 LTE cycles | `384268..400268` | `69..75` | `490352..496720` |

После всех тяжёлых сценариев при активном VPN: RSS `515940` kB, threads `73`, один VPN NetworkAgent, один active `tun0`, один foreground VPNService. В пределах коротких серий RSS не рос монотонно, threads оставались стабильны. Финальный высокий RSS является high-water snapshot после Edge/Telegram/YouTube/downloads и не доказывает утечку.

ADB shell не имеет права читать `/proc/<app-pid>/fd`; production FD count не выдумывался. PFD/TUN оценивались по `tun_open_success/tun_close/session_close_completed`, состоянию активного NetworkAgent и отсутствию active TUN после stop. Долгосрочное отсутствие FD/goroutine leak без soak не доказано.

`ApplicationExitInfo` не содержит `REASON_CRASH`, `REASON_CRASH_NATIVE`, `REASON_ANR` или `REASON_LOW_MEMORY` для ZEON. Во время теста система многократно перезапускала vendor NFC HAL с SIGABRT; cmdline `/vendor/bin/hw/android.hardware.nfc-service.nxp`, PID не принадлежал ZEON и событие классифицировано как unrelated device/ROM defect.

Evidence: [application-exit-info-redacted.txt](../out/stage2-device-validation/20260729T112449Z/application-exit-info-redacted.txt), [final-device-state.txt](../out/stage2-device-validation/20260729T112449Z/final-device-state.txt), cycle CSV выше.

## 18. Протоколы и реальные профили

Профиль и список production servers использовались read-only; ни один endpoint/credential не сохранён. Release UI показывает display servers, но не раскрывает transport type. `run-as` отклонён (`package not debuggable`), а извлечение private config/credentials не выполнялось.

Поэтому нельзя честно сопоставить текущий успешный outbound с VLESS/VMess/Trojan/Shadowsocks/Hysteria2/TUIC/WireGuard/AmneziaWG/Psiphon. Для каждого типа результат: **NOT DETERMINABLE FROM AVAILABLE REDACTED DEVICE INTERFACES**, а не PASS. Psiphon Android и существующий Psiphon TLS panic в этой device-сессии не проверены.

## 19. False Connected, crash/ANR/panic

| Проверка | Результат |
| --- | --- |
| False Connected на первом VPN permission flow | **REPRODUCED / FAIL** |
| False Connected после обычного чистого start | не наблюдался; каждый `Connected` в циклах имел VPN/TUN и data plane |
| Stale error меняет актуальный UI при mode restart | **REPRODUCED / FAIL** |
| ZEON Java/Flutter crash | не обнаружен |
| ZEON native SIGSEGV/SIGABRT | не обнаружен |
| Go panic | не обнаружен |
| ZEON ANR | не обнаружен |
| Orphan active VPN/TUN после штатных stop | не обнаружен в 21 цикле |
| Orphan command client/core | прямой process handle недоступен; отсутствие active service/TUN и terminal lifecycle events подтверждено |

## 20. Сравнение со Stage 1 и rollback

Stage 1 был установлен только после воспроизводимого Speedtest failure. Профиль сохранился, VPN и TUN поднялись, тот же Cloudflare test дал connection-closed error. После A/B immutable Stage 2 снова установлен через `adb install -r -d`; извлечённый с телефона APK имеет ожидаемый SHA `A183...36A`.

Это одновременно подтверждает работоспособный APK rollback без удаления данных и классифицирует Speedtest issue как общий/pre-existing, а не Stage 2-only regression. Stale mode-switch defect на Stage 1 в этой сессии не сравнивался, чтобы не расширять изменение пользовательских настроек после уже доказанного Stage 2 FAIL.

## 21. Evidence и SHA-256 manifest

Evidence root:

```text
out/stage2-device-validation/20260729T112449Z/
```

Manifest: [SHA256SUMS.txt](../out/stage2-device-validation/20260729T112449Z/SHA256SUMS.txt)

```text
SHA256(SHA256SUMS.txt)=2c7e772ca38a09471dba54429f54df9fa007e48fdfa4cbb8c55d5768c75c0b8e
entries=39
```

Скриншоты с display-названиями production servers исключены из evidence manifest. UUID, password, private key, endpoint, subscription URL и profile JSON в отчёт/manifest не включены.

## 22. Что не проверено

- безопасная targeted emergency failure injection;
- подтверждённый QUIC/HTTP3 flow и UDP-443 socket ownership;
- Telegram file upload/download;
- 5 завершённых Speedtest — невозможны из-за воспроизводимой ошибки;
- per-connection Round Robin distribution;
- server-side proof, что новое соединение после manual switch вышло через новый outbound;
- отдельные реальные protocol profiles и Psiphon;
- restart непосредственно при успешно созданном concurrent TCP/DNS load;
- длительный Doze, 6–12-часовой soak, городские поездки, tower/operator matrix, реальный Wi‑Fi ↔ mobile handover recovery, IPv6-only/NAT64.

## 23. Что владельцу проверить позднее

1. Длительный LTE soak 6–12 часов с Telegram, streaming и периодическими DNS/HTTPS probes.
2. Реальный Wi‑Fi ↔ LTE handover в движении и при краткой потере validation.
3. Несколько вышек/операторов и OEM battery restrictions.
4. Speedtest на другом production server и прямой сравнительный capture, чтобы отделить server policy от client routing.
5. QUIC/HTTP3 с controllable endpoint и server-side packet/accounting evidence.
6. Каждый реально используемый protocol profile отдельно, включая Psiphon при наличии.
7. Targeted emergency injection на выделенном тестовом outbound.
8. Повтор mode switch после исправления stale failure propagation; критерий — старый `tun_open` может быть отклонён, но не должен показывать terminal UI/error или останавливать новую generation.

## 24. Итог

Stage 2 core `1.13.14-zeon.1` способен стабильно передавать обычный data plane на данном телефоне и выдержал короткие lifecycle/load проверки. Однако Stage 2 **не соответствует** заявленным stop-критериям из-за доказанного false Connected, воспроизводимого stale-generation UI failure при переключении Smart/Round Robin и систематически незавершающегося Speedtest. Вердикт остаётся **FAIL** до исправления и повторной device validation.

