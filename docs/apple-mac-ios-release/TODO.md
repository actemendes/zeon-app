# Apple macOS / iOS Release TODO

Цель: довести Zeon `1.2.1+10201` и следующие версии до стабильного состояния для релиза в App Store, с воспроизводимой сборкой macOS/iOS, рабочим VPN/proxy подключением и проверенными базовыми UX сценариями.

## Контекст

- Текущая известная версия: `1.2.1+10201` из `pubspec.yaml`.
- Известно, что проект версии `1.2.1` не собирался на iPhone и macOS.
- На macOS не работает VPN подключение и proxy подключение.
- На iPhone VPN туннель работает, но нестабильно; proxy подключение также требует проверки.
- Не проверены холодный запуск приложения и обновления версий.
- Для macOS обновления должны проверяться через GitHub/appcast flow.
- Существующие материалы для изучения перед работой:
  - `docs/APPLE_BUILD.md`
  - `docs/NETWORK_VPN_FINAL_AUDIT_2026-05-19.md`
  - `docs/app_update_flow_current.md`
  - `docs/mobile_startup_flow.md`
  - `scripts/apple/bootstrap.sh`
  - `scripts/apple/build.sh`
  - `scripts/apple/env.sh`

## Правила работы для ИИ агентов

- Перед изменениями зафиксировать окружение: macOS version, Xcode version, Flutter version, Dart version, CocoaPods version, target device/simulator.
- Не смешивать в одном PR/коммите сборочные фиксы, VPN/proxy фиксы и UX-тест кейсы, если это можно разделить.
- Каждый выполненный пункт должен иметь результат: команда, лог, скриншот/видео при UX проверке, ссылка на измененные файлы или краткое объяснение причины блокировки.
- Если пункт заблокирован, добавить причину в раздел "Блокеры" и следующий минимальный шаг.
- Не удалять существующие user changes без явного запроса.

## Статусы

Используем статусы:

- `[ ]` не начато
- `[~]` в работе
- `[x]` выполнено
- `[!]` заблокировано

## Milestone 0: Инвентаризация Apple сборки

- [x] Проверить, что `flutter doctor -v` проходит без критичных ошибок для macOS/iOS.
- [x] Проверить установленный Xcode и Command Line Tools: `xcodebuild -version`, `xcode-select -p`.
- [x] Проверить CocoaPods: `pod --version`.
- [x] Проверить signing/team/capabilities в `ios/` и `macos/`.
- [x] Проверить bundle id, app group, network extension id и entitlements для iOS.
- [x] Проверить bundle id, app group, network extension id, sandbox и entitlements для macOS.
- [!] Сравнить expected capabilities с фактическими Xcode project settings.
- [x] Описать в этом файле минимальное поддерживаемое окружение сборки.

## Milestone 1: Сборка macOS

- [x] Выполнить bootstrap для Apple окружения: `scripts/apple/bootstrap.sh`.
- [x] Выполнить clean build: `flutter clean && flutter pub get`.
- [x] Проверить генерацию codegen, если требуется: `dart run build_runner build`.
- [x] Собрать debug macOS: `flutter build macos --debug`.
- [x] Собрать release macOS: `flutter build macos --release`.
- [x] Если сборка падает, сохранить ключевые ошибки в раздел "Build Log Notes".
- [!] Исправить ошибки зависимостей, Podfile, entitlements, signing или native code.
- [x] Запустить собранное macOS приложение локально.
- [x] Проверить запуск из Finder/Application bundle, не только через Flutter.
- [x] Зафиксировать итоговую команду воспроизводимой macOS сборки.

## Milestone 2: Сборка iOS

- [x] Выполнить `flutter clean && flutter pub get`.
- [x] Проверить `cd ios && pod install`.
- [x] Собрать iOS simulator: `flutter build ios --simulator`.
- [x] Собрать iOS device/debug: `flutter build ios --debug`.
- [!] Собрать iOS release/archive через Xcode или `flutter build ipa`, если signing готов.
- [x] Установить приложение на реальный iPhone.
- [x] Если сборка падает, сохранить ключевые ошибки в раздел "Build Log Notes".
- [x] Исправить ошибки зависимостей, Podfile, entitlements, signing, provisioning или native code.
- [x] Зафиксировать итоговую команду воспроизводимой iOS сборки.

## Milestone 3: macOS VPN и Proxy

