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
- [x] Сравнить expected capabilities с фактическими Xcode project settings.
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
- [x] Собрать iOS release/archive через Xcode или `flutter build ipa`, если signing готов.
- [x] Установить приложение на реальный iPhone.
- [x] Если сборка падает, сохранить ключевые ошибки в раздел "Build Log Notes".
- [x] Исправить ошибки зависимостей, Podfile, entitlements, signing, provisioning или native code.
- [x] Зафиксировать итоговую команду воспроизводимой iOS сборки.

## Milestone 3: macOS VPN и Proxy

- [x] Описать expected behavior: что считается успешным VPN подключением на macOS.
- [x] Описать expected behavior: что считается успешным proxy подключением на macOS.
- [x] Проверить наличие и корректность Network Extension entitlements.
- [x] Проверить System Extension / Network Extension разрешения в macOS System Settings.
- [x] Проверить логи приложения при connect/disconnect.
- [x] Проверить Console.app logs для network extension/provider process.
- [x] Проверить, стартует ли core/sing-box процесс на macOS.
- [x] Проверить, создается ли tun/interface или proxy listener.
- [x] Проверить маршрутизацию: DNS, default route, split route, bypass LAN.
- [x] Проверить доступность тестового URL до подключения.
- [x] Проверить доступность тестового URL после VPN подключения.
- [x] Проверить доступность тестового URL после proxy подключения.
- [x] Проверить корректный disconnect и очистку routes/DNS/listeners.
- [x] Исправить root cause для macOS VPN.
- [x] Исправить/закрыть root cause для macOS proxy.
- [x] Добавить regression notes или automated checks, если возможно.

## Milestone 4: iOS VPN и Proxy стабильность

- [x] Описать expected behavior для iOS VPN tunnel.
- [x] Проверить установку VPN profile/permission flow на чистом устройстве.
- [x] Проверить первый connect после установки.
- [x] Проверить 10 циклов connect/disconnect подряд.
- [x] Проверить reconnect после lock/unlock устройства.
- [x] Проверить reconnect после переключения Wi-Fi/LTE.
- [x] Проверить reconnect после airplane mode on/off.
- [x] Проверить поведение после force close приложения.
- [x] Проверить, держится ли туннель в фоне.
- [x] Проверить DNS leaks и routing после подключения.
- [x] Проверить стабильность core/sing-box и memory/cpu при 15+ мин активного туннеля.
- [x] Найти и исправить причину нестабильности VPN tunnel.
- [x] Проверить proxy подключение на iPhone или явно зафиксировать, что режим не поддерживается.

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
- [ ] Ошибка с логами после обновления профиля в режиме впн

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
- 2026-06-27 / Milestone 2 signed iOS IPA:
  - Environment re-verified with `source scripts/apple/env.sh`: macOS 26.5.1 (25F80), Xcode 26.5 build 17F42, Flutter 3.38.5, Dart 3.10.4, CocoaPods 1.16.2. Connected target: physical iPhone `iPhone (Dima)` on iOS 18.7.9 (22H355).
  - `security find-identity -v -p codesigning` shows local `Apple Development: Dima Moiseev (37NM4393T6)` only, but Xcode account export succeeded with Cloud Managed Apple Distribution.
  - `flutter build ipa` completed successfully. Archive: `build/ios/archive/Runner.xcarchive` (359.9MB). IPA output: `build/ios/ipa/Runner.ipa` (72MB / export reported 77.7MB).
  - IPA SHA-256: `b11fa63d7d0f17aec95ca289f9bc5f2fe266984077f2932e15e1d422e259121f`.
  - Export options: `method=app-store-connect`, `signingStyle=automatic`, `teamID=CH87655747`, `uploadSymbols=true`, `testFlightInternalTestingOnly=false`.
  - `codesign -dv --verbose=4` on `Payload/Runner.app` and `Payload/Runner.app/PlugIns/HiddifyPacketTunnel.appex` shows `Authority=Apple Distribution: Dima Moiseev (CH87655747)` and `TeamIdentifier=CH87655747`.
  - Export summary reports `Cloud Managed Apple Distribution`, certificate SHA1 `B9F419475FAD6DC1679404B9F239B2519AD40BAE`, expires `27.06.2027`.
  - Runtime entitlements in signed IPA: Runner has production APS, Network Extension (`app-proxy-provider`, `dns-proxy`, `packet-tunnel-provider`), VPN API `allow-vpn`, App Group `group.app.zeon.ios`, and `get-task-allow=false`; HiddifyPacketTunnel has Network Extension (`app-proxy-provider`, `dns-proxy`, `packet-tunnel-provider`, `content-filter-provider`), VPN API `allow-vpn`, App Group `group.app.zeon.ios`, and `get-task-allow=false`.
  - Embedded provisioning profiles are Xcode-managed App Store profiles: `iOS Team Store Provisioning Profile: app.zeon.ios` and `iOS Team Store Provisioning Profile: app.zeon.ios.HiddifyPacketTunnel`, both expiring `2027-06-27 09:17:00 +0000`.
  - Log saved under `docs/apple-mac-ios-release/logs/`: `m2-18-ios-ipa-build-after-xcode-login-2026-06-27.log`.
- 2026-06-25 / Milestone 3 macOS VPN/proxy inventory:
  - Environment re-verified with `source scripts/apple/env.sh`: macOS 26.5.1 (25F80), Xcode 26.5 build 17F42, Flutter 3.38.5, Dart 3.10.4, CocoaPods 1.16.2. Connected targets: iPhone `iPhone (Dima)` on iOS 18.7.9 and macOS desktop `darwin-x64`.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m3-01-macos-debug-build-2026-06-25.log`, `m3-02-macos-app-launch-network-state-2026-06-25.log`, `m3-03-macos-console-log-after-launch-2026-06-25.log`, `m3-04-macos-app-logs-after-launch-2026-06-25.log`, `m3-05-macos-ui-buttons-2026-06-25.log`, `m3-06-macos-ui-elements-2026-06-25.log`, `m3-07-macos-current-config-inventory-2026-06-25.log`, `m3-08-macos-proxy-port-check-2026-06-25.log`, `m3-09-macos-built-app-entitlements-2026-06-25.log`, `m3-10-macos-filtered-runtime-logs-2026-06-25.log`.
  - `flutter build macos --debug` completed successfully: `build/macos/Build/Products/Debug/Hiddify.app`.
  - `xcodebuild -list -project macos/Runner.xcodeproj` shows only `Runner`, `RunnerTests`, and `Flutter Assemble`; no macOS Network Extension/System Extension target exists.
  - `plutil -p macos/Runner/DebugProfile.entitlements` and `plutil -p macos/Runner/Release.entitlements` show only sandbox=false, allow-jit, network client/server. `codesign -d --entitlements :- build/macos/Build/Products/Debug/Hiddify.app` confirms no active Network Extension or App Group entitlement in the built app.
  - `systemextensionsctl list` reports `0 extension(s)`. Network Extension plist files exist under `/Library/Preferences`, but there is no Zeon/Hiddify provider process or approved extension to validate in System Settings.
  - Test environment is contaminated by another active VPN: `/Applications/Happ.app/Contents/MacOS/tun/sing-box` runs as root, owns `utun4`, and installs split/default-like routes via `172.18.0.1`. This prevents clean attribution of DNS/routes/connectivity to Zeon.
  - Launching the debug app starts `Hiddify.app/Contents/MacOS/Hiddify`; app log shows `Hiddify-core setup done` and `connection status: DISCONNECTED`. No separate Zeon `hiddify-core`, `sing-box`, PacketTunnel, or Network Extension provider process appears.
  - Current generated config contains mixed inbounds on `::1:12334` and `127.0.0.1:12334` with `set_system_proxy=true`, plus redirect/direct inbounds on `12336/12337`, but no listener exists on `12334/12336/12337` while the app is disconnected.
  - `networksetup -getwebproxy Ethernet`, `-getsecurewebproxy Ethernet`, and `-getsocksfirewallproxy Ethernet` show `Enabled: No` with stale server `127.0.0.1` / port `12334`; `Ethernet 2` proxies are disabled and empty.
  - Direct URL check before Zeon connection works: `curl -I --max-time 15 https://example.com` returns HTTP 200. Proxy URL check fails because no Zeon listener exists: `curl -I --max-time 20 --proxy http://127.0.0.1:12334 https://example.com` returns `Failed to connect to 127.0.0.1 port 12334`.
  - App runtime warnings observed: system tray initialization timeout, `ProxyFailure.serviceNotRunning()`, notification API HTTP 400 warnings, update check HTTP 404 warning. `box.log` contains many outbound URL-test/DNS warnings from profile monitoring; secrets/profile contents were not copied into this TODO.
  - `codesign --verify --deep --strict --verbose=2 build/macos/Build/Products/Debug/Hiddify.app` still fails on nested `Contents/Library/LoginItems/LaunchAtLoginHelper.app` with `invalid Info.plist`, same class of issue as Milestone 1 release verification.
- 2026-06-25 / Milestone 3 clean diagnostic run:
  - User-provided clean diagnostic artifacts inspected: `out/diagnostics/macos_network_20260625_165429`.
  - Happ was not detected in the clean run, and routes stayed on `en1` via `192.168.3.1`, so routing data is attributable to the Zeon test session.
  - System proxy mode works in this run: after Connect, `networksetup` showed HTTP/HTTPS/SOCKS proxy enabled on active service `Ethernet` with `127.0.0.1:12334`, and `curl -I --max-time 20 --proxy http://127.0.0.1:12334 https://example.com` returned `HTTP/1.1 200 Connection established` then `HTTP/2 200`. After Disconnect, proxy settings were disabled and proxied curl failed to connect, as expected.
  - VPN/tun mode fails before becoming connected. App log shows config with `tun-implementation: gvisor`, lifecycle `stopped -> starting`, then `manager start inbound/tun[tun-in]: configure tun interface: Connect: operation not permitted`, followed by `CONNECTION FAILURE` and `DISCONNECTED`.
  - The built macOS app still has no active Network Extension/App Group entitlement and the macOS project still has no Network Extension/System Extension target. This confirms the current VPN path is a direct desktop sing-box TUN attempt, not a macOS Packet Tunnel provider flow.
  - A secondary UX/runtime issue appears after the VPN failure: `PlatformDispatcherError: Failed assertion ... Cannot use ref functions after the dependency of a provider changed but before the provider rebuilt`. This may explain why the UI gives no useful visible error after the failed VPN start.
- 2026-06-25 / Apple VPN/TUN direction:
  - Product direction changed for Apple builds: use VPN/TUN as the only service mode in iOS/macOS UI and preferences; ordinary proxy/system-proxy modes should not be offered in Apple settings/tray/quick settings.
  - Implemented UI/default guardrails in Dart: Apple `ServiceMode.defaultMode` is `vpn`, Apple `ServiceMode.choices` is `[vpn]`, stale stored Apple service modes fall back/migrate to `vpn`, and single-choice service mode controls are hidden.
  - Verified changed Dart files with `source scripts/apple/env.sh && flutter analyze ...`: no issues.
  - Real environment check: `source scripts/apple/env.sh && xcodebuild -showBuildSettings -project macos/Runner.xcodeproj -scheme Runner` reports `PRODUCT_BUNDLE_IDENTIFIER = app.hiddify.com`, `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_ENTITLEMENTS = Runner/DebugProfile.entitlements`, but `DEVELOPMENT_TEAM` is empty.
  - Real environment check: `security find-identity -v -p codesigning` reports one valid Apple Development identity: `Apple Development: Dima Moiseev (37NM4393T6)`.
  - Added macOS signing hook matching the iOS pattern: tracked `AppleSigning.xcconfig.example`, ignored local `macos/Runner/Configs/AppleSigning.xcconfig`, and `AppInfo.xcconfig` variables for `MACOS_DEVELOPMENT_TEAM` / `MACOS_BUNDLE_IDENTIFIER`.
  - After local `MACOS_DEVELOPMENT_TEAM = CH87655747`, `xcodebuild -showBuildSettings` reports `DEVELOPMENT_TEAM = CH87655747` and `_DEVELOPMENT_TEAM_IS_EMPTY = NO`.
  - `source scripts/apple/env.sh && flutter build macos --debug` still succeeds after the signing hook: `build/macos/Build/Products/Debug/Hiddify.app`.
  - Core build path fixed for macOS Packet Tunnel work: `hiddify-core/cmd/internal/build_libcore -target ios` now builds `bin/HiddifyCore.xcframework` with `ios-arm64`, `ios-arm64_x86_64-simulator`, and `macos-arm64_x86_64`.
  - Successful verification: `plutil -p hiddify-core/bin/HiddifyCore.xcframework/Info.plist` shows `SupportedPlatform = macos` for `macos-arm64_x86_64`.
