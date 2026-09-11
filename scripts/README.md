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
Специализированные `build_*`, `package_*` и `apple/build.sh` остаются реализацией
и совместимыми обёртками. Если сборка сломалась, исправляется этот маршрут и его
тест — обходная ручная команда не становится новой инструкцией.

Все готовые к установке или передаче артефакты публикуются только в:

```text
out/installers/
├── android/
├── win/
├── ios/
└── macos/
```

Каталоги Flutter/Gradle/Xcode `build`, `dist` и временная рабочая копия — только
промежуточные данные. Их путь нельзя передавать как итог сборки.

### Windows и Android

```powershell
# Показать все действия, ничего не собирать
.\scripts\build.ps1 -List

# Windows: распакованная папка приложения
.\scripts\build.ps1 -Action windows-folder

# Windows: portable ZIP
.\scripts\build.ps1 -Action windows-portable

# Windows: подписанный EXE-установщик
.\scripts\build.ps1 -Action windows-exe

# Windows: MSIX
.\scripts\build.ps1 -Action windows-msix

# Android: универсальный release APK
.\scripts\build.ps1 -Action android-apk

# Android: универсальный и отдельные ABI APK
.\scripts\build.ps1 -Action android-apks

# Android: debug APK, установка на единственный подключённый телефон и запуск
.\scripts\build.ps1 -Action android-debug-install -CleanInstall -Launch
```

При нескольких Android-устройствах укажите `-DeviceId SERIAL`. Локальный неподписанный
EXE допускается только для проверки: `-AllowUnsignedExe`; его нельзя распространять.
Для debug/profile APK можно передать `-Mode debug` или `-Mode profile`.
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

## Пересборка core

`rebuild_zeon_core.ps1` запускает Linux-инструменты через WSL и собирает локальные
нативные библиотеки из исходников `hiddify-core`, включая необходимые Go-зависимости.

Доступные платформы:

```powershell
.\scripts\rebuild_zeon_core.ps1 -Platform android
.\scripts\rebuild_zeon_core.ps1 -Platform windows
.\scripts\rebuild_zeon_core.ps1 -Platform linux
.\scripts\rebuild_zeon_core.ps1 -Platform android,windows,linux
```

Полезные параметры:

```powershell
# Проверить выбранный маршрут без запуска тяжелой сборки
.\scripts\rebuild_zeon_core.ps1 -Platform android -DryRun

# Ускорить повторную Android-сборку после уже выполненного gomobile init
.\scripts\rebuild_zeon_core.ps1 -Platform android -SkipGomobileInit

# Указать конкретный WSL-дистрибутив
.\scripts\rebuild_zeon_core.ps1 -Platform android -WslDistribution Ubuntu-22.04

# Установить npm-зависимости web-части расширений core, если она изменялась
.\scripts\rebuild_zeon_core.ps1 -Platform android -InstallWebDependencies
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
- `build_*` и `package_*` — реализации и старые совместимые имена; новые инструкции
  должны ссылаться на `build.ps1`/`build.sh`.
- `rebuild_hiddify_core.ps1` — пересборка native core, а не приложения.
- `verify_*`, `validate_*`, `stage2_*`, `diagnostics/` и `tests/` — проверки и диагностика.
- `bootstrap.ps1`, `bootstrap.sh` и `apple/bootstrap.sh` — подготовка окружения.
