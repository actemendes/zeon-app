# ZEON Stage 2.7 — UI/core synchronization and RU routing

Date: 2026-07-30  
Branch: `stage2.7/ui-core-sync-ru-routing`  
Android device: OnePlus GM1901, Android 16 / API 36, serial `18bfc103`  
Production package: `com.zeon.hiddify`

## 1. Executive summary

Stage 2.7 replaced the previously fragmented Android/Flutter connection-state
assembly with one immutable, generation-scoped `VpnSessionSnapshot`. The Android
session coordinator is authoritative. Flutter and the foreground notification
consume the same snapshot, and Flutter explicitly requests a snapshot after
startup, resume, EventChannel reconnection, a sequence gap, or a bounded startup
timeout.

The known mismatch:

```text
core/TUN/notification Connected
Flutter UI Connecting
```

was caused by two independent publication paths:

1. `ServiceNotification` read `SystemInfo.current_outbound` directly and could
   render a newer core state.
2. Flutter relied on a lossy status subscription plus an outstanding start
   `Future`; there was no replayable authoritative state, runtime epoch, or
   sequence-gap recovery.

The fix is in commits `2e38165f`, `c5f92112`, `e8994032`, `57a9d7f8`, and
`b129c65f`. Duplicate no-op snapshots were removed in `a1516851`.

Physical Android validation found an additional, independent defect: teardown
ran `Mobile.close()` on the main looper. It produced a real ANR after repeated
lifecycle cycles. The trace points to
`com.hiddify.core.mobile.Mobile.close(Native method)` on thread `main`.
Commit `66cabae5` moves only this blocking native close to `Dispatchers.IO` and
adds a deterministic regression test.

Post-fix physical result:

```text
20/20 core start
20/20 authoritative snapshot CONNECTED
20/20 Android VPN validated
20/20 HTTPS 200 with 65,536 transferred bytes
20/20 teardown
0 orphan VPN NetworkAgent after stop
0 false Connected
0 endless Connecting
0 new ZEON crash/ANR/panic
```

The current Russia routing was audited. Stage 2.7 adds explicit `.su` and
`.xn--p1ai` coverage beside the existing `.ru` rule. It does not import a DPI
hostlist. Yandex and Wildberries families remain explicit VPN overrides before
the generic RU direct rule, preserving current ZEON behavior.

No installed “Запрет” implementation was found on the Windows host or OnePlus.
The only available comparison source is the separately cloned official
`youtubediscord/ZapretKVN-android` repository at
`20794bfd2e4223c0d11dba73cab2a0f0fb354e07`. Its RU domain source contains only
`.ru`, `.su`, and `.xn--p1ai`; its RU IP set is a pinned country snapshot, not a
classic DPI include/exclude hostlist.

Verdicts:

```text
UI/core synchronization: PASS
Russia routing: CONDITIONAL PASS
Windows: UI/MOCK ONLY — VPN NOT STARTED
iOS: DEVICE VALIDATION BLOCKED
Overall: CONDITIONAL PASS
```

Russia routing is conditional because an installed Zapret instance was absent,
the physical preset could not be changed after the phone returned to a
PIN-locked state, and production has no validation-only route-match telemetry
that proves the exact outbound for every public service. These limitations are
not replaced with assumptions.

## 2. State-source inventory