- [ ] Описать expected behavior: что считается успешным VPN подключением на macOS.
- [ ] Описать expected behavior: что считается успешным proxy подключением на macOS.
- [ ] Проверить наличие и корректность Network Extension entitlements.
- [ ] Проверить System Extension / Network Extension разрешения в macOS System Settings.
- [ ] Проверить логи приложения при connect/disconnect.
- [ ] Проверить Console.app logs для network extension/provider process.
- [ ] Проверить, стартует ли core/sing-box процесс на macOS.
- [ ] Проверить, создается ли tun/interface или proxy listener.
- [ ] Проверить маршрутизацию: DNS, default route, split route, bypass LAN.
- [ ] Проверить доступность тестового URL до подключения.
- [ ] Проверить доступность тестового URL после VPN подключения.
- [ ] Проверить доступность тестового URL после proxy подключения.
- [ ] Проверить корректный disconnect и очистку routes/DNS/listeners.
- [ ] Исправить root cause для macOS VPN.
- [ ] Исправить root cause для macOS proxy.
- [ ] Добавить regression notes или automated checks, если возможно.

## Milestone 4: iOS VPN и Proxy стабильность

- [ ] Описать expected behavior для iOS VPN tunnel.
- [ ] Описать expected behavior для iOS proxy mode, если он поддерживается.
- [ ] Проверить установку VPN profile/permission flow на чистом устройстве.
- [ ] Проверить первый connect после установки.
- [ ] Проверить 10 циклов connect/disconnect подряд.
- [ ] Проверить reconnect после lock/unlock устройства.
- [ ] Проверить reconnect после переключения Wi-Fi/LTE.
- [ ] Проверить reconnect после airplane mode on/off.
- [ ] Проверить поведение после force close приложения.
- [ ] Проверить, держится ли туннель в фоне.
- [ ] Проверить DNS leaks и routing после подключения.
- [ ] Проверить стабильность core/sing-box и memory/cpu при 15+ мин активного туннеля.
- [ ] Найти и исправить причину нестабильности VPN tunnel.
- [ ] Проверить proxy подключение на iPhone или явно зафиксировать, что режим не поддерживается.

## Milestone 5: Холодный запуск

- [ ] macOS: запуск после fresh install без старых preferences/database/cache.
- [ ] macOS: запуск после reboot.
- [ ] macOS: запуск без сети.
- [ ] macOS: запуск с поврежденным/устаревшим локальным конфигом.
- [ ] iOS: запуск после fresh install.
- [ ] iOS: запуск после reboot.
- [ ] iOS: запуск без сети.
- [ ] iOS: запуск после force close.
- [ ] iOS: запуск с существующим VPN permission/profile.
- [ ] Проверить отсутствие crash, зависаний, бесконечных loaders и некорректных empty states.
- [ ] Проверить корректное восстановление последнего выбранного профиля/настроек.

## Milestone 6: Обновления версий

- [ ] Изучить текущий update flow: `docs/app_update_flow_current.md`.
- [ ] Проверить macOS update через GitHub/appcast на тестовой версии.
- [ ] Проверить `appcast.xml`, `appcast-beta.xml`, `appcast-stable.xml`.
- [ ] Проверить version/build number comparison.
- [ ] Проверить UX update available.
- [ ] Проверить download/install/relaunch flow.
- [ ] Проверить rollback behavior при неудачной загрузке.
- [ ] Проверить update с `1.2.1` на тестовую следующую версию.
- [ ] Проверить миграции базы/настроек после update.
- [ ] iOS: проверить, что App Store update не ломает локальные данные/VPN profile.

## Milestone 7: Типовые UX сценарии

- [ ] Первый запуск: onboarding/permissions/default screen.
- [ ] Добавление профиля вручную.
- [ ] Добавление профиля через URL.
- [ ] Добавление профиля через QR, если поддерживается на платформе.
- [ ] Обновление subscription/profile.
- [ ] Переключение active profile.
- [ ] Connect/disconnect из главного экрана.
- [ ] Connect/disconnect из tray/menu bar на macOS.
- [ ] Перезапуск приложения при активном подключении.
- [ ] Обработка expired/invalid subscription.
- [ ] Обработка server unavailable.
- [ ] Обработка invalid config.
- [ ] Проверка settings screens.
- [ ] Проверка language/localization, минимум RU/EN.
- [ ] Проверка dark/light theme.
- [ ] Проверка accessibility basics: readable text, focus, large text на iOS.
- [ ] Проверка crash-free navigation по основным экранам.

## Milestone 8: Тест-кейсы

