# ZEON VPN Stage 2: controlled sing-box v1.13.14 migration report

Date: 2026-07-29  
Branch: `stage2/sing-box-1.13.14-zeon.1`  
Core build source revision: `14b8022a7412c05faeee7eb3fc09843afa5e4446`  
Artifact manifest: `baselines/android-core/2026-07-29-stage2.json`

## 1. Executive summary

A reproducible ZEON core named `v1.13.14-zeon.1` was produced from the official SagerNet tag `v1.13.14` at commit `25a600db24f7680ad9806ce5427bd0ab8afe1114`. Hiddify compatibility, ZEON Smart Active/Round Robin/readiness/quality/speed/real-user-health/UDP-probe logic, and the Stage 1 selector interruption policy were manually retained. The working Android bridge was not rewritten.

The new AAR builds with the unchanged Go `1.25.6`, gomobile `v0.1.11`, NDK `28.2.13676358`, and the same production tags. It passes the provenance verifier, Flutter tests, Android JVM tests, release build, and the complete `13/13` instrumented suite on OnePlus GM1901. The immutable Stage 1 rollback artifacts still pass the verifier, and the current bridge also compiles against the Stage 1 AAR.

This report does **not** claim that v1.13.14 fixes the observed data-plane disconnects or that Stage 2 is ready for production promotion. Long-lived Telegram, Speedtest, video, UDP/QUIC, failure injection, and 6–12 hour A/B runs have not been performed. Promotion is gated on the A/B plan in section 17.

No physical-network recovery, DNS policy, MTU policy, selector policy, profile/subscription format, server API, supported protocol set, Go, gomobile, NDK, Gradle, AGP, Kotlin, or JDK migration was included.

## 2. Verified Stage 1 provenance

| Item | Verified value | Evidence |
| --- | --- | --- |
| Baseline source | `51d6c5156431f46fc56a4b79f5571a1771ca6caf` | user gate; audit history |
| Stage 1 implementation | `f6650c782c72d7e7260827b2f8f1eb9d3d95cd76` | `2026-07-29-stage2-source.json` |
| Stage 1 core revision | `31c5987477d3cd02a099c2c0c01c3a07da05ce69` | embedded metadata and Stage 1 manifest |
| Stage 1 sing-box tree | `70dc263d60846a4fc66f357b7b227941d4d54d2c` | `2026-07-28-stage1.json` |
| Stage 1 AAR | `04453FE46DDEC27DB8A4B9F859FB084D19D5F9121E709D3457BD52BABD8359E5` | verifier passed again after Stage 2 |
| Stage 1 APK | `2FA51176B2A7536C66FA73403D0ADAB15756FDC0B602813F4D6DC34DF7A55AAF` | verifier passed again after Stage 2 |
| Pre-Stage-1 rollback AAR | `7A94C004286875410D70D8CECF07D8813DAB33D27F7D76A23C7ABA3460E37600` | baseline manifest/audit |

The source manifest was committed before migration as `f886ca56bda3479b50dd4add7976c0901a236521`. The pre-existing untracked `android/app/src/main/assets/adi-registration.properties` was neither read into migration fixtures nor modified, staged, or committed.

## 3. Verified official upstream

The external clone at `B:\1CODING\zeon-stage2-sing-box-20260729` had origin `https://github.com/SagerNet/sing-box.git`. A forced tag fetch followed by `git rev-parse 'v1.13.14^{commit}'` returned exactly:

```text
25a600db24f7680ad9806ce5427bd0ab8afe1114
```

Its tree is `ebe928ddfdf2273bc2ab7e0cba818db315cd6151`, and the external worktree was clean. This check preceded source replacement. No ZapretKVN or sing-box-extended patch was imported.

## 4. Provenance graph

