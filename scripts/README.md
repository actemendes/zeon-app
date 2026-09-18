# Скрипты сборки ZEON

Все команды запускаются из корня репозитория. Для Windows и Android используйте
PowerShell; для iOS и macOS — терминал на Mac.

Требования и приёмка: [docs/testing](../docs/testing/README.md). Скрипт является
инструментом, а не источником критериев PASS; runtime-проверки выполняются отдельным
заданием. Новое evidence и вспомогательные бинарники размещать в `Temp` вне репозитория.

## Два входа во все сборки

- `build.ps1` — Windows и Android.
- `build.sh` — iOS и macOS.

Это публичные точки входа для человека, ИИ-агента, локальных Make-обёрток и новых сценариев.
Специализированные `build_*`, `package_windows_installers.ps1` и `apple/build.sh`
остаются внутренней реализацией. Если сборка сломалась, исправляется этот маршрут и его
тест — обходная ручная команда не становится новой инструкцией.

Все готовые к установке или передаче артефакты публикуются только в:

```text
out/installers/
├── android/
├── win/
├── ios/
└── macos/
```

### Безоконный Windows runtime harness

Отдельный тестовый runtime собирается только из чистого зафиксированного commit и
не заменяет обычную Windows-сборку или runtime-приёмку:

```powershell
.\scripts\build.ps1 -Action windows-runtime -Mode release
```

Команда использует `tool/windows_recovery_runtime.dart`, portable-режим, compile-time
guard и Flutter из `pubspec.yaml`. ZIP и manifest создаются в `out/installers/win`.
Manifest фиксирует version/build number, source SHA, время и тип сборки, Flutter,
SHA-256 ZIP, EXE и native core. Повторная сборка с уже записанным build number
отклоняется; перед новой компиляцией увеличьте `+N` в единственном источнике версии —
`pubspec.yaml`.

Прямая лаборатория `ZEON-W10-LAB` — это фактически Windows Server 2022, а не
Windows 10. Controller использует только key-only SSH/SCP и отдельную Scheduled
Task `\ZEON-LAB\ZEON-LAB Runtime Validation` от выделенного локального пользователя
`ZEONRuntime`. Пользователю разрешён batch logon, запрещены локальный интерактивный
и RDP logon; watchdog остаётся под `SYSTEM`. Пароль генерируется только при первом
provisioning и при обновлении harness не сбрасывается, чтобы не инвалидировать
CurrentUser DPAPI. Выделенное roaming-состояние ZEON очищается на границах run.
Сначала локально
проверьте controller, затем неизменяемо опубликуйте артефакт и установите harness:

```powershell
.\scripts\windows_runtime_lab.ps1 `
  -ValidateOnly `
  -ArtifactPath '<out/installers/win/ZEON-1.5.0+N-...zip>'
.\scripts\windows_runtime_lab.ps1 `
  -PublishArtifact `
  -ArtifactPath '<out/installers/win/ZEON-1.5.0+N-...zip>'
.\scripts\windows_runtime_lab.ps1 `
  -DeployHarness -ApplyNoOpRecovery `
  -ArtifactPath '<out/installers/win/ZEON-1.5.0+N-...zip>'
```

Remote request принимает `preflight`, `connect`, однократный S02, фазовый S06,
`manual-proxy`, `auto-proxy`, совмещённый P03/R17 и P04 в режимах `system-proxy`,
`tun` и `local-proxy`. P04 дополнительно требует один из четырёх `-IPv6Mode`:
`ipv4_only`, `prefer_ipv4`, `prefer_ipv6` или `ipv6_only`. Он проверяет Smart Active,
capability gating concrete leaf и HTTPS-трафик через выбранный transport. Для
P03/R17 контроллер передаёт временный источник
подписки из локального DPAPI vault; remote harness хранит его только под DPAPI
выделенного тестового пользователя и редактирует URI из evidence.
Параметры передаются валидируемым immutable JSON v2, а не аргументами Scheduled
Task. После queue SSH-сессия закрывается; `-Detach`, `-Status`, `-ListRuns` и
`-CollectOnly` используют новые конечные сессии. Watchdog применяет delta-recovery
только по одноразовому manifest конкретного `run_id`; явный `-Recover` использует
тот же ограниченный contract. Автоматический reboot запрещён.