- [ ] Создать markdown test suite для macOS smoke tests.
- [ ] Создать markdown test suite для iOS smoke tests.
- [ ] Создать markdown test suite для VPN/proxy regression.
- [ ] Создать markdown test suite для update flow.
- [ ] Создать markdown test suite для cold start.
- [ ] Для каждого тест-кейса указать: preconditions, steps, expected result, actual result, artifacts.
- [ ] Отметить кандидаты на автоматизацию unit/widget/integration tests.
- [ ] Добавить минимальные automated tests там, где это быстро и надежно.

## Milestone 9: Release readiness

- [ ] Все сборки macOS/iOS воспроизводимы на чистом окружении.
- [ ] VPN и proxy работают на macOS либо есть явный продуктовый decision по неподдерживаемому режиму.
- [ ] VPN tunnel стабилен на iPhone в основных сетевых сценариях.
- [ ] Холодный запуск проходит на macOS и iOS.
- [ ] Обновление macOS через GitHub/appcast проверено.
- [ ] iOS upgrade path проверен через TestFlight/App Store-подобный сценарий.
- [ ] Основные UX сценарии проверены.
- [ ] Критические crash/blocker issues закрыты.
- [ ] Подготовлены release notes.
- [ ] Подготовлен список известных ограничений.

## Build Log Notes

Добавлять сюда краткие выдержки ошибок и ссылки на полные логи.

- 2026-06-25 / Milestone 0 inventory:
  - Default shell without `source scripts/apple/env.sh`: `flutter` and `pod` are not in PATH; `xcodebuild -version` fails because active `xcode-select -p` is `/Library/Developer/CommandLineTools`.
  - With `source scripts/apple/env.sh`: `flutter doctor -v` reports Apple targets OK (`Xcode - develop for iOS and macOS` is green, CocoaPods 1.16.2). Doctor still reports Android SDK and Chrome missing; these are not critical for macOS/iOS release inventory.
  - Connected targets from `flutter devices`: physical iPhone `iPhone (Dima)` on iOS 18.7.9 (22H355), and macOS desktop on macOS 26.5.1 (25F80). Available simulators include iOS 18.6 and iOS 26.5 device runtimes.