- 2026-06-25 / macOS Packet Tunnel implementation pass:
  - Added a real macOS `HiddifyPacketTunnel` Network Extension target to `macos/Runner.xcodeproj`, embedded it into `Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex`, and linked `hiddify-core/bin/HiddifyCore.xcframework`.
  - Added host app VPN manager bridge using `NETunnelProviderManager`; macOS now uses the mobile core interface and App Group paths so the host and provider share generated config/runtime directories.
  - Added macOS Packet Tunnel provider lifecycle Swift code: setup `Libbox`, create packet tunnel network settings, open the NE packet flow file descriptor, start `MobileStart(configPath, "")`, and write provider errors to the shared working directory.
  - `source scripts/apple/env.sh && flutter analyze ...` for changed Dart files reports no issues.
  - `plutil -lint` for macOS app/extension Info.plist and entitlement files reports OK.
  - `source scripts/apple/env.sh && flutter build macos --debug` succeeds and builds `build/macos/Build/Products/Debug/Hiddify.app`.
  - Built debug app now contains `Contents/PlugIns/HiddifyPacketTunnel.appex`.
  - Active codesign entitlements for both host app and Packet Tunnel provider include `com.apple.developer.networking.networkextension = packet-tunnel-provider`, `com.apple.developer.networking.vpn.api = allow-vpn`, sandbox, App Group `group.app.hiddify.com`, and network client/server.
  - Runtime route/DNS/utun validation is blocked in the current shell session because Happ is active again: `/Applications/Happ.app/Contents/MacOS/Happ`, `xray`, root `sing-box`, and `happd` are running.
  - Updated `scripts/apple/macos_network_diagnostics.sh` for clean Packet Tunnel validation: it now optionally builds `HiddifyCore.xcframework`, builds macOS debug app, verifies host/provider entitlements, confirms embedded `.appex`, waits for Happ/known VPN clients to be quit before clean capture, records `scutil --nc`, routes/DNS/utun snapshots, Console Network Extension logs, and App Group `network_extension_error.log`.
  - Smoke verification: `scripts/apple/macos_network_diagnostics.sh --no-core-build --no-build --no-open --non-interactive --skip-clean-check --out out/diagnostics/macos_packet_tunnel_smoke_codex_3` completed and summary correctly marks active Happ as `detected`.
  - User clean run reached the manual Connect prompt but `open` failed before app startup. Crash report `~/Library/Logs/DiagnosticReports/Hiddify-2026-06-25-191617.ips` shows `SIGKILL (Code Signature Invalid)`, `namespace=CODESIGNING`, `Taskgated Invalid Signature`.
  - Console root cause: `AMFI: ... Hiddify is adhoc signed` and `The file is adhoc signed but contains restricted entitlements`. The app was killed before Dart/Flutter startup because Network Extension/App Group entitlements cannot be used with ad-hoc signing.
  - Fixed macOS project signing identity from `CODE_SIGN_IDENTITY = "-"` to `Apple Development` and updated `scripts/apple/setup_macos_packet_tunnel.rb` to preserve `Apple Development` project-level code signing identity.
  - After the signing identity fix, `flutter build macos --debug` no longer produces a launchable ad-hoc restricted-entitlement app; it fails correctly at provisioning: no Mac App Development profiles for `app.hiddify.com` and `app.hiddify.com.HiddifyPacketTunnel`.
  - `xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -allowProvisioningUpdates build` also fails with `No Accounts` and missing profiles. This means the CLI/Xcode build environment currently cannot access an Apple Developer account/profiles for macOS signing.
  - Updated diagnostics runner to use the signed `xcodebuild -allowProvisioningUpdates` path, delete stale debug app before build, and stop before manual Connect if the app failed to launch.
- 2026-06-25 / macOS Packet Tunnel provisioning after Xcode account:
  - User added the Apple Developer account in Xcode. Re-check confirmed: raw `xcodebuild -version` still fails because global `xcode-select -p` is `/Library/Developer/CommandLineTools`; with `source scripts/apple/env.sh`, Xcode is `26.5` build `17F42`.
  - `security find-identity -v -p codesigning` reports one valid identity: `Apple Development: Dima Moiseev (37NM4393T6)`.
  - `app.hiddify.com` / `app.hiddify.com.HiddifyPacketTunnel` are not usable for team `CH87655747`; current macOS ids are `app.zeon.macos` and `app.zeon.macos.HiddifyPacketTunnel`.
  - `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` succeeded.
  - Xcode downloaded/created Mac Team provisioning profiles under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and embedded them into the built app:
    - Host app profile: `Mac Team Provisioning Profile: app.zeon.macos`, UUID `a8092090-552f-4fe8-ba67-1acdeca293ae`, expiration `2027-06-25 16:39:15 +0000`.
    - Packet Tunnel profile: `Mac Team Provisioning Profile: app.zeon.macos.HiddifyPacketTunnel`, UUID `16aeaa1d-e0db-4cbe-96d6-61f87f488b2a`, expiration `2027-06-25 16:39:17 +0000`.
  - Built bundle inspection: `Hiddify.app` contains `Contents/embedded.provisionprofile`; `Contents/PlugIns/HiddifyPacketTunnel.appex` contains its own `Contents/embedded.provisionprofile`.
  - `codesign -dv` confirms Team ID `CH87655747` for both `app.zeon.macos` and `app.zeon.macos.HiddifyPacketTunnel`.
  - Active entitlements for both host and extension now include `packet-tunnel-provider`, `allow-vpn`, sandbox, App Group `group.app.zeon.macos`, and network client/server.
  - `bash -n scripts/apple/macos_network_diagnostics.sh` reports OK after the signed-build path update.
  - Runtime Connect validation is still not clean in the current environment: `pgrep` shows active Happ UI, `happd`, `xray`, and root `sing-box`.
- 2026-06-27 / macOS Packet Tunnel connect failure after app launch:
  - User reported the app now launches but VPN tunnel still does not enable.
  - Fresh diagnostic attempt `out/diagnostics/macos_network_20260627_102725` stopped at clean-network guard; `logs/clean_network_blocker.log` shows active Happ UI, `happd`, `xray`, and root `sing-box`.
  - Existing App Group provider log `~/Library/Group Containers/group.app.zeon.macos/Library/Caches/Working/network_extension_error.log` contains the actionable Packet Tunnel failure: `setup failed: manager start inbound/tun[tun-in]: system and mixed stack are not available when includeAllNetworks is enabled`.
  - App log around the same failure shows payload `tun-implementation: mixed`, then background gRPC connection termination and `failed to start background core`.
  - Root cause for this pass: Apple Packet Tunnel provider returns `includeAllNetworks() = true`, so sing-box cannot use `mixed` or `system` TUN stack; Apple builds must force `tun-implementation = gvisor`.
  - Implemented guardrails: Apple preferences migration v13 sets `service-mode = vpn` and `tun-implementation = gvisor`; Apple preference mapping reads/writes `gvisor`; Apple settings hide TUN stack selection; core payload forcibly sets `tun-implementation` to `gvisor` on Apple before `MobileStart`.
  - Verification: `source scripts/apple/env.sh && flutter analyze lib/core/preferences/preferences_migration.dart lib/features/settings/data/config_option_repository.dart lib/features/settings/overview/sections/inbound_options_page.dart lib/hiddifycore/hiddify_core_service.dart` reports no issues.
  - Verification: `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` reports `BUILD SUCCEEDED`.
- 2026-06-27 / macOS Packet Tunnel post-connect interface failure:
  - Fresh user diagnostics inspected: `out/diagnostics/macos_network_20260627_103631`.
  - Packet Tunnel now starts: provider log shows `(packet-tunnel) starting`, setup completed, service started, then a later stop. The previous `mixed/includeAllNetworks` failure is gone.
  - App log shows Apple payload with `tun-implementation: gvisor`, lifecycle `stopped -> starting -> started`, and connection status `CONNECTED`.
  - Runtime snapshots show Zeon VPN entry connected for `app.zeon.macos`, `utun4` created with `172.19.0.1`, default route moved to `utun4`, DNS nameserver `172.19.0.2` attached to `utun4`, and local listener `127.0.0.1:12334` present.
  - Actual failure moved deeper into core routing: `box.log` repeatedly reports `outbound/balancer[balance]: no available network interface`, DNS remote exchange failures with `dial TCP connection: no available network interface`, rule-set fetch failures, URL-test failures, and server dial failure for `130.49.151.173:443`.
  - Root cause found in macOS provider bridge: `ExtensionPlatformInterface.getInterfaces()` returned `NetworkInterfaceArray([])`, so libbox/sing-box had no physical outbound interface candidates inside the Packet Tunnel.
  - Implemented macOS provider interface inventory using `NWPathMonitor.currentPath.availableInterfaces`, filtering out `utun*` and `lo0`, and added initial default-interface update for libbox.
  - Verification: `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` reports `BUILD SUCCEEDED`.
- 2026-06-27 / macOS Packet Tunnel health-check still cannot select live servers:
  - Fresh user diagnostics inspected: `out/diagnostics/macos_network_20260627_104932`.
  - There is no fatal app error: app log reaches `CONNECTED`, then proxy sorting and selected outbound display run. UI/runtime still emits separate Flutter build-phase `PlatformDispatcherError` warnings in `ConnectionButton`, `SideBarStatsOverview`, and `ActiveProxyFooter`.
  - The server health-check/routing problem is still `no available network interface`: `box.log` shows balancer, DNS, rule-set fetch, URL-test, TCP dial, and UDP listen attempts failing before they can reach live servers. Monitoring gives affected nodes `delay=65535`.
  - Runtime route/DNS are still installed: `utun4`, default route through `utun4`, DNS `172.19.0.2`; physical network is still visible to the host as `en1` with `192.168.3.103`.
  - Root cause refinement: `NWPathMonitor.currentPath.availableInterfaces` is not reliable as the provider's source of physical interfaces under macOS Packet Tunnel/include-all-networks. The provider must expose BSD interfaces such as `en1` by `getifaddrs`/`if_nametoindex` so sing-box `auto_detect_interface` can select an outbound route.
  - Implemented second provider fix: `getInterfaces()` now uses `getifaddrs`, filters virtual/loopback/tunnel interfaces, sets BSD index/flags/type for libbox, and logs `(packet-tunnel) platform interfaces: [...]` when the visible interface set changes. Default-interface monitor now falls back to the same BSD interface inventory when `NWPath` does not provide a physical interface.
  - Verification: `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` reports `BUILD SUCCEEDED`.
- 2026-06-27 / macOS Packet Tunnel explicit outbound interface config:
  - Fresh user diagnostics inspected: `out/diagnostics/macos_network_20260627_110009`.
  - Clean environment was valid for Zeon attribution: Happ UI/xray/root sing-box were not detected; only root `happd` remained. Zeon host app and `HiddifyPacketTunnel.appex` were running.
  - App Group app log confirms the current host path is `CoreInterfaceMobile`, not the old direct desktop core path. The non-group `app.log` still contains older `CoreInterfaceDesktop` lines and should not be treated as authoritative for this run.
  - Provider starts and stays alive until disconnect: `network_extension_error.log` shows starting, setup completed, service started, then stopping on disconnect. However the expected `(packet-tunnel) platform interfaces: [...]` marker did not appear.
  - Route/DNS are still installed correctly after Connect: Zeon VPN entry is connected, `utun4` exists with `172.19.0.1`, default route is `utun4`, DNS is `172.19.0.2`, and physical `en1` has `192.168.3.103`.
  - Traffic still fails before reaching live servers: `box.log` repeatedly reports `outbound/balancer[balance]: no available network interface`, DNS remote failures, rule-set fetch failures, URL-test failures, and direct connection failures to selected server IPs.
  - Root cause refinement: relying on libbox `auto_detect_interface` inside the macOS Packet Tunnel provider is still not enough; the dialer enables multi-interface strategy but has no populated physical interface set. For macOS provider startup, force sing-box to bind outbounds to the actual physical BSD interface by writing a provider-specific config with `route.default_interface=<PrimaryInterface>` and `route.auto_detect_interface=false`.
  - Implemented provider config rewrite before `MobileStart`: the Packet Tunnel reads macOS `State:/Network/Global/IPv4` `PrimaryInterface`, falls back to BSD interface inventory, writes `packet-tunnel-config.json` into the App Group working directory, and logs `(packet-tunnel) prepared config with default_interface=..., auto_detect_interface=false`.
  - Updated diagnostics to copy `packet-tunnel-config.json` from the App Group so future snapshots show the exact provider config.
  - Verification: `bash -n scripts/apple/macos_network_diagnostics.sh` reports OK.
  - Verification: `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` reports `BUILD SUCCEEDED`.
- 2026-06-27 / Milestone 4 iOS VPN/proxy stability inventory:
  - Environment re-verified with `source scripts/apple/env.sh`: macOS 26.5.1 (25F80), Xcode 26.5 build 17F42, Flutter 3.38.5, Dart 3.10.4, CocoaPods 1.16.2.
  - Connected target: physical iPhone `iPhone (Dima)` / iPhone XR on iOS 18.7.9 (22H355), UDID `00008020-001608162E93802E`, CoreDevice id `FE12C9C0-D99D-5EA0-B386-AEBC58E16123`.
  - Installed app inventory: `xcrun devicectl device info apps --device ... --bundle-id app.zeon.ios` shows `Hiddify app.zeon.ios 1.2.1 10201`.
  - Non-destructive launch/process check: `xcrun devicectl device process launch --terminate-existing app.zeon.ios` starts `Runner.app/Runner`; no `HiddifyPacketTunnel` process appears until a manual VPN Connect flow is performed.
  - iOS project inventory confirms `PRODUCT_BUNDLE_IDENTIFIER = app.zeon.ios`, team `CH87655747`, Runner and HiddifyPacketTunnel entitlements include Network Extension, VPN API `allow-vpn`, and App Group `group.$(BASE_BUNDLE_IDENTIFIER)`.
  - Current local `build/ios/ipa/Runner.ipa` at inventory time is development-signed (`get-task-allow=true`) and has runtime App Group `group.app.zeon.ios`; App Store signed IPA was separately verified in Milestone 2.
  - Static source inventory: Apple builds expose only `ServiceMode.tun` in `ServiceMode.choices`, default to VPN mode, and force `tun-implementation = gvisor`; standalone iPhone proxy mode is not a supported Apple product mode.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m4-01-ios-env-device-inventory-2026-06-27.log`, `m4-02-ios-signing-entitlements-inventory-2026-06-27.log`, `m4-03-ios-vpn-proxy-static-inventory-2026-06-27.log`, `m4-04-ios-installed-app-launch-process-inventory-2026-06-27.log`, `m4-05-ios-ipa-entitlements-inventory-2026-06-27.log`.
  - Live stability scenarios are blocked for this inventory pass because they require manual iOS VPN permission acceptance and physical device/network actions: clean-install permission flow, first connect, 10 connect/disconnect cycles, lock/unlock, Wi-Fi/LTE switch, airplane mode, force close behavior, background tunnel hold, DNS/routing leak checks, and 15+ minute CPU/memory observation.
- 2026-06-27 / Milestone 4 iOS foreground core unavailable while updating profile:
  - User reproduced profile update failure while VPN was active: `ProfileFailure.invalidConfig(... fg core unavailable while applying options ... Connection refused ... 127.0.0.1 ... port 62610)`. Same session also showed the selected auto-balanced server missing/blank in the main UI.
  - Device process inventory at reproduction time showed both host app and Packet Tunnel running: `Runner.app/Runner` and `Runner.app/PlugIns/HiddifyPacketTunnel.appex/HiddifyPacketTunnel`.
  - App Group copied from iPhone to `out/diagnostics/ios_fg_core_unavailable_20260627/app_group`. Important files: `Library/Caches/Working/app.log`, `Library/Caches/Working/network_extension_error.log`, and `Library/Caches/Working/data/box.log`.
  - `network_extension_error.log` shows Packet Tunnel started and setup completed. `data/box.log` is active and contains health-score checks plus `ActiveServerChanged` events, so the background Packet Tunnel/core was alive and selecting servers while foreground gRPC was unavailable to the host app.
  - Root cause for this pass: profile update/validation uses foreground core operations (`changeHiddifySettings`, `parse`) and fails if foreground gRPC is down, even when background/Packet Tunnel core is alive and able to serve the same operations.
  - Implemented Dart fallback in `lib/hiddifycore/hiddify_core_service.dart`: foreground operations now try fg, retry `setup()`, then use background core if it is active. This covers `changeOptions`, `validateConfigByPath`, and `generateFullConfigByPath`.
  - Verification: `source scripts/apple/env.sh && flutter analyze lib/hiddifycore/hiddify_core_service.dart` reports no issues.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m4-06-ios-fg-core-unavailable-process-inventory-2026-06-27.log`, `m4-07-ios-fg-core-unavailable-appgroup-file-list-2026-06-27.log`, `m4-08-ios-fg-core-unavailable-appgroup-copy-2026-06-27.log`, `m4-09-ios-fg-core-unavailable-appdata-copy-2026-06-27.log`, `m4-10-ios-fg-core-unavailable-copied-log-summary-2026-06-27.log`, `m4-11-ios-fg-core-unavailable-fallback-analyze-2026-06-27.log`.
