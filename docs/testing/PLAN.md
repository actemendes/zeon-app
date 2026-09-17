# Точка продолжения и план восстановления

Снимок обновлён **2026-09-17**. Актуальные статусы брать из TickTick; этот документ
не является автоматически обновляемой панелью и не утверждает готовность релиза.
Требования — [README.md](README.md) и [MATRIX.md](MATRIX.md).

## Откуда продолжаем

Рабочий репозиторий: `Z:\Zeon-Envelope\Projects\zeon-app`, ветка `main`.
До этого документационного коммита HEAD:
`37dca78e952cf1d819bb132c2eae2bef4f2582be`.

Это merge предыдущего main `e009e46b2be4c562467e706a03940a3f585550b1`
и recovery-кандидата `716a1e57f8094de23e066164769186cbed1c3685`.
Дерево merge и кандидата проверено: `a9b61bf82e567426550daa371dd31c63de71d8c0`.
Родители сохранены; новый откат, копия репозитория или перенос recovery не нужны.

Исторический source baseline 1.4.2:
`c68474c353c6bbb080fed1388b5ba1672c7cb400`. Тег v1.4.2 ранее не соответствовал
нужному исходному состоянию; связь опубликованного бинарника с этим SHA не доказана.
Baseline используется для сравнения поведения и причин регрессий. Дальнейшие
минимальные изменения делаются из текущего main, без слепого reset к baseline.

Toolchain кандидата: Flutter **3.38.5**, Dart **3.10.4**, совместимый `pubspec.lock`;
Go **1.25.6** использовался при проверке консолидации. Начало сборки —
[BUILD_REPRODUCIBLE.md](../build/BUILD_REPRODUCIBLE.md), но команды и paths перед запуском
сверять с текущими скриптами. Примеры старого SDK в CONTRIBUTING не являются pin.

## Что уже есть и чего это не доказывает

