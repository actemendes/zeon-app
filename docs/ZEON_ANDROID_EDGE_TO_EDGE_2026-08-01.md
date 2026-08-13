# ZEON Android edge-to-edge — Stage 2.10 and 2.10.1

Date: 2026-08-01  
Package: `com.zeon.hiddify`  
Built repository version: `1.4.0+104001` (the working tree was already newer than the requested `1.3.0+103001`)  
Flutter: `3.41.9`, engine `42d3d75a56`  
compileSdk/targetSdk: `36/36`

## Play Console API origins

The exact Stage 2.9 production AAB contained all three forbidden Window method references. R8 mapping, DEX method-id parsing, dependencyInsight, source inspection and decompilation established these origins:

| Play location | Original class | Artifact/version | Method | Reachability | Remediation |
|---|---|---|---|---|---|
| `D1.j.r` | `androidx.work.impl.utils.NetworkRequest28$$ExternalSyntheticApiModelOutline0.m` | `androidx.work:work-runtime:2.10.2` synthetic outline holder | `setNavigationBarDividerColor` | Sole call path came from Flutter `PlatformPlugin` | Remove color input and erase the side-effect-free compatibility write with R8 |
| `U1.g.d` | `io.flutter.plugin.platform.PlatformPlugin.setSystemChromeSystemUIOverlayStyle` after R8 horizontal merging | Flutter Android embedding 3.41.9 | `setStatusBarColor`, `setNavigationBarColor`, outlined divider call | Reachable through the Flutter platform channel and `onPostResume` | Stop sending bar colors from Dart; R8 removes the remaining embedding compatibility writes |
| `com.google.android.material.datepicker.o.H` | `MaterialDatePicker.onStart`, with `EdgeToEdgeUtils.applyEdgeToEdge` inlined | `com.google.android.material:material:1.7.0` | `setStatusBarColor`, `setNavigationBarColor` | Not called by ZEON but retained through Fragment reflection rules | Remove `dynamic_color:1.7.0`, the sole source of Material Components |

Machine-readable details: `out/edge-to-edge/play-api-origins.csv`.

Updating dependencies blindly was rejected: the newer inspected Flutter PlatformPlugin and Material EdgeToEdgeUtils sources still contained the same legacy setters. The production DEX, not a runtime API-level guard, is the release criterion.

## Own system-bar uses and edge-to-edge implementation

Stage 2.10 removed all Dart color ownership from `SystemUiOverlayStyle`. ZEON now supplies only icon brightness (`statusBarIconBrightness`, `statusBarBrightness`, `systemNavigationBarIconBrightness`). Flutter surfaces draw under transparent system bars.

There is one Android edge-to-edge authority:

- API 35+: Android/Flutter target-36 enforcement owns edge-to-edge.
- API 24–34: `MainActivity.onCreate` calls `WindowCompat.setDecorFitsSystemWindows(window, false)` once.
- No resume/reconnect/theme/VPN-state call repeats edge-to-edge setup.
- No `android:windowOptOutEdgeToEdgeEnforcement` exists.

Pre-35 XML themes retain transparent system-bar compatibility values. `values-v35` themes omit legacy bar-color attributes. Launch and normal themes share cutout-safe edge-to-edge behavior.

## Insets architecture

- The app root is not wrapped in a blanket SafeArea.
- The adaptive shell protects side/bottom interactive content while allowing backgrounds beneath system bars.
- Top app-bar controls use a top SafeArea; the decorative/header background may extend behind the status bar.
- NavigationBar uses `maintainBottomViewPadding` so controls remain above gesture/three-button areas without double padding.
- Modal bottom sheets use route-level `useSafeArea`.
- The custom toast removed a nested SafeArea because toastification already applies view padding and IME insets.
- Form and dialog keyboard handling remains based on `viewInsets`, without summing it blindly with both padding types.

Detailed matrix: `out/edge-to-edge/screen-insets-matrix.csv`.

## Material Date Picker remediation

