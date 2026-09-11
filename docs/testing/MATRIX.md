# Матрица проверок

Контракт **REGRESSION-v1.4**. Общие preconditions, evidence, пороги и правила
передачи — в [README.md](README.md). Очередь исправлений — [PLAN.md](PLAN.md).
Все строки ниже — требования; результат появляется только в отчёте конкретного run.

## SHORT: одинаковый набор после продуктового исправления

Один цикл каждой применимой ветки. Windows — локальный host с независимым
управлением; Android — физическое устройство, только VPN.

| ID | Действия и ожидаемый результат | Где |
|---|---|---|
| S01 | Cold start → Home/настройки. UI отзывчив; при disconnected кнопки «Сервера» нет, после connect она доступна; нет ложного Connected | Один запуск на Windows и Android; состояние после connect наблюдать в S02 |
| S02 | Connect → свежий HTTPS → disconnect/cleanup → обычный интернет без ZEON proxy → reconnect/HTTPS → stop. Нет старых ресурсов | Windows TUN, System Proxy, Local Proxy; Android VPN — по циклу |
| S03 | На подключении manual A → B → Auto → manual A. UI/намерение/конкретный native leaf/свежий flow согласованы | Windows System Proxy + Android VPN |
| S04 | Точный R08 ниже: подключён manual A → OFF → ON(A) → Auto → Telegram → HTTPS/MTProto | Windows System Proxy + Android VPN; один цикл |
| S05 | Ручной R16-W: интернет после reboot до запуска ZEON и без ручного сброса proxy | Пользователь, Windows System Proxy; не входит в автоматический запуск |
| S06 | Повтор исходного дефекта и проверки root cause. Для 01 — отмена до readiness, наблюдение позднего старта, retry/трафик/stop | Каждая реально затронутая платформа/ветка один раз; Windows 01 включает все три режима и две фазы отмены |

S01–S04/S06 — агентский SHORT; S05 отдельно MANUAL/NOT_RUN до результата пользователя.
Проверки можно объединять только с сохранением точного порядка и preconditions;
каждый ID/режим/ветка получает собственный verdict. После несвязанного изменения
не добавлять автоматически длинный cancel/IPv6/storage stress в постоянный SHORT.

## FULL: каталог перед выпуском

По умолчанию Windows — все три режима, Android — VPN. Явные исключения ниже.
R02–R08 — три повтора на режим; для **R08 Android VPN и Windows System Proxy —
10 последовательных PASS вместо трёх**. Остальные строки — минимум один полный
проход каждой ветки. Нельзя собрать «10/10» из удачных попыток среди FAIL.