| Область | Фактическая точка / ограничение |
|---|---|
| Код | В main сохранены cancellation/session ownership, ранняя отправка stop, отдельный Windows command transport и generation-bound native stop proof; commits 1080cca1, 3fd056ca, b778902d, f820dff9, 716a1e57 |
| Сборка/UI | Ранее закреплён toolchain и startup markers (3e46180d); отсутствие окна не сводилось к одному продуктовому дефекту. Сборка не равна network PASS |
| Automated | По записи консолидации KB: Flutter 468 PASS / 24 SKIP, целевые Go packages PASS. В этой документационной задаче тесты не повторялись |
| Этап 00 | Закрыт пользователем как исходный замер, а не полная приёмка. Исторические FAIL/BLOCKED сохранены |
| Android | Этап 01 принят на `1.5.0+1050006` / `6713b98f`: UI-free Riverpod S02 и обе фазы S06 PASS на физическом Android 16, по 150 секунд без late activation, retry/HTTPS/stop; native instrumentation 89/89 PASS. S01 остаётся известным FAIL задачи 04; S03/S04 не повышены по незавершённому UI replay |
| Windows | Этап 01 принят на том же SHA: S02 3/3 и S06 6/6 PASS во всех режимах/обеих фазах, preflight и strict cleanup PASS. SHORT сохранил независимые FAIL: S03 domain health (задача 06), S04 Auto/native selector (задача 04). Стенд Windows Server 2022 не является Windows 10 compatibility evidence |
| Этап 03 | Принят 13.09.2026 на `1.5.0+1050010` / `9ddff9db`: Android fresh/upgrade подтвердили schema v18 и VPN-only, legacy Proxy preference мигрирована в VPN, native instrumentation 89/89 PASS на обеих изолированных установках; физический Android S02/S06 и 10/10 HTTPS PASS. Windows S02 PASS во всех трёх неизменённых режимах |
| Этап 06 | Принят 13.09.2026 на том же кандидате: `https://api.zeon-vps.online/health` дал HTTP 200 через Windows System Proxy, TUN и Local Proxy; IP fallback/TLS bypass не добавлялись. Первый TUN запуск harness завершил gRPC stream, повтор неизменённого артефакта PASS; исходный evidence сохранён |
| Этап 05 | Принят 14.09.2026 на `1.5.0+1050016` / `984d40c4`: точный R08 PASS на физическом Android VPN с двусторонним Telegram UID flow, двумя HTTPS и MTProto DC1/DC2; Windows System Proxy и контрольные TUN/Local Proxy PASS. Android R13 UI PASS: crossed manual A доказанно не пропускает пять свежих probes до/после reconnect, Auto выбирает другой concrete leaf и восстанавливает весь трафик. Дополнительно действие уведомления `Перевыбор` PASS: рабочий manual → Auto/concrete leaf без restart VPN generation, HTTP/HTTPS/MTProto PASS до и после; production endpoints не изменялись |
| Этап 04 | Принят 15.09.2026 на `1.5.0+1050050` / `afc252b6`: карточка «Сервера» следует authoritative Connected, selector snapshot восстанавливает concrete leaf после UI/provider replay. Android S01–S04/S06 и R09 PASS с Manual A→B→Auto→A, direct/ZEON HTTPS и reconnect persistence; Windows S02 3/3, manual и exact Auto System Proxy PASS. Windows UI/runtime evidence разделены между widget tests и прямым noninteractive стендом; стенд Server 2022 не является Windows 10 evidence |
| Этап 07 | Принят 14.09.2026 на `1.5.0+1050021` / `ec3104f4`: R17 PASS до подключения и при активном VPN на физическом Android и в Windows System Proxy/TUN/Local Proxy. Доменный refresh продвигает timestamp, сохраняет валидный cache и ручной выбор; подключённый refresh выполняет native restart, после него Auto имеет concrete leaf и реальный HTTPS. TLS/IP обходы не добавлялись |
| Host-lab | Отчёт 09.09 принял standalone Agent через отдельный sing-box, включая stop/crash независимость. Обычный Desktop Agent остаётся ограничением; готовность инфраструктуры не равна приёмке приложения |
| Этап 09 | Принят 14.09.2026 на том же кандидате: P03 PASS на Android и Windows во всех трёх режимах — WAL/busy timeout, независимые DB connections и competing write, integrity, key-loss fail-closed с восстановлением, URI decode-once, concurrent error dedup и redaction. Targeted Flutter 76/76 и Android instrumentation 89/89 PASS; 8 из разрешённых 10 build-итераций |
| Этап 12 | Реализован 15.09.2026 на `1.5.0+1050026` / `4322e96b`: strict per-leaf IPv6 HTTPS capability, TTL/generation/network invalidation, четыре режима, Smart Active gating и UI. Android P04 PASS без global-IPv6 underlay; Windows обычный connect 3/3 PASS, но Windows P04 `NOT_RUN` |
| Релиз | 1.5.0 не принят и не выпущен этим этапом; push/deployment не выполняются в задаче документации |

Первичные локальные evidence, не копировать в Git:

- `Z:\Zeon-Envelope\Temp\zeon-recovery-142\stage01-20260908\resume-20260909-01\report.md`;
- `Z:\Zeon-Envelope\Temp\zeon-recovery-142\stage01-local-host-20260909\S06-SYSTEM-PROXY-PASS.md`;
- `Z:\Zeon-Envelope\Temp\zeon-recovery-142\stage01-local-host-20260909\S06-TUN-PASS.md`;
- `Z:\Zeon-Envelope\Temp\zeon-recovery-142\stage01-local-host-20260909\EXTENDED-WINDOWS-CHECKPOINT-20260911.md`;
- `Z:\Zeon-Envelope\Temp\zeon-recovery-142\local-windows-host-20260909\FINAL-REPORT.md`.

Доступность файла и совместимость evidence проверяет тестер; ссылки не заменяют
проверку артефактов. Исчезнувшее или неполное evidence не повышать до PASS.