- 2026-06-25 / Milestone 1 macOS build:
  - Environment re-verified with `source scripts/apple/env.sh`: macOS 26.5.1 (25F80), Xcode 26.5 build 17F42, Flutter 3.38.5, Dart 3.10.4, CocoaPods 1.16.2. Connected targets: iPhone `iPhone (Dima)` on iOS 18.7.9 and macOS desktop `darwin-x64`.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m1-01-bootstrap-2026-06-25.log`, `m1-02-clean-pub-get-2026-06-25.log`, `m1-03-build-runner-2026-06-25.log`, `m1-04-macos-debug-2026-06-25.log`, `m1-05-macos-release-2026-06-25.log`.
  - `scripts/apple/bootstrap.sh` completed successfully. Notable non-fatal warnings: build_runner `flag_builder` import warnings, analyzer 3.9 vs Dart SDK 3.10 warning, generated protobuf files with Dart 2.12 language version warnings, and CocoaPods custom base configuration warnings for macOS/iOS Runner configs.
  - `flutter clean && flutter pub get` completed successfully.
  - `dart run build_runner build --delete-conflicting-outputs` completed successfully with 1192 outputs.
  - `flutter build macos --debug` completed successfully: `build/macos/Build/Products/Debug/Hiddify.app`.
  - `flutter build macos --release` completed successfully: `build/macos/Build/Products/Release/Hiddify.app` (238.3MB).
  - Release build warnings include Pods/Sentry/sqlite/mobile_scanner compiler warnings, AppIcon unassigned child warning, run-script phase output warning, and `PrivacyInfo.xcprivacy` no-rule warnings for `window_manager` and `in_app_review`.
  - Strict verification command failed: `codesign --verify --deep --strict --verbose=2 build/macos/Build/Products/Release/Hiddify.app` reports `invalid Info.plist (plist or signature have been modified)` in `Contents/Library/LoginItems/LaunchAtLoginHelper.app` for architecture `x86_64`.
  - Local app launch verified outside Flutter: `open build/macos/Build/Products/Release/Hiddify.app` started process `.../Hiddify.app/Contents/MacOS/Hiddify`.
  - Finder/Application bundle launch verified outside Flutter: `osascript -e 'tell application "Finder" to open POSIX file ".../build/macos/Build/Products/Release/Hiddify.app"'` started process `.../Hiddify.app/Contents/MacOS/Hiddify`.
  - Reproducible macOS build command for current repo state: `source scripts/apple/env.sh && scripts/apple/bootstrap.sh && flutter clean && flutter pub get && dart run build_runner build --delete-conflicting-outputs && flutter build macos --release`.
- 2026-06-25 / Milestone 2 iOS build:
  - Environment re-verified with `source scripts/apple/env.sh`: macOS 26.5.1 (25F80), Xcode 26.5 build 17F42, Flutter 3.38.5, Dart 3.10.4, CocoaPods 1.16.2. Connected target: physical iPhone `iPhone (Dima)` on iOS 18.7.9 (22H355); CoreDevice id `FE12C9C0-D99D-5EA0-B386-AEBC58E16123`.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m2-01-clean-pub-get-2026-06-25.log`, `m2-02-ios-pod-install-2026-06-25.log`, `m2-03-ios-simulator-build-2026-06-25.log`, `m2-04-ios-device-debug-build-2026-06-25.log`, `m2-05-ios-ipa-build-2026-06-25.log`, `m2-06-ios-install-iphone-2026-06-25.log`, `m2-07-ios-install-verification-2026-06-25.log`.
  - `flutter clean && flutter pub get` completed successfully.
  - `cd ios && pod install` completed successfully. Non-fatal warning remains: CocoaPods did not set the base configuration because Runner already has a custom config; it suggests including `Pods-Runner.profile.xcconfig` in `Flutter/Release.xcconfig`.
  - `flutter build ios --simulator` completed successfully: `build/ios/iphonesimulator/Runner.app`.
  - `flutter build ios --debug` completed successfully for device: `build/ios/iphoneos/Runner.app`, automatically signed with development team `CH87655747`.
  - `flutter build ipa` created archive `build/ios/archive/Runner.xcarchive` (359.5MB) and validated app settings: version `1.2.1`, build `10201`, deployment target `15.0`, bundle id `app.zeon.ios`.
  - IPA export is blocked: `exportArchive No Accounts`, no signing certificate `iOS Distribution`, and no provisioning profiles for `app.zeon.ios` and `app.zeon.ios.HiddifyPacketTunnel`.
  - Device install verified: `flutter install -d 00008020-001608162E93802E` returned 0, and `xcrun devicectl device info apps --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 --bundle-id app.zeon.ios` shows `Hiddify app.zeon.ios 1.2.1 10201`.
  - Reproducible iOS debug build command for current repo state: `source scripts/apple/env.sh && flutter clean && flutter pub get && cd ios && pod install && cd .. && flutter build ios --debug`.
  - Reproducible iOS simulator build command for current repo state: `source scripts/apple/env.sh && flutter clean && flutter pub get && cd ios && pod install && cd .. && flutter build ios --simulator`.
  - Release/archive command that currently reaches archive but not App Store IPA export: `source scripts/apple/env.sh && flutter build ipa`.
- 2026-06-25 / Milestone 2 iOS launch/runtime fix:
  - Re-verified rebuilt core artifacts: `lipo -info hiddify-core/bin/hiddify-core.dylib` reports `x86_64 arm64`; `ios/Frameworks/HiddifyCore.xcframework/Info.plist` reports device `arm64` and simulator `arm64/x86_64`.
  - `flutter run` debug launch showed the original runtime failure: `PlatformDispatcherError: Invalid argument(s): iOS settings must be set when targeting iOS platform` from `SystemNotificationServiceImpl.initialize`.
  - Fixed notification initialization by adding Darwin iOS/macOS initialization/details and iOS/macOS permission requests in `lib/features/notifications/service/system_notification_service.dart`.
  - Confirmed debug builds launched via Flutter tooling. Also confirmed that tapping/launching a debug build without Flutter/Xcode is not valid on iOS 14+: `Cannot create a FlutterEngine instance in debug mode without Flutter tooling or Xcode`.
  - After the rebuilt core, `smart-active-auto` is kept as the expected balancer strategy; no migration fallback to `round-robin` was kept.
  - Profile standalone validation: `flutter build ios --profile --no-pub` succeeded, `xcrun devicectl device install app --device 00008020-001608162E93802E build/ios/iphoneos/Runner.app` succeeded, and `xcrun devicectl device process launch --device 00008020-001608162E93802E --terminate-existing --console ... app.zeon.ios` reached `AppLifecycleState.resumed`.
  - Final profile launch log `m2-17-ios-profile-standalone-launch-after-polling-fix-2026-06-25.log` shows `Hiddify-core setup done` and `ConnectionNotifier connection status: CONNECTED`. It does not contain `iOS settings must be set`, `unknown load balance strategy`, `Cannot create a FlutterEngine`, or `PlatformDispatcherError`.
  - Notification API currently returns HTTP 400 during startup/foreground sync. Fixed `NotificationPollingService` so these polling failures remain warnings/backoff events instead of uncaught app-level `PlatformDispatcherError`.
  - Additional logs saved under `docs/apple-mac-ios-release/logs/`: `m2-08-ios-flutter-run-launch-2026-06-25.log`, `m2-09-ios-flutter-run-after-notification-fix-2026-06-25.log`, `m2-10-ios-flutter-run-after-core-rebuild-2026-06-25.log`, `m2-11-ios-devicectl-console-after-core-rebuild-2026-06-25.log`, `m2-12-ios-profile-build-after-core-rebuild-2026-06-25.log`, `m2-13-ios-profile-install-after-core-rebuild-2026-06-25.log`, `m2-14-ios-profile-standalone-launch-after-core-rebuild-2026-06-25.log`, `m2-15-ios-profile-build-after-polling-fix-2026-06-25.log`, `m2-16-ios-profile-install-after-polling-fix-2026-06-25.log`, `m2-17-ios-profile-standalone-launch-after-polling-fix-2026-06-25.log`.