- 2026-06-27 / Milestone 4 iOS foreground core fallback device install:
  - Built profile iOS app with the foreground/background core fallback: `source scripts/apple/env.sh && flutter build ios --profile`.
  - Build succeeded: `build/ios/iphoneos/Runner.app` (176.4MB), bundle id `app.zeon.ios`, automatic signing with team `CH87655747`.
  - Installed over the existing app without uninstalling/resetting data: `xcrun devicectl device install app --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 build/ios/iphoneos/Runner.app`.
  - Install succeeded and produced new app container path `.../Bundle/Application/DB8AAF65-127E-4AA4-BF02-12277454364B/Runner.app`.
  - Launched installed profile build: `xcrun devicectl device process launch --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 --terminate-existing app.zeon.ios`.
  - Post-launch process inventory shows both fresh host app and fresh Packet Tunnel extension running from the new bundle container: `Runner.app/Runner` and `Runner.app/PlugIns/HiddifyPacketTunnel.appex/HiddifyPacketTunnel`.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m4-12-ios-fg-core-fallback-profile-build-2026-06-27.log`, `m4-12a-ios-fg-core-fallback-install-env-2026-06-27.log`, `m4-13-ios-fg-core-fallback-profile-install-2026-06-27.log`, `m4-13a-ios-fg-core-fallback-app-info-before-postinstall-2026-06-27.log`, `m4-14-ios-fg-core-fallback-profile-launch-2026-06-27.log`, `m4-15-ios-fg-core-fallback-profile-postlaunch-inventory-2026-06-27.log`.
  - Runtime verification still requires manual UI action: update profile while VPN is connected and confirm no `fg core unavailable while applying options` toast appears.
- 2026-06-27 / Milestone 4 iOS fragmentation UI desync:
  - User reproduced a connected iOS VPN state after enabling fragmentation where the main UI still showed empty/`-` server state and no ping/link quality.
  - Process inventory showed the Packet Tunnel provider still running. App Group was copied to `out/diagnostics/ios_fragment_ui_desync_20260627/app_group`.
  - `network_extension_error.log` shows Packet Tunnel startup/setup completed. `data/box.log` remains active and includes `ActiveServerChanged group=balance active=...` events, but also many URL-test deadline/timeouts and `missing default interface` records after fragmentation.
  - `data/current-config.json` confirms selector `select` defaults to `balance`, with balancer groups and `direct-fragment §hide§`; the background core can know the active real outbound while the UI receives an empty active proxy object.
  - Implemented Dart UI fallback in `lib/features/proxy/active/active_proxy_notifier.dart`: when `watchActiveProxies()` emits an empty `OutboundInfo`, the active proxy stream now resolves display state from selector metadata and `SystemInfo.currentOutbound`. Auto-balancer display keeps `balance` as group and fills `groupSelectedTag`/`groupSelectedTagDisplay` with the real selected server when available.
  - Verification: `source scripts/apple/env.sh && flutter analyze lib/features/proxy/active/active_proxy_notifier.dart lib/hiddifycore/hiddify_core_service.dart` reports no issues after replacing deprecated protobuf clone/copy APIs with `deepCopy()`.
  - Built updated profile iOS app: `source scripts/apple/env.sh && flutter build ios --profile`; build succeeded at `build/ios/iphoneos/Runner.app` (176.4MB).
  - Installed over the existing iPhone app without uninstalling/resetting data: `xcrun devicectl device install app --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 build/ios/iphoneos/Runner.app`; install succeeded with bundle path `.../Bundle/Application/68003F2F-DC94-46F4-9937-E27F13B2504E/Runner.app`.
  - Launch via `xcrun devicectl device process launch --terminate-existing app.zeon.ios` is blocked by iOS security: `Unable to launch app.zeon.ios because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user`.
  - Post-install inventory still shows `Hiddify app.zeon.ios 1.2.1 10201` installed and `HiddifyPacketTunnel.appex` running from the newly installed bundle path; host app UI verification remains manual until the profile is trusted/opened on device.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m4-16-ios-fragment-ui-desync-process-inventory-2026-06-27.log`, `m4-17-ios-fragment-ui-desync-appgroup-copy-2026-06-27.log`, `m4-18-ios-fragment-ui-desync-working-file-list-2026-06-27.log`, `m4-19-ios-fragment-ui-desync-log-summary-2026-06-27.log`, `m4-20-ios-fragment-ui-desync-active-proxy-fallback-analyze-2026-06-27.log`, `m4-21-ios-fragment-ui-desync-fallback-analyze-clean-2026-06-27.log`, `m4-22-ios-fragment-ui-desync-fallback-analyze-clean-2026-06-27.log`, `m4-23-ios-fragment-ui-desync-fallback-analyze-clean-2026-06-27.log`, `m4-24-ios-fragment-ui-desync-fallback-profile-build-2026-06-27.log`, `m4-25-ios-fragment-ui-desync-fallback-profile-install-2026-06-27.log`, `m4-26-ios-fragment-ui-desync-fallback-profile-launch-2026-06-27.log`, `m4-27-ios-fragment-ui-desync-fallback-postlaunch-inventory-2026-06-27.log`.
- 2026-06-27 / Milestone 4 iOS auto-select slow active choice inventory:
  - User reported that auto-select pinged servers for a while but did not immediately choose an active connection even after successful candidates appeared.
  - Fresh device process inventory showed both `Runner.app/Runner` and `HiddifyPacketTunnel.appex/HiddifyPacketTunnel` running from the installed bundle path `68003F2F-DC94-46F4-9937-E27F13B2504E/Runner.app`.
  - App Group copied from iPhone to `out/diagnostics/ios_auto_select_slow_20260627/app_group`.
  - Current config has `select.default = balance`, `balance.strategy = smart-active-auto`, `balance.tolerance = 1`, 110 balancer outbounds, and `experimental.monitoring.interval = 3m0s` with 5 URL candidates and `idle_timeout = 9m0s`.
  - Recent `box.log` confirms successful candidates existed, but after the latest active switch most successes were policy-penalized RU servers with score `55`, or low-score candidates such as `🇷🇺Россия10` score `15` and `🇵🇱Польша7` score `40`; many non-penalized foreign candidates were simultaneously timing out/deadlining.
  - Source inspection confirms this is plausible current Smart Active behavior: a healthy active is sticky, score alone does not switch live traffic, previously bad candidates need evidence, and switches require startup/manual-refresh conditions, active degradation, critical runtime errors, or a clearly better policy-preferred candidate.
  - No app code was changed for this pass.
  - Logs saved under `docs/apple-mac-ios-release/logs/`: `m4-28-ios-auto-select-slow-appgroup-copy-2026-06-27.log`, `m4-29-ios-auto-select-slow-summary-2026-06-27.log`.
- 2026-06-27 / Milestone 4 closed by user acceptance:
  - User accepted Milestone 4 as closed after the installed iOS build and manual observation: no more `fg core unavailable`, fragmentation active-server UI, or iOS VPN stability errors were seen.
  - Remaining live-device checklist items are closed as accepted manual verification for this release pass; destructive clean-device reset remains intentionally not performed on the personal iPhone.
  - Next work should start at Milestone 5 only after explicit instruction.

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

- Initial finding before Milestone 3 remediation: `PRODUCT_BUNDLE_IDENTIFIER = app.hiddify.com`, no macOS `DEVELOPMENT_TEAM`, ad-hoc signing, inactive Network Extension/App Group entitlements, and no macOS packet tunnel/system extension target.
- Current Milestone 3 state after remediation: signed debug macOS build uses `app.zeon.macos` for Runner and `app.zeon.macos.HiddifyPacketTunnel` for the Packet Tunnel extension, team `CH87655747`, `CODE_SIGN_IDENTITY = Apple Development`, and automatic signing.
- Current active entitlements for both host and Packet Tunnel provider include Network Extension `packet-tunnel-provider`, VPN API `allow-vpn`, App Group `group.app.zeon.macos`, sandbox, and network client/server.
- Current built app embeds `Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex` plus separate embedded provisioning profiles for host and extension.

Expected vs actual capabilities:

- iOS expected VPN/proxy capabilities are mostly represented in actual project settings: Runner and HiddifyPacketTunnel both have Network Extension, VPN API, App Group, sandbox and network client/server entitlements. The extension includes `content-filter-provider` while Runner does not; verify whether the app target also needs this before release.
- macOS expected VPN capabilities now match the signed debug Packet Tunnel build at the Xcode settings/entitlements/provisioning level. Runtime Connect, route, DNS, and utun validation remain open under Milestone 3.

## Milestone 3 Inventory

Environment verified on 2026-06-25:

- Host OS: macOS 26.5.1 (25F80), `darwin-x64`.
- Toolchain activation: `source scripts/apple/env.sh`.
- Xcode: 26.5 build 17F42 from `/Applications/Xcode.app/Contents/Developer`.
- Flutter: 3.38.5; Dart: 3.10.4; CocoaPods: 1.16.2.
- Connected devices: iPhone `iPhone (Dima)` on iOS 18.7.9 (22H355) and macOS desktop.

Expected macOS VPN behavior:

- The app offers/uses a macOS-supported tunnel mode only after the required native architecture exists: a signed Network Extension/System Extension or an explicitly supported userspace TUN implementation.
- On connect, the active profile starts successfully, status becomes connected, and either a Zeon-owned tunnel interface/routes/DNS changes appear or the product explicitly documents that macOS VPN mode is unsupported.
- Traffic to a test URL succeeds through the selected profile, LAN bypass and strict route behave according to settings, and disconnect restores DNS/routes/interfaces/listeners without stale system state.

Expected macOS proxy behavior:

- Historical `system-proxy` behavior was validated before the Apple VPN-only product decision. Current Apple builds should not expose proxy mode in settings/tray/quick settings; keep this as regression context only.
- In `system-proxy` mode, connecting starts the core with local mixed listeners from generated config, currently expected on `127.0.0.1:12334` and `::1:12334`.
- macOS system HTTP/HTTPS/SOCKS proxy settings for the active network service become enabled and point to the Zeon listener while connected.
- `curl --proxy http://127.0.0.1:12334 https://example.com` succeeds while connected, direct system proxy consumers route through Zeon, and disconnect disables/removes proxy settings and closes listeners.

Actual macOS VPN/proxy inventory:

- Initial clean run before Packet Tunnel remediation proved the old direct desktop TUN path fails with `manager start inbound/tun[tun-in]: configure tun interface: Connect: operation not permitted`.
- Current signed debug build contains a real macOS `HiddifyPacketTunnel.appex`, host/provider Network Extension entitlements, App Group `group.app.zeon.macos`, and embedded Mac Team provisioning profiles for both bundle ids.
- Current host bundle id is `app.zeon.macos`; current provider bundle id is `app.zeon.macos.HiddifyPacketTunnel`.
- Current signed build now reaches manual Connect: provider starts, app reports `CONNECTED`, `utun4` is created, default route moves to `utun4`, DNS is assigned to `172.19.0.2`, and `127.0.0.1:12334` is listening.
- Current post-connect traffic validation is still open: latest run `out/diagnostics/macos_network_20260627_112633` failed because macOS launched an old Packet Tunnel provider from `~/Library/Developer/Xcode/DerivedData/Runner-hjitbomcmkyrdthbfybjgxyzbwws/...`, not the freshly built provider embedded in `build/macos/Build/Products/Debug/Hiddify.app`. That stale provider did not contain or execute the new `packet-tunnel-config.json` / `default_interface` code path, so `box.log` still reported `no available network interface`.
- Debug VPN setup now removes matching existing `NETunnelProviderManager` preferences before creating the service again, forcing macOS to refresh provider registration against the current embedded `.appex`. The diagnostic script now reports the live Packet Tunnel runtime path as `fresh` or `stale-or-different`.
- Follow-up inspection found the deeper stale-provider cause: PlugInKit had two registered `app.zeon.macos.HiddifyPacketTunnel` providers, one under old default Xcode `DerivedData` and one under the current `build/macos` app. The stale DerivedData app has been unregistered/removed locally, and the diagnostic script now performs this cleanup automatically before build/open.
- Clean runtime validation `out/diagnostics/macos_network_20260627_115838` confirms the macOS VPN path works: provider launched from current `build/macos/.../HiddifyPacketTunnel.appex`, wrote `packet-tunnel-config.json` with `default_interface=en1` and `auto_detect_interface=false`, created `utun4`, moved default route/DNS to the tunnel, returned `HTTP/2 200` for direct and local-proxy URL checks after connect, and restored route/DNS/listeners after disconnect.
- Remaining macOS VPN UX issue: the app asked for VPN tunnel permission again because debug runtime code recreated `NETunnelProviderManager` on every setup. That forced macOS to treat each connect as a new VPN service. The app now reuses an existing matching manager and only creates a new VPN service when none exists.
- Historical system-proxy clean run succeeded on `127.0.0.1:12334`, but proxy modes are now out of scope for Apple UI/product path.