## Что сохраняем

- Полезную актуальную маршрутизацию: исправлять доказанные ошибки, не возвращать
  старую реализацию просто ради совпадения с 1.4.2.
- API через `api.zeon-vps.online`, корректные DNS/TLS/SNI; прямой IP и отключение
  certificate validation не использовать как исправление.
- Корректную работу DB/error пакета `95c43cef` → `e3d6df4f`: сначала аудит,
  затем только необходимое исправление. Не повторять автоматически backend/DB миграции.
- Разное ownership Android VPN Service и Windows core/TUN/proxy. Общий механизм
  требует тестов обеих платформ, но не принудительно одинаковой native архитектуры.

## Очередь задач

TickTick: `💤ZEON`, parent `6a9fbc3a8f08ecb120d254c7`.
Исторический parent `6a8344641824cc6689b60fbd` не перезапускать.
На момент чтения 01–11 незавершены, имеют метку `подумать`; это не новая приёмка
и не разрешение менять все статусы. Брать только текущую задачу по canonical workflow.

| Этап / Task ID | Конкретный следующий результат | Основные проверки сверх общего SHORT |
|---|---|---|
| 00 / 6a9fbc748f08c18d5f58c05a | Исторический замер завершён; не повторять весь аудит | Сохранить ограничения исходных отчётов |
| 01 / 6a9fbc768f0852d54c2e225f | Завершён 12.09.2026 на runtime-кандидате `6713b98f`: собственный acceptance PASS; независимые SHORT FAIL задач 04/06 сохранены | R03/R04/S06: Windows 3 режима × 2 фазы, Android VPN × 2 фазы; S02 reconnect/cleanup |
| 02 / 6a9fbc778f08ecb120d25be9 | После crash интернет не зависит от ZEON; корректное восстановление чужого proxy/PAC | R14–R16, ownership/RunOnce; reboot пользовательский |
| 03 / 6a9fbc788f08ecb120d25c0e | Завершён 13.09.2026 на `1.5.0+1050010` / `9ddff9db`: Android только VPN, legacy Proxy preference мигрирована, внутренние listeners сохранены | Fresh/upgrade и 89/89 instrumentation PASS; физический Android S02/S06 PASS; Windows S02 3/3 PASS |
| 04 / 6a9fbc798f08ecb120d25c30 | Переоткрыт 17.09.2026: Android regression на `1.5.0+1050058` / `3c0e8167` принят; полный cross-platform SHORT пока PARTIAL | Android S01–S04/S06 PASS; Windows runtime S02 3/3 + manual/Auto PASS, но Windows GUI S01, полный UI A→B→Auto→A и настоящий Telegram остаются NOT_RUN |
| 05 / 6a9fbc7a8f08c18d5f58c270 | Завершён 14.09.2026 на `1.5.0+1050016` / `984d40c4`: после reconnect/Auto есть конкретный native leaf и настоящий трафик | R08 Android Telegram UID flow + HTTPS/MTProto и Windows три режима PASS; Android R13 fault → reconnect → Auto recovery PASS; Android notification `Перевыбор` manual → Auto without VPN restart PASS |
| 06 / 6a9fbc7c8f0852d54c2e2311 | Завершён 13.09.2026 на `1.5.0+1050010` / `9ddff9db`: domain API сохранён и runtime-подтверждён во всех Windows режимах | P01 targeted + HTTP 200 для доменного health; без IP fallback и TLS/SNI bypass |
| 07 / 6a9fbc7d8f08c18d5f58c2b7 | Завершён 14.09.2026 на `1.5.0+1050021` / `ec3104f4`: обновление профиля до/во время VPN сохраняет ownership, cache и ручной выбор; после native restart реальный трафик и Auto/concrete leaf PASS | R17 Android + Windows System Proxy/TUN/Local Proxy; domain/TLS без IP fallback и bypass |
| 08 / 6a9fbc7e8f08c18d5f58c2d5 | Завершён 13.09.2026 на `1.5.0+1050012` / `74491004`: Android managed/per-app update, пользовательский override, TARGETED и SHORT PASS | R18/R19 и P02 PASS; IPv4 PASS; отдельная недоработка IPv6 egress вынесена в `6aa6de518f087a6320ca4572` |
| 09 / 6a9fbc7f8f08ecb120d25d4a | Завершён 14.09.2026 на `1.5.0+1050021` / `ec3104f4`: DB/error fixes сохранены и runtime-проверены на Android и Windows; регрессия задач 07/05 не выявлена | P03 concurrency/integrity/key loss/URI/error queue/redaction; Android lifecycle + 89/89 instrumentation; Windows три режима PASS |
| 10 / 6a9fbc808f0857fda2282227 | Проверен настоящий Windows installer/portable пакет | Native dependencies, Private/Public в согласованной disposable-среде; host firewall не менять |
| 11 / 6a9fbc818f08ea0eca05038e | Полная приёмка и фактический выпуск 1.5.0 | FULL обеих платформ, ручной reboot, release hashes/provenance, KB sync |
| 12 / 6aa6de518f087a6320ca4572 | Реализация завершена на `1.5.0+1050026` / `4322e96b`; Android P04 PASS, Windows P04 и leak-проверка на global-IPv6 underlay остаются `NOT_RUN` | Strict HTTPS/AAAA/SNI/cert per leaf, capability cache/generation, четыре режима, manual/Auto, P04 Android; Windows System Proxy/TUN/Local Proxy только обычный connect PASS |