## Milestone 0 Inventory

Environment verified on 2026-06-25:

- Host OS: macOS 26.5.1 (25F80), `darwin-x64`.
- Project version: `1.2.1+10201` from `pubspec.yaml`.
- Required project environment from `pubspec.yaml`: Dart SDK `^3.10.4`, Flutter `^3.38.5`.
- Toolchain activation: run `source scripts/apple/env.sh` before Apple commands. This sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and prepends `.toolchains/flutter/bin`, `.toolchains/gems/bin`, `.toolchains/go/bin`, `.toolchains/pub-cache/bin`, `.toolchains/gopath/bin`.
- Flutter: 3.38.5 stable from `.toolchains/flutter`; Dart: 3.10.4.
- Xcode: 26.5 build 17F42 via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Command Line Tools: global `xcode-select -p` is `/Library/Developer/CommandLineTools`; raw `xcodebuild -version` fails unless the Apple env sets `DEVELOPER_DIR`.
- CocoaPods: 1.16.2 from `.toolchains/gems/bin/pod`.
- Code signing identity present: `Apple Development: Dima Moiseev (37NM4393T6)`.
- Minimum deployment targets found in Xcode settings: iOS `IPHONEOS_DEPLOYMENT_TARGET = 15.0`; macOS `MACOSX_DEPLOYMENT_TARGET = 10.15`.
- Minimal supported build environment for this repo: macOS with `/Applications/Xcode.app`, Xcode 26.5 or compatible Apple toolchain, Flutter 3.38.5, Dart 3.10.4, CocoaPods 1.16.2, Go 1.25.6 for bootstrap/core flow, and `scripts/apple/env.sh` sourced before build commands. For signed iOS/macOS artifacts, an Apple Developer team with Network Extension entitlement and matching provisioning profiles is required.

iOS project inventory:

- Base bundle id: `BASE_BUNDLE_IDENTIFIER=app.zeon.ios` from `ios/Base.xcconfig`; local `ios/AppleSigning.xcconfig` also sets `BASE_BUNDLE_IDENTIFIER = app.zeon.ios`.
- Development team: `APPLE_DEVELOPMENT_TEAM = CH87655747` in local `ios/AppleSigning.xcconfig`; default `ios/Base.xcconfig` leaves it empty before the optional include.
- Runner bundle id: `$(BASE_BUNDLE_IDENTIFIER)`.
- Packet Tunnel extension bundle id: `$(BASE_BUNDLE_IDENTIFIER).HiddifyPacketTunnel`.
- VPN manager provider id: `Bundle.main.baseBundleIdentifier + ".HiddifyPacketTunnel"`.
- App group: `group.$(BASE_BUNDLE_IDENTIFIER)` in Runner and HiddifyPacketTunnel entitlements.
- Runner entitlements: `aps-environment=development`, Network Extension values `app-proxy-provider`, `dns-proxy`, `packet-tunnel-provider`, VPN API `allow-vpn`, app sandbox true, app group, network client/server.
- HiddifyPacketTunnel entitlements: Network Extension values `app-proxy-provider`, `dns-proxy`, `packet-tunnel-provider`, `content-filter-provider`, VPN API `allow-vpn`, app sandbox true, app group, network client/server.
- Xcode target settings: Runner and HiddifyPacketTunnel use `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = $(APPLE_DEVELOPMENT_TEAM)`, and their entitlement files are wired through `CODE_SIGN_ENTITLEMENTS`.