`preflight` не требует профиля. Источник разрешённого fixture один раз вводится
интерактивно через `-EnrollFixture` и хранится только под CurrentUser DPAPI в
`Z:\Zeon-Envelope\Temp\ZEON-W10-LAB\fixture-vault`. Для обычных прогонов команда
содержит лишь непрозрачный `-FixtureId`; controller получает свежий профиль в памяти,
передаёт короткоживущий файл, а remote host сразу шифрует его LocalMachine DPAPI вне
evidence. Plaintext удаляется после secret-scan. URI и содержимое не выводятся:

```powershell
.\scripts\windows_runtime_lab.ps1 `
  -EnrollFixture -FixtureId 'zeon-authorized'
.\scripts\windows_runtime_lab.ps1 `
  -FixtureSelfTest -FixtureId 'zeon-authorized'
.\scripts\windows_runtime_lab.ps1 `
  -Scenario preflight -RunId '<unique-preflight-id>' `
  -ArtifactPath '<out/installers/win/ZEON-1.5.0+N-...zip>'
.\scripts\windows_runtime_lab.ps1 `
  -Scenario connect -NetworkMode system-proxy -RunId '<unique-connect-id>' `
  -ArtifactPath '<out/installers/win/ZEON-1.5.0+N-...zip>' `
  -FixtureId 'zeon-authorized' -Detach
.\scripts\windows_runtime_lab.ps1 `
  -Scenario p04 -NetworkMode tun -IPv6Mode prefer_ipv6 -RunId '<unique-p04-id>' `
  -ArtifactPath '<out/installers/win/ZEON-1.5.0+N-...zip>' `
  -FixtureId 'zeon-authorized' -Detach
.\scripts\windows_runtime_lab.ps1 -Status -RunId '<unique-connect-id>'
.\scripts\windows_runtime_lab.ps1 -CollectOnly -RunId '<unique-connect-id>'
```

Remote evidence находится в `C:\ZEON-LAB\evidence\runs\<run_id>`, локальная
проверенная копия — в `Z:\Zeon-Envelope\Temp\zeon-app-testing\<run_id>\evidence`.
Повторный сбор после обрыва controller: `.\scripts\windows_runtime_lab.ps1
-CollectOnly -RunId '<run-id>'`. System Proxy проверяется клиентом без явного proxy
override в WinINet-профиле именно `ZEONRuntime`. Это не доказывает интерактивный
профиль Administrator и не является доказательством Windows 10 compatibility.

Каталоги Flutter/Gradle/Xcode `build`, `dist` и временная рабочая копия — только
промежуточные данные. Их путь нельзя передавать как итог сборки.

### Windows и Android

```powershell
# Показать все действия, ничего не собирать
.\scripts\build.ps1 -List

# Android: изолированный UI-free lifecycle harness + androidTest для физического стенда
.\scripts\build.ps1 -Action android-runtime

# Windows: распакованная папка приложения
.\scripts\build.ps1 -Action windows-folder

# Windows: portable ZIP
.\scripts\build.ps1 -Action windows-portable

# Windows: подписанный EXE-установщик
.\scripts\build.ps1 -Action windows-exe

# Windows: неподписанный EXE-установщик для локальной проверки
.\scripts\build.ps1 -Action windows-exe-unsigned

# Windows: MSIX
.\scripts\build.ps1 -Action windows-msix

# Android: универсальный release APK
.\scripts\build.ps1 -Action android-apk

# Android: универсальный и отдельные ABI APK
.\scripts\build.ps1 -Action android-apks

# Google Play: подписанный release AAB без GitHub-проверки обновлений и её UI
.\scripts\build.ps1 -Action android-google-play

# Android: debug APK, установка на единственный подключённый телефон и запуск
.\scripts\build.ps1 -Action android-debug-install -CleanInstall -Launch
```

