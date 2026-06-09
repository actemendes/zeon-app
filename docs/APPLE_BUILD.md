# Сборка ZEON для iOS и macOS

## Подготовка

Требуется установленный `/Applications/Xcode.app`. Остальные инструменты
устанавливаются локально в `.toolchains`:

```bash
make apple-setup
source scripts/apple/env.sh
make apple-doctor
```

Версии Flutter и Go закреплены в `scripts/apple/bootstrap.sh`. Bootstrap также
скачивает core 4.1.0, устанавливает CocoaPods и готовит оба Xcode workspace.

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