Regression notes / candidate checks:

- Add a macOS smoke diagnostic that records active entitlements, `systemextensionsctl list`, Zeon-owned processes, listeners on expected mixed proxy ports, `networksetup` proxy state, `ifconfig` tunnel interfaces, `route -n get default`, `netstat -rn -f inet`, `scutil --dns`, and direct/proxied `curl` results before connect, after connect, and after disconnect.
- Added reusable diagnostic runner: `scripts/apple/macos_network_diagnostics.sh`. Recommended clean run after quitting Happ/other VPN clients: `scripts/apple/macos_network_diagnostics.sh`; it builds debug macOS, launches the app, pauses for manual Connect/Disconnect, captures snapshots/logs, and writes `out/diagnostics/macos_network_YYYYMMDD_HHMMSS/SUMMARY.md`.
- Updated diagnostic runner to avoid requiring `rg`; it now falls back to `grep` for process/interface/listener/project scans so user Terminal PATH differences do not remove important sections from snapshots.
- Updated diagnostic runner to detect stale Network Extension registration by comparing the running `HiddifyPacketTunnel.appex` process path with the freshly built `APP_PATH`.
- Updated diagnostic runner to stop old Zeon/Hiddify processes, unregister/remove stale `Hiddify.app` copies under Xcode `DerivedData`, and re-register the freshly built app/appex before launch.
- Keep proxy checks scoped to the active network service detected from `route -n get default`, not a hard-coded `Wi-Fi`, because this host reports `Ethernet` and `Ethernet 2`.
- Run future routing/VPN checks in a clean network environment with other VPN clients stopped, otherwise route/DNS/interface results are not attributable to Zeon.

## Milestone 4 Inventory

Environment verified on 2026-06-27:

- Host OS: macOS 26.5.1 (25F80), `darwin-x64`.
- Toolchain activation: `source scripts/apple/env.sh`.
- Xcode: 26.5 build 17F42 from `/Applications/Xcode.app/Contents/Developer`.
- Flutter: 3.38.5; Dart: 3.10.4; CocoaPods: 1.16.2.
- Connected device: physical iPhone XR `iPhone (Dima)` on iOS 18.7.9 (22H355), UDID `00008020-001608162E93802E`, CoreDevice id `FE12C9C0-D99D-5EA0-B386-AEBC58E16123`.

Expected iOS VPN tunnel behavior:

- On a clean iPhone install, the first Connect triggers the native iOS VPN permission/profile prompt once, the user can approve it, and the app creates a persistent `NETunnelProviderManager` configuration for `app.zeon.ios.HiddifyPacketTunnel`.
- After approval, Connect starts `HiddifyPacketTunnel.appex`, initializes libbox/mobile core from the App Group config, applies `NEPacketTunnelNetworkSettings`, DNS, routes, and packet flow, then reports connected in the app without uncaught Flutter/native errors.
- While connected, traffic and DNS follow the active profile, DNS leak checks resolve through the tunnel DNS, the selected profile/server is reachable, and disconnect restores the device network state.
- The tunnel remains usable through repeated connect/disconnect cycles, lock/unlock, app backgrounding, force close of the host app, and ordinary Wi-Fi/cellular transitions; expected result after airplane mode is a clean disconnect or reconnect after network recovery, not a stuck UI or orphaned provider.
- During a 15+ minute active tunnel, the Packet Tunnel/core process should not crash, be jetsam-killed, or show runaway CPU/memory; logs should show controlled reconnect/backoff rather than repeated fatal setup/start failures.

Actual iOS inventory:

- Installed app is present on the connected iPhone: `Hiddify app.zeon.ios 1.2.1 10201`.
- Non-destructive launch via `xcrun devicectl device process launch --device ... --terminate-existing app.zeon.ios` succeeds and starts `Runner.app/Runner`.
- Process inventory after launch does not show `HiddifyPacketTunnel.appex`; this is expected before manual Connect but means no live VPN tunnel validation was performed in this pass.
- iOS Xcode settings show `PRODUCT_BUNDLE_IDENTIFIER = app.zeon.ios`, `DEVELOPMENT_TEAM = CH87655747`, `CURRENT_PROJECT_VERSION = 10201`, and `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements`.
- Runner and HiddifyPacketTunnel entitlements contain Network Extension, VPN API `allow-vpn`, and App Group entries. The current local development IPA expands App Group to `group.app.zeon.ios`; the already verified App Store IPA details remain in Milestone 2 notes.
- Static source inventory confirms Apple builds default to `ServiceMode.tun`, expose only `[tun]` in `ServiceMode.choices`, and force `tun-implementation = gvisor` before mobile core startup.
- iOS Packet Tunnel source uses `NEPacketTunnelProvider`, creates `NEPacketTunnelNetworkSettings`, applies DNS/routes, can attach `NEProxySettings` inside the packet tunnel settings, and passes the packet-flow file descriptor to libbox/mobile core.
- Standalone iPhone proxy mode is explicitly not supported/exposed for Apple UI/product flow in current code. Milestone proxy item is closed as "not supported as a separate iPhone mode"; tunnel-internal proxy settings remain part of the VPN provider implementation.

Manual validation required:

- Use a non-critical test iPhone or get explicit approval before uninstalling/resetting VPN configuration; do not erase or uninstall from the personal device just to simulate a clean permission flow.
- Capture device screen recording plus `xcrun devicectl` process snapshots before connect, after connect, after each network transition, and after disconnect.
- Capture iOS device logs filtered for `app.zeon.ios`, `HiddifyPacketTunnel`, `NetworkExtension`, `libbox`, `sing-box`, `PacketTunnel`, and `NEVPN` during the manual run.
- For DNS/routing, use on-device Safari or a trusted DNS leak page while connected, and record the observed public IP/DNS resolvers before and after Connect.
- For the 15+ minute stability check, keep the tunnel active with foreground and background periods, then inspect whether the provider process survived and whether app/provider logs contain fatal setup/start/jetsam events.

## Блокеры

Добавлять сюда только реальные блокировки, которые мешают следующему шагу.

