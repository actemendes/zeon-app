# Документация zeon-app: читать сначала

Дата организации: 2026-09-11. Этот файл — карта документов, не новый регламент
разработки и не доказательство актуальности всех старых описаний.

## Порядок чтения для агента

1. Локальный bootstrap и canonical `AI-AGENT-GUIDE.md` через `ssh zeon-server`.
2. Релевантная страница компонента в `/opt/zeon-knowledge/02-PROJECTS/zeon-app/`.
3. [Тестовый контракт](testing/README.md) и [текущая точка/план](testing/PLAN.md).
4. Только нужная инструкция или справка из таблиц ниже. Архив открывать по
   конкретному вопросу истории/root cause, а не читать целиком перед работой.

## Что где находится и чему доверять

| Путь | Назначение | Статус |
|---|---|---|
| [testing/README.md](testing/README.md) | Частота проверок, среда, evidence и передача тестеру | Действующий контракт REGRESSION-v1.4 |
| [testing/MATRIX.md](testing/MATRIX.md) | SHORT/FULL, Android/Windows, точный R08 и ручной reboot | Действующие требования; не результаты запусков |
| [testing/PLAN.md](testing/PLAN.md) | Точка main и последовательность 00–11 | Датированный снимок; текущий статус — TickTick |
| [build/BUILD_REPRODUCIBLE.md](build/BUILD_REPRODUCIBLE.md) | Bootstrap/сборка | GUIDE; перед исполнением сверить текущие scripts |
| [build/APPLE_BUILD.md](build/APPLE_BUILD.md) | Сборка iOS/macOS | GUIDE; не включает Apple в текущий recovery scope |
| reference/ | Тематические описания кода и инструментария | REFERENCE / NOT REVALIDATED, рабочая гипотеза |
| [archive/README.md](archive/README.md) | Старые аудиты, этапы стабилизации, заметки и планы | HISTORICAL; не текущая очередь и не release PASS |
| assets/ | Изображения, используемые документацией | Ресурсы, не требования |

Фактический код/runtime → релевантная canonical KB → guide → TickTick → история.
Архитектура и общий workflow остаются в Knowledge Base. Только требования к тестам
и их передаче версионируются в `testing/`; копировать их в новые планы не нужно.
Слова «current», «финальный», «PASS» или старый TODO внутри справки/архива относятся
к исходной записи и не повышают её статус. Каждая перенесённая страница помечена
в начале, чтобы прямой поиск по файлу не обходил эти ограничения.

## Найти описание функции

- [Android deep links](reference/android_deep_links_com_zeon_hiddify.md)
- [Обновление приложения (описание июня 2026)](reference/app_update_flow_current.md)
- [Профиль backend → UI](reference/backend_profile_ui_bindings.md)
- [Работа над Flutter UI](reference/design_workflow_ru.md)
- [Оплата во внешнем браузере и подписка](reference/mobile_payment_flow.md)
- [Мобильный startup/import/account](reference/mobile_startup_flow.md)
- [Polling уведомлений](reference/notifications_polling.md)
- [Smart Active: мониторинг активного сервера](reference/smart-active-active-monitoring.md)
- [Smart Active: debug fault injection](reference/smart-active-debug-fault-injection.md)
- [Обновление подписки через VPN](reference/subscription_update_vpn_routing.md)
- [Интервал URL-теста](reference/url_test_interval_analysis_ru.md)
- [Widgetbook (пути инструментов перепроверять)](reference/widgetbook_quickstart_ru.md)

Для UI canonical-владелец — ZEON Design System в удалённой KB; локальные заметки
не заменяют его. Для команды сборки читать также [scripts/README.md](../scripts/README.md)
и применимый `scripts/AGENTS.md`, если он присутствует. Переезд документов не означает
запуска сборок, исправления build tooling или изменения контрактов приложения.

## Как поддерживать порядок

- Новая справка — в `reference/`, инструкция сборки — в `build/`; добавить ссылку
  сюда. Указать область, дату/SHA фактической проверки и canonical-владельца знаний.
- Изменение текущих тестов — в существующие `testing/README.md`/`MATRIX.md`/`PLAN.md`.
  Не создавать новый recovery-план или prompt-файл на каждый запуск.
- Законченный исторический аудит/исследование — в `archive/` с исходной датой/версией
  и статусом HISTORICAL. Не переносить его рекомендации в backlog автоматически.
- Runtime evidence, screenshots, логи и одноразовые отчёты — в Temp, не в docs.
  Секреты/пользовательские данные не сохранять ни в одном из этих разделов.
- При переносе обновлять Markdown-ссылки и текущие точки входа. Пути внутри старых
  commit manifests/changelog — исторические; находить файл через архивный индекс
  или Git history. Не оставлять рядом дубли/redirect-файлы с прежними инструкциями.
- Структурирование не объявляет REFERENCE свежим аудитом. Устаревшее утверждение
  исправляется после проверки соответствующего кода, а не по названию документа.