ZEON source contains no native MaterialDatePicker use. `dynamic_color:1.7.0` was the only dependency that pulled `material:1.7.0`; removing it eliminated the entire Material artifact and the retained datepicker class. Post-change `dependencyInsight` reports no matching Material dependency.

## Stage 2.10.1 — main VPN button synchronization

### Root cause

The main button did not read `VpnSessionSnapshot`. It watched a secondary `AsyncValue<ConnectionStatus>`, used a local last-settled visual fallback, and selected callbacks from that projection while native Android lifecycle truth lived in the snapshot stream. This allowed native/text state to advance to CONNECTED while a stale UI branch still exposed START semantics/action.

### Fix

`MainVpnButtonState` is immutable and derives Android behavior only from the accepted authoritative snapshot fields: phase, generation, runtimeEpoch, requestedAction, recoverable and failureCode. One presentation object supplies label and semantics; the same state supplies visual mode, enabled state and callback action.

- `IDLE`, `DISCONNECTED`, recoverable `FAILED` → START.
- permission/start phases through `VERIFYING` → STOP/cancel; repeated START is impossible.
- `CONNECTED` → STOP and “Нажмите для отключения”.
- `STOP_REQUESTED`, `STOPPING` → disabled with “Отключение выполняется”.
- Failed authoritative resync is fail-closed: cached DISCONNECTED cannot start a new generation.
- A second authoritative read occurs after profile/notice dialogs, closing the asynchronous START race.
- Separate in-flight guards only deduplicate command dispatch; they never determine text, visual state, semantics or action. STOP can still supersede an older pending START.
- Disabled state now removes `InkWell.onTap`; previously an apparently disabled button could remain physically tappable.

`ZeonCoreService` republishes every accepted EventChannel or MethodChannel-resynced snapshot through a replaying authoritative stream. The existing app-resume resync therefore updates the button immediately after process/UI recreation, notification open, background return, theme/layout rebuild or sequence-gap recovery.

No native VPN core, TUN, DNS, routing, lifecycle snapshot structure, foreground service, notification synchronization, package name or signing configuration was changed by Stage 2.10.1. Four pre-existing concurrent native lifecycle edits remained in the working tree and are not attributed to this UI stage.

## Tests

### Flutter

- Targeted model/widget tests: 10/10 PASS.
- ConnectionNotifier tests: 20/20 PASS.
- Full suite: 262/262 PASS (Stage 2.10 baseline was 247/247).
- New deterministic coverage includes CONNECTED→STOP, CONNECTED semantics, exactly-one stop, no start while connected, stale event rejection, gap resync, resume resync, late START future, STOPPING lock, post-stop START, theme rebuild and 100 phase transitions.
- Targeted analyzer: no warnings or errors after the final cleanup.

### Native instrumentation

OnePlus GM1901/API 36 validation package: 77 tests, 0 failures, 0 errors, 0 skipped. Evidence: `out/edge-to-edge/stage2.10.1-native-instrumentation.xml`.

## Exact release artifacts and DEX scan

Stage 2.10.1 production artifacts were built with current production signing and `lib/main_prod.dart`:

- AAB: `out/edge-to-edge/release/zeon-stage2.10.1-production.aab`
- arm64 APK: `out/edge-to-edge/release/zeon-stage2.10.1-production-arm64.apk`
- universal APK: `out/edge-to-edge/release/zeon-stage2.10.1-production-universal.apk`
- AAB/APK mappings: `out/edge-to-edge/release/stage2.10.1-*-mapping.txt` (identical hashes)

Package/version: `com.zeon.hiddify`, `1.4.0+104001`, minSdk 24, targetSdk 36. APK signature v2 verifies with certificate SHA-256 `8c767dc4657bb13ccfee900b4b7cacc8f794027e6544650ef85d006bdc9f8ee7`.

The fail-closed scanner parsed DEX `method_ids` in the AAB, arm64 APK and universal APK: 3 artifacts, 6 DEX files, all forbidden references ABSENT. Evidence: `out/edge-to-edge/dex-api-scan-after-stage2.10.1.txt`.

