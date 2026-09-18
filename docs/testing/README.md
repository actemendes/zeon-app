# Требования к тестированию ZEON

Версия контракта: **REGRESSION-v1.4**, 2026-09-11. Это требования и порядок работы,
а не отчёт о прошедших проверках или готовности версии 1.5.0.

## Три документа вместо отдельных планов на каждый запуск

- [MATRIX.md](MATRIX.md) — постоянный SHORT, полный каталог, точный Auto/Telegram
  сценарий и ручная проверка после перезагрузки.
- [PLAN.md](PLAN.md) — проверенная исходная точка, ограничения и очередь задач.
- Этот README — разделение разработки и тестирования, требования к среде,
  доказательствам и передаче результата.

Эта папка — версионируемый источник требований к тестам приложения. Менять критерии
нужно здесь, отдельным проверяемым diff; не создавать параллельные матрицы в Temp
или описаниях задач. Knowledge Base хранит архитектуру, общий workflow и ссылку
на этот контракт; TickTick — актуальные статусы, блокеры и ссылки на evidence.
Общий процесс: `/opt/zeon-knowledge/AI-AGENT-GUIDE.md`; операции и расположение
инструментов: `/opt/zeon-knowledge/06-OPERATIONS/Runbooks.md` через `ssh zeon-server`.

## Разработка и проверка — отдельные задания

1. Разработчик читает текущую задачу и предыдущий результат, проверяет Git state,
   воспроизводит дефект доступным минимальным способом. Цикл:
   reproduce → trace → compare → root cause → fix → targeted test.
2. Одно исправление — один осмысленный коммит. Неизвестную staged/unstaged/untracked
   работу сохранять. Нельзя начинать новую recovery-копию для обычного исправления.
3. Разработчик передаёт **зафиксированный кандидат** отдельному тестовому агенту
   или исполнителю команд. Передача ниже достаточна; новый длинный промпт не нужен.
4. Тестер проверяет TARGETED acceptance задачи и один SHORT на Windows и Android.
   Он не меняет продуктовый код и не начинает следующую задачу. Проблема тестового
   инструмента отделяется от дефекта приложения; его исправление фиксируется.
5. FAIL возвращается разработчику с воспроизводимым сценарием. Повторяются
   затронутые проверки, а не вся история. Новый candidate требует оценки влияния.
6. Полный FULL выполняется перед выпуском. SHORT не доказывает FULL или релиз.

Для чисто документационного изменения достаточно проверки документации; запуск
приложения не требуется. Для продуктового исправления успешная сборка, analyzer,
unit/widget или native tests не заменяют реальные проверки двух платформ.

## Отдельная Apple acceptance: APPLE-TARGETED-v1