При нескольких Android-устройствах укажите `-DeviceId SERIAL`. Действие
`windows-exe-unsigned` публикует отдельный файл с суффиксом `-unsigned`; он допускается
только для локальной проверки и не должен распространяться как подписанный релиз.
Параметр `windows-exe -AllowUnsignedExe` сохранён для совместимости и даёт тот же результат.
Для debug/profile APK можно передать `-Mode debug` или `-Mode profile`.
`android-google-play` всегда собирает release AAB с жёстко заданным
`release=google-play`, публикует `ZEON-<version>-google-play.aab` и не создаёт
локальный ключ: до запуска должны существовать корректные `android/key.properties`
и настроенный upload keystore. В этой сборке автоматический GitHub checker и ручная
кнопка «Проверить обновления» отключены; магазинный `UpgradeAlert` остаётся
Google Play-механизмом обновления.
Entrypoint проверяет версию Flutter из `pubspec.yaml`; если общий SDK новее, закреплённая
версия автоматически готовится в `Z:\Zeon-Envelope\Caches\Flutter` из локального Git tag.
Переопределить SDK можно переменной `ZEON_FLUTTER_ROOT`.

### iOS и macOS

```bash
./scripts/build.sh doctor
./scripts/build.sh macos-app
./scripts/build.sh macos-artifacts
./scripts/build.sh ios-ipa
./scripts/build.sh ios-device
```

Entrypoint хранится в Git с executable-битом; проверка запуска без сборки:
`bash scripts/tests/apple_entrypoint_test.sh`.

`ios-device` требует подключённый и разблокированный iPhone; при необходимости
передайте `DEVICE_ID=<CoreDevice-UUID>`. App Store upload остаётся явным действием:
`ios-upload`, `macos-app-store-upload` или `apple-upload`.

## Точный Android-тест переключения в Auto

`verify_android_exact_auto.py` проверяет последовательность: выбран ручной сервер
при включённом VPN → выключить VPN → включить VPN → выбрать «Автовыбор» →
проверить Telegram. Нужны физическое ADB-устройство, русская локализация,
подключённый VPN validation-сборки, её `androidTest` APK с
`VerificationTrafficService` и установленный Telegram.

```powershell
$testRunDir = Join-Path 'Z:\Zeon-Envelope\Temp\zeon-app-testing' ('exact-auto-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $testRunDir | Out-Null
$snapshotExe = Join-Path $testRunDir 'runtime_core_snapshot.exe'
dart compile exe tool/runtime_core_snapshot.dart -o $snapshotExe
python scripts/verify_android_exact_auto.py --serial DEVICE_SERIAL --manual-label 'MANUAL_SERVER_LABEL' --snapshot-exe $snapshotExe --evidence-dir $testRunDir
```

Если ADB отсутствует в `PATH`, передайте `--adb` с путём к нему. Название ручного
сервера передаётся без флага и должно присутствовать в текущем списке.
Скрипт сначала выводит validation-приложение на передний план и готовит ручной
выбор; затем выполняет указанные нажатия. Проверки требуют конкретный сервер
от native core, отсутствие индикатора подключения Telegram и подтверждённые
HTTPS/MTProto-ответы через VPN из отдельного Android UID. Каждому запуску
присваивается уникальный идентификатор; старые записи logcat не засчитываются.
Полные UI-деревья и содержимое чатов не сохраняются. После теста приложение
остаётся в Auto, Telegram — на переднем плане. Результат этого сценария не
подтверждает доступность API ZEON: она проверяется отдельно.