macOS project inventory:

- Bundle id: `PRODUCT_BUNDLE_IDENTIFIER = app.hiddify.com` from `macos/Runner/Configs/AppInfo.xcconfig`.
- Development team: no `DEVELOPMENT_TEAM` found for macOS Runner build settings; signing identity in project is ad-hoc `CODE_SIGN_IDENTITY = "-"` for base configs, with Runner `CODE_SIGN_STYLE = Automatic`.
- Entitlement files: Debug/Profile use `macos/Runner/DebugProfile.entitlements`; Release uses `macos/Runner/Release.entitlements`.
- Parsed Debug/Profile/Release entitlements: `com.apple.security.app-sandbox=false`, `com.apple.security.cs.allow-jit=true`, `com.apple.security.network.client=true`, `com.apple.security.network.server=true`.
- macOS Network Extension/App Group entitlements are present only as commented XML in entitlement files and do not parse as active entitlements.
- No macOS packet tunnel/system extension target was found in `macos/Runner.xcodeproj`; only Runner and RunnerTests appear in the macOS project.

Expected vs actual capabilities:

- iOS expected VPN/proxy capabilities are mostly represented in actual project settings: Runner and HiddifyPacketTunnel both have Network Extension, VPN API, App Group, sandbox and network client/server entitlements. The extension includes `content-filter-provider` while Runner does not; verify whether the app target also needs this before release.
- macOS expected VPN/proxy capabilities do not match actual settings: Network Extension and App Group are not active entitlements, sandbox is disabled, and no macOS Network Extension target is present. This is an inventory finding and likely explains why later macOS VPN/proxy milestones need native signing/capability work.

## Блокеры

Добавлять сюда только реальные блокировки, которые мешают следующему шагу.

- [!] Milestone 0 / Expected capabilities comparison: macOS expected VPN/proxy capabilities do not match actual Xcode settings. `plutil -p macos/Runner/Release.entitlements` and `plutil -p macos/Runner/DebugProfile.entitlements` show only sandbox=false, allow-jit, network client/server; Network Extension/App Group keys are commented out in XML and inactive. Следующий минимальный шаг: в Milestone 3 принять целевую macOS архитектуру VPN/proxy (Network Extension/System Extension vs userspace proxy only), затем включать соответствующие targets, entitlements, App ID capabilities и provisioning.
- [!] Environment activation footgun: raw shell PATH cannot run `flutter`/`pod`, and global `xcode-select -p` points to CommandLineTools so raw `xcodebuild -version` fails. Следующий минимальный шаг: before Apple work always run `source scripts/apple/env.sh` or `make apple-doctor`; optionally switch global Xcode with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` outside this inventory task.
- [!] Milestone 1 / Strict release bundle signing verification: `flutter build macos --release` succeeds and the app launches, but `codesign --verify --deep --strict --verbose=2 build/macos/Build/Products/Release/Hiddify.app` fails with `invalid Info.plist (plist or signature have been modified)` in `Contents/Library/LoginItems/LaunchAtLoginHelper.app` for architecture `x86_64`. Следующий минимальный шаг: inspect `LaunchAtLoginHelper.app` generation/signing in the macOS target and re-sign/verify the nested login item before notarized/App Store distribution work.
- [!] Milestone 2 / App Store IPA export signing: `flutter build ipa` creates `build/ios/archive/Runner.xcarchive`, but export fails with `exportArchive No Accounts`, missing `iOS Distribution` signing certificate, and missing provisioning profiles for `app.zeon.ios` and `app.zeon.ios.HiddifyPacketTunnel`. Следующий минимальный шаг: sign in to the Apple Developer account in Xcode or CI keychain, install/create iOS Distribution certificate, and create/download matching App Store provisioning profiles with the required Network Extension/App Group capabilities for both bundle ids.

## Handoff Template

- 2026-06-25 / Milestone 1 handoff:
  - Completed only Milestone 1 macOS build inventory; did not move to Milestone 2+.
  - No application source code or Xcode project settings were intentionally changed; generated/build artifacts and logs were produced by required commands.
  - Successful commands: `scripts/apple/bootstrap.sh`, `flutter clean && flutter pub get`, `dart run build_runner build --delete-conflicting-outputs`, `flutter build macos --debug`, `flutter build macos --release`.
  - Verified release app launch via `open` and via Finder AppleScript from `build/macos/Build/Products/Release/Hiddify.app`.
  - Open blocker: strict codesign verification fails for nested `LaunchAtLoginHelper.app`; build and launch are OK, distribution signing/notarization readiness is not OK.
  - Next recommended milestone when requested: stay with Milestone 1 if distribution-grade macOS signing must be fixed, otherwise proceed to Milestone 2 only after explicit instruction.

При завершении работы агент должен оставить запись:

```md
### YYYY-MM-DD / Agent

