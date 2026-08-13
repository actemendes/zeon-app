# ZEON VPN Stage 2.4 — data-plane stabilization

Date: 2026-07-30
Branch: `stage2.4/data-plane-stabilization`
Device: OnePlus GM1901, Android 16 / API 36, ADB `18bfc103`
Production package: `com.zeon.hiddify`

## 1. Executive summary

Stage 2.4 does not migrate or rebuild the core. The production AAR is
byte-identical to Stage 2.3:

```text
5BEC09E8AA72E385C0BB4950FE9970759725C6083F813E6DAB7BBFE436BECB00
```

Two Android-side changes were made:

1. instrumented validation was isolated in
   `com.zeon.hiddify.validation`; Gradle cannot create
   `connectedDebugAndroidTest` for the production package;
2. notification and VPN permissions are now one serialized operation owned
   by one VPN generation. Notification permission is requested first, then
   VPN consent, then the service is launched exactly once.

The previous HTTPS 14/20 result was not reproduced by the controlled
Stage 2.3 transport probe: 30/30 HTTPS in one VPN session and 30/30
connect/HTTPS/stop passed. A separate failure of the first validation probe
was reproduced both with and without VPN and localized to Android killing
sockets of a background/cached test UID while its blank activity was hidden
behind the secure keyguard. Keeping the validation activity visible removed
the artifact: direct parallel upload passed 20/20. This is evidence against
changing ZEON DNS, MTU, mux or core without a production-path reproduction.

Controlled Stage 2.3 HTTP/3 validation succeeded with `protocol=h3`,
HTTP 200 and transferred bytes through an active validated VPN. This closes
the earlier undifferentiated `NetworkException error_code=1`, whose symbolic
stage was hostname resolution.

The final Stage 2.4 physical run is recorded in the sections below. No
result is promoted to PASS merely because the APK compiled or the UI showed
Connected.

## 2. Scope and invariants

Unchanged:

- sing-box `1.13.14-zeon.1`;
- upstream commit `25a600db24f7680ad9806ce5427bd0ab8afe1114`;
- core source revision
  `e8c06439e1864255d81f4ee89290d89cbb1b3a18`;
- Hiddify compatibility and ZEON core patch trees;
- Smart Active ranking and readiness;
- Round Robin distribution;
- mode-change rule: only while VPN is stopped;
- selector interruption policy;
- DNS, routing, MTU, IPv6 and UDP probe policy;
- profile/subscription formats and protocol implementations.

The Stage 2.3 resource and immutable `URLTestHistory` fixes remain present in
the unchanged AAR.

## 3. Protection of production application data

### 3.1 Root cause

The old `connectedDebugAndroidTest` targeted `com.zeon.hiddify`.
Android Gradle Plugin's managed test cleanup is allowed to uninstall its
target, so user data was deleted even though no explicit `adb uninstall`
command had been issued.

### 3.2 Fix

Commit `79034ed8`:

- `android/app/build.gradle`
  - adds the `validation` build type derived from debug;
  - adds `applicationIdSuffix ".validation"`;
  - sets `testBuildType "validation"`;
  - refuses managed Android-test tasks whose target is not validation;
- `VpnTestInstrumentation` refuses to run if its target context is
  `com.zeon.hiddify`;
- the safe target is `com.zeon.hiddify.validation`;
- the test APK is `com.zeon.hiddify.validation.test`.

Proof:

- `:app:connectedDebugAndroidTest --dry-run` is rejected because no such
  production-target task exists;
- `:app:assembleValidationAndroidTest` succeeds;
- direct `am instrument` ran 37 tests in the validation package;
- production `firstInstallTime`, `lastUpdateTime`, version and package
  remained byte-for-byte identical before/after the isolated suite;
- no `adb uninstall` and no `pm clear` were executed.

The phone still contains legacy test packages from earlier stages. They were
not invoked or removed in Stage 2.4. Their mere presence is not treated as
safe; the new build/test guard prevents their Gradle flow from being used.

## 4. First-install permission orchestration