`verify_android_r13.py` проверяет recovery от реально неработающего manual
сервера. До запуска при включённом validation VPN вручную выбрать сервер, который
после свежей проверки задержки имеет `✕`, и независимо подтвердить, что новые
HTTP/HTTPS/MTProto-запросы через него завершаются ошибкой: сам значок `✕` не
доказывает отказ data plane. Скрипт повторяет fault-probe, выполняет OFF → ON с
сохранённым manual A, повторно доказывает отсутствие трафика, UI-нажатием выбирает
Auto и требует конкретный новый native leaf плюс HTTP 204 от
`zeon-vps.link/generate_204`, две HTTPS-цели и MTProto DC1/DC2 `resPQ`.

```powershell
python scripts/verify_android_r13.py --serial DEVICE_SERIAL --fault-label 'FAULT_SERVER_LABEL' --snapshot-exe $snapshotExe --evidence-dir $testRunDir
```

Скрипт не изменяет профиль и не сохраняет UI-дерево или секреты; fault endpoint
должен уже присутствовать в validation-подписке. После PASS приложение остаётся
подключённым в Auto, поэтому вызывающий тест обязан выполнить disconnect/cleanup.

## Пересборка core

`rebuild_hiddify_core.ps1` запускает Linux-инструменты через WSL и собирает локальные
нативные библиотеки из исходников `hiddify-core`, включая необходимые Go-зависимости.

Доступные платформы:

```powershell
.\scripts\rebuild_hiddify_core.ps1 -Platform android
.\scripts\rebuild_hiddify_core.ps1 -Platform windows
.\scripts\rebuild_hiddify_core.ps1 -Platform linux
.\scripts\rebuild_hiddify_core.ps1 -Platform android,windows,linux
```

Полезные параметры:

```powershell
# Проверить выбранный маршрут без запуска тяжелой сборки
.\scripts\rebuild_hiddify_core.ps1 -Platform android -DryRun

# Ускорить повторную Android-сборку после уже выполненного gomobile init
.\scripts\rebuild_hiddify_core.ps1 -Platform android -SkipGomobileInit

# Указать конкретный WSL-дистрибутив
.\scripts\rebuild_hiddify_core.ps1 -Platform android -WslDistribution Ubuntu-22.04

# Установить npm-зависимости web-части расширений core, если она изменялась
.\scripts\rebuild_hiddify_core.ps1 -Platform android -InstallWebDependencies
```

## Требования

Для обычной Android-пересборки внутри WSL должны быть доступны `go`, `java`,
Android SDK и NDK `28.2.13676358`. По умолчанию SDK ищется в
`$HOME/Android/Sdk`. Скрипт сам устанавливает закрепленные версии `gomobile` и
`gobind`.

Для Windows core внутри WSL дополнительно нужны `make` и
`x86_64-w64-mingw32-gcc`. Для Linux core нужен `make`; Cronet подготавливается
автоматически.

Для Ubuntu WSL базовые desktop-зависимости можно установить так:

```bash
sudo apt update
sudo apt install -y make git gcc-mingw-w64-x86-64
```

Сборка iOS/macOS core требует macOS и Xcode. На Windows через WSL ее выполнять
нельзя. На Mac используйте штатные цели из корневого `Makefile`:

```bash
make build-ios-libs
make build-macos-libs
```

Если изменялись `.proto`-файлы, перед пересборкой библиотек отдельно выполните
`make protos` в Linux/macOS-окружении с установленными генераторами protobuf.

## Что ещё лежит в папке

- `build/common.ps1` — единая проверка пути и публикация артефактов.
- `build_*`, `package_windows_installers.ps1` и `apple/build.sh` — только реализация
  действий `build.ps1`/`build.sh`; напрямую их не вызывают.
- `rebuild_hiddify_core.ps1` — пересборка native core, а не приложения.
- `verify_android_exact_auto.py`, `verify_android_window_api_refs.ps1`, `diagnostics/`
  и `tests/` — действующие проверки и диагностика.
- `generate_brand_icons.py` — явная ручная регенерация иконок из брендового SVG.
- `bootstrap.ps1`, `bootstrap.sh` и `apple/bootstrap.sh` — подготовка окружения.
