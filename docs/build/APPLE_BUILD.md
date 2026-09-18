# Сборка ZEON для iOS и macOS

> **Статус: GUIDE / VERIFY BEFORE USE.** Инструкция сборки, не приёмка продукта. Перед выполнением сверить команды с текущими scripts и закреплённым SDK; структурирование не является свежей проверкой всех команд. Команды запускать из корня репозитория. [Навигация](../README.md).

## Подготовка

Требуется установленный `/Applications/Xcode.app`. Остальные инструменты
устанавливаются локально в `.toolchains`:

```bash
make apple-setup
source scripts/apple/env.sh
./scripts/build.sh doctor
```

Версии Flutter и Go закреплены в `scripts/apple/bootstrap.sh`. Bootstrap также
скачивает core 4.1.0, устанавливает CocoaPods и готовит оба Xcode workspace.

Для загрузки обеих Store-сборок в App Store Connect/TestFlight:

```bash
./scripts/build.sh apple-upload
```

Перед повторной загрузкой той же версии увеличьте build number в `pubspec.yaml`;
App Store Connect не принимает повторный upload с уже использованным build.

## macOS

Собрать приложение:

```bash
./scripts/build.sh macos-app
```

Собрать приложение, DMG и PKG:

```bash
./scripts/build.sh macos-artifacts
```

Результат находится в `out/installers/macos`. Локальные DMG/PKG создаются без Developer ID.
Для распространения вне своей машины приложение и установщики нужно подписать
Developer ID Application/Installer и отправить на notarization.

Собрать Mac App Store пакет:

```bash
./scripts/build.sh macos-app-store
```

Собрать и загрузить Mac App Store пакет в App Store Connect/TestFlight:

```bash
./scripts/build.sh macos-app-store-upload
```

## iOS

Для отдельного тестового стенда доступны `ios-test-simulator`, `ios-test-runner`
и `ios-test-diagnostic` через тот же `scripts/build.sh`. Артефакты и provenance
публикуются в `out/installers/ios/lab`; команды — [scripts/README.md](../../scripts/README.md#ios-test-lab).
Это не Store pipeline: ASC API и automatic provisioning не нужны. Dedicated
runner требует собственного существующего development profile; профиль ZEON
или PacketTunnel не подходит для нового runner App ID. Без него device run BLOCKED.

Проверить компиляцию без сертификата:

```bash
./scripts/build.sh ios-unsigned
```

Для устанавливаемого IPA:

```bash
cp ios/AppleSigning.xcconfig.example ios/AppleSigning.xcconfig
```

Укажите в локальном файле Team ID и уникальный bundle ID, добавьте аккаунт в
Xcode и создайте App ID для приложения и Packet Tunnel extension. Затем:

```bash
./scripts/build.sh ios-ipa
```

Для VPN-приложения Apple Developer Program должен разрешать Network Extension
entitlement. Без сертификата, provisioning profiles и этого entitlement
устанавливаемый IPA создать нельзя.

Собрать и загрузить iOS build в App Store Connect/TestFlight:

```bash
./scripts/build.sh ios-upload
```

Если архив уже собран и нужно только повторить upload без пересборки:

```bash
IOS_UPLOAD_SKIP_BUILD=1 ./scripts/build.sh ios-upload
```

Для upload через App Store Connect API key можно задать переменные:

```bash
export APP_STORE_CONNECT_API_KEY_PATH=/path/to/AuthKey_KEYID.p8
export APP_STORE_CONNECT_API_KEY_ID=KEYID
export APP_STORE_CONNECT_API_ISSUER_ID=ISSUER_UUID
```

Без этих переменных `xcodebuild` использует Apple account, добавленный в Xcode.
