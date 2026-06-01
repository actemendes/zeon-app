# Скрипты сборки ZEON

Все команды ниже запускаются из корня репозитория в PowerShell.

## Быстрые сценарии

1. Пересобрать Android core после изменений в `hiddify-core`:

   ```powershell
   .\scripts\rebuild_hiddify_core.ps1 -Platform android
   ```

2. Собрать готовые APK для распространения:

   ```powershell
   .\scripts\build_android_installation_apks.ps1
   ```

3. Собрать и установить приложение на подключенный Android-телефон:

   ```powershell
   .\scripts\build_and_install_android_device.ps1 -CleanInstall -Launch
   ```

4. Пересобрать Windows core после изменений в `hiddify-core`:

   ```powershell
   .\scripts\rebuild_hiddify_core.ps1 -Platform windows
   ```

5. Собрать готовый Windows EXE-установщик:

   ```powershell
   .\scripts\build_windows_installer_exe.ps1
   ```

6. Собрать только Windows release-папку без установщика:

   ```powershell
   .\scripts\build_windows_release_folder.ps1
   ```

## Какие шаги применять

| Задача | Шаги |
| --- | --- |
| Полностью новый APK с измененным core, установить на телефон | `1`, затем `3` |
| Готовые APK-файлы с измененным core для отправки пользователям | `1`, затем `2` |
| Новый APK после изменений только во Flutter/Kotlin-коде приложения | `2` |
| Установить свежую локальную версию приложения без изменений core | `3` |
| Новый Windows-установщик с измененным core | `4`, затем `5` |
| Новый Windows-установщик после изменений только в приложении | `5` |

APK из шага `2` копируются в `out/installers/android`.
Windows EXE из шага `5` копируется в `out/installers/win`.

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

## Остальные скрипты

- `build_and_install_android.ps1` - расширенная версия шага `3`.
- `build_and_install_windows.ps1` - расширенная Windows-сборка с запуском.
- `package_windows.ps1` - совместимый сценарий упаковки Windows.
- `bootstrap.ps1` и `bootstrap.sh` - базовая подготовка Flutter-проекта.