Порядок: stop → crash cleanup → Android VPN-only → selection → Auto traffic →
domain → profile → routing → DB → package → release. Изменение зависимости допустимо
по доказанному root cause с обновлением плана и TickTick, а не по случайному FAIL.
Preserve-first проверки действуют сразу, несмотря на поздние углублённые этапы.
Отложенные задачи и iOS/macOS/Linux не входят в эту очередь.

## Следующий небольшой шаг

Этапы 03 и 06 завершены по отдельному пользовательскому заданию; общий отчёт хранится
вне Git в `Z:\Zeon-Envelope\Temp\zeon-app-testing\T03-T06-B1050010-FINAL-20260913\report.md`.
Этап 08 завершён: Android managed/per-app routing, override и один SHORT прошли на
`1.5.0+1050012`; отчёт хранится в
`Z:\Zeon-Envelope\Temp\zeon-app-testing\T08-B1050012-FINAL-20260913\report.md`.
Этап 04 завершён на `1.5.0+1050050` / `afc252b6`: TARGETED и task-specific SHORT
прошли на физическом Android и прямом Windows-стенде с разделённым UI/runtime
evidence. S05 остаётся пользовательским `MANUAL/NOT_RUN`, FULL не запускался. Отчёт:
`Z:\Zeon-Envelope\Temp\zeon-app-testing\T04-B1050050-FINAL-20260915\report.md`.
Повторное открытие этапа 04 от 17.09.2026: пользователь сообщил об исчезновении
карточки на Android при перезаходе с продолжающимся VPN. Предыдущая приёмка
сохранена как исторический результат. Регрессионный widget test воспроизвёл
исчезновение: native Connected при пустом `ConnectionNotifier` скрывал карточку.
Теперь карточка и кнопка используют общую проекцию native session; имя и Auto/leaf
восстанавливаются из того же snapshot, поздние foreground данные не заменяют выбор.
Передача тестеру: Task `6a9fbc798f08ecb120d25c30`, Android Home re-entry и полное
пересоздание UI при живом VPN, Manual → Auto → Manual, native stop при устаревшем
UI Connected. Проверить имя/флаг против native leaf и свежего трафика; затем SHORT
по README. На runtime-кандидате `1.5.0+1050056` карточка пережила пересоздание
Activity, но выявлен связанный дефект: `serviceRunningProvider` принимал устаревший
Disconnected за выключенный VPN и откладывал выбор сервера до следующего старта.
В `1.5.0+1050057` Android gate потоков и live selection переведён на тот же native
snapshot; 40 регрессионных тестов PASS. Повторная физическая приёмка выполняется;
FULL — `NOT_RUN`. Evidence текущего прогона:
`Z:\Zeon-Envelope\Temp\zeon-app-testing\T04-CARD-RUNTIME-20260917`.
На физической проверке `1050057` live selection восстановлен, но выявлена причина
застывшего имени после пересоздания UI: wall-clock seed нового Dart gate новее
поколения живого VPN, поэтому следующие native snapshots отвергались как stale.
`1050058` принимает поколение Android до первой новой локальной команды; новая
команда по-прежнему резервирует поколение выше wall-clock seed и принятого native.
Поток выбранного сервера также отделён от разрешения/настройки динамического
уведомления; при выключенном отображении скорости native snapshot остаётся живым.
`1050058` / `3c0e8167`: 107 unit/widget/lifecycle и 91/91 native instrumentation PASS,
scoped analyzer clean. Физический Android S01/S02/S03/S04/S06 PASS: Manual A→B→Auto→A,
Activity recreation при прежних PID/VPNService, актуальное имя/Auto leaf, независимые
HTTPS/MTProto через tun0; точный OFF→ON(manual)→Auto с Telegram UID flow. Проверены
оба значения dynamic notification и native Stop receiver после пересоздания UI.
Windows runtime S02 во всех трёх режимах и manual/Auto System Proxy PASS на том же
source SHA. Стенд — Windows Server 2022, не Win10.
Первый Local Proxy S02 завершился HARNESS_ERROR на gRPC-чтении выбранного сервера
после успешного reconnect; cleanup PASS. Единственный повтор тем же артефактом PASS,
исходный сбой сохранён; причина transport close не локализована.
Полный SHORT остаётся PARTIAL: Windows GUI S01, полный UI A→B→Auto→A и настоящий
Telegram S04 — NOT_RUN (тестер).
S05 — MANUAL/NOT_RUN (пользователь), FULL/release/deployment не выполнялись.
Итоговый отчёт: `Z:\Zeon-Envelope\Temp\zeon-app-testing\T04-CARD-RUNTIME-20260917\report.md`.
Локальное evidence разработки:
`Z:\Zeon-Envelope\Temp\zeon-app-testing\T04-ANDROID-CARD-20260917\report.md`.
Этапы 07 и 09 завершены на `1.5.0+1050021` / `ec3104f4`; P03/R17 и регрессия
задачи 05 прошли на физическом Android и во всех трёх Windows-режимах. Отчёт:
`Z:\Zeon-Envelope\Temp\zeon-app-testing\T09-B1050021-FINAL-20260914\report.md`.
По решению пользователя реальный IPv6 egress не блокирует managed routing: он
реализован отдельной задачей `6aa6de518f087a6320ca4572` на `1.5.0+1050026` /
`4322e96b`. Android task-specific P04 прошёл; Windows P04 и проверка утечки при
global IPv6 остаются `NOT_RUN`. Отчёт:
`Z:\Zeon-Envelope\Temp\zeon-app-testing\T12-B1050026-FINAL-20260915\report.md`.
Windows package-list N/A; поддерживаемые process/domain compiler paths проверены.
FULL, release и deployment этим результатом не разрешены.

## Порядок в репозитории

Обычная работа — canonical checkout и ветки того же репозитория. Отдельный worktree
только при необходимости, в Temp, с последующей интеграцией и очисткой регистрации.
Этот коммит собирает требования и точки входа; он не удаляет накопленные неизвестные
файлы. Очистка выполняется отдельно по списку tracked/untracked/ignored, владельцам,
ссылкам и необходимости архива. Не превращать недовольство количеством файлов
в `git clean`, массовое удаление или потерю исходных доказательств.
