# ZEON Stage 2.5 — AGP 9 compatibility decision

Date: 2026-07-30  
Decision: **AGP 9 MIGRATION BLOCKED**

## Current supported build

| Component | Stage 2.5 baseline |
| --- | --- |
| Flutter | 3.41.9 |
| Dart | 3.11.5 |
| Android Gradle Plugin | 8.6.0 |
| Gradle | 8.7 |
| Kotlin Gradle Plugin | 2.1.0 |
| JDK | Temurin 17.0.19 |
| compileSdk / targetSdk | 36 / 36 |
| NDK | 28.2.13676358 |
| R8 | 8.6.17 |

## Blocking compatibility facts

1. Flutter's AGP 9 compatibility work for built-in Kotlin and the new AGP DSL
   landed in Flutter `3.44.0-0.1.pre` and first became stable in Flutter
   `3.44`. ZEON is pinned to Flutter `3.41.9`.
2. AGP `9.0.1` requires Gradle `9.1.0`, while ZEON uses Gradle `8.7`.
3. AGP 9 built-in Kotlin has a runtime dependency on Kotlin Gradle Plugin
   `2.2.10`. ZEON uses the legacy `org.jetbrains.kotlin.android` plugin
   version `2.1.0`.
4. `android/app/build.gradle` still uses `kotlinOptions` and the removed legacy
   `android.applicationVariants` API.
5. Eleven of the 22 resolved Android Flutter plugins apply the legacy Kotlin
   plugin and configure `kotlinOptions`: `device_info_plus`, `dynamic_color`,
   `in_app_review`, `installed_apps`, `mobile_scanner`, `network_info_plus`,
   `package_info_plus`, `sentry_flutter`, `share_plus`,
   `shared_preferences_android`, and `workmanager_android`.
6. Optimized resource shrinking cannot be enabled on the current AGP 8.6
   toolchain. Android documents it as introduced in AGP 8.12 and enabled by
   default in AGP 9.

Primary references:

- [Flutter built-in Kotlin / AGP 9 migration](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin)
- [Flutter plugin migration requirements](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors)
- [AGP 9.0.1 compatibility and behavior changes](https://developer.android.com/build/releases/agp-9-0-0-release-notes)
- [Android R8 and optimized resource shrinking](https://developer.android.com/topic/performance/app-optimization/enable-app-optimization)

The resolved plugin scan is stored in the Stage 2.5 evidence directory as
`host/agp9-plugin-compatibility.csv`.

## Minimal supported migration chain

This must be a separate migration stage, not part of the Stage 2.5 production
artifact:

1. Upgrade Flutter from 3.41.9 to a tested stable release at or above 3.44.
2. Move the wrapper from Gradle 8.7 to the AGP 9-required Gradle 9.1.x line.
3. Adopt AGP 9.0.x and its built-in Kotlin/KGP 2.2.10 model.
4. Replace `android.applicationVariants` with `androidComponents.onVariants`.
5. Migrate the app and every affected plugin away from unconditional legacy
   Kotlin plugin application and `kotlinOptions`.
6. Revalidate Wire/protobuf code generation, Flutter plugin registration,
   gomobile/JNI packaging, signing, AAB splits, R8 full mode, and optimized
   resource shrinking.
7. Repeat release AAB installation and the Stage 2.5 VPN regression.

## Stage 2.5 action

No AGP, Gradle, Kotlin, JDK, Flutter, plugin, core, or NDK version is changed.
Using AGP 9 in this stage would require several coupled unsupported upgrades
and would violate the one-factor migration boundary. The current AGP 8.6 build
continues with R8 full mode, code shrinking, obfuscation, optimization, and
legacy resource shrinking enabled.
