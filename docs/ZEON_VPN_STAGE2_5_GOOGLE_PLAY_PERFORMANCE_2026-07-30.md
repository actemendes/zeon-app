# ZEON VPN Stage 2.5 — Google Play performance и release hardening

Дата проверки: 2026-07-30  
Ветка: `stage2.5/google-play-performance`  
База: `stage2.4/data-plane-stabilization` / `961ced2058c8b67c268ac5a44bf4c260b958127d`  
Вердикт: **PASS**

## 1. Executive summary

Stage 2.5 не меняет VPN lifecycle, sing-box, Hiddify/ZEON core, DNS, routing,
MTU, IPv6, Smart Active, Round Robin, UDP probe, профили или подписки.

Две рекомендации Google Play были проверены на заново собранном release AAB:

1. Метод `r2.u5.a` действительно содержал небезопасный одноаргументный
   `BitmapFactory.decodeStream(InputStream)`. R8 horizontal class merging
   поместил метод
   `com.mr.flutter.plugin.filepicker.FileUtils.compressImage(Uri,int,Context)`
   из `file_picker 8.3.7` в обфусцированный класс, основной source marker
   которого принадлежит ML Kit. Владельцем проблемного метода остаётся
   `file_picker`, а не ZEON и не ML Kit.
2. В release уже работали R8, optimized default ProGuard configuration и
   resource shrinking. Приложение не содержало собственного широкого keep
   rule, `-dontoptimize`, `-dontshrink`, `-dontobfuscate` или отключения R8
   full mode. Stage 2.5 сделал release-контракт явным и добавил проверяющий
   verifier.

Bitmap path исправлен локальным совместимым backport в точную копию
`file_picker 8.3.7`: bounds-first decode, проверка размеров, power-of-two
`inSampleSize`, второй decode с `BitmapFactory.Options`, работа вне main
thread и явный `recycle()`. Release DEX больше не содержит исходный
одноаргументный decode в reported call site.

AGP 9 не внедрён. Для текущего Flutter `3.41.9` и plugin stack миграция
является неподдерживаемой связанной сменой Flutter/Gradle/Kotlin/plugin APIs.
Результат классифицирован как **AGP 9 MIGRATION BLOCKED**, а не скрыт
workaround-ом.

Финальный AAB установлен через bundletool на OnePlus GM1901. Изолированные
Android tests прошли `51/51`, Flutter tests — `133/133`. Физическая VPN
регрессия прошла: permission flow, 10 connect/stop, 5 restart, Telegram,
YouTube, два полных Cloudflare Speedtest и HTTP/3 `5/5`. Crash, ANR, native
panic и Go panic не обнаружены.

Google Play ещё не анализировал новый AAB, поэтому внешний статус:

```text
LOCALLY FIXED — PLAY REANALYSIS PENDING
```

## 2. Stage 2.4 baseline

| Объект | Значение |
|---|---|
| Stage 2.4 commit | `961ced2058c8b67c268ac5a44bf4c260b958127d` |
| Core | `sing-box 1.13.14-zeon.1` |
| Core source revision | `e8c06439e1864255d81f4ee89290d89cbb1b3a18` |
| Core AAR SHA-256 | `5BEC09E8AA72E385C0BB4950FE9970759725C6083F813E6DAB7BBFE436BECB00` |
| Baseline AAB SHA-256 | `43E2A522277EDA9BAA12AD8EC22DD5D9CEB9111210EB89032AC4063745FC530B` |
| Baseline AAB size | 232,637,936 bytes |
| Baseline universal APK SHA-256 | `6B3517B5C2D639D8210C6E36B86B331C8BBE8B3861F404831FB2A14B6E3DC6DA` |
| Baseline device download size | 48,156,581 bytes |
| Baseline cold start | 286 ms |
| Baseline stop + settling | PSS 268,789 KiB; RSS 385,276 KiB |

Baseline AAB был собран до Stage 2.5 изменений, установлен через bundletool,
запущен и проверен реальным DNS/HTTPS через валидированный Android VPN.
Evidence: `baseline/`, `baseline/device-summary.txt`.

## 3. Toolchain и финальные artifacts

Toolchain не обновлялся:

| Компонент | Версия |
|---|---|
| Flutter / Dart | 3.41.9 / 3.11.5 |
| AGP / R8 | 8.6.0 / 8.6.17 |
| Gradle | 8.7 |
| Kotlin Gradle Plugin | 2.1.0 |
| JDK | Temurin 17.0.19 |
| NDK | 28.2.13676358 |
| bundletool | 1.18.3 |
| compileSdk / targetSdk / minSdk | 36 / 36 / 24 |

Финальные artifacts:

| Artifact | SHA-256 | Size |
|---|---|---:|
| Release AAB | `E140523788ACCB3BEDDA685151E63CF35C7857B0FA609BB7EAD6A0D563AA5B39` | 232,638,745 |
| bundletool universal APK | `4EA930ADA761B120AB38ED3A6323081A89A68DAEC188C3BB35308E7ACF887AB2` | 318,096,071 |
| arm64 split APK | `1860149CEA3791FF68E30D76E6B2189596E502172AF48B918798F27E4115D367` | 103,445,640 |
| Core AAR | `5BEC09E8AA72E385C0BB4950FE9970759725C6083F813E6DAB7BBFE436BECB00` | 104,564,034 |
| AAR `classes.jar` | `959C71C4B641067BA96FA0D24BD23ADCC99F8DC063274FA4E99B2C0C07BE7B58` | unchanged |

Signing certificate SHA-256:
`8C767DC4657BB13CCFEE900B4B7CACC8F794027E6544650EF85D006BDC9F8EE7`.

Machine-readable provenance:
`baselines/android-core/2026-07-30-stage2-5.json`.

## 4. Mapping `r2.u5.a`

Фактическая R8 mapping chain в baseline:

```text
com.google.android.gms.internal.mlkit_vision_barcode.zzpg -> r2.u5
com.mr.flutter.plugin.filepicker.FileUtils.compressImage(
    android.net.Uri, int, android.content.Context
) -> a
```

Это результат horizontal class merging: target class назван по ML Kit, но
line mapping метода `a` указывает на `FileUtils.compressImage` из
`file_picker`.

Классификация:

| Поле | Результат |
|---|---|
| Source class | `com.mr.flutter.plugin.filepicker.FileUtils` |
| Source method | `compressImage(Uri,int,Context)` |
| Dependency | Flutter plugin `file_picker` |
| Версия | `8.3.7` |
| Baseline DEX call | `BitmapFactory.decodeStream(InputStream)` |
| Final DEX calls | два `decodeStream(InputStream,Rect,Options)` в bounded decoder |
| ZEON production reachability | В текущем ZEON `FilePicker` используется для JSON import/export; image compression path не вызывается |

Evidence:

- `baseline/r8/mapping.txt`;
- `baseline/bitmapfactory-obfuscated-mapping.txt`;
- `host/dex/baseline-bitmap-decode-calls.txt`;
- `host/dex/final-bitmap-decode-calls.txt`;
- `final/bitmap-callsite-verification.json`.

## 5. Аудит BitmapFactory

В release DEX найдено 13 production call sites. Они сгруппированы ниже.

| Владелец | Decode | Источник данных | Main thread / bounds | Reachability ZEON | Решение |
|---|---|---|---|---|---|
| `file_picker FileUtils.compressImage` (`r2.u5.a`) | stream | выбранный пользователем image URI | worker thread, baseline без bounds | текущие ZEON вызовы выбирают только JSON, но bytecode path присутствовал | исправлен |
| `flutter_local_notifications` | resource/file/byte array/stream | notification bitmap styles | plugin-owned; зависит от вызванного style | ZEON использует text notification path, bitmap style не обнаружен | не менять |
| AndroidX `IconCompat` | stream | framework/app icon | AndroidX internal density/icon conversion | косвенный framework path | не является reported call site |
| `mobile_scanner` | byte array | camera/QR frame | scanner worker pipeline | используется QR scanner | сохраняется; input ограничен camera frame |
| ML Kit barcode (`r2.p5`) | byte array | barcode pipeline | library-owned | QR scanner dependency | сохраняется |
| Flutter `FlutterJNI.decodeImage` | byte array | Flutter image codec | Flutter engine image pipeline | Flutter assets/external images | сохраняется |
| Flutter HEIF API 36 (`r4.c`) | byte array | Flutter engine HEIF | framework decoder | формат-зависимый | сохраняется |
| Sentry replay capture | file | app-owned replay frame | Sentry-owned capture size | только при replay capture | сохраняется |