| ID | Действия / ветки | Приёмка |
|---|---|---|
| R01 | Cold start с сетью → Home/настройки → connect → серверы | Отзывчивый UI; список доступен только после подключения; Connected подтверждён |
| R02 | Подключить сохранённый/default сервер → выбрать A → HTTPS → disconnect → обычный HTTPS | Нужный путь трафика, cleanup, кнопки серверов после отключения нет |
| R03 | A: connect → disconnect → connect → трафик → disconnect | Выбор сохранён, новая сессия без старых ресурсов/колбэков |
| R04 | Начать connect → отменить до readiness → наблюдать → retry; две доступные фазы startup | Нет поздней активации proxy/TUN; retry и stop работают; Windows наблюдать 150 с, retry ≤45 с |
| R05 | На подключении A → manual B → трафик → A | UI, persistent intent, native leaf и flow согласованы |
| R06 | Выбрать B на подключении → disconnect → connect; повторить с Auto | Выбор сохраняется; в disconnected кнопки нет; Auto разрешается в leaf |
| R07 | Подключён manual → Auto → трафик → manual B | Оба перехода работают без перезапуска приложения |
| R08 | Подключён manual A → OFF → ON → Auto → Telegram и probes | Точный протокол ниже; UI и реальный трафик согласованы |
| R09 | На подключении выбрать A → закрыть/запустить приложение → connect; повторить с Auto | Сохранено намерение выбора; native и UI совпадают |
| R10 | Сменить режим из disconnected и connected → connect → трафик → disconnect | Windows: все 6 направленных пар между тремя режимами, освобождены старые ресурсы; Android N/A |
| R11 | На подключении убрать тестовую сеть → вернуть без restart; manual и Auto | UI отражает потерю сети, реальный трафик восстанавливается |
| R12 | Cold start без сети с кэшем → connect на сохранённом выборе → вернуть сеть; отдельно fresh без кэша | Нет тупика backend, ложной готовности и требования скрытого выбора в disconnected |
| R13 | Подготовленный недоступный manual endpoint → connect → Auto или рабочий B | Нет ложного рабочего интернета; поддерживаемый переход восстанавливает связь |
| R14 | Контролируемый отказ core start → убрать причину → retry | Ошибка, cleanup, новая успешная сессия; Windows TUN без elevation; Android отказ/отзыв VPN permission |
| R15 | Connect → аварийно завершить ZEON → проверить сеть → запуск/connect | Platform ownership соблюдён, нет старого proxy/TUN; новый запуск работает |
| R16 | Connect → ручной reboot → сеть до ZEON; затем запуск/connect | Windows R16-W ниже во всех режимах; Android отдельно с зафиксированными always-on/lockdown; агент reboot не запускает |
| R17 | Обновить профиль до подключения и при подключении → reconnect | Запрос к домену, валидный TLS, корректный кэш, выбранный сервер не меняется без причины |
| R18 | DIRECT + VPN цели → disconnect/reconnect → смена режима Windows | Rules и DNS соблюдены, нет stale routes, утечки или непредусмотренного direct bypass |
| R19 | Сохранить сервер/режим/route override → restart + штатная синхронизация | Настройки и override сохранены, нет новых DB/crypto/key-loss ошибок |
| R20 | Сворачивание/фон → возврат → трафик → stop | Android VPN Service/foreground notification/session/TUN корректны; Windows core/статус не ломаются |

Для R13 fixture задаёт недоступный endpoint **до запуска сценария**. Нельзя
вводить выбор сервера в disconnected UI ради теста. Если текущий UI не позволяет
предусмотренный recovery-переход, сохранить FAIL/BLOCKED_BY и проверить независимую
ветку отдельно; подмена state через harness не доказывает пользовательский сценарий.

## R08: точные нажатия пользователя

1. VPN уже включён, вручную выбран рабочий сервер A. Подтвердить начальный трафик.
2. Нажать выключение VPN. Дождаться фактической остановки.
3. Нажать включение VPN. Сохраняется A; подтвердить runtime readiness.
4. Выбрать **АВТОВЫБОР**.
5. Открыть Telegram, подтвердить реальное соединение. Затем выполнить независимые
   HTTPS к двум целям и MTProto DC1/DC2 `resPQ` через тот же VPN.

Между шагами нельзя перезапускать приложение, сбрасывать профиль, дополнительно
reconnect или выбирать Auto до второго включения. Пробы не меняют выбранный outbound.

PASS требует конкретного свежего native leaf, согласованности UI/runtime,
HTTPS/MTProto-ответов и свидетельства реального двустороннего Telegram flow после
переключения. Исчезновение «Соединение…» недостаточно. Без Telegram flow его часть
BLOCKED/NOT_RUN; технические probes не подменяют её. Не читать содержимое чатов,
не записывать его и не отправлять сообщения людям.

Windows выполняет эквивалент по режимам. В Local Proxy Telegram требует явно
настроенного proxy самого тестового клиента; если его нет, только эта подпроверка
N/A(reason), HTTPS/SOCKS остаются обязательными. Android Proxy не применяется.

Существующие инструменты: [verify_android_exact_auto.py](../../scripts/verify_android_exact_auto.py)
и [runtime_core_snapshot.dart](../../tool/runtime_core_snapshot.dart). До исполнения
проверить русскую UI, validation APK + androidTest, snapshot executable и ADB forwards.
Один запуск скрипта не доказывает FULL 10/10 или Telegram flow без нужного evidence.

## R16-W: ручной критерий пользователя