```text
SagerNet/sing-box v1.13.14
25a600db24f7680ad9806ce5427bd0ab8afe1114
        |
        +-- Layer B: proven Hiddify compatibility
        |   module/config/libbox/protocol/replacement integration
        |
        +-- Layer C: ZEON feature layer
        |   Round Robin + Smart Active + readiness + telemetry + UDP probe
        |
        +-- Layer D: Stage 1 invariants
            selector interruption policy + emergency evidence + generation

ZEON build source: 14b8022a7412c05faeee7eb3fc09843afa5e4446
hiddify-core tree: c917889df67c1604b5e5bb82e70be7958d8ddc1b
hiddify-sing-box tree: 4381c26b40cd6be38845fe597bb9285fbc0999d6
```

The exhaustive patch table is in `docs/ZEON_SING_BOX_1_13_14_PORT_INVENTORY.md`. Its pre-AAR stop-gate section is intentionally historical; the final gate status is in this report.

## 5. Patch inventory by layer

### Layer A — exact upstream

The imported base is the official tree above. No merge of the entire Stage 1 fork was accepted with `ours`/`theirs` semantics.

### Layer B — Hiddify compatibility

| Patch | Source/evidence | Files/functions | Port decision | Test/evidence |
| --- | --- | --- | --- | --- |
| module and replacement graph | Hiddify `0a02b7729f6a211436bb8bdcd8696c283eb27767` | `hiddify-core/go.mod`; `hiddify-sing-box/go.mod`; `replace/*` | official 1.13.14 shared requirements plus existing Hiddify replacements | `go mod tidy`, AAR build |
| libbox context/command API | Hiddify fork plus upstream | `experimental/libbox/config.go`, `command_*`, `service.go` | combined Hiddify API with upstream lifecycle | gomobile build, javap diff |
| legacy WireGuard/WARP | Hiddify | `include/wireguard.go`; `protocol/wireguard`; `option/wireguard.go`; cachefile | retained legacy profile contract; adapted current readiness API | config fixture, Android build |
| Hiddify protocols | Hiddify | `protocol/hiddify`, Mieru, Psiphon, AWG, Tor | preserved registration; adapted removed fields/call signatures | package compile/AAR |
| Tailscale protect hook | upstream dependency commit `60874ec011f1fc5b6950e89e197382d24f253613` | `replace/tailscale/net/netns/netns.go` | exact minimal `SetControlFunc` backport; local fork not replaced | Android AAR compile |
| DNS diagnostics/dnscrypt | Hiddify | `dns/transport/udp.go`, module replaces | logger API adaptation only; DNS policy unchanged | DNS packages and config fixture |

### Layer C — ZEON features

| Feature | Files/functions | Preserved semantics | Risk/test |
| --- | --- | --- | --- |
| Round Robin | `protocol/group/balancer/*`; option/constant types | deterministic strategy and existing names | balancer tests passed |
| Smart Active | `protocol/group/balancer/smart_active.go:113`; `balancer.go:197` | full-generation readiness, score/state model, no partial/stale selection | high; balancer/monitor tests passed |
| URLTest readiness | `common/urltest/*`; `adapter/urltest.go` | check generation, ping/combined readiness retained | URLTest tests passed |
| quality/speed | URLTest/monitoring/libbox command types | multi-signal histories retained | monitoring tests passed |
| real-user health | `route/conn.go:96-433` | telemetry wraps upstream copy/handshake semantics | compile/unit passed; device data-plane pending |
| UDP probe | Smart Active probe files | probe cannot itself authorize user UDP interruption | unit passed; QUIC A/B pending |
| generation | `balancer.go:197-239`; `selector.go:132-185` | stale session/update ignored | Go and Android generation tests |
| dynamic MTU | Hiddify builder and Android caller | policy unchanged; cellular fixture remains 1380 | corpus and 13/13 instrumentation |

### Layer D — Stage 1 fixes

| Invariant | Evidence after port |
| --- | --- |
| manual selector preserves external sessions | `selector.go:132-168` calls `Interrupt(false)`; selector tests |
| regular/preventive Smart switch preserves sessions | `balancer.go:233-239`; `switch_policy.go:19-52` |
| emergency needs fresh outbound-specific evidence | `switch_policy.go:46-75`; timeout/DNS/QUIC/UDP exclusions at line 55 |
| stale generation cannot switch | `selector.go:134-135`; `balancer.go:200-201` |
| interruption counters remain | `common/interrupt/group.go:54-67` |
| Stage 1 Android lifecycle/protect/TUN ownership | unchanged Android sources; Flutter 126/126, JVM tests, GM1901 13/13 |
| provenance hooks | `platform/mobile/build_metadata.go:24`; rebuild/verifier scripts |