Отдельно проверены notification icons, profile/server icon usage, QR, splash,
onboarding и background assets. Небезопасный call site Google Play относится
не к маленькому drawable, а к image compression path `file_picker`.

Полный inventory: `baseline/bitmapfactory-callers.csv`.

## 6. Bitmap root cause и fix

Baseline `FileUtils.compressImage()` декодировал входной URI целиком до
сжатия JPEG. Пользователь или внешний provider мог передать изображение
значительно больше требуемого, и allocation происходил до возможности
уменьшить его.

Изменения:

- `third_party/file_picker/android/src/main/java/com/mr/flutter/plugin/filepicker/SampledBitmapDecoder.java:21`
  — новый bounded decoder;
- bounds-only pass — строки 38–46;
- power-of-two `inSampleSize` — строки 48–54 и 66–87;
- второй decode с `Options` — строки 56–63;
- source guard: 100,000 px по стороне и 1,000,000,000 source pixels —
  строки 90–100;
- `FileUtils.compressImage()` использует decoder и освобождает bitmap —
  `FileUtils.java:95`;
- plugin уже выполняет этот путь в отдельном worker thread —
  `FilePickerDelegate.java:113`;
- локальная dependency остаётся version-compatible `8.3.7`, MIT license
  сохранена в `third_party/file_picker/LICENSE`.

Маленькие изображения не увеличиваются. QR без необходимости sampling
остаётся 256×256 с проверкой чёрных/белых модулей. Повреждённые, пустые и
truncated inputs завершаются контролируемой ошибкой. Original-view path
ZEON не менялся.

## 7. Bitmap tests и memory

Изолированные instrumented tests покрывают:

1. landscape 4608×768;
2. portrait 768×4608;
3. small 128×96;
4. square 3072×3072;
5. very wide 8192×128;
6. very tall 128×8192;
7. corrupt;
8. empty;
9. truncated stream;
10. overflow dimensions;
11. repeated decode ×10;
12. parallel decode ×4;
13. QR quality;
14. notification/profile icon.

Результат: **14/14**, полный safe instrumentation suite: **51/51**.

Примеры максимального ARGB allocation:

| Case | Baseline full decode | Final sampled decode | Reduction |
|---|---:|---:|---:|
| 4608×768 → 1152×192 | 14,155,776 B | 884,736 B | 93.75% |
| 3072×3072 → 768×768 | 37,748,736 B | 2,359,296 B | 93.75% |
| 8192×128 → 2048×32 | 4,194,304 B | 262,144 B | 93.75% |
| 128×96 | 49,152 B | 49,152 B | 0%; no upscale |

Это allocation по фактическим decoded dimensions, а не утверждение о
процессном peak RSS. Текущий ZEON не вызывает image-compression path, поэтому
искусственно активировать его в production профиле для peak measurement было
бы неверным. Device Java/native/PSS приведены отдельно в разделе 14.

Evidence:
`host/bitmap/allocation-comparison.csv`,
`host/safe-validation-instrumentation-51.txt`.

## 8. R8 audit

Финальная release-конфигурация:

```text
minifyEnabled true
shrinkResources true
proguard-android-optimize.txt
R8 8.6.17
R8 full mode not disabled
```

Не обнаружены:

- `android.enableR8.fullMode=false`;
- `-dontoptimize`;
- `-dontshrink`;
- `-dontobfuscate`;
- app rule вида `-keep class ** { *; }`;
- app-wide `-keepclassmembers class ** { *; }`.

`android/app/proguard-rules.pro` намеренно пуст. Future rule должен называть
конкретного reflection/JNI/serialization owner и иметь release test.

Широкие dependency consumer rules, оставленные осознанно:

| Rule owner | Rule | Причина |
|---|---|---|
| `hiddify-core.aar` | `-keep class go.** { *; }`, `-keep class com.hiddify.core.** { *; }` | gomobile/JNI proxy и имена generated public API |
| `mobile_scanner` / ML Kit | ML Kit/barhopper classes | dependency reflection/native registry; не сужать без upstream contract tests |
| `sentry_flutter` | `io.sentry.flutter.**` | dependency consumer rule и Flutter integration |
| AndroidX Window | reflection guard interfaces | framework reflection |
| AAPT | manifest/inflated constructors | Android component and XML inflation |