| Layer | Previous source | Stage 2.7 authority | Evidence |
| --- | --- | --- | --- |
| Flutter UI | status stream, pending start/stop futures, cached provider state | parsed `VpnSessionSnapshot` through `VpnSessionSnapshotGate` | `lib/zeoncore/vpn_session_snapshot.dart:38-212` |
| Flutter resume | cached last state | `GetVpnSessionSnapshot` | `lib/zeoncore/zeon_core_service.dart:258-271` |
| Flutter EventChannel | service status only | `com.zeon.app/service.snapshot` with generation/epoch/sequence/version | `android/app/src/main/kotlin/com/zeon/zeon/EventHandler.kt:19-102` |
| Android UI bridge | independent `Status` enum | coordinator snapshot MethodChannel response | `android/app/src/main/kotlin/com/zeon/zeon/MethodHandler.kt:40,237` |
| Android foreground notification | direct `SystemInfo.current_outbound` plus service status | same coordinator snapshot used by Flutter | `android/app/src/main/kotlin/com/zeon/zeon/bg/ServiceNotification.kt:133-181` |
| Android core lifecycle | several booleans and callbacks | atomic `VpnSessionSnapshotCoordinator` | `android/app/src/main/kotlin/com/zeon/zeon/bg/VpnSessionSnapshot.kt:25-181` |
| Android start gates | `Status.Started` callback | snapshot reaches `CONNECTED` only after every gate | `android/app/src/main/kotlin/com/zeon/zeon/bg/BoxService.kt:594-662` |
| iOS app/extension bridge | locally synthesized status events | generation-scoped snapshot dictionary and request | `ios/Runner/VPN/VPNManager.swift`, `ios/Runner/Handlers/StatusEventHandler.swift` |
| Windows desktop | cached desktop status | shared snapshot adapter for mock/offline UI | `lib/zeoncore/core_interface/core_interface_desktop.dart` |
| shared core | `StartedService`, command server, selector observers | remains source of evidence, not UI authority | unchanged core lifecycle plus Android coordinator gates |

Local persistence is not an authority for a live VPN session. It may restore
display preferences, but it cannot publish `CONNECTED`.

## 3. `VpnSessionSnapshot` and state machine

The snapshot is immutable and contains:

```text
generation
runtimeEpoch
sequenceNumber
snapshotVersion
phase
requestedAction
coreReady
coreStarted
commandEndpointReady
tunnelReady
protectSucceeded
platformVpnValidated
selectedOutboundId
selectedOutboundLabel
strategy
failureCode
failureOwner
recoverable
```

Android stores the current value in an `AtomicReference` and serializes updates
under one short lock. No network I/O, Flutter callback, or core shutdown is
performed under that lock.

Phases:

```text
IDLE
PERMISSION_REQUIRED
START_REQUESTED
STARTING_PLATFORM
STARTING_CORE
WAITING_TUN
VERIFYING
CONNECTED
STOP_REQUESTED
STOPPING
DISCONNECTED
FAILED
```

The exact transition table is:

`out/stage2-7/session-state-transition-matrix.csv`.

### Android `CONNECTED` invariant

`VpnSessionSnapshot.provesConnected()` requires all of:

```text
generation > 0
phase == CONNECTED
coreReady
coreStarted
commandEndpointReady
tunnelReady
protectSucceeded
platformVpnValidated
selectedOutboundId is not empty
```

`BoxService.confirmCoreStarted()` additionally verifies that the operation
generation still owns the active session and that the session accepts
operations. A failed or stale gate cannot publish `Status.Started`.

### Generation and sequence rules

- Lower generations are ignored and logged as stale.
- A new generation resets per-session evidence.
- Events include `runtimeEpoch`, `sequenceNumber`, and `snapshotVersion`.
- Same-generation sequence duplicates are ignored.
- A sequence gap requests one authoritative snapshot.
- A new runtime epoch replaces the previous process cache.
- A newer event may not regress the same generation from `CONNECTED` to a
  transient start phase.
- An exact no-op does not increment sequence and is not published.
- A stale completion or exception is diagnostic only; it cannot update UI,
  notification, selector, or the active session.

## 4. Flutter resync and bounded self-healing

`CoreInterfaceMobile.resyncSessionStatus()` invokes
`get_vpn_session_snapshot`. `ConnectionNotifier` requests it on startup/resume
and when the snapshot gate reports a gap or contradiction.

The bounded startup timeout performs:

```text
request snapshot
→ adopt current generation/phase
→ do not call start again
→ if the authoritative start is terminal, expose that terminal result
```

It does not implement periodic polling and does not create another VPN
generation.

## 5. Notification synchronization

`ServiceNotification.show()` receives a snapshot. Dynamic selector statistics
may update the selected outbound only through
`VpnSessionSnapshotCoordinator.selectedOutbound()`. The notification is updated
only when the resulting snapshot still proves `CONNECTED`.

Thus the stable contract is:

```text
snapshot CONNECTED generation N
→ Flutter Connected generation N
→ notification Connected generation N
→ selected outbound id/label from generation N
```

## 6. Physical Android validation

### Artifact and preservation

Installed arm64 APK SHA-256:

`B7150507BF11CFD130E2118058A715FA77270CB7178DC1AE13094F2606EE0B4E`

The pulled installed `base.apk` has the same hash. Installation used
`adb install -r -d`; production `firstInstallTime` remained
`2026-07-29 23:13:48`. The existing profile was visible after installation.

The isolated validation packages were
`com.zeon.hiddify.validation` and
`com.zeon.hiddify.validation.test`; production data was not cleared.

### First connect and snapshot sequence

Observed sequence for generation `1785428549463922`:

```text
START_REQUESTED
STARTING_PLATFORM
STARTING_CORE
WAITING_TUN
VERIFYING
CONNECTED
```

`protect_result success=true`, `tun_open_success`, and
`core_start_success` preceded the terminal publication. Android showed a
validated VPN NetworkAgent and `tun0`. The validation activity returned HTTPS
200 and 65,536 bytes with `vpn=true validated=true`.

### Twenty post-fix cycles

Evidence:  
`out/stage2-7/evidence/device-final-post-anr/lifecycle-01-20.csv`

All 20 rows contain:

```text
core=1
snapshot_connected=1
https=1
validated_vpn=1
cleanup=1
vpn_after_stop=0
crash=0
```

Generations increased monotonically. No old generation published a terminal
error.

### Background/resume and screen-off

After HOME and reopening the app, UI hierarchy contained `Подключено` and the
same selected server while no new `core_start_success` was emitted. Screen-off
for 15 seconds stopped notification polling as designed; the foreground service,
core, TUN, and validated VPN NetworkAgent remained active after screen-on.

The phone then returned to its PIN lock screen. A PIN was not guessed or
bypassed. Activity-only force-stop is not possible because Flutter and the VPN
service share the production process. This scenario was therefore not replaced
with an unsafe process kill.

### ANR found and fixed

At `2026-07-30 19:09:07`, repeated lifecycle validation produced an ANR.
The main-thread trace was:

```text
"main" ... Native
at com.hiddify.core.mobile.Mobile.close(Native method)
at com.zeon.zeon.bg.BoxService...
at android.os.Handler...
```

Root cause: `BoxService.closeSession()` explicitly called the blocking native
close under `withContext(Dispatchers.Main)`.

Fix: `CoreShutdownDispatcher.close()` performs only `Mobile.close()` on
`Dispatchers.IO`; UI publication and notification operations retain their
existing dispatcher. The post-fix 20-cycle result above has no ANR.

### Resource result

After the final post-fix stop:

- process threads: 73;
- no active ZEON VPN NetworkAgent;
- no foreground VPN session;
- no crash-buffer entry;
- production process `/proc/<pid>/fd` was not readable by shell on this Android
  build, so no fabricated FD count is reported.

The short run shows no session-linear thread growth. It does not replace the
already completed Stage 2.2 resource audit or a long soak.

## 7. Deterministic mismatch tests

The full matrix is:

`out/stage2-7/ui-core-mismatch-tests.csv`.

It covers delayed subscriptions, process epochs, background/resume, stale
futures/errors, gaps, duplicates, phase regressions, stop/restart during start,
selector events, TUN/core loss, command/EventChannel reconnection, notification
recreation, timeout resync, and 100 repeated transitions.

Android instrumentation: `55/55 PASS`.  
Flutter tests: `172/172 PASS`.

## 8. iOS and Windows status

### iOS

Source now exposes a generation-scoped snapshot from `VPNManager` and applies
stale filtering in `StatusEventHandler`. `CoreReady` alone is not mapped to
`CONNECTED`.

No macOS/Xcode/signing/physical iPhone was available:

```text
iOS: DEVICE VALIDATION BLOCKED
```

No iOS PacketTunnel data-plane PASS is claimed.

### Windows

The desktop adapter supports snapshot resync/mock state. A release build
succeeded:

- `ZEON.exe` SHA-256:
  `6048A3992128A3AE32302BE9A01D41405DC428B761BE29CE9435306B21E72F48`
- `hiddify-core.dll` SHA-256:
  `6CC3A9A31BCA1D20285415AD49FD288E5BA370067B62271EDF66D10C7E31AC62`

The executable was not launched during Stage 2.7 and Windows VPN was not
started:

```text
Windows: UI/MOCK ONLY — VPN NOT STARTED
```

## 9. Current ZEON routing

The generated configuration uses modern sing-box `route.rule_set`; removed
legacy `geoip`/`geosite` option fields are not introduced.

Detailed order:

`out/stage2-7/current-zeon-routing.csv`.

### Russia preset

Relevant effective order:

1. mandatory internal/control-plane rules;
2. explicit user rules;
3. private/LAN direct;
4. force-direct;
5. security/ad blocking;
6. ZEON Yandex/Wildberries families via VPN and remote DNS;
7. `.ru`, `.su`, `.xn--p1ai` via direct and direct DNS;
8. `geoip-ru` and `geosite-ru` via direct;
9. optional existing QUIC block;
10. final VPN outbound.

The service-specific VPN override deliberately precedes `.ru` direct. Stage 2.7
does not change that product behavior.

The country rule sets are currently fetched from:

```text
https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geoip-ru.srs
https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geosite-ru.srs
```

with a five-day update interval and without an embedded commit/checksum in the
generated config. This mutable-source property is an identified provenance risk.
It was not silently replaced in this stage.

### Global preset

`Region == "other"` installs neither the RU suffix rule nor RU country rule
sets. The final outbound remains the VPN selector. Go tests prove that the
Global builder does not contain `geoip-ru`, `geosite-ru`, or RU direct suffixes.

## 10. “Запрет” discovery and semantic classification

Discovery checked:

- Windows processes;
- Windows services;
- common installation roots;
- OnePlus third-party package names.

No installed Zapret was found. Therefore there is no defensible claim about a
user-active hostlist, strategy, update date, or runtime behavior.

Reference-only comparison:

```text
repository: https://github.com/youtubediscord/ZapretKVN-android.git
commit: 20794bfd2e4223c0d11dba73cab2a0f0fb354e07
```

`rulesets/zapret-ru-domains.json` SHA-256:

`40D2A309AE180D1DBC7A2F7748106D1F8E1C9B6728EE65FBFFBCED6B911CD25F`

Its complete match content is `.ru`, `.su`, `.xn--p1ai`.

The documented binary RU IP set is sourced from pinned
`SagerNet/sing-geoip@5605651c12ed5b2fcf3b5de580c041eb9d8d938e` with SHA-256
`1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b`.

These are routing match sets. They are not evidence that every entry should be
copied from a classic Zapret DPI include/exclude file.

Full classification:

`out/stage2-7/zapret-list-classification.csv`.

## 11. Entries transferred and rejected

Transferred:

- `.su` → Russia preset direct;
- `.xn--p1ai` → Russia preset direct.

Already present:

- `.ru`.

Not transferred:

- Zapret binary `zapret-ru-ip.srs`: ZEON already has `geoip-ru`; replacing it
  would change source/update semantics and requires an explicit pinning
  migration.
- DPI strategy, binaries, fake packets, firewall rules: outside routing-list
  semantics and explicitly prohibited.
- Unknown include/exclude lists: none were found and their action cannot be
  inferred.
- Yandex/Wildberries direct conversion: conflicts with current explicit ZEON VPN
  overrides and lacks physical evidence that the override is wrong.

## 12. Managed rule-set architecture

`ManagedRuleSet` implements the client-side verified format:

```text
id
version
source
generatedAt
expiresAt
checksum
signature
formatVersion
domainCount
cidrCount
priority
action
applicablePreset
```

Actions are separate from match data:

```text
DIRECT
VPN
BLOCK
```

The normalizer:

- strips schemes, paths, wildcard/dot syntax;
- lowercases;
- converts IDN to canonical ASCII;
- validates domains and IPv4/IPv6 CIDR;
- deduplicates and sorts;
- detects cross-category action conflicts;
- verifies counts, ID, format, expiry, and SHA-256;
- writes a temporary file and atomically replaces only after verification;
- preserves the last-known-good file on fetch, checksum, parse, or expiry
  failure.