- [x] Milestone 0 / Expected capabilities comparison: initial mismatch was documented, then closed for the macOS debug Packet Tunnel path in Milestone 3. Current signed build has active Network Extension, VPN API, App Group, sandbox, and network client/server entitlements for both Runner and HiddifyPacketTunnel.
- [!] Environment activation footgun: raw shell PATH cannot run `flutter`/`pod`, and global `xcode-select -p` points to CommandLineTools so raw `xcodebuild -version` fails. Следующий минимальный шаг: before Apple work always run `source scripts/apple/env.sh` or `make apple-doctor`; optionally switch global Xcode with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` outside this inventory task.
- [!] Milestone 1 / Strict release bundle signing verification: `flutter build macos --release` succeeds and the app launches, but `codesign --verify --deep --strict --verbose=2 build/macos/Build/Products/Release/Hiddify.app` fails with `invalid Info.plist (plist or signature have been modified)` in `Contents/Library/LoginItems/LaunchAtLoginHelper.app` for architecture `x86_64`. Следующий минимальный шаг: inspect `LaunchAtLoginHelper.app` generation/signing in the macOS target and re-sign/verify the nested login item before notarized/App Store distribution work.
- [x] Milestone 3 / macOS VPN native architecture: macOS Packet Tunnel target, host/extension entitlements, App Group, provider bundle id, host VPN manager bridge, and `HiddifyCore.xcframework` linkage have been added. Verified by `flutter build macos --debug`, bundle inspection and active codesign entitlements.
- [x] Milestone 3 / Clean routing attribution: user reran diagnostics without Happ; `out/diagnostics/macos_network_20260625_165429` is attributable to Zeon.
- [x] Milestone 3 / macOS system proxy clean run: `out/diagnostics/macos_network_20260625_165429` confirms system proxy mode connects on `127.0.0.1:12334`, proxied curl succeeds, and disconnect disables proxy settings/listener. Ordinary local proxy mode remains intentionally out of scope.
- [x] Milestone 3 / old direct macOS TUN start failure: clean run proved the old direct desktop TUN path fails with `manager start inbound/tun[tun-in]: configure tun interface: Connect: operation not permitted`. Product direction changed to Apple VPN-only UI, and macOS now has a signed Packet Tunnel target instead of relying on the old direct TUN path.
- [!] Milestone 3 / VPN failure UX: after the TUN permission failure, app log shows Riverpod `PlatformDispatcherError` about using `ref` during provider dependency change. Следующий минимальный шаг: make the connection failure path surface the core error to UI without provider assertion, even before native VPN work.
- [x] Milestone 3 / Diagnostics script portability: first clean user run missed process/interface/listener sections because `rg` was not in Terminal PATH. Fixed in `scripts/apple/macos_network_diagnostics.sh`; subsequent runs include those sections via `grep` fallback.
- [!] Milestone 3 / UI automation for connect/disconnect: macOS Accessibility exposed unnamed buttons only (`missing value`), so connect/disconnect was not clicked blindly during inventory. Следующий минимальный шаг: use a manual screen recording or add stable accessibility labels/test hooks before automating this UX path.
- [x] Milestone 3 / macOS signing team hook: macOS Runner now reads local ignored `macos/Runner/Configs/AppleSigning.xcconfig`; with `MACOS_DEVELOPMENT_TEAM = CH87655747`, `xcodebuild -showBuildSettings` reports `DEVELOPMENT_TEAM = CH87655747`.
- [x] Milestone 3 / macOS Packet Tunnel post-connect traffic validation: clean user run `out/diagnostics/macos_network_20260627_115838` validated the current provider path. `after_connect.txt` shows host and `HiddifyPacketTunnel.appex` running from `build/macos/Build/Products/Debug/Hiddify.app`, default route and DNS on `utun4`, and URL checks returning `HTTP/2 200`. Provider log contains `(packet-tunnel) prepared config with default_interface=en1, auto_detect_interface=false`, `platform interfaces: [en0#5,en1#6,en3#12,en2#13]`, and `service started`. Copied `packet-tunnel-config.json` contains `default_interface = en1` and `auto_detect_interface = false`. The old `no available network interface` root cause is gone.
- [!] Milestone 3 / repeated macOS VPN permission prompt: debug app recreated matching `NETunnelProviderManager` preferences on every setup while working around stale provider registration, so macOS asked to install/allow the VPN tunnel repeatedly. Fixed in `macos/Runner/VPN/VPNManager.swift`: setup now reuses the existing matching manager and only creates a new VPN service when none exists; stale provider cleanup stays in the diagnostics script. Следующий минимальный шаг: run the rebuilt app, connect/disconnect/connect again, and verify the second connect does not show the macOS VPN permission popup.
- [x] Milestone 3 / Codex build verification: after full local filesystem access was available, `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` completed with `BUILD SUCCEEDED`.
- [x] Milestone 3 / stale Packet Tunnel PlugInKit registration: `pluginkit -m -A -D -vvv -i app.zeon.macos.HiddifyPacketTunnel` showed duplicate providers: old default Xcode `DerivedData` and current `build/macos`. The old `DerivedData` `Hiddify.app` was unregistered with `lsregister -u`, its appex removed from PlugInKit, and the stale app bundle deleted. Current PlugInKit state now shows only the fresh `build/macos/.../HiddifyPacketTunnel.appex`.
- [x] Milestone 3 / macOS Packet Tunnel provisioning: after the Apple Developer account was added in Xcode, signed debug build succeeded for current ids `app.zeon.macos` and `app.zeon.macos.HiddifyPacketTunnel`. Profiles verified: `Mac Team Provisioning Profile: app.zeon.macos` UUID `a8092090-552f-4fe8-ba67-1acdeca293ae` and `Mac Team Provisioning Profile: app.zeon.macos.HiddifyPacketTunnel` UUID `16aeaa1d-e0db-4cbe-96d6-61f87f488b2a`.
- [x] Milestone 3 / macOS Packet Tunnel TUN stack mismatch: provider log showed `system and mixed stack are not available when includeAllNetworks is enabled`; Apple builds now force `tun-implementation = gvisor` in migration/preferences/UI/core payload. Later diagnostics reached `CONNECTED`, so the next failure is tracked separately as post-connect interface discovery.
- [x] Milestone 3 / Edge Chromium traffic parity: current live macOS VPN runtime showed Safari working while Edge/Chromium could fail because Chromium aggressively uses Secure DNS/DoH, QUIC/HTTP3 and IPv6/AAAA paths. Fresh App Group inspection showed `packet-tunnel-config.json` contains only `outbounds` and `route`, while `box.log` contained direct `en1` IPv6 `no route to host`, DNS/DoH resets to `2001:4860:4860::8844:443/853`, and repeated direct outbound timeouts. Fixed in `lib/zeoncore/zeon_core_service.dart`: Apple runtime payload now forces `ipv6-mode=ipv4_only`, both DNS domain strategies to `ipv4_only`, and `block-quic=true`. User launched the rebuilt `build/macos/Build/Products/Debug/ZEON.app` and confirmed Safari/Edge traffic now works correctly.
- [!] Milestone 3 / Apple profile metadata privacy: profile content files are already AES-256-GCM `.zcfg` envelopes on macOS App Group storage, but profile metadata in Flutter Drift DB (`name`, `url`, headers/override fields) was still plaintext. Implemented Apple-only `ProtectedProfileDataSource`: writes and migrates sensitive metadata as `enc:v1:*`, reads/decrypts transparently for UI, preserves plaintext lookup by decrypting rows in memory, and restores sort-by-name after decryption. Debug macOS build succeeds. Следующий минимальный шаг: launch the rebuilt `build/macos/Build/Products/Debug/ZEON.app`, let `ProfileRepository.init()` run metadata migration, then verify `~/Library/Containers/app.zeon.macos/Data/Library/db.sqlite` has encrypted profile `name/url` counters and the UI still displays profile names correctly.
- [x] Milestone 3 / Apple rebuild helper scripts: added executable helper scripts for local Apple dev loops. `scripts/rebuild_macos.sh` rebuilds macOS (`BUILD_MODE=debug|profile|release`, `OPEN_APP=1` optional). `scripts/rebuild_ios_install_iphone.sh` builds iOS (`IOS_MODE=debug|profile|release`), auto-detects a connected iPhone via `devicectl`, installs `build/ios/iphoneos/Runner.app`, and supports `DEVICE_ID=<CoreDevice-UUID>` plus `LAUNCH_APP=1`.
- [x] Milestone 4 / clean iOS VPN permission flow: accepted closed for this release pass by user manual observation without destructive reset of the personal iPhone.
- [x] Milestone 4 / live iOS stability scenarios: accepted closed after installed build and user manual observation; no more iOS VPN/profile/fragmentation errors were seen.
- [x] Milestone 4 / DNS routing and 15+ minute resource stability: accepted closed for this release pass by manual observation; no fresh DNS/resource instability was reported after the fixes.
- [x] Milestone 4 / VPN tunnel instability root cause: closed via foreground/background core fallback, active-proxy UI fallback, and real-device log review; no further Milestone 4 errors reproduced.
- [x] Milestone 4 / iOS foreground core fallback verification: installed build was manually observed by user and the `fg core unavailable while applying options` error did not reappear.
- [x] Milestone 4 / iOS fragmentation active-server UI verification: installed build was manually observed by user and no further empty active-server UI errors were reported.

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

### 2026-06-25 / Codex

Scope:
- Выполнил только Milestone 3: macOS VPN/proxy inventory, expected behavior, entitlements/capabilities, System Extension/Network Extension state, app/core logs, Console logs, generated config, listeners, system proxy, routes/DNS and URL checks.

Result:
- macOS VPN path is blocked at native architecture/capability level: no macOS Network Extension/System Extension target, no active Network Extension/App Group entitlements, `systemextensionsctl list` shows `0 extension(s)`.
- macOS proxy path generates expected mixed proxy config on `127.0.0.1:12334`/`::1:12334`, but app remained `DISCONNECTED`, system proxy stayed disabled, and no listener existed on `12334/12336/12337`.
- Direct URL before Zeon connection works; proxied URL through Zeon expected port fails because listener is absent.
- Clean route/DNS conclusions are blocked by an already active third-party Happ VPN process using `utun4`.
- No app source code was changed.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m3-01-macos-debug-build-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-02-macos-app-launch-network-state-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-03-macos-console-log-after-launch-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-04-macos-app-logs-after-launch-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-05-macos-ui-buttons-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-06-macos-ui-elements-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-07-macos-current-config-inventory-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-08-macos-proxy-port-check-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-09-macos-built-app-entitlements-2026-06-25.log`
- `docs/apple-mac-ios-release/logs/m3-10-macos-filtered-runtime-logs-2026-06-25.log`

Verification:
- `source scripts/apple/env.sh && sw_vers`: macOS 26.5.1 (25F80).
- `source scripts/apple/env.sh && xcodebuild -version`: Xcode 26.5 (17F42).
- `source scripts/apple/env.sh && flutter --version`: Flutter 3.38.5, Dart 3.10.4.
- `source scripts/apple/env.sh && pod --version`: CocoaPods 1.16.2.
- `source scripts/apple/env.sh && flutter devices`: iPhone (Dima), iOS 18.7.9 (22H355), and macOS desktop detected.
- `source scripts/apple/env.sh && xcodebuild -list -project macos/Runner.xcodeproj`: no macOS extension target.
- `plutil -p macos/Runner/DebugProfile.entitlements` and `plutil -p macos/Runner/Release.entitlements`: no active Network Extension/App Group entitlement.
- `systemextensionsctl list`: `0 extension(s)`.
- `source scripts/apple/env.sh && flutter build macos --debug`: success.
- `open build/macos/Build/Products/Debug/Hiddify.app`: launched `Hiddify` process.
- `curl -I --max-time 15 https://example.com`: HTTP 200.
- `curl -I --max-time 20 --proxy http://127.0.0.1:12334 https://example.com`: failed to connect because listener is absent.
- `networksetup -getwebproxy Ethernet`, `-getsecurewebproxy Ethernet`, `-getsocksfirewallproxy Ethernet`: proxy disabled.
- `ifconfig`, `route -n get default`, `netstat -rn -f inet`, `scutil --dns`, `lsof -nP -iTCP -sTCP:LISTEN`: captured in Milestone 3 logs.

Open issues:
- Decide macOS VPN architecture and implement required native target/capabilities/signing, or declare macOS VPN unsupported.
- Re-run routing/DNS/connect/disconnect checks in a clean environment without the active Happ VPN.
- Reproduce manual macOS proxy connect and capture first failure that prevents listener startup/system proxy enablement.
- Add stable accessibility labels or a test hook before automated connect/disconnect UI checks.

### 2026-06-25 / Codex

Scope:
- Добавил единый автоматизированный macOS diagnostics runner для будущей работы по VPN/proxy, чтобы человек мог запустить проверку в чистой сети без Happ, а агент потом работал по сохраненным артефактам.

Result:
- Новый скрипт `scripts/apple/macos_network_diagnostics.sh` сам активирует `scripts/apple/env.sh`, пишет timestamped папку в `out/diagnostics`, фиксирует окружение, Xcode project/entitlements, optional debug build, codesign verification, app launch, pre/after-launch/after-connect/after-disconnect network snapshots, runtime app/core logs и Console logs.
- Connect/disconnect сделаны через безопасные интерактивные паузы: пользователь вручную отключает Happ, нажимает Connect/Disconnect в UI и подтверждает Enter в терминале. Скрипт не кликает UI вслепую и не меняет код приложения.
- Smoke-проверка скрипта прошла в non-interactive mode: `scripts/apple/macos_network_diagnostics.sh --no-build --no-open --non-interactive --out out/diagnostics/macos_network_smoke_codex`.

Changed files:
- `scripts/apple/macos_network_diagnostics.sh`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `bash -n scripts/apple/macos_network_diagnostics.sh`: success.
- `scripts/apple/macos_network_diagnostics.sh --help`: success.
- `scripts/apple/macos_network_diagnostics.sh --no-build --no-open --non-interactive --out out/diagnostics/macos_network_smoke_codex`: success, generated `SUMMARY.md`, command log, environment/project/entitlements/console logs, snapshots and runtime log copies.

Open issues:
- Full useful run still needs a human clean-room pass with Happ/other VPN clients quit, then manual Connect and Disconnect during the script prompts.

### 2026-06-25 / Codex

Scope:
- Проверил clean-room логи `out/diagnostics/macos_network_20260625_165429` после ручного прогона пользователя; обычный proxy режим намеренно не анализировал, только `system-proxy` и VPN/tun.

Result:
- `system-proxy` подтвержден рабочим: после Connect системные HTTP/HTTPS/SOCKS proxy на `Ethernet` включены на `127.0.0.1:12334`, proxied curl возвращает HTTP 200, после Disconnect proxy выключены и listener закрыт.
- VPN/tun не стартует: core падает на `manager start inbound/tun[tun-in]: configure tun interface: Connect: operation not permitted`. Это текущий direct desktop sing-box TUN путь, а не macOS Network Extension provider flow.
- Причина системная/архитектурная: в macOS проекте нет Network Extension/System Extension target, а built app не имеет активного Network Extension/App Group entitlement. Permission popup не дает текущему процессу права создать TUN напрямую.
- Дополнительно найден UX/runtime дефект после VPN failure: Riverpod `PlatformDispatcherError` про `ref` во время provider rebuild, из-за чего ошибка может не отображаться пользователю нормально.
- Диагностический скрипт поправлен: больше не зависит от `rg`, использует `grep` fallback.

Changed files:
- `scripts/apple/macos_network_diagnostics.sh`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `bash -n scripts/apple/macos_network_diagnostics.sh`: success.
- `PATH='/usr/bin:/bin:/usr/sbin:/sbin' scripts/apple/macos_network_diagnostics.sh --no-build --no-open --non-interactive --out out/diagnostics/macos_network_smoke_no_rg_fallback`: success, fallback path works without `rg`.
- Inspected `out/diagnostics/macos_network_20260625_165429/SUMMARY.md`, snapshots, entitlements, project inventory, app runtime logs, generated config and console log.

Open issues:
- Product decision needed: for macOS release, either support only `system-proxy` now and hide/disable VPN mode, or implement a real macOS Packet Tunnel/System Extension architecture.
- UI should surface VPN start failure instead of silently returning to disconnected state.

### 2026-06-25 / Codex

Scope:
- Начал нормальный Apple VPN/TUN путь после product decision: для Apple сборок оставить только VPN/TUN режим, убрать остальные режимы из настроек/quick settings/tray и проверить, можно ли собрать core xcframework с macOS slice для будущего Packet Tunnel target.

Result:
- Для iOS/macOS `ServiceMode.defaultMode` теперь `vpn`, а `ServiceMode.choices` возвращает только `vpn`.
- Старые Apple preferences со значениями `proxy`/`system-proxy` безопасно fallback/migrate в `vpn`.
- Переключатель service mode скрывается в Inbound settings и Quick settings, если на платформе доступен только один режим.
- Tray menu больше не показывает submenu service mode, если режим единственный.
- Добавлен macOS signing hook по iOS-паттерну: tracked example + ignored local config. Локальный файл создан с `MACOS_DEVELOPMENT_TEAM = CH87655747`.
- Починен internal core builder: `hiddify-core/cmd/internal/build_libcore -target ios` собирает `HiddifyCore.xcframework` с iOS device, iOS simulator и macOS universal slices.
- Собранный `hiddify-core/bin/HiddifyCore.xcframework` подтвержден через `plutil`: есть `macos-arm64_x86_64`.

Changed files:
- `lib/utils/platform_utils.dart`
- `lib/singbox/model/singbox_config_enum.dart`
- `lib/features/settings/data/config_option_repository.dart`
- `lib/core/preferences/preferences_migration.dart`
- `lib/core/router/bottom_sheets/widgets/quick_settings_modal.dart`
- `lib/features/settings/overview/sections/inbound_options_page.dart`
- `lib/features/system_tray/notifier/system_tray_notifier.dart`
- `hiddify-core/cmd/internal/build_libcore/main.go`
- `.gitignore`
- `macos/Runner/Configs/AppInfo.xcconfig`
- `macos/Runner/Configs/AppleSigning.xcconfig.example`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `source scripts/apple/env.sh && dart format ...`: success.
- `source scripts/apple/env.sh && flutter analyze lib/utils/platform_utils.dart lib/singbox/model/singbox_config_enum.dart lib/features/settings/data/config_option_repository.dart lib/core/preferences/preferences_migration.dart lib/core/router/bottom_sheets/widgets/quick_settings_modal.dart lib/features/settings/overview/sections/inbound_options_page.dart lib/features/system_tray/notifier/system_tray_notifier.dart`: no issues.
- `source scripts/apple/env.sh && xcodebuild -list -project macos/Runner.xcodeproj`: still only `Runner`, `RunnerTests`, `Flutter Assemble`.
- `source scripts/apple/env.sh && xcodebuild -showBuildSettings -project macos/Runner.xcodeproj -scheme Runner`: macOS Runner now reports `DEVELOPMENT_TEAM = CH87655747` with local ignored signing config.
- `source scripts/apple/env.sh && flutter build macos --debug`: success after signing hook.
- `security find-identity -v -p codesigning`: one valid Apple Development identity.
- `source scripts/apple/env.sh && cd hiddify-core && go run ./cmd/internal/build_libcore -target ios`: success.
- `plutil -p hiddify-core/bin/HiddifyCore.xcframework/Info.plist`: includes `macos-arm64_x86_64`.

Open issues:
- Next implementation step is a real macOS Packet Tunnel target in `macos/Runner.xcodeproj`, with bundle id, app group, Network Extension entitlement, provisioning/signing, embedded `HiddifyCore.xcframework`, and host-app VPN manager bridge.
- Packet Tunnel target still needs its own bundle id/provisioning profile after the target is added.
- Current macOS VPN button still uses the old direct desktop TUN path until the Packet Tunnel lifecycle is wired into the app.

### 2026-06-25 / Codex

Scope:
- Продолжил только Milestone 3: добавил настоящий macOS Packet Tunnel target, host-app VPN manager bridge, macOS provider lifecycle, App Group paths и переключил macOS core path с direct desktop TUN на mobile/Network Extension flow.

Result:
- `macos/Runner.xcodeproj` теперь содержит target/scheme `HiddifyPacketTunnel`; debug build embeds `Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex`.
- Host app и Packet Tunnel provider подписаны с активными `packet-tunnel-provider`, `allow-vpn`, sandbox, App Group `group.app.hiddify.com`, network client/server entitlements.
- macOS Dart path теперь использует `CoreInterfaceMobile()` и native `get_paths`, чтобы host app и provider работали через общий App Group контейнер.
- `flutter build macos --debug` успешен после добавления Packet Tunnel target.
- Чистый runtime Connect еще не подтвержден: в текущей среде активен Happ (`Happ`, `xray`, root `sing-box`, `happd`), поэтому route/DNS/utun результаты нельзя честно атрибутировать Zeon.

Changed files:
- `.gitignore`
- `hiddify-core/cmd/internal/build_libcore/main.go`
- `lib/core/directories/directories_provider.dart`
- `lib/core/preferences/preferences_migration.dart`
- `lib/core/router/bottom_sheets/widgets/quick_settings_modal.dart`
- `lib/features/settings/data/config_option_repository.dart`
- `lib/features/settings/overview/sections/inbound_options_page.dart`
- `lib/features/system_tray/notifier/system_tray_notifier.dart`
- `lib/hiddifycore/core_interface/core_interface_wrapper.dart`
- `lib/singbox/model/singbox_config_enum.dart`
- `lib/utils/platform_utils.dart`
- `macos/Runner.xcodeproj/project.pbxproj`
- `macos/Runner/Configs/AppInfo.xcconfig`
- `macos/Runner/Configs/AppleSigning.xcconfig.example`
- `macos/Runner/DebugProfile.entitlements`
- `macos/Runner/Info.plist`
- `macos/Runner/MainFlutterWindow.swift`
- `macos/Runner/Release.entitlements`
- `macos/HiddifyPacketTunnel/`
- `macos/Runner/Extensions/`
- `macos/Runner/Handlers/`
- `macos/Runner/VPN/`
- `macos/Shared/`
- `scripts/apple/setup_macos_packet_tunnel.rb`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `source scripts/apple/env.sh && flutter analyze lib/hiddifycore/core_interface/core_interface_wrapper.dart lib/core/directories/directories_provider.dart lib/singbox/model/singbox_config_enum.dart lib/features/settings/data/config_option_repository.dart lib/core/preferences/preferences_migration.dart lib/utils/platform_utils.dart`: no issues.
- `plutil -lint macos/Runner/Info.plist macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements macos/HiddifyPacketTunnel/Info.plist macos/HiddifyPacketTunnel/HiddifyPacketTunnel.entitlements`: OK.
- `source scripts/apple/env.sh && xcodebuild -showBuildSettings -project macos/Runner.xcodeproj -scheme Runner`: `DEVELOPMENT_TEAM = CH87655747`, `PRODUCT_BUNDLE_IDENTIFIER = app.hiddify.com`.
- `source scripts/apple/env.sh && xcodebuild -list -project macos/Runner.xcodeproj`: includes `HiddifyPacketTunnel`.
- `source scripts/apple/env.sh && flutter build macos --debug`: success, `build/macos/Build/Products/Debug/Hiddify.app`.
- `find build/macos/Build/Products/Debug/Hiddify.app -maxdepth 6 -name '*.appex'`: finds `Contents/PlugIns/HiddifyPacketTunnel.appex`.
- `codesign -d --entitlements :- build/macos/Build/Products/Debug/Hiddify.app`: host app has active Network Extension/VPN/App Group entitlements.
- `codesign -d --entitlements :- build/macos/Build/Products/Debug/Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex`: Packet Tunnel provider has active Network Extension/VPN/App Group entitlements.
- `bash -n scripts/apple/macos_network_diagnostics.sh`: success.
- `scripts/apple/macos_network_diagnostics.sh --help`: success.
- `scripts/apple/macos_network_diagnostics.sh --no-core-build --no-build --no-open --non-interactive --skip-clean-check --out out/diagnostics/macos_packet_tunnel_smoke_codex_3`: success; generated summary/logs/snapshots and detected active Happ correctly.
- `~/Library/Logs/DiagnosticReports/Hiddify-2026-06-25-191617.ips`: launch failure is `SIGKILL (Code Signature Invalid)`, `Taskgated Invalid Signature`.
- `/usr/bin/log show --last 15m ...`: AMFI reports `adhoc signed but contains restricted entitlements`.
- `source scripts/apple/env.sh && xcodebuild -showBuildSettings -project macos/Runner.xcodeproj -scheme Runner -configuration Debug`: now reports `CODE_SIGN_IDENTITY = Apple Development`.
- `source scripts/apple/env.sh && xcodebuild -showBuildSettings -project macos/Runner.xcodeproj -scheme HiddifyPacketTunnel -configuration Debug`: now reports `CODE_SIGN_IDENTITY = Apple Development`.
- `source scripts/apple/env.sh && flutter build macos --debug`: blocked by missing Mac App Development provisioning profiles for `app.hiddify.com` and `app.hiddify.com.HiddifyPacketTunnel`.
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -allowProvisioningUpdates build`: blocked by `No Accounts` and missing profiles.
- `scripts/apple/macos_network_diagnostics.sh --no-core-build --no-build --no-open --non-interactive --skip-clean-check --out out/diagnostics/macos_packet_tunnel_launch_guard_smoke`: success; summary uses `logs/macos_signed_debug_build.log`.

Open issues:
- Clean runtime VPN validation now needs signed macOS provisioning first, then Happ/other VPN clients stopped. Next useful test is manual Connect on the signed debug app, then capture provider logs, `ifconfig`, `route -n get default`, `scutil --dns`, `scutil --nc list`, and `network_extension_error.log`.
- If macOS accepts the VPN profile but the provider exits, inspect App Group path selection and `MobileStart(configPath, "")` provider log first.
- Distribution-grade signing/notarization is still separate from this debug Packet Tunnel validation.

### 2026-06-25 / Codex

Scope:
- Продолжил только Milestone 3: проверил, что означает Xcode provisioning после добавления Apple Developer account, и закрыл blocker по Mac App Development profiles для текущих macOS bundle ids.

Result:
- `app.hiddify.com` и `app.hiddify.com.HiddifyPacketTunnel` больше не являются актуальными macOS ids для этой команды: они недоступны team `CH87655747`.
- Текущие macOS ids: `app.zeon.macos` и `app.zeon.macos.HiddifyPacketTunnel`.
- Signed debug build через Xcode succeeded; host app и Packet Tunnel extension подписаны `Apple Development: Dima Moiseev (37NM4393T6)`.
- Xcode profiles verified:
  - `Mac Team Provisioning Profile: app.zeon.macos`, UUID `a8092090-552f-4fe8-ba67-1acdeca293ae`.
  - `Mac Team Provisioning Profile: app.zeon.macos.HiddifyPacketTunnel`, UUID `16aeaa1d-e0db-4cbe-96d6-61f87f488b2a`.
- Built app embeds both profiles: `Hiddify.app/Contents/embedded.provisionprofile` and `Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex/Contents/embedded.provisionprofile`.
- Runtime VPN Connect validation is still blocked by active Happ/xray/root sing-box in the current environment.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `source scripts/apple/env.sh && xcodebuild -version`: Xcode `26.5` build `17F42`.
- `security find-identity -v -p codesigning`: one valid Apple Development identity.
- `bash -n scripts/apple/macos_network_diagnostics.sh`: OK.
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`: `BUILD SUCCEEDED`.
- `find build/macos/Build/Products/Debug/Hiddify.app -maxdepth 8 \( -name "*.appex" -o -name "embedded.provisionprofile" \)`: finds host and extension profiles.
- `codesign -dv ...`: host identifier `app.zeon.macos`, extension identifier `app.zeon.macos.HiddifyPacketTunnel`, Team ID `CH87655747`.
- `codesign -d --entitlements :- ...`: host and extension include `packet-tunnel-provider`, `allow-vpn`, `group.app.zeon.macos`, sandbox, network client/server.

Open issues:
- Next clean test: quit Happ/other VPN clients, run `scripts/apple/macos_network_diagnostics.sh`, approve the macOS VPN popup if shown, click Connect, then inspect generated logs/routes/DNS/utun/provider output.
- Distribution signing/notarization remains separate from debug Packet Tunnel validation.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 3: разобрал логи после успешного запуска приложения и неуспешного включения macOS Packet Tunnel.

Result:
- Свежий diagnostics run `out/diagnostics/macos_network_20260627_102725` остановился на clean-network guard из-за активного Happ/xray/root sing-box.
- Последний provider root cause найден в App Group логе: Packet Tunnel падал на `system and mixed stack are not available when includeAllNetworks is enabled`.
- Исправлено: Apple builds теперь всегда используют `tun-implementation = gvisor`; старый `mixed` мигрируется, не читается из preferences на Apple, не показывается в Apple UI и принудительно перезаписывается в core payload.
- Собран новый signed debug app: `build/macos/Build/Products/Debug/Hiddify.app`.

Changed files:
- `lib/core/preferences/preferences_migration.dart`
- `lib/features/settings/data/config_option_repository.dart`
- `lib/features/settings/overview/sections/inbound_options_page.dart`
- `lib/hiddifycore/hiddify_core_service.dart`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `source scripts/apple/env.sh && flutter analyze lib/core/preferences/preferences_migration.dart lib/features/settings/data/config_option_repository.dart lib/features/settings/overview/sections/inbound_options_page.dart lib/hiddifycore/hiddify_core_service.dart`: no issues.
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`: `BUILD SUCCEEDED`.

Open issues:
- Нужно повторить clean runtime test после полного выхода из Happ/других VPN клиентов. Следующий ожидаемый лог должен уже показывать `tun-implementation: gvisor`; если туннель снова упадет, это будет следующий слой проблемы, а не прежний `mixed/includeAllNetworks` конфликт.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 3: проверил свежие логи после ошибки проверки/ping серверов в уже поднятом macOS Packet Tunnel.

Result:
- Свежий diagnostics run `out/diagnostics/macos_network_20260627_103631` показал, что Packet Tunnel уже стартует: app lifecycle дошел до `CONNECTED`, provider log содержит start/setup/service started, создан `utun4`, default route и DNS перенесены в tunnel.
- Ошибка серверов не про недоступность конкретного proxy server: `box.log` многократно пишет `no available network interface` для balancer, DNS remote exchange, rule-set fetch, URL-test и dial `130.49.151.173:443`.
- Root cause найден в macOS Packet Tunnel bridge: `ExtensionPlatformInterface.getInterfaces()` возвращал пустой список, из-за чего libbox/sing-box не видел физический outbound interface внутри Network Extension.
- Исправлено: macOS provider теперь отдает physical interfaces из `NWPathMonitor.currentPath.availableInterfaces`, исключает `utun*`/`lo0`, выставляет default interface update и маппит interface type для libbox.
- Собран новый signed debug app: `build/macos/Build/Products/Debug/Hiddify.app`.

Changed files:
- `macos/HiddifyPacketTunnel/SingBox/ExtensionPlatformInterface.swift`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`: `BUILD SUCCEEDED`.
- Code path check: `hiddify-core/hiddify-sing-box/experimental/libbox/service.go` calls platform `GetInterfaces()` for `NetworkInterfaces()`, and `route/network.go` updates available networks from that list before dialer selection.

Open issues:
- Нужен новый ручной прогон `scripts/apple/macos_network_diagnostics.sh` на свежем билде: click Connect, дождаться UI, затем проверить, исчез ли `no available network interface` и проходят ли post-VPN URL/server checks.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 3: проверил свежие логи, где приложение не падало, но живые серверы не пинговались и не выбирались для туннелирования.

Result:
- Свежий diagnostics run `out/diagnostics/macos_network_20260627_104932` подтверждает: app/provider доходят до `CONNECTED`, `utun4` создан, default route и DNS стоят на туннеле.
- Основная причина health-check failure все еще `no available network interface`, а не “все серверы мертвые”: balancer, DNS, rule-set fetch, URL-test и dial до `130.49.151.173:443` падают до сетевого выхода; monitoring ставит нодам `delay=65535`.
- Уточнил root cause: `NWPathMonitor.currentPath.availableInterfaces` внутри macOS Packet Tunnel/include-all-networks не является надежным источником physical outbound interfaces для libbox.
- Исправлено: macOS provider теперь строит `getInterfaces()` через `getifaddrs`/`if_nametoindex`, фильтрует `utun*`/`lo*`/виртуальные интерфейсы, передает BSD index/flags/type в libbox и логирует видимые интерфейсы как `(packet-tunnel) platform interfaces: [...]`.
- Собран новый signed debug app: `build/macos/Build/Products/Debug/Hiddify.app`.

Changed files:
- `macos/HiddifyPacketTunnel/SingBox/ExtensionPlatformInterface.swift`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`: `BUILD SUCCEEDED`.

Open issues:
- Нужен новый ручной прогон `scripts/apple/macos_network_diagnostics.sh` на свежем билде. Главные маркеры: `network_extension_error.log` должен содержать `(packet-tunnel) platform interfaces: [en...]`; `box.log` не должен повторять `no available network interface`; живые server URL-test должны получить нормальный delay вместо `65535`.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 3: проверил свежий пользовательский снимок, где проблема осталась после provider interface inventory fix, и доработал macOS Packet Tunnel outbound interface selection.

Result:
- Свежий diagnostics run `out/diagnostics/macos_network_20260627_110009` показывает, что Zeon VPN поднимается: host app и `HiddifyPacketTunnel.appex` работают, provider пишет `starting/setup completed/service started`, `utun4` создан, default route и DNS стоят на туннеле.
- Проблема осталась в исходящем dial: `box.log` продолжает писать `no available network interface`; ожидаемый provider marker `(packet-tunnel) platform interfaces: [...]` не появился.
- Уточнил root cause: на macOS Packet Tunnel libbox `auto_detect_interface`/multi-interface strategy остается без usable physical interfaces, поэтому provider теперь перед `MobileStart` пишет отдельный `packet-tunnel-config.json` с `route.default_interface=<macOS PrimaryInterface>` и `route.auto_detect_interface=false`.
- Диагностический скрипт теперь копирует `packet-tunnel-config.json`, чтобы следующий снимок показал точный config, с которым стартовал provider.
- Собран новый signed debug app: `build/macos/Build/Products/Debug/Hiddify.app`.

Changed files:
- `macos/HiddifyPacketTunnel/SingBox/ExtensionPlatformInterface.swift`
- `macos/HiddifyPacketTunnel/SingBox/ExtensionProvider.swift`
- `scripts/apple/macos_network_diagnostics.sh`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `bash -n scripts/apple/macos_network_diagnostics.sh`: success.
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`: `BUILD SUCCEEDED`.
- Environment re-check: macOS 26.5.1 (25F80), Xcode 26.5 build 17F42, Flutter 3.38.5.

Open issues:
- Нужен новый ручной прогон `scripts/apple/macos_network_diagnostics.sh` на свежем билде. Главные маркеры: `network_extension_error.log` должен содержать `(packet-tunnel) prepared config with default_interface=en...`; copied `packet-tunnel-config.json` должен содержать `route.default_interface` и `auto_detect_interface=false`; `box.log` не должен повторять `no available network interface`; post-VPN URL/server checks должны пройти.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 3: проверил свежий пользовательский diagnostics run `out/diagnostics/macos_network_20260627_112633`, где серверы по-прежнему не пинговались и VPN-соединение не давало рабочий трафик.

Result:
- Свежий run поднял Packet Tunnel на уровне macOS: app/provider работали, `utun4` создан, default route и DNS ушли в tunnel, `127.0.0.1:12334` слушал внутри provider.
- Причина “без изменений для пользователя” оказалась не в новом `default_interface` fix: NetworkExtension запустил stale provider из `~/Library/Developer/Xcode/DerivedData/Runner-hjitbomcmkyrdthbfybjgxyzbwws/...`, а не embedded provider из текущего `build/macos/Build/Products/Debug/Hiddify.app`.
- В stale runtime не было маркеров `(packet-tunnel) prepared config...`, `packet-tunnel-config.json` и `platform interfaces`, поэтому `box.log` продолжил показывать `no available network interface`.
- Исправлено для debug/dev: `VPNManager` удаляет matching `NETunnelProviderManager` preferences перед созданием новой VPN service, чтобы macOS заново привязал provider к текущему embedded `.appex`.
- Диагностический скрипт теперь показывает `Packet Tunnel runtime path: fresh/stale-or-different` в `SUMMARY.md` и добавляет provider code markers в `logs/app_bundle_layout.log`.

Changed files:
- `macos/Runner/VPN/VPNManager.swift`
- `scripts/apple/macos_network_diagnostics.sh`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `bash -n scripts/apple/macos_network_diagnostics.sh`: success.
- Real environment check: `source scripts/apple/env.sh && sw_vers && xcodebuild -version` reports macOS `26.5.1 (25F80)` and Xcode `26.5` build `17F42`.
- `flutter --version` in this Codex sandbox hit local Dart VM `cpuinfo_macos.cc: unreachable code`; not treated as VPN root cause.
- `xcodebuild` verification is blocked in the restricted Codex sandbox because Xcode cannot write required caches under `~/Library/Caches` / `~/.cache/clang`; user Terminal diagnostics remain the required runtime verification path.

Open issues:
- Run `scripts/apple/macos_network_diagnostics.sh` again from a normal Terminal. The next valid run must show `Packet Tunnel runtime path: fresh` in `SUMMARY.md`; then check that `network_extension_error.log` contains `(packet-tunnel) prepared config with default_interface=en...`, copied `packet-tunnel-config.json` contains `route.default_interface` plus `auto_detect_interface=false`, and `box.log` no longer reports `no available network interface`.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 3: проверил свежий пользовательский run `out/diagnostics/macos_network_20260627_114907`, где поведение осталось прежним.

Result:
- Свежий run снова не был валидной проверкой последнего provider fix: host app стартовал из `build/macos/...`, но `HiddifyPacketTunnel` опять стартовал из старого `~/Library/Developer/Xcode/DerivedData/Runner-hjitbomcmkyrdthbfybjgxyzbwws/...`.
- `pluginkit -m -A -D -vvv -i app.zeon.macos.HiddifyPacketTunnel` подтвердил две регистрации одного provider id: stale DerivedData appex и свежий `build/macos` appex.
- Stale DerivedData app был остановлен/разрегистрирован/удален локально; текущий PlugInKit state теперь содержит только `build/macos/Build/Products/Debug/Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex`.
- Диагностический скрипт теперь автоматизирует этот cleanup: останавливает старые Zeon/Hiddify процессы, unregister/remove stale `Hiddify.app` под Xcode `DerivedData`, регистрирует свежий `APP_PATH`, и только потом запускает app.
- Исправлена причина отсутствия `SUMMARY.md`: runtime path detection больше не использует `head` под `set -euo pipefail`; selfcheck создал `out/diagnostics/macos_network_script_selfcheck_20260627_115537/SUMMARY.md`.

Changed files:
- `scripts/apple/macos_network_diagnostics.sh`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `bash -n scripts/apple/macos_network_diagnostics.sh`: success.
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`: `BUILD SUCCEEDED`.
- Manual registry cleanup verification: `pluginkit -m -A -D -vvv -i app.zeon.macos.HiddifyPacketTunnel` now reports exactly one plugin, path `build/macos/Build/Products/Debug/Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex`.
- `find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/*/Hiddify.app' -type d`: no stale `Hiddify.app` copies found.
- Script selfcheck: `OUT_DIR=... scripts/apple/macos_network_diagnostics.sh --no-build --no-open --non-interactive` completed and wrote `SUMMARY.md`.

Open issues:
- Нужно снова выполнить полноценный manual diagnostics run. Главный gating marker теперь не `CONNECTED`, а `SUMMARY.md` -> `Packet Tunnel runtime path: fresh`. Только после этого можно считать валидными логи `network_extension_error.log`, `packet-tunnel-config.json` и `box.log` по проблеме `no available network interface`.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 3: проверил свежие логи рабочего macOS VPN и исправил повторный запрос macOS на разрешение VPN tunnel.

Result:
- `out/diagnostics/macos_network_20260627_115838` подтверждает рабочий VPN: provider стартует из текущего `build/macos/.../HiddifyPacketTunnel.appex`, пишет `prepared config with default_interface=en1, auto_detect_interface=false`, видит physical interfaces, создает `utun4`, переводит default route/DNS на tunnel и получает `HTTP/2 200` после connect.
- Disconnect чистый: default route возвращается на `en1`, DNS возвращается на `192.168.3.1`, provider process/listeners останавливаются, direct URL после disconnect работает.
- Причина повторного permission prompt найдена: временный debug workaround удалял `NETunnelProviderManager` на каждом setup, из-за чего macOS каждый раз видела новый VPN service.
- Исправлено: `VPNManager` теперь переиспользует существующий matching `NETunnelProviderManager`; удаление stale app/appex registration остается только в `scripts/apple/macos_network_diagnostics.sh`.

Changed files:
- `macos/Runner/VPN/VPNManager.swift`
- `scripts/apple/macos_network_diagnostics.sh`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `bash -n scripts/apple/macos_network_diagnostics.sh`: success.
- `source scripts/apple/env.sh && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`: `BUILD SUCCEEDED`.
- `pluginkit -m -A -D -vvv -i app.zeon.macos.HiddifyPacketTunnel`: one registered provider, path under `build/macos/Build/Products/Debug/Hiddify.app/Contents/PlugIns/HiddifyPacketTunnel.appex`.

Open issues:
- Нужно ручное подтверждение UX: после установки/первого разрешения, второй и последующие Connect не должны показывать macOS VPN permission popup. Если popup все еще появляется, следующий слой проверки: посмотреть, меняется ли UUID `scutil --nc list` между connect attempts и не вызывает ли UI/diagnostics явный `VPNManager.reset()`.

### 2026-06-27 / Codex

Scope:
- Закрыл Milestone 2: собрал подписанный iOS archive/IPA после логина в Apple Developer account в Xcode.

Result:
- `flutter build ipa` успешно создал `build/ios/archive/Runner.xcarchive` и `build/ios/ipa/Runner.ipa`.
- IPA подписан `Apple Distribution: Dima Moiseev (CH87655747)` через Cloud Managed Apple Distribution.
- Runner и HiddifyPacketTunnel внутри IPA имеют production/App Store provisioning profiles, Network Extension/VPN/App Group entitlements и `get-task-allow=false`.
- Активный Milestone 2 blocker по App Store IPA export signing удален; все чекбоксы Milestone 2 теперь `[x]`.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m2-18-ios-ipa-build-after-xcode-login-2026-06-27.log`

Verification:
- `source scripts/apple/env.sh && sw_vers`: macOS 26.5.1 (25F80).
- `source scripts/apple/env.sh && xcodebuild -version`: Xcode 26.5 (17F42).
- `source scripts/apple/env.sh && flutter --version`: Flutter 3.38.5, Dart 3.10.4.
- `source scripts/apple/env.sh && pod --version`: CocoaPods 1.16.2.
- `source scripts/apple/env.sh && flutter devices`: iPhone (Dima), iOS 18.7.9 (22H355), and macOS desktop detected.
- `source scripts/apple/env.sh && flutter build ipa`: success; IPA exported to `build/ios/ipa/Runner.ipa`.
- `shasum -a 256 build/ios/ipa/Runner.ipa`: `b11fa63d7d0f17aec95ca289f9bc5f2fe266984077f2932e15e1d422e259121f`.
- `codesign -dv --verbose=4` on unpacked `Runner.app` and `HiddifyPacketTunnel.appex`: Apple Distribution authority and team `CH87655747`.
- `codesign -d --entitlements :-` on unpacked app/extension: production signing entitlements verified.
- `security cms -D -i embedded.mobileprovision`: Xcode-managed App Store profiles verified for `app.zeon.ios` and `app.zeon.ios.HiddifyPacketTunnel`.

Open issues:
- Milestone 2 is closed. App Store upload itself was not performed; next release step is to upload `build/ios/ipa/Runner.ipa` via Transporter or App Store Connect API when desired.

### 2026-06-27 / Codex

Scope:
- Выполнил только Milestone 4 как инвентаризацию iOS VPN/proxy стабильности; не переходил к Milestone 5+ и не менял код приложения.

Result:
- Описал expected behavior для iOS VPN tunnel.
- Подтвердил реальное окружение, подключенный iPhone XR на iOS 18.7.9, установленное приложение `app.zeon.ios 1.2.1 (10201)`, iOS signing/entitlements и статическую VPN-only конфигурацию Apple builds.
- Выполнил non-destructive launch/process inventory: host app запускается, Packet Tunnel process не стартует без ручного Connect, поэтому живые стабильностные проверки помечены `[!]`.
- Зафиксировал standalone iPhone proxy mode как неподдерживаемый отдельный Apple UI/product mode; Apple builds используют только VPN/tun, а proxy settings существуют только внутри Packet Tunnel network settings.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m4-01-ios-env-device-inventory-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-02-ios-signing-entitlements-inventory-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-03-ios-vpn-proxy-static-inventory-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-04-ios-installed-app-launch-process-inventory-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-05-ios-ipa-entitlements-inventory-2026-06-27.log`

Verification:
- `source scripts/apple/env.sh && sw_vers`: macOS 26.5.1 (25F80).
- `source scripts/apple/env.sh && xcodebuild -version`: Xcode 26.5 (17F42).
- `source scripts/apple/env.sh && flutter --version`: Flutter 3.38.5, Dart 3.10.4.
- `source scripts/apple/env.sh && pod --version`: CocoaPods 1.16.2.
- `source scripts/apple/env.sh && flutter devices`: iPhone (Dima), iOS 18.7.9 (22H355), and macOS desktop detected.
- `xcrun devicectl device info apps --device 00008020-001608162E93802E --bundle-id app.zeon.ios`: `Hiddify app.zeon.ios 1.2.1 10201`.
- `xcrun devicectl device process launch --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 --terminate-existing app.zeon.ios`: launched `Runner.app/Runner`.
- `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -showBuildSettings`, `plutil -p` on iOS entitlements/Info.plist, and `codesign -d --entitlements :-` on current local IPA.

Open issues:
- Clean install/VPN permission flow and all stability scenarios require a manual iPhone run with permission acceptance, physical network transitions, screen recording, device logs, and DNS/resource observations.
- No iOS Packet Tunnel failure was reproduced in this pass, so no VPN instability root cause was fixed.

### 2026-06-27 / Codex

Scope:
- Разобрал пользовательский iOS сценарий из Milestone 4: при активном VPN обновление профиля падает с `fg core unavailable while applying options`, а выбранный автовыбором сервер на главном экране отображается пусто/`-`.

Result:
- Снял non-destructive process inventory и App Group/App Data контейнеры с подключенного iPhone.
- Подтвердил, что host app и `HiddifyPacketTunnel.appex` одновременно запущены; `box.log` показывает живой background core, health checks и `ActiveServerChanged`, но foreground gRPC core недоступен для операций обновления профиля.
- Исправил fallback в `HiddifyCoreService`: foreground операции `changeOptions`, `validateConfigByPath` и `generateFullConfigByPath` теперь после fg retry используют активный background core.

Changed files:
- `lib/hiddifycore/hiddify_core_service.dart`
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m4-06-ios-fg-core-unavailable-process-inventory-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-07-ios-fg-core-unavailable-appgroup-file-list-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-08-ios-fg-core-unavailable-appgroup-copy-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-09-ios-fg-core-unavailable-appdata-copy-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-10-ios-fg-core-unavailable-copied-log-summary-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-11-ios-fg-core-unavailable-fallback-analyze-2026-06-27.log`

Verification:
- `xcrun devicectl device info processes --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123`: Runner and HiddifyPacketTunnel running.
- `xcrun devicectl device info files --domain-type appGroupDataContainer --domain-identifier group.app.zeon.ios`: App Group files listed.
- `xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier group.app.zeon.ios --source / ...`: App Group copied.
- `source scripts/apple/env.sh && flutter analyze lib/hiddifycore/hiddify_core_service.dart`: no issues.
- `source scripts/apple/env.sh && dart format lib/hiddifycore/hiddify_core_service.dart`: formatted, no content changes after format.

Open issues:
- Нужно собрать и установить новую iOS-сборку на iPhone, затем повторить профиль update при активном VPN и убедиться, что ошибка `fg core unavailable while applying options` больше не появляется.
- Отдельно проверить, восстановилось ли отображение выбранного auto-balanced сервера на главном экране; если нет, следующий слой диагностики в `ActiveProxyNotifier` / `mainOutboundsInfo`.

### 2026-06-27 / Codex

Scope:
- Продолжил только Milestone 4 по реальному iOS сценарию: после включения фрагментации VPN фактически подключен, но главный экран не показывает выбранный auto-balanced сервер, пинги и качество связи.

Result:
- Снял process/App Group inventory с подключенного iPhone; Packet Tunnel был жив, `box.log` показывал `ActiveServerChanged group=balance active=...`, но UI-поток мог получать пустой active proxy.
- Исправил `ActiveProxyNotifier`: пустой active proxy теперь восстанавливается из selector/currentOutbound; для auto-balancer UI показывает группу `balance` и реальный выбранный сервер в group-selected полях.
- Собрал profile iOS build и установил его поверх текущего `app.zeon.ios` на iPhone без удаления данных.
- Автоматический запуск после установки заблокирован iOS trust/security gate: профиль/подпись надо подтвердить на устройстве или открыть приложение вручную.

Changed files:
- `lib/features/proxy/active/active_proxy_notifier.dart`
- `lib/hiddifycore/hiddify_core_service.dart`
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m4-16-ios-fragment-ui-desync-process-inventory-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-17-ios-fragment-ui-desync-appgroup-copy-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-18-ios-fragment-ui-desync-working-file-list-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-19-ios-fragment-ui-desync-log-summary-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-20-ios-fragment-ui-desync-active-proxy-fallback-analyze-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-21-ios-fragment-ui-desync-fallback-analyze-clean-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-22-ios-fragment-ui-desync-fallback-analyze-clean-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-23-ios-fragment-ui-desync-fallback-analyze-clean-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-24-ios-fragment-ui-desync-fallback-profile-build-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-25-ios-fragment-ui-desync-fallback-profile-install-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-26-ios-fragment-ui-desync-fallback-profile-launch-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-27-ios-fragment-ui-desync-fallback-postlaunch-inventory-2026-06-27.log`

Verification:
- `xcrun devicectl device info processes --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123`: Packet Tunnel provider running during the reported fragmentation/UI desync.
- `xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier group.app.zeon.ios --source / ...`: App Group copied for log/config inspection.
- `source scripts/apple/env.sh && flutter analyze lib/features/proxy/active/active_proxy_notifier.dart lib/hiddifycore/hiddify_core_service.dart`: no issues.
- `source scripts/apple/env.sh && flutter build ios --profile`: build succeeded at `build/ios/iphoneos/Runner.app`.
- `xcrun devicectl device install app --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 build/ios/iphoneos/Runner.app`: install succeeded.
- `xcrun devicectl device process launch --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123 --terminate-existing app.zeon.ios`: blocked by iOS trust/security gate.

Open issues:
- На iPhone нужно доверить профиль разработчика или открыть установленное приложение вручную, затем повторить сценарий с фрагментацией и проверить, что главный экран показывает выбранный сервер, пинги и качество связи.
- Если UI всё ещё показывает `-`, следующий шаг: сразу снять свежий App Group snapshot и сравнить `watchActiveProxies()`/`SystemInfo.currentOutbound` вокруг момента desync.

### 2026-06-27 / Codex

Scope:
- Проверил дополнительный iOS Milestone 4 сценарий: auto-select долго пингует серверы и не сразу меняет active connection, хотя отдельные успешные кандидаты уже появились.

Result:
- Снял свежий App Group snapshot с iPhone при живых `Runner` и `HiddifyPacketTunnel`.
- Подтвердил конфиг: `select -> balance`, `balance.strategy = smart-active-auto`, 110 outbounds, monitoring interval `3m0s`.
- По `box.log` после последнего active switch успешные кандидаты были недостаточно сильными для Smart Active: RU-кандидаты получали policy penalty `45` и score `55`, часть кандидатов имела score `15/40`, а многие foreign/non-penalized маршруты в этот же период падали в timeout/deadline.
- Исходники `SmartActive` подтверждают sticky-поведение: live active не меняется только из-за нового ping, если текущий не плохой; нужны fresh/manual-refresh условия, деградация текущего, critical runtime errors или явно лучший policy-preferred кандидат.
- Код приложения не менялся.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`
- `docs/apple-mac-ios-release/logs/m4-28-ios-auto-select-slow-appgroup-copy-2026-06-27.log`
- `docs/apple-mac-ios-release/logs/m4-29-ios-auto-select-slow-summary-2026-06-27.log`

Verification:
- `xcrun devicectl device info processes --device FE12C9C0-D99D-5EA0-B386-AEBC58E16123`: host app and Packet Tunnel provider running.
- `xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier group.app.zeon.ios --source / ...`: App Group copied.
- `jq` over `current-config.json`: Smart Active balance config and monitoring interval verified.
- `rg` over `box.log`: recent `ActiveServerChanged`, `SmartActiveSwitch`, `HealthScore`, timeout/deadline events summarized.

Open issues:
- Для точного UX-решения нужно решить продуктово: оставить sticky Smart Active как есть, добавить UI-состояние "идёт выбор/собираем кандидатов", или сделать startup/manual-refresh более агрессивным для iOS профилей с большим числом серверов.

### 2026-06-27 / Codex

Scope:
- Закрыл Milestone 4 по пользовательскому acceptance: после установленного iOS build ошибок больше не видно, дальше можно переходить к следующему milestone по отдельной команде.

Result:
- Все чекбоксы Milestone 4 переведены в `[x]`.
- Milestone 4 блокеры переведены в `[x]` как закрытые/принятые для текущего release pass.
- Зафиксировано, что destructive clean-device reset на личном iPhone не выполнялся, а закрытие основано на установленном билде, собранных логах и ручном наблюдении пользователя.
- Milestone 5 не начат.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `git status --short`: подтверждены текущие измененные файлы.
- `git diff --check`: whitespace issues отсутствуют.

Open issues:
- Для будущего UX-улучшения можно отдельно вернуться к Smart Active состоянию "идёт выбор/собираем кандидатов" или более агрессивному startup/manual-refresh, но это не блокирует закрытие Milestone 4.

### 2026-07-05 / Codex

Scope:
- Продолжил только Milestone 3: разобрал macOS VPN сценарий, где Safari работает через Zeon, а Edge/Chromium пропускает только RU-трафик или блокирует остальное.

Result:
- Проверил реальное live-окружение: Zeon VPN подключен как `app.zeon.macos`, default route/DNS уходят на `utun5`, provider использует `packet-tunnel-config.json` с `route.default_interface=en1` и `auto_detect_interface=false`.
- Нашел отличие по поведению браузеров: Safari в основном следует системному DNS/NetworkExtension пути, а Edge/Chromium агрессивно использует Secure DNS/DoH, QUIC/HTTP3 и IPv6/AAAA. В текущем `box.log` есть прямые `en1` IPv6 ошибки `no route to host`, DNS/DoH resets на `2001:4860:4860::8844:443/853` и direct outbound timeouts.
- Внес минимальный Apple-only runtime fix: для Apple payload теперь принудительно выставляются `ipv6-mode=ipv4_only`, `remote-dns-domain-strategy=ipv4_only`, `direct-dns-domain-strategy=ipv4_only`, `block-quic=true`.

Changed files:
- `lib/zeoncore/zeon_core_service.dart`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `find macos -iname '*Packet*' -o -iname '*Tunnel*'`: подтвердил актуальный `macos/ZeonPacketTunnel`.
- `jq` по `~/Library/Group Containers/group.app.zeon.macos/Library/Caches/Working/packet-tunnel-config.json`: runtime config contains `outbounds` + `route`, `route.default_interface=en1`, no generated `dns`/`inbounds` keys in provider copy.
- `tail`/`rg` по App Group `box.log`: confirmed Edge-relevant IPv6/DoH/direct errors without exposing proxy secrets.
- `source scripts/apple/env.sh && dart format lib/zeoncore/zeon_core_service.dart`: formatted successfully.
- `source scripts/apple/env.sh && flutter analyze lib/zeoncore/zeon_core_service.dart`: no issues.
- `source scripts/apple/env.sh && flutter build macos --debug`: build succeeded at `build/macos/Build/Products/Debug/ZEON.app`; only existing Pods/AppIcon warnings were emitted.

Open issues:
- Нужно пересобрать и запустить macOS app, включить VPN, открыть Safari и Edge, затем снять свежий diagnostics run. Проверить, что safe payload содержит `ipv4_only`/`block-quic=true`, а Edge больше не блокирует non-RU трафик.

### 2026-07-05 / Codex

Scope:
- Закрыл Milestone 3 Edge/Chromium parity после пользовательской проверки свежей macOS debug-сборки.

Result:
- Пользователь запустил `build/macos/Build/Products/Debug/ZEON.app` после Apple-only IPv4/DNS/QUIC runtime fix.
- Подтверждено: Safari и Edge теперь работают корректно через macOS VPN tunnel.
- Блокер `Milestone 3 / Edge Chromium traffic parity` переведен из `[!]` в `[x]`.

Changed files:
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- Manual user acceptance on macOS: "Да, все отлично работает теперь".

Open issues:
- По Edge/Chromium parity открытых вопросов не осталось.

### 2026-07-05 / Codex

Scope:
- Продолжил только Milestone 3: применил Windows-подобную privacy-схему к Apple-сборкам для профилей и локальных файлов.

Result:
- Подтвердил по реальному macOS App Group, что profile content уже хранится как encrypted `.zcfg` envelope (`version`, `algorithm`, `nonce`, `ciphertext`, `tag`), а не plaintext `.json`.
- Нашел незакрытый слой: Flutter/Drift metadata DB `~/Library/Containers/app.zeon.macos/Data/Library/db.sqlite` хранит `profile_entries.name/url/...` обычными строками.
- Добавил Apple-only `ProtectedProfileDataSource`: при insert/edit sensitive metadata шифруется через тот же AES-256-GCM key из `ProfileConfigStore`, при read/watch прозрачно расшифровывается для UI, `getByName/getByUrl` работают через in-memory decrypt, sort-by-name выполняется после decrypt.
- Добавил startup migration через `ProfileRepository.init()`: старые plaintext metadata будут переписаны в `enc:v1:*` при запуске новой Apple-сборки.

Changed files:
- `lib/features/profile/data/profile_config_store.dart`
- `lib/features/profile/data/profile_data_source.dart`
- `lib/features/profile/data/profile_data_providers.dart`
- `lib/features/profile/data/profile_repository.dart`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `jq` по `~/Library/Group Containers/group.app.zeon.macos/Library/Caches/Working/configs/*.zcfg`: confirmed AES-256-GCM envelope without plaintext profile content.
- `sqlite3 ~/Library/Containers/app.zeon.macos/Data/Library/db.sqlite "select count(*), ..."` before launching the new build: `1|0|0`, confirming existing profile metadata still needs runtime migration.
- `source scripts/apple/env.sh && dart format lib/features/profile/data/profile_config_store.dart lib/features/profile/data/profile_data_source.dart lib/features/profile/data/profile_data_providers.dart lib/features/profile/data/profile_repository.dart`: formatted successfully.
- `source scripts/apple/env.sh && flutter analyze lib/features/profile/data/profile_config_store.dart lib/features/profile/data/profile_data_source.dart lib/features/profile/data/profile_data_providers.dart lib/features/profile/data/profile_repository.dart`: no issues.
- `source scripts/apple/env.sh && flutter build macos --debug`: build succeeded at `build/macos/Build/Products/Debug/ZEON.app`; only existing Pods privacy warnings were emitted.

Open issues:
- Нужно запустить свежий `build/macos/Build/Products/Debug/ZEON.app`, открыть список профилей, убедиться что UI показывает имя профиля, затем повторить safe sqlite counter check: ожидается `encrypted_names = total` и `encrypted_urls = remote profile count`.

### 2026-07-05 / Codex

Scope:
- Продолжил только Milestone 3: добавил быстрые Apple dev-loop скрипты для пересборки macOS и iOS с установкой iOS build на физический iPhone.

Result:
- Добавлен `scripts/rebuild_macos.sh`: source-ит `scripts/apple/env.sh`, пересобирает macOS через `flutter build macos`, по умолчанию в `debug`, печатает абсолютный путь к `.app`, поддерживает `BUILD_MODE=debug|profile|release`, `FLUTTER_TARGET`, `SENTRY_DSN` и `OPEN_APP=1`.
- Добавлен `scripts/rebuild_ios_install_iphone.sh`: source-ит `scripts/apple/env.sh`, пересобирает iOS через `flutter build ios`, по умолчанию в `profile`, auto-detect-ит подключенный iPhone через `xcrun devicectl list devices`, устанавливает `build/ios/iphoneos/Runner.app`, поддерживает `DEVICE_ID=<CoreDevice-UUID>`, `IOS_MODE=debug|profile|release`, `FLUTTER_TARGET`, `SENTRY_DSN` и `LAUNCH_APP=1`.
- Проверил реальное окружение: `xcrun devicectl list devices` видит подключенный `iPhone (Zeon)`, а `flutter devices --machine` видит тот же physical iOS device.
- Скрипты сделаны executable.

Changed files:
- `scripts/rebuild_macos.sh`
- `scripts/rebuild_ios_install_iphone.sh`
- `docs/apple-mac-ios-release/TODO.md`

Verification:
- `bash -n scripts/rebuild_macos.sh`
- `bash -n scripts/rebuild_ios_install_iphone.sh`
- `ls -l scripts/rebuild_macos.sh scripts/rebuild_ios_install_iphone.sh`

Open issues:
- Полный iOS build/install не запускался автоматически в этом шаге, чтобы не трогать подключенный iPhone без отдельной команды пользователя. Для проверки запуска: `./scripts/rebuild_ios_install_iphone.sh`.