## 6. Upstream impact report: 1.13.0 to 1.13.14

| Upstream commit | Area/file | Before → after | ZEON intersection / action |
| --- | --- | --- | --- |
| `72a8723e` | DNS connection pool | duplicate/deadlock risk → serialized dedup | retained upstream pool; combined Hiddify validation once |
| `d166f0da` | DNS pool | leaked connection path → close on failure | retained; no duplicate backport |
| `6548c171` | DNS deadline | incomplete deadline propagation → bounded calls | retained; DNS policy unchanged |
| `27c5b0b1` | DNS recursion | recursive deadlock path → guarded resolution | retained |
| `55ec8abf` | Android local DNS | stale/local behavior fixes | retained transport implementation; no policy copy from another app |
| `9b72b352`, `8947cb24` | UoT | concurrent lifecycle races → synchronized state | retained |
| `8f006316` | mux UDP | faulty write behavior → corrected packet write | retained |
| `4e1af060` | UDP sniff | fragmented packet handling fixed | retained |
| `627912a7` | QUIC | ALPN race → synchronized configuration | retained; ZEON probe remains separate |
| `84d22809` | QUIC/Hysteria | incomplete close paths → explicit close | retained |
| `0b7ffbaa` | TUN/UDP NAT | mapping collision → collision-safe ownership | retained |
| `e98b4ad` | WireGuard | shutdown leak/order issue → corrected close | retained while preserving legacy outbound |
| `ea464cef` | libbox daemon | stale instance could survive → explicit stale close | combined with bounded Hiddify close |

Other structural impacts include the session-owned `adapter.ConnectionManager`, current route-rule matching/serialization, new multi-package Android owner API, and additive FDroid/HTTP/semver libbox methods. No upstream fix was deliberately reapplied twice.

## 7. Conflict register and selected semantics

| Conflict | Both meanings | Selected resolution and proof |
| --- | --- | --- |
| connection tracking | old global Hiddify conntrack vs upstream per-core manager | upstream is sole owner; ZEON reads `ConnectionManager.Count()` (`route/conn.go:32-85`), avoiding double wrap |
| close lifecycle | Hiddify bounded close vs upstream stage logging/stale close | retained bounded close plus upstream stages (`box.go`, `daemon/instance.go`) |
| DNS response validation | Hiddify filtering/logging vs upstream address limit | both execute in one validation path (`dns/router.go`) |
| route copy | new upstream copy/handshake close vs ZEON health telemetry | upstream copy remains; telemetry wraps outcomes (`route/conn.go:278-433`) |
| WireGuard readiness | upstream atomic readiness vs ZEON probe confirmation | atomic state retained; ready is published only under existing probe condition |
| libbox Android owner | upstream iterator replaces scalar used by Stage 1 Kotlin | additive compatibility shim preserves scalar and synchronizes iterator (`platform.go:27-51`) |
| Tailscale socket control | new endpoint calls absent replacement API | ported only atomic control hook; replacement history otherwise untouched |
| removed legacy WG deprecation constants | official removed outbound vs Hiddify profile support | retained Hiddify outbound without references to removed constants |

## 8. Replacement graph before/after

No replacement module version was updated for freshness. The graph identity is preserved; official shared dependency requirements moved to the versions required by 1.13.14.