Conflict details:

`out/stage2-7/rule-conflicts.csv`.

The current application contains no documented backend rule-set endpoint or
signature trust root. Therefore Stage 2.7 provides the verified client
normalizer/store but does not invent an admin API URL, key, or production
auto-update. Wiring it to a backend remains blocked on an explicit server
contract. Current Hiddify remote SRS behavior remains unchanged.

## 13. Russian public service matrix

The validation-only allowlist tested 28 public entry points without cookies,
credentials, subscription data, or arbitrary URLs.

Active-VPN transport result:

- 26/28 returned an HTTP response and transferred bytes;
- Alfa Bank failed TLS validation because the Android trust manager could not
  build the presented chain;
- Ozon entered a 21-redirect loop;
- Wildberries returned HTTP 498, Avito 429, Aeroflot 503, and HH 406. These prove
  transport reachability but not application-level PASS;
- Gosuslugi, ESIA public entry, Nalog, Mos.ru, CBR, SBP, Sber, T-Bank,
  Gazprombank, Yandex, VK, Mail.ru, OK, Dzen, 2GIS, Rutube, Kinopoisk, RuStore,
  RZD, RIA, Lenta, and Megamarket returned HTTP 200 with bytes.

IPv6 DNS answers were observed for Yandex, Mail.ru, Dzen, Wildberries, and
Kinopoisk; the VPN NetworkAgent had both IPv4 and IPv6 default routes.

Android rejected validation-app binding to the physical network while the
non-bypassable VPN was active:

```text
SocketException: Binding socket to physical network failed: EPERM
```

That makes simultaneous one-factor direct probing unavailable to a different
UID. It is recorded as a platform constraint, not reclassified as a ZEON route
failure.

Matrix:

`out/stage2-7/russian-services-matrix.csv`.

The test validates DNS/TLS/HTTP/data transfer through the active VPN
NetworkAgent. It does not claim that every request took a specific internal
sing-box outbound because production route-match logging is intentionally
absent and the physical preset was not exposed to the validation package.

## 14. Tests

| Test | Result |
| --- | --- |
| Full Flutter suite | PASS, 172/172 |
| Snapshot + managed rule-set targeted suite | PASS, 39/39 |
| Android instrumentation | PASS, 55/55 |
| Android validation APK compile | PASS |
| Android release APK build | PASS |
| Windows release build | PASS, not launched |
| Go config builder with required QUIC/WireGuard/AWG tags | PASS |
| Go race: monitoring/urltest/interrupt/group/balancer/route/DNS | PASS |
| Go config with full production tags including Naive/Cronet on WSL | ENVIRONMENT LIMITATION |
| iOS source compile/device | BLOCKED: Windows host, no Xcode/iPhone |

The full-tag WSL limitation is an old linker rejecting the packaged Cronet
archive section type `.crel.text`; omitting only `with_naive_outbound` makes the
same config corpus pass. Android production AAR includes
`with_naive_outbound` and is physically validated.

## 15. Artifact provenance

No dependency or sing-box version was updated.

Core AAR:

- SHA-256:
  `4FEA6918DA38B746C89CB98A904FDC0FA83B8F77AB2B22352C8D6064E29C6F43`
- classes.jar:
  `959C71C4B641067BA96FA0D24BD23ADCC99F8DC063274FA4E99B2C0C07BE7B58`
- ABI: `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`
- Go: `go1.25.6`
- sing-box: `v1.13.14`
- upstream commit:
  `25a600db24f7680ad9806ce5427bd0ab8afe1114`
- embedded core build revision:
  `c6392e34d5fbe72dee13c504d821086301c91189`
- hiddify-core tree:
  `52e05bbd28fa737a89ed7e9cc49e9b347c51ef17`
- hiddify-sing-box tree:
  `7f4930c76d7dbe9f08a6de01acaaca33db5bac9d`
- build tags unchanged:
  `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack`

APK:

- arm64 release:
  `B7150507BF11CFD130E2118058A715FA77270CB7178DC1AE13094F2606EE0B4E`
- universal release:
  `A55E2622CD8A366011A62737B707E8821BA51BFABD9130A8442B4A0FF3B7899F`

The AAR contains the RU builder change. Later commits affect the Android/Flutter
bridge or validation-only source and do not change the AAR native core.

## 16. Commits

| Commit | Purpose |
| --- | --- |
| `2e38165f` | immutable Flutter snapshot and gate |
| `c5f92112` | Android authoritative coordinator and notification/UI source |
| `e8994032` | Flutter resync and stale/sequence filtering |
| `57a9d7f8` | iOS snapshot/lifecycle adaptation |
| `b129c65f` | Windows offline/mock snapshot resync |
| `82474adf` | versioned rule-set normalizer/store/conflicts |
| `550b7710` | explicit `.su` and `.xn--p1ai` Russia rules |
| `c6392e34` | monotonic phase and 100-cycle invariants |
| `a1516851` | no-op snapshot suppression |
| `66cabae5` | physical ANR fix: native close off main looper |
| `2fbeb661` | redacted public Russian service probe |
| `f594f251` | validation-only physical network comparison mode |
| `275be8b8` | analysis-only cleanup for the managed rule-set module |

## 17. Rollback

State synchronization rollback:

1. revert `e8994032`, `c5f92112`, and `2e38165f` in reverse order;
2. revert platform adapters `57a9d7f8` and `b129c65f` if required;
3. rebuild without changing the core AAR.

Routing rollback:

1. revert `550b7710`;
2. restore the previous AAR;
3. run the existing core verifier and config corpus.

Rule-set framework rollback:

1. revert `82474adf`;
2. no profile/config migration is required because the store is not wired to a
   production backend.

ANR fix rollback is independent (`66cabae5`), but is not recommended because a
physical main-thread ANR was captured.

Do not use `git reset --hard`, uninstall the app, or clear app data.

## 18. Evidence and privacy

Primary redacted evidence:

```text
out/stage2-7/evidence/device-final-post-anr/lifecycle-01-20.csv
out/stage2-7/evidence/device-final-post-anr/russian-services-russia-raw.log
out/stage2-7/evidence/device-final-post-anr/russian-services-direct-raw.log
out/stage2-7/evidence/device-final/anr-traces-19-09-07.txt
out/stage2-7/artifact-inspect/entries.csv
```

The broad `dumpsys notification --noredact` capture contained an unrelated
Telegram notification and was deleted. It is not present in the evidence
manifest. No endpoint, UUID, password, key, subscription URL, cookie, or user
DNS history is included in the final tables.

Final hashes are in:

`out/stage2-7/SHA256SUMS-redacted.txt`.

## 19. Remaining limitations

1. No installed Zapret instance was available; only the pinned reference clone
   could be classified.
2. Physical Direct and Global sweeps were not safely completed after the phone
   entered PIN lock. The PIN was not bypassed.
3. No production route-match telemetry exists; internal outbound selection for
   each service is proven by builder order/tests, not per-request device logs.
4. Alfa Bank TLS chain and Ozon redirects require a direct/Global/browser A/B
   before any routing conclusion.
5. The remote Hiddify country SRS URLs are mutable and lack manifest pinning in
   the generated config.
6. Backend API URL and signature trust root for managed lists are unspecified;
   production update wiring was not invented.
7. iOS physical Network Extension validation remains blocked.
8. Windows routing data plane was not started.

## 20. Final verdict

```text
UI/core synchronization:
PASS

Russia routing:
CONDITIONAL PASS

Windows:
UI/MOCK ONLY — VPN NOT STARTED

iOS:
DEVICE VALIDATION BLOCKED

Overall:
CONDITIONAL PASS
```

The UI/core PASS is supported by deterministic generation/sequence tests,
55/55 Android instrumentation tests, and 20/20 post-fix physical
connect/data-plane/stop cycles with no persistent mismatch. The routing verdict
remains conditional for the explicitly listed environmental and evidence
limitations; no hostlist or route behavior was inferred beyond available proof.