Stage 2.5 не удалял dependency consumer rules методом проб.

Verifier: `scripts/verify_android_r8_release.ps1`.  
Result: `final/r8-verification.json`.

## 9. R8 variants

| Variant | Содержание | AAB | Device download | Result |
|---|---|---:|---:|---|
| A | Stage 2.4 implicit Flutter release defaults | 232,637,936 | 48,156,581 | optimized R8 уже работал |
| B | Bitmap fix + явные minify/shrink/custom rules contract | 232,638,745 | 48,156,661 | PASS |
| C | B + optimized resource shrinking | not built | not built | AGP 8.6 не поддерживает; feature доступен в более новом AGP |

Разница A→B обусловлена новым bounded decoder, а не «экономией» от уже
активного R8:

- AAB: +809 bytes;
- device download: +80 bytes;
- compressed DEX: 2,364,652 → 2,365,310 bytes;
- resources и native payload не изменились.

R8 hardening здесь повышает воспроизводимость и предотвращает случайное
отключение оптимизации. Он не выдаётся за неподтверждённое уменьшение size.

## 10. AGP 9 compatibility

Результат: **AGP 9 MIGRATION BLOCKED**.

Текущий Flutter `3.41.9` предшествует stable Flutter `3.44`, где появилась
поддержка AGP 9 built-in Kotlin migration. AGP 9.0.1 требует Gradle 9.1 и
перехода на built-in Kotlin/KGP 2.2.10. ZEON и 11 из 22 Android plugins
используют legacy Kotlin plugin/`kotlinOptions`; приложение также использует
legacy `android.applicationVariants`.

Следовательно, AGP 9 сейчас означает одновременный upgrade Flutter, Gradle,
Kotlin DSL и plugin stack, что выходит за Stage 2.5 и нарушает требование
не обновлять всё одной миграцией.

Точная матрица и отдельный upgrade path:
`docs/ZEON_STAGE2_5_AGP9_COMPATIBILITY_2026-07-30.md`.

Официальные источники:

- https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin
- https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors
- https://developer.android.com/build/releases/agp-9-0-0-release-notes
- https://developer.android.com/topic/performance/app-optimization/enable-app-optimization

## 11. Native AAR / JNI / Flutter plugins

Core AAR не изменён. Stage 2.4 и Stage 2.5 byte-identical:

- AAR SHA;
- `classes.jar`;
- `libhiddify-core.so` для arm64-v8a, armeabi-v7a и x86_64;
- Java public API;
- gomobile/JNI proxy symbols;
- native library names и ABI.

Arm64 split APK также byte-identical baseline:
`1860149CEA3791FF68E30D76E6B2189596E502172AF48B918798F27E4115D367`.

`scripts/verify_android_core.ps1` прошёл для финального universal APK.
Evidence: `final/core-aar-api-abi.csv`, `host/core-verifier.log`.

Release plugin registration, profile loading, notification, VPN foreground
service, Flutter MethodChannel/EventChannel и gomobile bridge прошли
физическую проверку.

## 12. Host tests

| Test | Result |
|---|---|
| `flutter test` | 133/133 PASS |
| Safe Android instrumentation | 51/51 PASS |
| Bitmap instrumented subset | 14/14 PASS |
| Android validation JVM task | BUILD SUCCESSFUL; `NO-SOURCE` |
| Release AAB build | PASS |
| bundletool build/install | PASS |
| Bitmap release verifier | PASS |
| R8 release verifier | PASS |
| Core provenance verifier | PASS |
| AAR API/ABI comparison | identical |
| `dart analyze lib test` | 465 pre-existing warnings/info; no error caused by Stage 2.5 Android-only change |
| `git diff --check` | PASS |

Go/core tests не перезапускались в Stage 2.5: Go source, AAR и per-ABI native
libraries byte-identical Stage 2.4. Core provenance verifier является
контролем этого инварианта.

## 13. Device VPN regression

Устройство:

```text
serial=18bfc103
OnePlus GM1901
Android 16 / API 36
package=com.zeon.hiddify
```

Финальный bundletool device set установлен поверх пользовательских данных.
`firstInstallTime=2026-07-29 23:13:48` не изменился; профиль и подписка
сохранились.

Результаты:

| Scenario | Result |
|---|---|
| First permission flow | one Connect; notification + VPN consent; one generation; command/TUN/protect/core success |
| Android VPN | active + VALIDATED |
| First controlled HTTPS | 10/10, HTTP 200, 65,536 bytes |
| Connect/stop | 10/10 start, validated VPN, HTTPS and cleanup |
| Restart | 5/5, new generation/TUN, HTTPS, no stale dialog |
| Telegram | foreground/background + 15 s screen-off; post-check HTTP 200 |
| YouTube | Shorts playback active 20 s; post-check HTTP 200 |
| Cloudflare Speed | 2/2 complete download + upload |
| HTTP/3 | 5/5 `protocol=h3`, HTTP 200, body/network bytes > 0, VPN validated |
| Notification | runtime permission and VPN foreground notification PASS |
| Crash/ANR/panic | 0 matches |

Cloudflare results:

| Run | Download | Upload | Latency | Jitter | Loss |
|---:|---:|---:|---:|---:|---:|
| 1 | 53.7 Mbps | 69.2 Mbps | 51.4 ms | 12.0 ms | 0% |
| 2 | 52.3 Mbps | 79.6 Mbps | 47.4 ms | 7.60 ms | 0% |

Перед двумя успешными run одна первая browser navigation при ещё активном
YouTube PiP дала `ERR_FAILED`. Это не повторилось после закрытия PiP:
контрольный HTTPS оставался рабочим, два полных Speedtest завершились, а
post-load HTTPS вернул 200/65,536 bytes. Поэтому этот warm-up navigation
failure не классифицирован как VPN regression.

HTTP/3 evidence для каждого из пяти run:

```text
protocol=h3
status=200
body_bytes=296..297
network_bytes=404..405
vpn=true
validated=true
```

## 14. Device memory и startup

| Snapshot | PSS KiB | RSS KiB | Java heap KiB | Native heap KiB | Threads |
|---|---:|---:|---:|---:|---:|
| Stage 2.4 cold launch | 305,044 | 438,212 | 9,804 | 37,912 | n/a |
| Stage 2.4 stop + settling | 268,789 | 385,276 | 5,840 | 33,232 | n/a |
| Stage 2.5 after Speedtest + HTTP/3, connected | 264,832 | 385,976 | 7,424 | 29,568 | 71 |
| Stage 2.5 stop + 45 s, UI foreground | 401,527 | 545,724 | 10,400 | 43,148 | 72 |
| Stage 2.5 stop + 105 s, background settled | 254,442 | 375,632 | 8,180 | 29,348 | 68 |
| Stage 2.5 clean cold launch | 203,754 | 315,756 | 4,912 | 29,492 | 54 |

Высокий foreground high-water mark после нагрузки вернулся в baseline range
после background settling. Threads снизились 72→68, active VPN NetworkAgent
после stop отсутствовал, `tun_close` и `session_close_completed` записаны,
foreground service имел `startRequested=false`. Session-linear growth не
обнаружен.

Cold startup: 286 ms baseline против 291 ms final. Разница 5 ms находится
внутри шума одиночного измерения; улучшение или регрессия startup не
утверждается.

## 15. Production app data protection

Instrumentation target:

```text
com.zeon.hiddify.validation
com.zeon.hiddify.validation.test
```

`connected*AndroidTest` для production build type блокируется в
`android/app/build.gradle:187`; validation имеет
`applicationIdSuffix ".validation"` (`build.gradle:154`).

Перед и после safe instrumentation совпали:

- production package;
- versionCode/versionName;
- `firstInstallTime`;
- `lastUpdateTime`;
- наличие профиля.

Production package не удалялся, `pm clear` и `adb uninstall` не выполнялись.

## 16. Google Play local verification

| Check | Result |
|---|---|
| Reported `r2.u5.a` identified | PASS |
| Original one-argument decode at that method | absent in final DEX |
| Bounds pass | present |
| `BitmapFactory.Options` | present |
| `inSampleSize` | present |
| Heavy decode off main thread | present |
| R8 mapping | generated |
| R8 usage/config/seeds | generated |
| Resource shrink report | generated |
| R8 optimize/shrink/obfuscate enabled | PASS |
| Broad ZEON keep rule | absent |
| AAB bundletool install | PASS |
| AGP 9+ | not used; compatibility blocker documented |

Локальная техническая формулировка:

