# Точка продолжения и план восстановления

Снимок на **2026-09-11**. Актуальные статусы брать из TickTick; этот документ
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
| Android | Отчёт 09.09: SHORT S02/S03/точный S04/S06 PASS; S01 — известный FAIL кнопки «Сервера». Это evidence своего кандидата/fixture, не автоматический PASS текущего запуска |
| Windows | Отчёты 10–11.09: S06 System Proxy/TUN PASS; S02 System Proxy и 6/6 длительных циклов PASS как отдельные результаты. Весь extended suite FAIL/INCOMPLETE после timeout восстановления. Полной приёмки 01 нет |
| Host-lab | Отчёт 09.09 принял standalone Agent через отдельный sing-box, включая stop/crash независимость. Обычный Desktop Agent остаётся ограничением; готовность инфраструктуры не равна приёмке приложения |
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
| 01 / 6a9fbc768f0852d54c2e225f | Закончить disconnect/cancel текущего кандидата: сначала сверить недостающую приёмку, чинить только подтверждённый FAIL | R03/R04/S06, обе фазы cancel, все Windows режимы, Android VPN |
| 02 / 6a9fbc778f08ecb120d25be9 | После crash интернет не зависит от ZEON; корректное восстановление чужого proxy/PAC | R14–R16, ownership/RunOnce; reboot пользовательский |
| 03 / 6a9fbc788f08ecb120d25c0e | Android только VPN; миграция legacy Proxy preference, без удаления нужных внутренних listeners | Fresh/upgrade, VPN permission, SHORT Windows без изменения его режимов |
| 04 / 6a9fbc798f08ecb120d25c30 | Выбор и persistence соответствуют runtime/UI; кнопки «Сервера» нет при disconnected | R01/R05–R09, late stats/RPC ACK, история старого server selection |
| 05 / 6a9fbc7a8f08c18d5f58c270 | После reconnect/Auto есть настоящий трафик, а не только Connected | Точный R08/Telegram, недоступный сервер R13 |
| 06 / 6a9fbc7c8f0852d54c2e2311 | Сохранить и подтвердить domain API | P01, cold/offline/reconnect, legacy URLs, prod/debug, TLS/SNI |
| 07 / 6a9fbc7d8f08c18d5f58c2b7 | Корректное обновление профиля до/во время VPN | R17, cache/retry, WinHTTP TLS 12175 и проблемные узлы без обхода TLS/IP |
| 08 / 6a9fbc7e8f08c18d5f58c2d5 | Сохранённые managed/per-app/routing правила работают без утечек | R18/R19, P02/P04, DIRECT/VPN/BLOCK/DNS, LKG/overrides, IPv4/IPv6 |
| 09 / 6a9fbc7f8f08ecb120d25d4a | Проверены и сохранены DB/error fixes | P03, concurrency/integrity, key loss, URI decoding, обе платформы |
| 10 / 6a9fbc808f0857fda2282227 | Проверен настоящий Windows installer/portable пакет | Native dependencies, Private/Public в согласованной disposable-среде; host firewall не менять |
| 11 / 6a9fbc818f08ea0eca05038e | Полная приёмка и фактический выпуск 1.5.0 | FULL обеих платформ, ручной reboot, release hashes/provenance, KB sync |

Порядок: stop → crash cleanup → Android VPN-only → selection → Auto traffic →
domain → profile → routing → DB → package → release. Изменение зависимости допустимо
по доказанному root cause с обновлением плана и TickTick, а не по случайному FAIL.
Preserve-first проверки действуют сразу, несмотря на поздние углублённые этапы.
Отложенные задачи и iOS/macOS/Linux не входят в эту очередь.

## Следующий небольшой шаг

Передать отдельному тестовому исполнителю этап 01 на текущем зафиксированном main:
сопоставить source/native hashes с уже принятыми результатами, составить точный
required_cases для отсутствующих Windows S06/Local Proxy, S02 TUN/Local Proxy, S03/S04
и применимых Android проверок. Сохранить известный S01 FAIL за задачей 04.
Не считать частичный/прерванный soak завершённым SHORT. S05 ждать от пользователя.

Если проверка выявит новый app FAIL, передать его разработчику как одно исправление.
Не запускать заново всю матрицу и не переписывать lifecycle до доказательства причины.
Следующая задача начинается отдельным заданием после отчёта текущей.

## Порядок в репозитории

Обычная работа — canonical checkout и ветки того же репозитория. Отдельный worktree
только при необходимости, в Temp, с последующей интеграцией и очисткой регистрации.
Этот коммит собирает требования и точки входа; он не удаляет накопленные неизвестные
файлы. Очистка выполняется отдельно по списку tracked/untracked/ignored, владельцам,
ссылкам и необходимости архива. Не превращать недовольство количеством файлов
в `git clean`, массовое удаление или потерю исходных доказательств.