### 4.1 Root cause

Before Stage 2.4 the flow was split:

```text
Flutter prepareVpnConfiguration
  -> MainActivity.prepareVpn
  -> Android VPN consent

Flutter setupBackground / MethodHandler.Start
  -> MainActivity.startService
  -> notification permission
  -> second VPN prepare check
  -> service/core start
```

Thus the second system dialog was introduced after the first asynchronous
operation had already progressed. Permission ownership, the pending start
future and the core startup timeout were not one state machine. The first
attempt could finish without core start; a retry could then inherit the
timeout window.

### 4.2 Fix

Commit `6b25acb3`:

- new `StartPermissionRequestCoordinator`;
- one request owns `generation`, `startAfterGrant` and completion;
- deterministic order: notification permission, then VPN permission;
- each callback re-evaluates actual permission state;
- only the current generation may launch the service;
- service launch is once-per-generation;
- duplicate callbacks are idempotent;
- replacement by a newer generation completes the older request as stale;
- activity destruction cancels pending permission ownership;
- denial is a terminal permission outcome, not a synthetic success;
- stale completion is diagnostic only and cannot launch or alert the current
  session.

Relevant files/functions:

- `android/app/src/main/kotlin/com/zeon/zeon/MainActivity.kt`
  - `startService()`
  - `prepareVpn()`
  - `requestStartPermissions()`
  - `executePermissionAction()`
  - `startServiceAfterPermissions()`
- `android/app/src/main/kotlin/com/zeon/zeon/MethodHandler.kt`
  - preparation result mapping;
- `android/app/src/main/kotlin/com/zeon/zeon/bg/StartPermissionRequestCoordinator.kt`
  - `begin()`
  - `completeNotification()`
  - `completeVpn()`
  - `cancelAll()`.

### 4.3 Deterministic tests

The 12 added cases cover:

1. both permissions missing;
2. notification granted then VPN granted;
3. VPN already granted, notification pending;
4. notification denied;
5. VPN denied;
6. dialog closed;
7. delayed callbacks using a barrier;
8. duplicate callback;
9. stop/cancel while dialog is pending;
10. activity/process recreation;
11. stale result after a newer generation;
12. successful first start without a second begin/click.

Together with the Stage 1/2.1 lifecycle tests, the isolated suite result is:

```text
Ran 37 VPN instrumentation tests; failures=0
```

The descriptor ownership stress uses one complete 100-cycle warm-up batch
and a second identical measured batch. This avoids counting ART/logcat
process-wide lazy descriptors while still requiring every created PFD to be
invalid after close and rejecting growth in the repeated batch. There is no
sleep or production lifecycle change.

### 4.4 Physical first-install result

The final physical permission sequence is recorded here after resetting only
`POST_NOTIFICATIONS` and Android VPN consent. Application data is not reset.

```text
PASS
```

Physical sequence on OnePlus GM1901:

```text
one Connect at 2026-07-30 13:11:56 local
-> notification permission granted
-> Android VPN consent granted
-> generation 1785406313224635
-> command_endpoint_ready
-> start_gate_waiting
-> protect_result success=true
-> tun_open_success identity=tun-1
-> start_gate_completed reason=all_required_evidence
-> core_start_success
-> Android VPN VALIDATED
-> controlled HTTPS status=200, bytes=65536
```

Only one `vpn_session_start` and one `core_start_success` occurred for this
generation. There was no duplicate start, timeout, stale user-visible error
or false Connected interval. No second Connect tap was made. After Stop the
VPN NetworkAgent and session-owned service state were absent. Evidence:
`device-final/permission-flow/lifecycle-redacted.txt`,
`readiness.txt`, `https-evidence.txt` and `cleanup.txt`.

## 5. HTTPS 14/20 investigation

### 5.1 Improved probe

`DataPlaneValidationActivity` is validation-only and allowlists a public
Cloudflare measurement endpoint. It records:

- run/cycle/scenario correlation;
- active network handle and VPN/Wi-Fi/cellular/validated flags;
- DNS duration, address-family counts and one-way address fingerprints;
- TCP/TLS/HTTP start;
- status, cipher, first-byte/total duration and transferred bytes;
- exception class and sanitized reason.

It cannot accept an arbitrary URL, endpoint or credential.

### 5.2 Reproduction results before the Stage 2.4 APK

Using the exact Stage 2.3 production core:

| Scenario | Result |
|---|---:|
| Same VPN session, HTTPS 64 KiB | 30/30 |
| Connect → validated VPN → HTTPS → stop | 30/30 |
| Sequential download, 10 MiB | 5/5 |
| Sequential upload, 10 MiB | 5/5 |
| Parallel download, 20 × 5 MiB, concurrency 4 | 20/20 |
| Direct parallel upload after foreground fix | 20/20 |

All 30 lifecycle cycles showed core start, post-TUN protect success and
cleanup. No permanent configuration defect was present.

### 5.3 Validation-harness artifact

The initial parallel upload probe failed after several successes both direct
and through VPN. The test Activity had no visible content and sat behind a
secure keyguard. Android moved the UID to a cached/background state and netd
destroyed that UID's live sockets. This accounts for the same clustered
abort/timeout/DNS pattern outside ZEON.

Commit `b3e528be` makes the validation-only Activity:

- visible over keyguard;
- turn the screen on;
- keep the screen on during the bounded probe.

With that control, direct parallel upload passed 20/20. These flags are not
present in the production application path.

### 5.4 Stage 2.4 exact-production result

Two independent foreground validation series passed:

| Series | Core start | Validated VPN/TUN | HTTPS 64 KiB | Cleanup |
|---|---:|---:|---:|---:|
| A | 20/20 | 20/20 | 20/20 | 20/20 |
| B | 20/20 | 20/20 | 20/20 | 20/20 |

All 40 probes returned HTTP 200 and exactly 65,536 response bytes. Every
cycle used a new monotonic generation. No false Connected, stale dialog or
terminal failure was observed. Series A generations ended at
`1785406313224675`; series B ended at `1785406313224715`.

The former 14/20 failure therefore did not reproduce on the immutable
Stage 2.4 production APK when the validation Activity remained visible and
the screen remained unlocked. The evidence supports the previously
localized validation-UID/keyguard artifact; it does not support changing
production DNS, MTU, mux, IPv6 or core behavior.

Evidence:
`device-final/https-series-A/summary.tsv` and
`device-final/https-series-B/summary.tsv`.

No DNS/MTU/mux/IPv6/monitoring production change is justified unless the
controlled foreground probe fails on the immutable Stage 2.4 APK.

## 6. Speedtest

The Stage 2.3 browser symptom was real at the UI level:

- direct Cloudflare/Fast passed;
- through VPN Cloudflare/Fast closed;
- three outbounds from one subscription behaved the same.

However, controlled Stage 2.4 investigation shows that the same core can
complete both 10 MiB download and 10 MiB upload and parallel transfers. This
rules out a general TUN, TLS or upload-path failure but does not by itself
prove browser Speedtest.

Final browser/official result:

```text
PASS — Cloudflare browser Speedtest 5/5
```

| Run | Download, Mbps | Upload, Mbps | Latency, ms | Jitter, ms | Loss |
|---:|---:|---:|---:|---:|---:|
| 1 | 61.6 | 58.8 | 53.2 | 11.0 | 0% |
| 2 | 62.9 | 51.9 | 57.9 | 31.0 | 0% |
| 3 | 64.7 | 60.2 | 55.4 | 11.4 | 0% |
| 4 | 63.6 | 59.5 | 62.8 | 12.8 | 0% |
| 5 | 64.1 | 61.8 | 61.0 | 9.09 | 0% |

Each run reached its final measured-results screen and included download
and upload. The VPN remained active and Android-validated after the fifth
run. A controlled post-load HTTPS check then returned HTTP 200 and 65,536
bytes through the VPN. No official Ookla application was installed, so it
was not added solely for this run. Evidence:
`device-final/speedtest/speed1-final.png` through
`speed5-final.png` and `post-speed-https.txt`.