| Module | Stage 1 → Stage 2 replacement | Change/API/license/test |
| --- | --- | --- |
| sing-box | local fork → local fork, module version `1.13.0` → `1.13.14` | migration target; GPL; full AAR/config tests |
| sing-dns | `shtorm-7/sing-dns v0.4.6-extended-1.0.0` → same | no replacement change; GPL; DNS compile/tests |
| dnscrypt/v2 | `shtorm-7/dnscrypt/v2 v2.4.0-extended-1.0.0` → same | no change; public-domain license text; config/AAR compile |
| wireguard-go | local `replace/wireguard-go` → same | API adapted by core, module not replaced; MIT; build/config |
| Tailscale | local `replace/tailscale`, requirement `v1.92.4-sing-box-1.13-mod.7` | only 21-line socket-control API backport; BSD-3-Clause; Android compile |
| Psiphon QUIC | local replacement, requirement `79fe45fb83b1` → same | unchanged; MIT; Android compile; Windows host constraints noted |
| Psiphon TLS | local replacement, requirement `2a2fae2db378` → same | unchanged BSD-derived license; Windows/Go 1.25 init guard remains |
| warp-plus | `hiddify/warp-plus@4f3122e0d11d` → same | unchanged; MIT; Android compile |
| ray2sing | local `./ray2sing` → same | unchanged; CC0; parent compile |

The complete machine-readable graph is stored in the Stage 2 manifest.

## 9. Stage 2 commits

| Commit | Purpose / independent revert boundary |
| --- | --- |
| `f886ca56bda3479b50dd4add7976c0901a236521` | verified source manifest |
| `842287fd76d1b00e4ddc3cb789ee327c84affad0` | four-layer inventory and semantic conflict register |
| `b645b57f5340b42c1b6b77d2e7c60c4d6e941549` | upstream 1.13.14 and Hiddify compatibility layer |
| `97ac497da0832c151f5cd7a3978949a3c19e90ea` | ZEON selection and real-user health adaptation |
| `ffb3d116e4df3abedca638638e28340b46631f71` | minimal Tailscale control hook |
| `d76ac8f4dff0f5737c08c019e12c9cdff774d541` | parent hiddify-core API/module adaptation |
| `1cff012889a8e4e3bdc26dcf0c3fac46c98f6e5c` | anonymized compatibility corpus |
| `c390890273c73c70c894212a31694b5000ea2599` | reproducible metadata and verifier extension |
| `14b8022a7412c05faeee7eb3fc09843afa5e4446` | additive Stage 1 libbox API shim |
| `d9bbac77c4bf9534233f713e55fb6111c6321f6e` | immutable Stage 2 artifact manifest |

The large base port is isolated from ZEON feature, replacement, parent API, compatibility shim, tests, and provenance commits. Within the base port, conflicts were resolved manually in a clean candidate; no unconditional mega-merge was used.

## 10. AAR API/ABI diff

| Check | Stage 1 | Stage 2 | Result |
| --- | ---: | ---: | --- |
| AAR SHA | `04453F…9E5` | `EFB8EB…B222` | expected change |
| classes.jar SHA | `00BE8E…1240` | `959C71…7B58` | expected generated API change |
| classes entries | 96 | 105 | 9 additive classes |
| removed Java public signatures | — | 0 | compatible |
| added public signature lines | — | 9 | additive |
| removed JNI/proxy symbols | — | 0 | compatible |
| native library name | `libhiddify-core.so` | same | compatible |
| AAR ABI | arm64, armv7, x86, x86_64 | same | compatible |
| ELF SONAME | absent | absent | unchanged |

New Java classes are FDroid mirror/iterator/update types, ping result/iterator, HTTP progress handler, and proxy helper classes. Existing `ConnectionOwner.androidPackageName` and `ProcessInfo.packageName` were initially absent in generated 1.13.14 API; commit `14b8022a` restored them additively while retaining the new iterator APIs. The unchanged bridge then compiled against both Stage 1 and Stage 2 AARs.

Native AAR sizes increased from 69,009,224/62,677,000/67,027,352/73,398,000 bytes to 70,246,672/63,270,896/68,229,596/74,922,128 bytes for arm64/armv7/x86/x86_64. The raw dynamic table changes include cgo-generated symbols with content hashes, but no removed `Java_*`, `proxylibbox*`, or `proxy_class*` symbol.

## 11. Config compatibility results