После этапа — System Proxy; на FULL — все три Windows-режима. Не запускать reboot
из агента и не автоматизировать его обходным scheduled task. Отчёт агента может
быть передан без этой проверки с явным MANUAL/NOT_RUN.

1. Зафиксировать исходный работающий интернет, proxy/PAC/WinHTTP/DNS/routes.
2. Подключить ZEON и доказать свежий трафик нужным путём.
3. Пользователь вручную перезагружает Windows при активном соединении.
4. После входа в тот же профиль **не запускать ZEON и не сбрасывать proxy**.
   Автозапуск приложения должен быть выключен. Штатный одноразовый recovery helper
   допустим, но его выполнение/завершение фиксируется.
5. Подтвердить отсутствие ZEON/core и зависимости от его listener; проверить
   proxy/PAC, DNS, routes/adapters и обычный интернет из proxy-aware клиента.
6. Свежий HTTPS к двум независимым целям без явного proxy override/`--noproxy`;
   повторить через **60 секунд**. Доступность служебного proxy Codex не доказательство.
7. Если требуются запуск ZEON или ручной reset — FAIL. После фиксации можно
   восстановить среду и отдельно проверить новый запуск/connect/stop.

Для 02/FULL дополнительно: disconnect → закрыть → ручной reboot; исходный чужой
тестовый proxy/PAC; чужая смена настроек во время ZEON. Восстанавливается именно
исходный принадлежащий владельцу вариант, а не безусловный ProxyEnable=0.
Задача исправления мёртвого proxy остаётся обязательной; передача reboot пользователю
не отменяет критерий выпуска и не стирает исторические результаты.

## Защитные проверки

FULL и TARGETED при изменении соответствующего слоя; базовые признаки — всегда.

| ID | Проверка | Приёмка |
|---|---|---|
| P01 | Domain defaults, legacy URL migration, негативные TLS tests | API остаётся доменным; старый IP не fallback; неверный сертификат отклоняется. IP в DNS-ответе нормален |
| P02 | Managed routing, LKG/offline, overrides, реальные R18–R19 | Полезные правила сохранены; Android package rules и поддерживаемые Windows process/domain rules работают |
| P03 | DB/error targeted tests, integrity тестовой БД, persistence | Нет потери данных, дублирования workaround и новых ошибок; production БД не менять |
| P04 | IPv4 и отдельный IPv6-enabled probe с восстановлением настроек | Подтверждены конкретный IPv6 path/egress и отсутствие утечки либо честный FAIL/BLOCKED |
| P05 | Сборки обеих платформ, полный unit/widget suite, scoped analyzer, нужные native tests | Закреплённые SDK/lockfile, provenance native; нет новых diagnostics; SKIP не PASS |

## Дополнения по root cause

- Lifecycle/cleanup: старые generation не трогают новую; stop/cancel/restart,
  process kill, permission failure, чужие proxy/PAC и RunOnce. Android nativeStartFailure,
  TUN ownership, foreground/background проверяются отдельно от Windows ownership.
- Selection: полный путь intent → storage → generated config → core → flow → UI;
  late stats, потерянный RPC ACK, старые рабочие revisions как источник объяснения.
- Domain/profile: fresh и legacy, prod/debug, HTTPS/WSS, offline/cache/retry,
  проблемные и доступные VPN-узлы; без IP fallback/TLS bypass.
- Routing: fresh/upgrade от 1.4.2 на тестовых данных, managed update, LKG,
  malformed/rollback, override, DIRECT/VPN/BLOCK/DNS, cleanup и IPv4/IPv6.
- DB: два SQLite writer, Android foreground/background worker, Windows writes,
  key unavailable/corrupt profile, URI decoding и безопасная передача ошибок.
- Package/firewall: installer/portable на согласованной чистой среде, Private/Public,
  native dependencies, HTTPS/WSS, три режима, отсутствие лишних allow rules;
  reboot только вручную. Firewall рабочего хоста не менять.

Новый воспроизведённый root cause добавлять с новым ID в FULL и профильный TARGETED.
Включение его во все SHORT требует обоснования. Порог, порядок R08 и старые ID
нельзя менять молча или ослаблять ради зелёного результата.
