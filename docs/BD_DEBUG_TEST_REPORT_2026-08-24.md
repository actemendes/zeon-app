# BD debug: отчёт о тестировании

Дата: 2026-08-24  
Ветка: `bd-debug`  
Flutter: 3.41.9  
Dart: 3.11.5

## Итог

Финальные тестовые прогоны: 96 успешных тестовых сценариев, 0 падений.

## Регрессионный набор изменений

Команда:

```text
flutter test --no-pub test/features/diagnostics/data/diagnostics_noise_control_test.dart test/features/diagnostics/data/error_report_controller_test.dart test/utils/link_parsers_test.dart test/features/profile/data/profile_config_store_key_recovery_test.dart test/drift/db/concurrency_pragmas_test.dart
```

Результат: 10/10 passed.

Проверено:

- фильтрация служебной телеметрии и Go frames;
- нормализация fingerprint и cooldown дедупликации;
- pseudonymous device ID;
- безопасное завершение error reporter;
- однократное URI decoding;
- отказ от замены потерянного ключа при наличии encrypted artifacts;
- SQLite `busy_timeout=5000`.

## Связанный VPN/UI набор

Команда:

```text
flutter test --no-pub test/features/connection/notifier/connection_notifier_test.dart test/features/home/home_proxy_stop_build_test.dart
```

Результат: 34/34 passed.

Проверено:

- фильтрация stale/transient START/STOP событий;
- authoritative platform resync;
- отсутствие пересоздания владельца соединения при core restart;
- отсутствие build-time mutation при rebuild Home и active proxy.

## Отдельный готовый тест репозитория

Команда:

```text
flutter test --no-pub test/zeoncore/session_generation_test.dart
```

Результат: 52/52 passed.

Тест выбран как наиболее близкий к найденным VPN lifecycle ошибкам. Он покрывает session generations, конкурирующие команды, stale callbacks, replacement cleanup, platform-owned stop и Android snapshots.

## Статический анализ

- Адресный `dart analyze` изменённых файлов не выявил ошибок компиляции. Для `connection_notifier.dart` финальный результат — чисто.
- Полный `flutter analyze` завершился с 949 накопленными issues и кодом 1. Основная масса — lint/deprecation предупреждения существующего проекта, generated/third-party код и архивный `out/stage2-2-resource-audit/.../validation-worktree`.
- Среди затронутых файлов остались существующие предупреждения: experimental `TableMigration` и ordering импортов в нескольких старых файлах. Новых compile errors нет.
- `git diff --check` не выявил whitespace errors; выведено только предупреждение Git о будущем LF→CRLF для пользовательского `scripts/package_windows_installers.ps1`.

## Обратная связь от тестов

Первый прогон новых тестов обнаружил неверный pattern type и слишком строгое ожидание для литерального `%`; оба случая исправлены. Первый связанный VPN-прогон обнаружил преждевременное создание error reporter при `AsyncLoading<AppInfoEntity>`; инициализация сделана безопасной и повторный прогон прошёл полностью.