No production workaround has been added. In particular DNS, MTU, mux, QUIC
and monitoring hooks were not modified without a one-factor reproduction.

## 7. QUIC / HTTP/3

The validation client now logs DNS preflight, active network, symbolic
HttpEngine failure and response transport. On the exact Stage 2.3 core over
the active validated VPN it produced:

```text
protocol=h3
status=200
body_bytes=299
network_bytes=407
vpn=true
validated=true
```

This is positive ALPN/transport evidence and not an inference from YouTube.
The earlier `NetworkException error_code=1` maps to hostname resolution, not
to an established QUIC session failure.

Stage 2.4 exact-APK repeat:

```text
PASS
```

Five exact-APK probes completed through the active validated VPN. Runs 1
and 4 positively negotiated `protocol=h3`:

```text
run 1: h3, HTTP 200, body=297, network=405 bytes
run 4: h3, HTTP 200, body=299, network=405 bytes
vpn=true, validated=true
```

The other three requests negotiated HTTP/2 fallback and also succeeded.
The two positive `h3` runs are transport evidence for QUIC/UDP through the
TUN; fallback on separate requests does not negate them. Evidence:
`device-final/http3-repeats.txt`.

## 8. Restart, rollback and resource regression

Exact Stage 2.4 restart:

```text
PASS — 10/10
```

All ten counted restarts closed the old VPN NetworkAgent, produced a new
`core_start_success` generation, created a new validated VPN/TUN, and passed
the 65,536-byte HTTPS probe. Scenarios included idle, concurrent DNS,
concurrent parallel TCP download, and Smart Active refresh. Generations
were unique, from `1785407738723845` through `1785407738723863`. There was
no stale dialog, false Connected or terminal failure.

An initial coordinate-only automation attempt was discarded: after opening
the selector, the harness tapped the selector Activity rather than the VPN
control. The VPN remained validated; this was not a product restart result.
The counted run explicitly returned from the selector before lifecycle
control. Evidence: `device-final/restart-10-r2/summary.tsv` cycles 1–9 and
`cycle-10-r3.tsv` for the Smart Active case.

Static rollback verification passed for immutable Stage 2.1:

```text
APK SHA:
B1D47F7A57685B2947121D638148F548937AE17F0B9B77373146A6CCC1A5D5ED

AAR SHA:
EFB8EB73D0AE2878667A3B4E7A58E0D95E5FBA1FD37ABE045CB13642805EB222
```

The existing verifier confirmed the Stage 2.1 APK/AAR ABI and embedded
metadata. Interactive Stage 2.1 VPN data plane and return to Stage 2.4:

```text
PASS
```

`adb install -r -d` installed Stage 2.1 without clearing data. Its pulled
`base.apk` matched `B1D47F...D5ED`; the retained profile established a
validated VPN, TUN and HTTP 200/65,536-byte HTTPS path, then cleaned up.
Stage 2.4 was reinstalled the same way; its pulled `base.apk` matched
`99993A...DDFCD27` and repeated the same data-plane and cleanup assertions.
`firstInstallTime` remained unchanged. Evidence:
`device-final/rollback/summary.tsv`.

Resource settling table:

| Snapshot | PSS KiB | RSS KiB | Java heap KiB | Native heap KiB | Threads |
|---|---:|---:|---:|---:|---:|
| Permission-flow baseline | 375,378 | 513,088 | 7,352 | 39,848 | not reliable |
| After HTTPS series A | 301,279 | 416,460 | 7,452 | 39,168 | 73 |
| After HTTPS series B | 297,555 | 413,808 | 7,172 | 37,160 | 77 |
| After Speedtest | 394,843 | 538,976 | 22,496 | 42,656 | 70 |
| After 10 counted restarts | 426,257 | 568,912 | 7,784 | 44,720 | 74 |
| Final Stop | 361,036 | 498,656 | 6,476 | 42,144 | 70 |
| Final Stop + 45 s settling | 276,707 | 393,228 | 5,260 | 34,464 | 64 |