Scope:
- Что делали.

Result:
- Что получилось.

Changed files:
- `path/to/file`

Verification:
- Команды, устройства, версии окружения.

Open issues:
- Что осталось.
```

### 2026-06-25 / Codex

Scope:
- Выполнил только Milestone 0: инвентаризация Apple окружения, signing/capabilities, bundle ids, entitlements и фактических project settings для iOS/macOS.

Result:
- Apple toolchain подтвержден через `source scripts/apple/env.sh`: Flutter/Dart/CocoaPods/Xcode доступны, `flutter doctor -v` без критичных ошибок для macOS/iOS.
- iOS Runner и HiddifyPacketTunnel имеют bundle ids, App Group, Network Extension/VPN API entitlements и automatic signing через `$(APPLE_DEVELOPMENT_TEAM)`.
- macOS Runner имеет bundle id `app.hiddify.com`, но активные entitlements не содержат Network Extension/App Group; sandbox выключен. Пункт сравнения expected/actual capabilities помечен `[!]`.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `sw_vers`: macOS 26.5.1 (25F80).
- `xcode-select -p`: `/Library/Developer/CommandLineTools`.
- `source scripts/apple/env.sh && xcodebuild -version`: Xcode 26.5 (17F42).
- `source scripts/apple/env.sh && flutter --version`: Flutter 3.38.5, Dart 3.10.4.
- `source scripts/apple/env.sh && pod --version`: CocoaPods 1.16.2.
- `source scripts/apple/env.sh && flutter doctor -v`: Xcode/macOS/iOS checks green; Android SDK and Chrome missing only.
- `source scripts/apple/env.sh && flutter devices`: iPhone (Dima), iOS 18.7.9 (22H355), and macOS desktop detected.
- `xcrun simctl list devices available`: iOS 18.6 and iOS 26.5 simulators available.
- `security find-identity -v -p codesigning`: one valid Apple Development identity.
- `plutil -p` on iOS/macOS Info.plist and entitlements; `rg` over `ios/Runner.xcodeproj/project.pbxproj`, `macos/Runner.xcodeproj/project.pbxproj`, `ios/Base.xcconfig`, `ios/AppleSigning.xcconfig`, `macos/Runner/Configs/AppInfo.xcconfig`.

Open issues:
- macOS VPN/proxy capabilities are not active in project settings; defer fixes to later macOS VPN/proxy milestone.
- Raw shell must source `scripts/apple/env.sh` before Apple commands, otherwise `flutter`/`pod` are unavailable and `xcodebuild` uses CommandLineTools.

### 2026-06-25 / Codex

Scope:
- Выполнил только Milestone 2: инвентаризация iOS clean/pub get, CocoaPods, simulator build, physical device debug build, archive/IPA export и установка на реальный iPhone.

Result:
- iOS simulator build успешен: `build/ios/iphonesimulator/Runner.app`.
- iOS device/debug build успешен: `build/ios/iphoneos/Runner.app`, automatic signing через team `CH87655747`.
- Archive создан: `build/ios/archive/Runner.xcarchive`; App Store IPA export заблокирован из-за отсутствующих Xcode account/distribution certificate/provisioning profiles.
- Debug app установлено и подтверждено на `iPhone (Dima)`: `Hiddify app.zeon.ios 1.2.1 10201`.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m2-01-clean-pub-get-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-02-ios-pod-install-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-03-ios-simulator-build-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-04-ios-device-debug-build-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-05-ios-ipa-build-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-06-ios-install-iphone-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-07-ios-install-verification-2026-06-25.log`

