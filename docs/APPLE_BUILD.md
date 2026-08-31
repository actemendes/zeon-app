# Сборка ZEON для iOS и macOS

## Подготовка

Требуется установленный `/Applications/Xcode.app`. Остальные инструменты
устанавливаются локально в `.toolchains`:

```bash
make apple-setup
source scripts/apple/env.sh
make apple-config-check
make apple-doctor
```

The first macOS build also prepares a universal `HiddifyCore.xcframework`
with `arm64` and `x86_64` macOS slices. The result is cached under
`hiddify-core/bin`; subsequent builds only validate it. Set
`MACOS_CORE_AUTOBUILD=0` to require a prebuilt framework instead.

The standalone macOS `hiddify-core.dylib` is linked with dead stripping. This
preserves the Naive/Cronet implementation while removing an unused Cronet
function that references the private CoreFoundation symbol
`__kCFBundleNumericVersionKey`. Apple build commands validate both universal
slices and reject any cached or embedded core that still imports this symbol.

Версии Flutter и Go закреплены в `scripts/apple/bootstrap.sh`. Bootstrap также
скачивает core 4.1.0, устанавливает CocoaPods и готовит оба Xcode workspace.
Версия host app и Packet Tunnel берётся из одного `pubspec.yaml`; автоматическое
изменение build number при export отключено для воспроизводимости.

Для загрузки обеих Store-сборок в App Store Connect/TestFlight:

```bash
make apple-upload
```

Перед повторной загрузкой той же версии увеличьте build number в `pubspec.yaml`;
App Store Connect не принимает повторный upload с уже использованным build.

Все release/Store-команды жёстко используют production entrypoint
`lib/main_prod.dart`. Если `FLUTTER_TARGET` случайно указывает на dev entrypoint,
сборка остановится до запуска Flutter. Для локальной разработки используйте
`scripts/rebuild_macos.sh` (debug по умолчанию) или
`scripts/rebuild_ios_install_iphone.sh` (profile по умолчанию); эти режимы
продолжают использовать `lib/main.dart` и поддерживают явный `FLUTTER_TARGET`.
Release-артефакты дополнительно получают `ZEON_FLUTTER_ENVIRONMENT=prod` в
`Info.plist`; upload отклонит старый или неподтверждённый архив. Переменные
`FLUTTER_XCODE_*`, способные подменить entrypoint, environment, channel namespace
или версию, запрещены в этих helpers.

Namespace нативных Flutter channels закреплён как `com.zeon.app` в tracked
xcconfig для обеих платформ. В локальных `AppleSigning.xcconfig` задаются только
Team ID и bundle ID.

## macOS

Собрать приложение:

```bash
make macos-app
```

Собрать приложение, DMG и PKG:

```bash
make macos-artifacts
```

Результат находится в `out/apple`. Локальные DMG/PKG создаются без Developer ID.
Для распространения вне своей машины приложение и установщики нужно подписать
Developer ID Application/Installer и отправить на notarization.
Эти две вне-магазинные команды по умолчанию используют `release=general`, поэтому
в них остаётся доступна проверка обновлений из GitHub. Store-команды ниже всегда
используют `release=app-store`.

Собрать Mac App Store пакет:

```bash
make macos-app-store
```

Собрать и загрузить Mac App Store пакет в App Store Connect/TestFlight:

```bash
make macos-app-store-upload
```

## iOS

Проверить компиляцию без сертификата:

```bash
make ios-unsigned
```

Для устанавливаемого IPA:

```bash
cp ios/AppleSigning.xcconfig.example ios/AppleSigning.xcconfig
```

Укажите в локальном файле Team ID и уникальный bundle ID, добавьте аккаунт в
Xcode и создайте App ID для приложения и Packet Tunnel extension. Затем:

```bash
make ios-ipa
```

Для VPN-приложения Apple Developer Program должен разрешать Network Extension
entitlement. Без сертификата, provisioning profiles и этого entitlement
устанавливаемый IPA создать нельзя.

Собрать и загрузить iOS build в App Store Connect/TestFlight:

```bash
make ios-upload
```

Если архив уже собран и нужно только повторить upload без пересборки:

```bash
IOS_UPLOAD_SKIP_BUILD=1 make ios-upload
```

Skip разрешён только для архива, собранного после внедрения production-маркера.
Перед export проверяются production marker, версия/build number основного
приложения и совпадение этих значений у embedded Packet Tunnel extension. Если
проверка не проходит, пересоберите IPA.

Для upload через App Store Connect API key можно задать переменные:

```bash
export APP_STORE_CONNECT_API_KEY_PATH=/path/to/AuthKey_KEYID.p8
export APP_STORE_CONNECT_API_KEY_ID=KEYID
export APP_STORE_CONNECT_API_ISSUER_ID=ISSUER_UUID
```

Без этих переменных `xcodebuild` использует Apple account, добавленный в Xcode.