Series A and B used the same PID and show no session-linear PSS/RSS or
native-heap growth across 40 full cycles. Process IDs changed during APK
installation and the discarded automation attempt, so cross-PID values are
reported but not treated as a leak curve. The final same-PID settling
dropped PSS by 84,329 KiB, RSS by 105,428 KiB and threads from 70 to 64.
After final Stop there was no VPN NetworkAgent, active TUN or foreground
VPN service. `/proc/<pid>/fd` enumeration is denied to the shell UID on this
device and is therefore marked unavailable, not zero.

The time-bounded final scan found zero `FATAL EXCEPTION`, app ANR, SIGSEGV,
SIGABRT, Go panic or native panic matches. Evidence:
`device-final/resources/summary.tsv`, the corresponding meminfo/thread
snapshots, `final-vpn-state.txt`, `final-services-filtered.txt` and
`device-final/final-crash-scan.txt`.

## 9. Emergency switch

```text
NOT RUN — NO MANAGED TEST OUTBOUND
```

No production endpoint or whole-device physical network is intentionally
broken. Emergency policy is unchanged.

## 10. Protocol-specific profiles

Only redacted protocol type/fingerprint may be recorded. Endpoints, UUIDs,
passwords, keys, subscription URLs and profile JSON are excluded.

The retained subscription/profile passed generic connect, DNS, HTTPS, TUN,
restart and cleanup checks, but the safe release diagnostics did not expose
its protocol type. Extracting application data or effective configs solely
to identify it was prohibited. Therefore no protocol-specific PASS is
claimed:

| Protocol | Result |
|---|---|
| VLESS | NOT IDENTIFIED |
| VMess | NOT IDENTIFIED |
| Trojan | NOT IDENTIFIED |
| Shadowsocks | NOT IDENTIFIED |
| Hysteria2 | NOT IDENTIFIED |
| TUIC | NOT IDENTIFIED |
| WireGuard | NOT IDENTIFIED |
| AmneziaWG | NOT IDENTIFIED |
| Psiphon | NOT IDENTIFIED |

This is an evidence limitation, not a protocol failure. Evidence:
`device-final/protocol-identification.txt`.

## 11. Artifact provenance

Core:

```text
sing-box: v1.13.14-zeon.1
upstream: 25a600db24f7680ad9806ce5427bd0ab8afe1114
core source: e8c06439e1864255d81f4ee89290d89cbb1b3a18
hiddify-core tree: 7390740472f8e17abd281c0e10ab40eb77c971af
hiddify-sing-box tree: 7f4930c76d7dbe9f08a6de01acaaca33db5bac9d
Go: 1.25.6
gomobile: v0.1.11
NDK: 28.2.13676358
```

Artifacts:

| Artifact | SHA-256 |
|---|---|
| Production AAR | `5BEC09E8AA72E385C0BB4950FE9970759725C6083F813E6DAB7BBFE436BECB00` |
| Stage 2.4 universal APK | `99993A4D9F2C4911FF8282A9D68A6E2DB912A344D637AC0998D892788DDFCD27` |
| Stage 2.4 arm64 APK | `CAF9E9B9AA7D525EC2004BC6B7F348AE343084655728C87928AA849AF7693F96` |

The installed production `base.apk` was pulled back and matched the universal
APK SHA exactly. Installation used only `adb install -r -d`.

Manifest:

```text
baselines/android-core/2026-07-30-stage2-4.json
```

The Stage 2.3 and Stage 2.4 AARs are byte-identical; therefore Java API, JNI,
native ABI, SONAME behavior and per-ABI core code are identical. The
provenance verifier passed the new APK and unchanged AAR.

## 12. Host test results