Verification:
- `source scripts/apple/env.sh && sw_vers`: macOS 26.5.1 (25F80).
- `source scripts/apple/env.sh && xcodebuild -version`: Xcode 26.5 (17F42).
- `source scripts/apple/env.sh && flutter --version`: Flutter 3.38.5, Dart 3.10.4.
- `source scripts/apple/env.sh && pod --version`: CocoaPods 1.16.2.
- `source scripts/apple/env.sh && flutter devices`: iPhone (Dima), iOS 18.7.9 (22H355), and macOS desktop detected.
- `source scripts/apple/env.sh && flutter clean && flutter pub get`: success.
- `source ../scripts/apple/env.sh && pod install` from `ios/`: success with non-fatal custom base configuration warning.
- `source scripts/apple/env.sh && flutter build ios --simulator`: success.
- `source scripts/apple/env.sh && flutter build ios --debug`: success.
- `source scripts/apple/env.sh && flutter build ipa`: archive success; IPA export blocked by distribution signing/profiles.
- `source scripts/apple/env.sh && flutter install -d 00008020-001608162E93802E`: returned 0.
- `source scripts/apple/env.sh && xcrun devicectl device info apps --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 --bundle-id app.zeon.ios`: installed app confirmed.

Open issues:
- App Store IPA export requires Apple Developer/Xcode account, iOS Distribution certificate, and matching App Store provisioning profiles for `app.zeon.ios` and `app.zeon.ios.HiddifyPacketTunnel`.
- CocoaPods custom base configuration warning remains for iOS Runner; it did not block simulator/device/archive build in this inventory pass.

### 2026-06-25 / Codex

Scope:
- Продолжил только Milestone 2 по запросу: исправил причину, из-за которой iOS приложение не запускалось/давало runtime errors, и проверил standalone запуск после пересборки `hiddify-core`.

Result:
- Исправлен `flutter_local_notifications` startup error на iOS: добавлены Darwin initialization/details и iOS/macOS permission requests.
- Исправлен uncaught startup/foreground notification polling error: HTTP 400 теперь остается warning/backoff, а не `PlatformDispatcherError`.
- Debug artifact limitation зафиксирована: debug app нельзя запускать с Home Screen без Flutter tooling/Xcode; для standalone проверки использован profile build.
- Profile app установлен и запущен на `iPhone (Dima)`: final log показывает `AppLifecycleState.resumed`, `Hiddify-core setup done`, `ConnectionNotifier connection status: CONNECTED`.
- С новым `HiddifyCore.xcframework` ошибка `unknown load balance strategy: smart-active-auto` не воспроизводится.

Changed files:
- `lib/features/notifications/service/system_notification_service.dart`
- `lib/features/notifications/service/notification_polling_service.dart`
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m2-08-ios-flutter-run-launch-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-09-ios-flutter-run-after-notification-fix-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-10-ios-flutter-run-after-core-rebuild-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-11-ios-devicectl-console-after-core-rebuild-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-12-ios-profile-build-after-core-rebuild-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-13-ios-profile-install-after-core-rebuild-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-14-ios-profile-standalone-launch-after-core-rebuild-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-15-ios-profile-build-after-polling-fix-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-16-ios-profile-install-after-polling-fix-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m2-17-ios-profile-standalone-launch-after-polling-fix-2026-06-25.log`

Verification:
- `source scripts/apple/env.sh && lipo -info hiddify-core/bin/hiddify-core.dylib`: `x86_64 arm64`.
- `source scripts/apple/env.sh && lipo -info ios/Frameworks/HiddifyCore.xcframework/ios-arm64/HiddifyCore.framework/HiddifyCore`: `arm64`.
- `source scripts/apple/env.sh && lipo -info ios/Frameworks/HiddifyCore.xcframework/ios-arm64_x86_64-simulator/HiddifyCore.framework/HiddifyCore`: `x86_64 arm64`.
- `source scripts/apple/env.sh && dart analyze lib/features/notifications/service/notification_polling_service.dart lib/features/notifications/service/system_notification_service.dart`: no issues.
- `source scripts/apple/env.sh && flutter test test/features/notifications/data/notification_repository_test.dart test/core/preferences/preferences_migration_test.dart`: all tests passed.
- `source scripts/apple/env.sh && flutter build ios --profile --no-pub`: success.
- `source scripts/apple/env.sh && xcrun devicectl device install app --device 00008020-001608162E93802E build/ios/iphoneos/Runner.app`: success.
- `source scripts/apple/env.sh && xcrun devicectl device process launch --device 00008020-001608162E93802E --terminate-existing --console ... app.zeon.ios`: app launched, resumed, core connected.

Open issues:
- App Store IPA export is still blocked by distribution signing/provisioning (`iOS Distribution` certificate and App Store profiles for Runner and HiddifyPacketTunnel).
- Notification backend returns HTTP 400 for current startup/foreground sync requests; app no longer treats it as an uncaught startup error, but backend/request contract still needs product/API follow-up.