Apple-стенд не наследует PASS Windows/Android. Для инфраструктурной задачи
`6aad153d8f085e121ad13499` выполнять только строки Apple из [MATRIX.md](MATRIX.md),
один выбранный сценарий за команду; длинную продуктовую матрицу не запускать.
Команды и fixture contract: [scripts/README.md](../../scripts/README.md#ios-test-lab).

Simulator запускает production Flutter widgets/ConnectionNotifier с тестовым
`ConnectionRepository`. Его native bootstrap отключён только при сочетании
`targetEnvironment(simulator)` и `ZEON_IOS_SIMULATOR_LAB`. Метка результата всегда
`UI_LOGIC_ONLY`, `real_ios_vpn=false`: стек сети Simulator принадлежит macOS.
Текущий импорт SIM03 проверяет metadata parser и передачу профиля connection owner;
полный UI-import с записью в реальное хранилище пока NOT_RUN.

Device runner использует XCUITest для UI и собственный URLSession для двух HTTPS
целей. Это другой процесс/application sandbox, не Runner и не PacketTunnel.
Ответ каждой цели: свежий `nonce`, ожидаемые `marker` и `egress`; TLS проверяется
системой. До/после туннеля нужен direct baseline, при VPN — выход A/B. Provider
health-check, один UI Connected, IP без nonce или результат Simulator недостаточны.
Live USB round trip `devicectl device info processes` с присутствующим процессом
`ZeonPacketTunnel` должен попасть внутрь окна подтверждённого VPN-трафика.
В отчёте сохраняется только boolean присутствия, не список процессов.
Cached `list devices` этого не доказывает.

В режиме `directEgress=discover` прямой baseline определяется самим iPhone до Start:
оба независимых ответа должны совпасть, иметь валидный IP и отличаться от A/B.
Baseline фиксируется в памяти на весь case, после остановки не переобучается и не
пишется в evidence. Mac и iPhone могут использовать разные underlay/выходы.
Native journal получает PASS только после явного конца выбранного сценария и cleanup;
нулевой XCTest failureCount в teardown сам по себе недостаточен (setup мог упасть).
Отказ HTTPS сохраняется как whitelist-категория причины и номер цели, без адресов,
response body или текста системной ошибки. Controller извлекает такой receipt и
при XCTest FAIL, отделяя ошибку baseline/environment от неподтверждённого VPN.

Диагностическая сборка отдельно включает `ZEON_IOS_LAB`: host записывает абсолютную
lease в App Group, PacketTunnel отказывает без lease/после истечения и отменяет
туннель по локальному таймеру независимо от Mac. Lease нельзя автоматически
продлевать при возврате приложения. Это test hook, не доказательство поведения
обычной сборки. Реальная lease/controller-loss приёмка остаётся обязательной.
Обычная сборка пока BLOCKED для unattended device run: автономное восстановление
без hooks не подтверждено. Не выдавать diagnostic PASS за functional PASS.

Результат сначала сохраняется как INTERRUPTED; только законченные тесты, проверенные
артефакты и cleanup дают PASS. Отдельно отмечать app/environment/external-path/unknown.
При отсутствии устройства/signing/fixture/receipt — BLOCKED. Пропущенный XCTest
не считается PASS. SIGTERM завершает дочерние процессы и cleanup; SIGKILL оставляет
INTERRUPTED, следующий запуск удаляет только Simulator с сохранённым ownership.
Уничтожение Mac/USB ещё требует физического drill; lease code review его не заменяет.

Evidence по умолчанию: абсолютный `$HOME/Library/Logs/ZEON/ios-lab/<run-id>`.
В нём source SHA/dirty, artifact/core hashes, OS/toolchain, времена шагов, verdict,
cleanup, минимальные безопасные receipts. Сырые device logs, screenshots, fixture
contents и provisioning не копировать в evidence. Native runner оставляет последний
sanitized journal в собственном Documents для последующего восстановления.

Передача отдельному тестеру: clean SHA + manifests из `out/installers/ios/lab`,
один Simulator run, повтор для проверки cleanup и device preflight. Device VPN
не запускать при отсутствующем dedicated runner development profile, fixture или
доказанном совпадении установленной диагностической сборки. Не удалять/переустанавливать
пользовательскую ZEON, профили или данные ради устранения блокера. Установка диагностической
сборки поверх существующей требует отдельного решения владельца устройства.

Непокрыто до device commissioning: настоящий PacketTunnel и native/egress correlation,
физическая потеря USB/контроллера, обычная functional сборка, IPv6/leaks, полный UI import,
сохранение A/B после перезапуска и системные VPN permission prompts. Эти строки не
повышаются в PASS по успешной компиляции. KB final sync/закрытие TickTick — только
после достижения конечной цели по AI-AGENT-GUIDE.

## Частота и бюджет

| Набор | Когда | Объём |
|---|---|---|
| TARGETED | При исправлении | Исходный дефект и затронутая причина; необходимые платформы/режимы |
| SHORT | После законченного продуктового исправления 01–10 | S01–S04 и S06, один цикл, обе платформы; S05 отдельно выполняет пользователь |
| FULL | Этап 11 перед выпуском | R01–R21, P01–P05, все применимые ветки и серии; reboot только вручную |

Один проход — одна задача и контрольный результат за 60–90 минут активной работы.
Это граница до сохранения результата/передачи, а не обещание PASS. Не запускать
следующий этап автоматически. Прогоны на одном устройстве не выполнять параллельно.
Независимые read-only проверки можно объединять; один наблюдатель на устройство.

Ожидания выполняет конечная команда с дедлайном. Лёгкие события собирать постоянно,
снимки routes/DNS/processes/listeners — на границах и при ошибке. Сохранять run ID,
PID и время создания управляющего процесса, event cursor, начало/конец шага и verdict.
При потере контроллера без конечного результата — INTERRUPTED, не PASS.
Не повторять устойчивый FAIL до случайного успеха и не опрашивать логи часами.

Connect и cancel-retry: **45 секунд** до подтверждённой готовности. Bootstrap
учитывается отдельно; бюджет записывается до запуска. Для Windows cancel в 01/R04:
**150 секунд** наблюдения после отмены, без поздней активации. Не увеличивать пороги
ради PASS; продлённая диагностика не меняет результат исходного измерения.

## Среда и безопасный запуск

- **Windows:** подготовленная локальная машина, TUN / System Proxy / Local Proxy.
  Сетевыми тестами управляет независимый standalone Agent через служебный sing-box.
  Принятый 09.09 endpoint — `127.0.0.1:17890`; актуальные процессы, транспорт через
  физический интерфейс и запросы агента перепроверять перед разрушительными тестами.
  Обычный Desktop Agent исторически зависел от ZEON; его доступность не доказательство
  независимости. Запускать crash из такого канала нельзя. Подробности — Runbooks.
- Служебный proxy, его watchdog и настройки не принадлежат тестируемой ZEON.
  ZEON и тестовые клиенты не должны наследовать HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/
  NO_PROXY и варианты регистра от управляющего агента. Маршрут служебного транспорта
  не должен подменять тестовый трафик или создавать обход проверяемых правил.
- Не запускать одновременно два ZEON, владеющих TUN/system proxy. Для networking
  нужен обычный артефакт; startup-validation, запрещающий VPN Start, не подходит.
  Специальный harness не заменяет UI-нажатия и приёмку обычной сборки.
- **Android:** физическое ADB-устройство, только VPN/TUN. Отдельный validation package
  и тестовые данные; production package и пользовательские данные не стирать.
  Режимы Proxy на Android не тестировать. Миграция старой настройки в VPN — задача 03.
- До сценария сохранить исходную сеть, proxy/PAC/WinHTTP, DNS, routes, interfaces,
  listeners, настройки Android VPN/per-app/always-on/lockdown. Указать доступные
  серверы A/B, Auto, недоступный тестовый endpoint и версию fixture без секретов.
- Fault injection делать на тестовых данных, не на production серверах/БД.
  Потерю сети на хосте моделировать только с сохранённым каналом управления либо
  конечным автономным сценарием восстановления. Иначе BLOCKED, а не рискованный запуск.
- Firewall хоста не менять. Изменение firewall/проверка чистой установки — отдельная
  согласованная disposable-среда этапа 10; обычный host smoke её не заменяет.
- Автоматический reboot не запускать. Windows R16-W выполняет пользователь.
  Отсутствующий ручной результат отдельно MANUAL/NOT_RUN; он не блокирует передачу
  агентского отчёта, но не превращается в PASS и не закрывает задачу 02/релиз.
- Перед аварийным тестом проверить план восстановления именно тестируемой сети.
  Существующий helper служебного proxy не обещает очистить ресурсы ZEON. Ручное
  восстановление допустимо после фиксации FAIL, не считается штатным cleanup.

## Что считается доказательством

Общие для каждой проверки требования:

- UI `Connected` подтверждается core/native state и свежим трафиком. Для выбора
  сервера сопоставить user intent → provider → storage → config → конкретный native
  leaf → flow → UI в одной сессии. Группа `select`/`balance` без leaf недостаточна.
- HTTPS: две независимые заранее доступные цели, новый nonce/run ID, проверка TLS
  и ожидаемого status/body. API проверять отдельно: его ошибка не равна отказу VPN.
- Windows TUN: клиент без явного proxy + реальный TUN/route/outbound. System Proxy:
  клиент действительно использует системные настройки, без явного proxy override.
  Local Proxy: клиент направлен на порт ZEON; системные proxy/default route не меняются.
- Android: независимый UID, подтверждённая VPN Network и фактический flow.
  Один `adb shell curl` не доказывает пользовательский VPN-трафик.
- Cleanup: нет старого data-plane listener, TUN/маршрутов и трафика старой сессии;
  принадлежащие ZEON настройки возвращены к исходным. Не удалять чужой proxy/PAC.
  Служебный management endpoint сам по себе не является утечкой.
- IPv4 не доказывает IPv6. Без IPv6 underlay нельзя поставить PASS проверке его утечек.
  Domain/TLS, полезные routing и DB/error fixes остаются preserve-first на каждом шаге.
- Не сохранять секретные профили, токены, идентификаторы подписок и содержимое чатов.
  Не читать чаты и не отправлять сообщения контактам для теста Telegram.

## Передача тестов

Исполнитель получает один короткий блок (значения заполняются перед запуском):

```text
Task/stage: <TickTick ID и конкретный результат>
Candidate: <branch, полный SHA, dirty=false либо точный patch hash>
Contract: REGRESSION-v1.4, <Git SHA документации>
Artifacts: <Windows/Android paths, SHA256, native provenance, build flags, SDK>
Scope: TARGETED + SHORT; required_cases=<ID/platform/mode/branch/iteration>
Repro: <исходные условия, точные действия и ожидаемое изменение>
Environment/fixture: <устройства, сеть, безопасные метки A/B, исходные настройки>
Known failures: <ID, task ID, исходный run; независимые или блокирующие>
Evidence directory: <Temp/zeon-app-testing/<run-id>>
Stop: <дедлайн, запрет перехода к следующей задаче, восстановление среды>
```

Один source candidate на обеих платформах. Неизменившиеся артефакты не пересобирать
без причины, но проверять native provenance и hashes. REUSED допустим только с
ссылкой на исходный run и доказанной совместимостью candidate/artifact, контракта,
fixture и среды. Новый SHA после merge с тем же деревом или docs-only коммит не даёт
автоматический PASS: явно доказать эквивалентность применимых исходников и условий.

## Результат и размещение файлов

В Git — требования, переиспользуемые тесты и инструменты. Исполняемые тесты уже
живут в `test/`, Android source sets, `hiddify-core/`, `scripts/`, `tool/`;
не переносить их в эту папку и не создавать новый framework ради требований.
Новые runtime logs, screenshots и report-файлы — в
`Z:\Zeon-Envelope\Temp\zeon-app-testing\<run-id>`, постоянные кэши — `Caches`.
Готовые installable/distributable сборки создаются только через `scripts/build.ps1`
или `scripts/build.sh` и публикуются в `out/installers`; в evidence сохраняются их
путь и SHA-256, а не ещё одна копия бинарника.
Не добавлять новые `out/`, `.codex-*`, временные checkout и архивы в корень проекта.
Старые неизвестные файлы не удалять массово: отдельный аудит владельца и ценности.

Windows lifecycle harness собирается действием `windows-runtime` через canonical
`scripts/build.ps1` и запускается `scripts/windows_runtime_lab.ps1`. Он управляет
`ConnectionNotifier`, настройками и proxy selector через внутренние Riverpod API,
не кликами. Поддерживаемые конечные сценарии: connect, S02, фазовый S06,
manual-proxy и возврат auto-proxy. Harness сохраняет test-only compile guard,
portable data, 45-секундный connect contract, отдельный cleanup timeout и
150-секундное наблюдение поздней активации S06. Его `PASS` — результат только
указанного сценария/режима; он не заменяет SHORT/FULL или ручной S05.

Прямой remote-controller для `ZEON-W10-LAB` не использует историческую локальную
VM: он публикует version/build неизменяемо, запускает продуктовую Scheduled Task
под выделенным `ZEONRuntime` и передаёт immutable JSON v2 через SSH/SCP. Пользователю
разрешён только batch logon, интерактивный и RDP logon запрещены; elevated token
нужен для TUN, а watchdog/recovery остаются под `SYSTEM`. Пароль principal не
сбрасывается при redeploy; dedicated roaming-состояние ZEON очищается на границах
каждого run, поэтому CurrentUser DPAPI не переносит повреждённое состояние. Controller поддерживает
bounded `preflight`, `connect`, S02, фазовый S06, ручной/Auto selector и все три
Windows network mode. Fixture хранится локально под CurrentUser DPAPI, на lab — под
LocalMachine DPAPI вне evidence; plaintext короткоживущий и удаляется после
secret-scan. Delta-recovery меняет только совпавшее run-owned состояние, проверяет
baseline и никогда не перезагружает машину. Результат Windows Server 2022 не является
Windows 10 compatibility evidence и не доказывает профиль Administrator.

Android lifecycle harness собирается действием `android-runtime` в изолированный
application ID и использует отдельный compile-time guarded entrypoint
`tool/android_recovery_runtime.dart`. Он без кликов вызывает production
`connectionNotifierProvider`: проверяет S02 и обе фазы S06, держит каждое окно
late activation 150 секунд, выполняет retry/реальный HTTPS/stop и сохраняет JSON
в private app support. Это TARGETED evidence lifecycle; UI-ветки S01/S03/S04
по-прежнему требуют отдельного SHORT и не становятся PASS из результата harness.

Фактическая приёмка прямого контура 12.09.2026 завершена статусом
`TEST_CONTOUR_READY_WITH_PRODUCT_FAILURES`: выполнены local/system proxy, S02,
обе фазы S06 с полным 150-секундным наблюдением, manual→Auto, bounded TUN,
timeout reconciliation и финальный повторный connect. Канонический подробный
результат вне Git: `C:\ZEON-LAB\evidence\test-contour-readiness.json`, локальная
hash-verified копия —
`Z:\Zeon-Envelope\Temp\ZEON-W10-LAB\readiness\test-contour-readiness.json`.
Product FAIL доменного health отдельного balanced leaf и несогласованности Auto с
native selector не скрыты; они привязаны к TickTick `6a9fbc7c8f0852d54c2e2311` и
`6a9fbc798f08ecb120d25c30`. Каждый terminal run завершил cleanup/secret-scan, и
следующий запуск не требовал ручного ремонта машины.

На запуск достаточно `report.json`, краткого `report.md` и необходимого evidence.
Не создавать новый план, матрицу и десяток summary-файлов для каждого повтора.
Минимальные поля отчёта:

```text
schema, contract_git_sha, level, stage, task_id, run_id, started_utc, ended_utc,
source_sha, source_dirty, artifacts[{platform,sha256,native_sha,native_sha256,flags}],
environment, fixture, required_cases,
cases[{id,platform,mode,branch,iteration,status,classification,reason,
       evidence_paths,known_failure_task_id,reused_from}],
before_after_changes, unresolved, cleanup_verified, remaining_processes, next_action
```

Статусы: PASS / FAIL / BLOCKED / NOT_RUN / INTERRUPTED / N/A(reason).
REUSED — происхождение результата, а не новый запуск. MANUAL — исполнитель,
не результат. FULL-only вне SHORT: OUT_OF_SCOPE(level). Классификация отдельно:
app / environment / external-path / unknown. Для зависимого теста — BLOCKED_BY(ID).

PASS→FAIL/BLOCKED расследовать; известные независимые FAIL не скрывать и не гонять
бесконечно. Можно принять исправление при пройденном его acceptance и отсутствии
новых регрессий, явно перечислив независимые дефекты. Неполный SHORT не называть
пройденным; ручной S05 указывать отдельно. Статусы релиза и закрытие TickTick —
по AI-AGENT-GUIDE, с KB sync после достижения конечной цели.

## Изменение v1.3 → v1.4

Требования перенесены в репозиторий по решению пользователя 11.09.2026; разработка
и runtime-приёмка передаются разным исполнителям. S05 явно вынесен из агентского
запуска в ручную проверку. Каталог R/P, точный R08, 45/150 секунд, частота SHORT/FULL
и критерии трафика сохранены. Технически невозможный UI-переход в R13 отмечается
BLOCKED, а не обходится скрытым селектором. Новый номер не обнуляет старые evidence
и не переименовывает исторические FAIL в PASS.