The committed synthetic corpus is `hiddify-core/v2/config/stage2_config_corpus_test.go:14-122`. It contains documentation-only IPs and synthetic credentials; no user profile was stored.

Passed assertions cover VLESS, VMess, Trojan, Shadowsocks, Hysteria2/QUIC, legacy WireGuard, AmneziaWG endpoint, single and multi-server membership, selector, URLTest, Round Robin, Smart Active, custom/global-final routing, DNS cache/final policy, dual-stack route material, UDP/QUIC-capable protocols, retained credential markers, JSON round trip, `CheckConfig`, final outbound, selector membership, and cellular dynamic MTU `1380`. Stage 1 interruption flags are explicitly asserted.

The corpus is a structural/semantic Stage 2 round-trip and builder gate. It is not a byte-for-byte export of real profiles and does not store unknown secrets. A separate executable Stage 1-vs-Stage 2 effective-config snapshot was not produced because the unchanged Psiphon TLS replacement panics in a Windows host test process under Go 1.25.6 (section 12). Therefore production promotion remains gated; any real profile rejected by Stage 2 is a stop condition.

## 12. Go test results

| Command/scope | Result | Classification |
| --- | --- | --- |
| config corpus (`TestStage2*`) | passed | migration gate |
| `protocol/group`, `protocol/group/balancer` | passed | selector, Round Robin, Smart Active, policy |
| `common/interrupt`, `common/urltest`, `common/monitoring` | passed | Stage 1/ZEON behavior |
| `route/rule`, DNS local, protocol/transport compile | passed | core regression |
| `go test ./...` in sing-box | most packages passed/compiled; two failures below | partial suite |
| `dns/transport/hosts.TestHosts` | empty hosts result | environment/upstream: identical failure on pristine official v1.13.14 |
| `experimental/libbox` | init panic in local Psiphon TLS `unsafe.go:44` | pre-existing replacement/toolchain host limitation; file unchanged from Stage 1 |
| `go test ./...` in hiddify-core | same Psiphon init panic; old `fmt` vet diagnostics in tunnel service | pre-existing/host limitation |
| production tags on Windows | `with_naive_outbound` requires Cronet package unavailable for Windows host | platform-specific; Android AAR passed |
| `go test -race` | unavailable: `gcc` absent and race requires cgo | environment limitation |

The first parallel test attempt also exhausted `C:\Temp`; it was discarded as environment failure. Only completed `go-build*` directories and Go build cache were removed, then tests were rerun with temporary/cache directories on drive B. No repository or user data was deleted.

The Psiphon limitation was not silently “fixed” by updating a replacement, because it is unchanged from Stage 1 and the task forbids unrelated replacement/toolchain migration. It remains a specific follow-up risk.

## 13. Flutter and Android results

| Test/build | Result |
| --- | --- |
| `flutter test` | passed, `126/126` |
| targeted `flutter analyze lib/zeoncore test/zeoncore` | exit 1: 194 existing warning/info findings, predominantly generated protobuf style; no migration compile error |
| `:app:testDebugUnitTest` | passed |
| `:app:assembleDebugAndroidTest` | passed |
| initial combined debug package | transient `PackageAndroidArtifact` failure without root exception |
| repeated `:app:packageDebug --stacktrace` | passed |
| `:app:connectedDebugAndroidTest` | passed on OnePlus GM1901 (Gradle device label `GM1901 - 16`): `13/13`, 0 skipped, 0 failed |
| `flutter build apk --release` | passed; 303.2 MB reported by Flutter |
| Stage 1 AAR bridge compile | passed with `--rerun-tasks`; Stage 2 AAR restored in `finally` and SHA verified |
| Stage 1 rollback verifier | passed |
| Stage 2 verifier | passed |

The instrumented suite covers Stage 1 generation, startup/stop/restart gating, TUN/PFD ownership cycles, idempotent teardown, protect failure/config guard, and selector policy assertions implemented by Stage 1. It does not constitute a 6–12 hour real traffic test.

## 14. New artifact hashes