```text
Bitmap: LOCALLY FIXED — PLAY REANALYSIS PENDING
R8: LOCALLY VERIFIED — PLAY REANALYSIS PENDING
AGP 9: MIGRATION BLOCKED BY CURRENT FLUTTER/PLUGIN STACK
```

Нельзя утверждать, что Play Console предупреждение исчезло, пока
`E1405237...AA5B39` не загружен и Google Play не завершил новый анализ.

## 17. Size comparison

| Category | Stage 2.4 | Stage 2.5 | Delta |
|---|---:|---:|---:|
| AAB | 232,637,936 | 232,638,745 | +809 |
| Device download | 48,156,581 | 48,156,661 | +80 |
| Universal APK | 318,096,372 | 318,096,071 | -301 |
| Compressed DEX | 2,364,652 | 2,365,310 | +658 |
| Compressed resources | 907,997 | 907,997 | 0 |
| Compressed native | 117,509,971 | 117,509,971 | 0 |

Stage 2.5 не выдаёт небольшой рост DEX за size optimization. Цель bitmap fix
— ограничить runtime allocation; R8 hardening — гарантировать сохранение
release optimization contract.

## 18. Commits

| Commit | Назначение | Independent rollback |
|---|---|---|
| `e6e11ff0` | bitmap identification + verifier | yes |
| `02dbc548` | file_picker downsampling + 14 tests | yes |
| `85ca8964` | explicit R8/repository shrink contract + verifier | yes |
| `7b27fb0a` | AGP 9 compatibility decision | yes |
| `4093b038` | immutable Stage 2.5 provenance | yes |

Отдельный AGP migration commit отсутствует, потому что migration
классифицирована как blocked. Отдельный keep-rule-removal commit отсутствует,
потому что ZEON app-wide keep rule не существовал; создавать пустой commit
или удалять dependency consumer rules было бы недоказанным изменением.

## 19. Rollback

Bitmap rollback:

```powershell
git revert 02dbc548
flutter pub get
```

R8 hardening rollback:

```powershell
git revert 85ca8964
```

Полный возврат application artifact без очистки данных:

```powershell
adb -s 18bfc103 install -r -d `
  out/stabilization/stage2.4-6b25acb3/zeon-1.3.0-stage2.4-release.apk
```

После rollback проверить SHA
`99993A4D9F2C4911FF8282A9D68A6E2DB912A344D637AC0998D892788DDFCD27`,
сохранность профиля, VPN VALIDATED, DNS, HTTPS и stop cleanup.

`git reset --hard`, `adb uninstall` и `pm clear` не требуются.

## 20. Evidence

Evidence root:

```text
out/stage2-5-google-play/20260730T110709Z/
```

Основные каталоги:

- `baseline/` — Stage 2.4 AAB, bundletool APKs, R8 reports и baseline metrics;
- `final/` — Stage 2.5 AAB/APKs, R8 reports, signing и API/ABI;
- `host/` — builds, tests, verifiers, DEX proof и AGP compatibility;
- `device/` — permission flow, lifecycle summaries, apps, HTTP/3 и resources.

Redacted evidence manifest:

```text
out/stage2-5-google-play/20260730T110709Z/SHA256SUMS-redacted.txt
SHA-256:
95EDD805205100B69851DC14C9E817CE2B47F82CE79BE9F3239653C171A7042C
```

58 raw temporary files с Wi-Fi identifiers, physical IP/BSSID или
пользовательским UI были удалены после извлечения обезличенных assertions.
Они не входят в manifest. Один transient screenshot экрана блокировки с
персональным уведомлением также был сразу удалён и никогда не включался в
evidence.

## 21. Ограничения и verdict

Оставшиеся ограничения:

- Google Play reanalysis нового AAB ещё не выполнен;
- AGP 9 требует отдельной поддерживаемой Flutter/plugin migration;
- одиночные startup/memory значения не являются benchmark suite;
- 6–12-часовой soak не относится к Stage 2.5 и не выполнялся.

Обязательные Stage 2.5 критерии выполнены:

- bitmap issue локализован и исправлен в текущем release bytecode;
- R8 и resource shrinking включены и проверены;
- AAB устанавливается;
- JNI/gomobile/Flutter plugins работают;
- физическая VPN regression прошла;
- crash/ANR/panic отсутствуют;
- AGP 9 blocker точно классифицирован.

Итог:

```text
PASS
```