| Test | Result |
|---|---|
| Flutter | PASS, 133/133 |
| Targeted Flutter analyze | no new error; existing generated/protobuf warnings remain |
| Android validation build | PASS |
| Isolated Android instrumentation | PASS, 37/37 |
| Unsafe production instrumentation task | rejected/not created |
| `go test ./...` sing-box fork | PASS |
| required `go test -race` packages | PASS |
| Smart Active race test ×100 | PASS |
| config corpus without tags | expected FAIL for omitted QUIC/WG/AWG tags |
| config corpus with production-compatible host tags | PASS |
| release APK build | PASS |
| AAR/API/ABI verifier | PASS |
| Stage 2.1 rollback verifier | PASS |
| `git diff --check` | PASS |

All Go commands used `GOTOOLCHAIN=go1.25.6`; the installed system Go 1.26 was
not substituted.

## 13. Commits

| Commit | Purpose |
|---|---|
| `79034ed8` | isolate Android validation target and reject production managed tests |
| `6b25acb3` | serialize notification/VPN permissions in one generation |
| `b3e528be` | validation-only correlated HTTPS/upload/download and HTTP/3 probes |
| `58200dfd` | immutable Stage 2.4 app/core provenance |
| `d632dc62` | deterministic two-batch descriptor ownership stress baseline |

Core, AAR and production data-plane behavior were not changed.

## 14. Evidence

Root:

```text
out/stage2-4-data-plane-stabilization/20260730T081809Z/
```

Key evidence:

- `permission-instrumentation-final.txt`;
- `device-final/safe-instrumentation-final-r2.txt`;
- `stage23-https-same-session-30.txt`;
- `stage23-connect-https-stop-30b/summary.csv`;
- `stage23-cf-download-5x10m.txt`;
- `stage23-cf-upload-5x10m.txt`;
- `direct-visible-parallel-upload-20x5m.txt`;
- `stage23-http3-vpn.txt`;
- `host/go-race-required.txt`;
- `host/go-race-monitoring-count100.txt`;
- `host/go-test-all.txt`;
- `host/hiddify-core-config-corpus-production-tags.txt`;
- `host/flutter-test.stdout.txt`;
- `host/core-verifier-stage24.txt`;
- `host/rollback-stage21-verifier.txt`;
- `device-final/installed-stage24-base.apk`.
- `device-final/permission-flow/lifecycle-redacted.txt`;
- `device-final/https-series-A/summary.tsv`;
- `device-final/https-series-B/summary.tsv`;
- `device-final/speedtest/speed1-final.png` through `speed5-final.png`;
- `device-final/http3-repeats.txt`;
- `device-final/restart-10-r2/summary.tsv`;
- `device-final/restart-10-r2/cycle-10-r3.tsv`;
- `device-final/resources/summary.tsv`;
- `device-final/rollback/summary.tsv`;
- `SHA256SUMS-redacted.txt`.

Private UI hierarchies and raw connectivity captures were quarantined
outside the evidence root before hashing. The redacted manifest contains
296 files:

```text
SHA256SUMS-redacted.txt
SHA-256: 8BB576C9849D6070FA751B09A0169757E45193835C85FF8A2BB3C03A83844EC2
```

## 15. Remaining limitations and verdict

The following are intentionally not required by Stage 2.4: 6–12 hour soak,
city movement, tower/operator matrix and long Doze.

Verdict:

```text
PASS
```

The exact Stage 2.4 APK completed the physical one-Connect permission flow,
two independent 20/20 HTTPS/cleanup series, 10/10 counted restarts, 5/5
full browser Speedtests, positive HTTP/3 transport proof, stable short-run
resource settling, and interactive Stage 2.1 rollback/return. No crash,
ANR, panic, false Connected, stale dialog or orphan VPN/TUN/service was
observed.

Emergency switch remains `NOT RUN — NO MANAGED TEST OUTBOUND`, as explicitly
permitted by the Stage 2.4 acceptance criteria. Protocol-specific coverage
remains `NOT IDENTIFIED` because release-safe diagnostics do not expose the
retained profile type and credentials/config extraction was prohibited.
Long city/mobile/tower testing, long Doze and 6–12 hour soak remain owner
follow-up items and are not Stage 2.4 PASS prerequisites.