```text
Stage 2 AAR
EFB8EB73D0AE2878667A3B4E7A58E0D95E5FBA1FD37ABE045CB13642805EB222

Stage 2 release APK
A1833DD86C0F4865496E24DABE3C0CADBC45FD6E343E72B65D9408C80CEC836A
```

Immutable paths:

```text
out/stabilization/14b8022a7412c05faeee7eb3fc09843afa5e4446/hiddify-core.aar
out/stabilization/14b8022a7412c05faeee7eb3fc09843afa5e4446/zeon-1.3.0-stage2-release.apk
```

The manifest contains raw and post-strip per-ABI hashes. An AAR cannot cryptographically embed its own final SHA without a circular self-hash; therefore its SHA is stored in the immutable external manifest and checked by `verify_android_core.ps1`.

## 15. Embedded metadata

All four AAR native libraries were scanned and verified to contain:

```text
upstream version: v1.13.14
upstream commit: 25a600db24f7680ad9806ce5427bd0ab8afe1114
ZEON/core build revision: 14b8022a7412c05faeee7eb3fc09843afa5e4446
hiddify-core tree / compatibility revision: c917889df67c1604b5e5bb82e70be7958d8ddc1b
hiddify-sing-box tree / ZEON patch revision: 4381c26b40cd6be38845fe597bb9285fbc0999d6
Go: go1.25.6
gomobile: v0.1.11
NDK: 28.2.13676358
dirty for core build: false
timestamp policy: SOURCE_DATE_EPOCH=0
build ID policy: empty
```

Runtime sing-box version is `1.13.14-zeon.1-14b8022a7412c05faeee7eb3fc09843afa5e4446`. The root worktree remains dirty only because of the excluded pre-existing user asset; the core build source itself was clean.

## 16. Device/data-plane tests not executed

The device was available for automated instrumentation, but the following require controlled profiles, servers, traffic generators, durations, and user authorization and were not run automatically:

- 50–100 real VPN start/stop and 20 real full-core restart cycles while forwarding traffic;
- manual/Smart/emergency selector switch during sustained TCP download;
- Telegram long-lived connection, Speedtest completion, streaming video;
- UDP flow and QUIC/HTTP3 continuity across selector switch;
- IPv4-only and dual-stack real networks, DNS bursts, screen-off/Doze;
- server failure, DNS failure, and core failure injection;
- 6–12 hour soak with fd/goroutine/RSS tracking;
- Wi-Fi/mobile handover measurement (recovery policy intentionally not added).

No claim about disconnect reduction can be made until these are A/B tested.

## 17. A/B commands and assertions

Use immutable Stage 1 and Stage 2 AAR/APK pairs. Do not uninstall the app.

Artifact verification:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify_android_core.ps1 `
  -ManifestPath baselines/android-core/2026-07-28-stage1.json `
  -AarPath out/stabilization/31c5987477d3cd02a099c2c0c01c3a07da05ce69/hiddify-core.aar `
  -ApkPath out/stabilization/31c5987477d3cd02a099c2c0c01c3a07da05ce69/zeon-1.3.0+103001-stage1-release.apk

powershell -ExecutionPolicy Bypass -File scripts/verify_android_core.ps1 `
  -ManifestPath baselines/android-core/2026-07-29-stage2.json `
  -AarPath out/stabilization/14b8022a7412c05faeee7eb3fc09843afa5e4446/hiddify-core.aar `
  -ApkPath out/stabilization/14b8022a7412c05faeee7eb3fc09843afa5e4446/zeon-1.3.0-stage2-release.apk