Hashes are in `out/edge-to-edge/SHA256SUMS.txt`.

## Physical API 36 results

Exact Stage 2.10.1 arm64 production APK on OnePlus GM1901:

- Main button connect: 10/10 PASS.
- Main button stop: 10/10 PASS.
- Connect → background → reopen → stop: 10/10 PASS.
- Open from foreground notification → stop: 5/5 PASS.
- Native VPN state, CONNECTED snapshot, STOP semantics and notification Stop agreed in every successful cycle.
- Zero repeated START while CONNECTED.
- Zero “Подключено + кнопка подключения”.
- Zero “Отключено + кнопка остановки”.
- Zero “Сервис недоступен” after a STOP tap.
- Stop sequences contained `STOP_REQUESTED → STOPPING → DISCONNECTED`.
- Screen off/on → authoritative resync → main-button stop: 5/5 PASS. Every wake retained the real Android VPN connection, CONNECTED snapshot and “Нажмите для отключения”; every main-button tap ended in DISCONNECTED without a repeated START or service dialog.
- Gesture navigation exact-candidate recheck passed in light/dark, portrait/landscape, 130% font scale and 480-dpi enlarged display mode. Cutout top inset was 79 px and interactive content remained clear of it.
- IME recheck passed: the keyboard occupied `y=1354..2340`; the URL field and dialog actions remained above it (`y≤979`). The test edit was cancelled and the original URL was preserved.
- Splash was captured at 80/200 ms in light and dark with edge-to-edge coverage and no system-bar color strip.
- Gesture navigation was restored through the system overlay: `navigation_mode=2`, gestural enabled, three-button disabled. Theme mode, font scale, display density and rotation were restored to their initial values; VPN was left disconnected.

Evidence CSVs:

- `out/edge-to-edge/stage2.10.1-main-button-cycles.csv`
- `out/edge-to-edge/stage2.10.1-background-reopen-cycles.csv`
- `out/edge-to-edge/stage2.10.1-notification-open-cycles.csv`
- `out/edge-to-edge/stage2.10.1-screen-off-on-cycles.csv`

## Edge-to-edge screenshots

Stage 2.10 screenshots cover splash, gesture/three-button, light/dark and home/settings. Stage 2.10.1 adds exact-candidate connected/disconnected UIAutomator trees, notification evidence, gesture light/dark portrait screenshots, landscape, 130% font, enlarged display, IME and light/dark splash captures under `out/edge-to-edge/`.

The exact API 36 candidate passed three-button and gesture navigation, portrait and landscape, cutout and bottom inset, light and dark, splash, enlarged font/display and keyboard checks. API 34/35 hardware or emulator images were not available, so the original cross-version physical edge-to-edge verdict remains conditional even though the requested API 36 recheck is complete.

## Rollback

Rollback only Stage 2.10.1 UI changes:

1. Revert `MainVpnButtonState`, its providers, `connection_button.dart`, the new notifier handler and the snapshot replay bridge.
2. Revert the three new connection semantics keys in translation JSON files and regenerate Slang output.
3. Revert only the Stage 2.10.1 Flutter tests.
4. Do not revert or overwrite the four unrelated native lifecycle files that were already dirty during this work.
5. Rebuild signed AAB/APK and rerun the DEX method-id gate; never roll back the Stage 2.10 deprecated API removal or edge-to-edge themes.

## Verdict

```text
Edge-to-edge UI: CONDITIONAL PASS
Deprecated API removal: PASS
Main VPN button synchronization: PASS
VPN regression: PASS
Overall: CONDITIONAL PASS
```

The Stage 2.10.1 blocking regression is resolved: text, visual state, semantics and callback agreed with one current `VpnSessionSnapshot` throughout all completed matrices. Overall PASS is withheld only because the original Stage 2.10 acceptance criteria require physical API 35/36 coverage and API 35 remains unavailable; this does not change the API 36 UI/VPN PASS or exact DEX PASS.
