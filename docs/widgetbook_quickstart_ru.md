# Widgetbook Quickstart (RU)

## 1) Если `puro` не найден в PowerShell

Запускай через полный путь:

```powershell
& "C:\Users\actemendes\AppData\Local\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter --version
```

Для удобства можно создать alias в текущей сессии:

```powershell
Set-Alias puro "C:\Users\actemendes\AppData\Local\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe"
```

## 2) Сгенерировать Widgetbook директории

```powershell
& "C:\Users\actemendes\AppData\Local\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter pub run build_runner build --delete-conflicting-outputs
```

## 3) Запустить дизайн-режим

```powershell
& "C:\Users\actemendes\AppData\Local\Microsoft\WinGet\Packages\pingbird.Puro_Microsoft.Winget.Source_8wekyb3d8bbwe\puro.exe" flutter run -d chrome --target lib/widgetbook/main.dart
```

## 4) Что уже подключено

- `lib/widgetbook/main.dart` — отдельная точка входа Widgetbook.
- `lib/widgetbook/widgetbook.dart` — конфиг addons (сетка, темы, viewport).
- `lib/widgetbook/use_cases/home/home_page.usecase.dart` — use-cases для `HomePage` (Disconnected / Connected).

## 5) Как работать дизайнеру

1. Держи Widgetbook открытым в браузере.
2. Меняй виджеты в `lib/features/**` или тему в `lib/core/theme/**`.
3. Сохраняй файл и смотри hot reload.
4. Если добавил новый use-case, снова запусти `build_runner`.