```

Install-over-existing-data commands, one variant at a time:

```powershell
adb install -r -d <immutable-stage1-or-stage2-apk>
adb logcat -c
adb shell dumpsys package com.zeon.zeon | Select-String version
adb shell dumpsys meminfo com.zeon.zeon
adb shell ls /proc/$(adb shell pidof com.zeon.zeon)/fd | Measure-Object
```

For every scenario keep identical device, OS, network, server, profile, routing, MTU, IPv6 mode, test payload, and duration. Record session generation, selector reason/policy, core metadata, command readiness, TUN identity, protect results, terminal state, RSS/fd/goroutine indicators, transferred bytes, completion time, and disconnect count. Server/DNS/physical/core failure must be labeled separately.

Pass assertions:

1. no stale generation changes state or selector;
2. no `ALREADY_STARTED` is accepted as success;
3. exactly one successful TUN open per generation and no fd growth trend;
4. manual/regular/better-score switch records `interrupt_external=false` and continues established flows;
5. emergency external interruption occurs only with fresh current-outbound connection evidence;
6. profile membership/final/DNS/routing/MTU remain equal;
7. no panic, native crash, ANR, command-channel orphan, or connected-with-dead-core state;
8. Stage 2 must be statistically no worse than Stage 1 before promotion.

## 18. Rollback instructions

Do not use `git reset --hard` and do not uninstall the app.

```powershell
Copy-Item -LiteralPath `
  out/stabilization/31c5987477d3cd02a099c2c0c01c3a07da05ce69/hiddify-core.aar `
  -Destination android/app/libs/hiddify-core.aar -Force

Push-Location android
.\gradlew.bat :app:assembleDebug --no-daemon
Pop-Location

flutter build apk --release

powershell -ExecutionPolicy Bypass -File scripts/verify_android_core.ps1 `
  -ManifestPath baselines/android-core/2026-07-28-stage1.json `
  -AarPath android/app/libs/hiddify-core.aar `
  -ApkPath out/stabilization/31c5987477d3cd02a099c2c0c01c3a07da05ce69/zeon-1.3.0+103001-stage1-release.apk
```

Generated bindings were not checked into the Android bridge; the Stage 1 scalar API is preserved by Stage 2, so rollback needs only the AAR plus rebuild. To return to Stage 2, copy its immutable AAR back and verify with the Stage 2 manifest. The rollback compile and verifier were exercised during this stage.

## 19. Remaining risks and stop gates

1. Real data-plane A/B is incomplete; Stage 2 is built and regression-tested but not production-promoted.
2. The local Psiphon TLS replacement has an existing `ConnectionState` unsafe-layout guard that panics in Windows host tests with Go 1.25.6. Android runtime coverage for an actual Psiphon profile is required; replacement/toolchain changes need a separate decision.
3. The full race suite could not run because the Windows environment lacks `gcc`; run it in an approved fixed-toolchain CI image before promotion.
4. Official `dns/transport/hosts.TestHosts` fails on this host and on pristine v1.13.14; this is not evidence of a ZEON regression, but Windows hosts resolution should remain in CI coverage.
5. The config corpus is anonymized structural coverage, not an execution of every production profile. Run read-only config generation/diff over locally held profiles without committing outputs.
6. Native size increased by roughly 0.6–1.5 MB per ABI; long soak must verify RSS/goroutine/fd stability.
7. The first combined Gradle debug packaging attempt failed transiently; two subsequent package paths and connected tests passed, but CI reproducibility should repeat from a clean runner.
8. `with_conntrack` remains in the tag list for exact build compatibility although 1.13.14 uses `adapter.ConnectionManager`; removing the inert tag is outside this migration.

Any Stage 1 invariant failure, config semantic change, ABI loss, new panic/race/deadlock, resource growth, or failed rollback remains a hard stop.

## 20. Scope confirmation

- Official base moved only from sing-box `v1.13.0` to stable `v1.13.14`.
- Hiddify and ZEON functionality was retained through explicit compatibility layers; sing-box-extended was not used.
- Stage 1 lifecycle, TUN/PFD ownership, protect failure/probe/guard, generation diagnostics, and selector interruption policy were not reverted.
- Physical-network recovery was not implemented.
- DNS policy, routing policy, profile/subscription format, server API, supported protocols, and dynamic MTU policy were not changed intentionally.
- Go, gomobile, NDK, Gradle, AGP, Kotlin, and JDK versions were not upgraded.
- The pre-existing `adi-registration.properties` was not modified or committed.

The controlled port and rollback artifacts are ready for A/B validation. Production rollout remains blocked until section 16 scenarios satisfy section 17 assertions.
