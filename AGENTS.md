# zeon-app: вход в работу

Соблюдай macOS bootstrap
`/Users/actemendes/Documents/zeon-app/AGENTS.md` и canonical workflow
`/opt/zeon-knowledge/AI-AGENT-GUIDE.md` через `ssh zeon-server`.
Windows bootstrap `Z:\AGENTS.md` относится только к прежней Windows workstation и
Windows-specific операциям. Если macOS bootstrap отсутствует, используй инструкции
текущей сессии и зафиксируй расхождение; не создавай параллельную копию общего
регламента в репозитории.

Вход в локальную документацию — [docs/README.md](docs/README.md): карта, назначение
и статус документов. `docs/archive/` — история, не актуальная очередь или приёмка;
`docs/reference/` — справка, требующая проверки по коду и canonical KB.

Перед изменениями приложения прочитай [docs/testing/README.md](docs/testing/README.md):
там единые требования к проверкам, передача отдельному тестовому исполнителю,
ссылка на матрицу и текущий план. Продуктовая разработка и runtime-приёмка — отдельные
задания. Не запускай длительную матрицу автоматически и не складывай evidence в Git.

Для iOS/macOS дополнительно прочитай [docs/build/APPLE_BUILD.md](docs/build/APPLE_BUILD.md),
[scripts/AGENTS.md](scripts/AGENTS.md) и релевантные canonical-страницы Apple. Публичный
build entrypoint — `./scripts/build.sh`; Store upload, signing и entitlement changes
не выполняются без явной постановки такой цели.
