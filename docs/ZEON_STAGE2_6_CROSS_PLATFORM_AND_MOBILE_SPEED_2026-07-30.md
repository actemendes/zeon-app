# ZEON Stage 2.6 — cross-platform startup and mobile-speed validation

Date: 2026-07-30
Branch: `stage2.6/cross-platform-mobile-speed`
Stable base: `961ced2058c8b67c268ac5a44bf4c260b958127d`
Android core: `sing-box 1.13.14-zeon.1`, source revision `e8c06439e1864255d81f4ee89290d89cbb1b3a18`

## 1. Executive summary

Stage 2.6 produced three independent outcomes:

| Area | Verdict | Meaning |
|---|---|---|
| Windows UI/startup | **PASS — VPN NOT STARTED** | 30/30 cold launches and 20/20 rapid secondary launches passed with the validation-only no-tunnel guard. No route, DNS, proxy or adapter change was caused by ZEON. |
| iOS | **DEVICE VALIDATION BLOCKED** | Generation/readiness fixes were implemented in Swift source, but this Windows host cannot compile/sign an iOS app or execute a real Network Extension. The checked-in XCFramework is proven stale and was not represented as current. |
| Android mobile speed | **INCONCLUSIVE** | LTE was proven as the underlying transport. Direct connectivity varied during the run; two short direct HTTPS probes passed, while all validated-VPN probes failed at DNS. No numerical Direct/VPN throughput ratio can be computed and no network tuning is justified. |

Overall Stage 2.6 status: **CONDITIONAL PASS**. Windows startup is closed for the no-VPN scope. iOS artifact/device validation and an independent Android cellular data-plane comparison remain blocked.

No change was made to sing-box, Android AAR, Smart Active scoring, Round Robin, selector policy, MTU, mux, QUIC, DNS, routing, IPv6, UDP probe, profiles or protocol implementations.

## 2. Inputs and safety boundary

The reports for Stages 2.1–2.5 were read in full before implementation. The Windows audit never issued a Connect action and never invoked the desktop core's VPN start path.

Before Windows launch tests, the following state was captured:

- route table;
- physical and virtual adapters;
- IP configuration;
- DNS client configuration;
- WinHTTP proxy;
- per-user Internet Settings proxy;
- ZEON/Hiddify services and processes.

An unrelated already-running Hiddify process and its pre-existing loopback WinINet proxy were observed. They were not stopped or modified. The before/after files were compared byte-for-byte for route, adapters, IP configuration, DNS, WinHTTP and WinINet state. Every comparison was equal.

Evidence: `out/stage2-6/evidence/20260730T133517Z/windows/network-state-comparison.csv`.

## 3. Windows startup root cause and fixes

### 3.1 Single-instance race

The runner created the named mutex and the secondary process immediately searched for the primary window. During primary startup, the mutex can exist before the HWND. The secondary process could therefore exit without activating a window, which is indistinguishable to a user from “the app does not start.”

Fix:

- the secondary process now waits for the primary HWND for a bounded five seconds;
- it activates the existing window and exits before Flutter/plugin initialization;
- the mutex handle is closed;
- validation correlation markers can be written through `ZEON_STARTUP_DIAGNOSTICS_FILE`.

Evidence:

- `windows/runner/main.cpp`, functions around lines 25–147;
- commit `1cddb740` (`fix(windows): serialize startup and add safe markers`);
- 20/20 rapid secondary launches left exactly one primary process and returned success.

### 3.2 Unowned proxy mutation

The Windows runner unconditionally disabled the current user's WinINet proxy during window creation, destruction and end-session. The runner did not prove that ZEON owned that proxy. This could silently alter another Hiddify/ZEON instance or the user's explicit system configuration and could contribute to startup/exit symptoms.

Fix:

- removed the unconditional proxy reset from window lifecycle;
- removed the now-unused WinINet linker dependency.

Evidence:

- `windows/runner/flutter_window.cpp`;
- `windows/runner/CMakeLists.txt`;
- commit `d1bc9bc7` (`fix(windows): preserve unowned system proxy state`);
- WinINet/WinHTTP state is unchanged after all launch tests.

### 3.3 Desktop core endpoint and lifecycle ambiguity

`CoreInterfaceDesktop` used a fixed management port. A ZEON process could collide with, or attach to, an unrelated Hiddify-derived process. Setup calls were not coalesced, temporary FFI strings were not arena-owned, and `setupBackground()` reported `CoreStarted` before a VPN data plane was proven.

Fix:

- process-owned dynamic loopback management port;
- serialized setup future;
- bounded command-readiness probe;
- scoped FFI allocations;
- monotonic desktop generation and stale-generation rejection;
- `setupBackground()` returns `CoreStarting`, never `CoreStarted`;
- explicit `markCoreStarted()` gate;
- stop acknowledges the shared gRPC lifecycle without tearing down a newer generation.

Evidence:

- `lib/zeoncore/core_interface/core_interface_desktop.dart:58-220`;
- commit `e5cd4930` (`fix(windows): isolate core ownership and generations`);
- targeted `flutter analyze`: PASS;
- Flutter test suite: 133/133 PASS.

### 3.4 Validation-only no-VPN guard

The compile-time constant `zeon_windows_startup_validation` is checked before any explicit desktop VPN start. It returns `Stopped` and logs that the validation artifact blocked the operation. The guard is enabled only in the validation artifact; it is absent from the production artifact.

Evidence:

- `lib/zeoncore/core_interface/core_interface_desktop.dart:24,160-169`;
- `scripts/build_windows_release_folder.ps1`;
- commit `9ca355df` (`test(windows): add isolated startup validation guard`);
- validation and production `app.so` hashes differ, proving separate build inputs.

## 4. Windows launch results

| Scenario | Result |
|---|---:|
| Cold launch, two-second idle, normal close | 30/30 |
| Rapid second launch while primary exists | 20/20 |
| Unexpected exit | 0 |
| Unhandled/native crash or relevant WER event | 0 |
| Invisible orphan process after close | 0 |
| Minimize/restore | PASS |
| Tray/close confirmation | PASS |
| Launch from a foreign working directory | PASS |
| Unicode path | PASS |
| Long-path packaging | BLOCKED by legacy path handling during the copied validation layout |
| Tunnel/proxy/route/DNS/adapter mutation | 0 |

The close action correctly displayed the existing “close or hide” UI. Selecting close terminated the process without an orphan.

Consolidated table: `out/stage2-6/windows-startup-results.csv`.

The long-path result is not counted as a runtime crash: copying the validation layout exceeded legacy Win32 path handling before a trustworthy launch could be completed. It remains a packaging limitation.

## 5. Windows dependencies, artifact and provenance

Environment:

- host: Windows 10 IoT Enterprise LTSC 21H2, x64;
- Flutter `3.41.9`, engine revision `42d3d75a56`;
- Dart `3.11.5`;
- Visual Studio Build Tools 2022 `17.14.37301.10`;
- Windows SDK `10.0.26100.0`;
- architecture: x64.

Dependency inspection showed the expected MSVC runtime imports (`MSVCP140`, `VCRUNTIME140`, `VCRUNTIME140_1`) and bundled Flutter plugin DLLs. No WebView2 dependency was detected in the runner import table. Tunnel-related DLLs were only inspected as files; no tunnel was loaded.

Production artifacts:

| Artifact | SHA-256 |
|---|---|
| `out/stage2-6/windows/production/ZEON-stage2.6-windows-x64.zip` | `9DA20081CEA00D0760E12582EDA38A18050FA423C3207096A8851D59894AE143` |
| `ZEON.exe` | `6048A3992128A3AE32302BE9A01D41405DC428B761BE29CE9435306B21E72F48` |
| `hiddify-core.dll` | `6CC3A9A31BCA1D20285415AD49FD288E5BA370067B62271EDF66D10C7E31AC62` |
| `libcronet.dll` | `C7434CFA93C3041321DD19111C4DE6C52B8A9531A65661BA45425D3C51EC69E2` |

The Windows ZIP is not Authenticode-signed. It is suitable as a reproducible validation/release-folder artifact, not as a signed public installer.

Embedded `hiddify-core.dll` metadata was read through the exported metadata API:

```text
upstream_version=v1.13.14
upstream_commit=25a600db24f7680ad9806ce5427bd0ab8afe1114
build_revision=8591066dac5bfa6c4491724bdbf482545b7186b4
hiddify_core_tree=8f4fe7e1407ad20b21d96b8f7fde46a900c9112c
hiddify_sing_box_tree=7f4930c76d7dbe9f08a6de01acaaca33db5bac9d
go=go1.25.6
dirty=false
source_date_epoch=0
build_id=empty
```

Production tags:

```text
with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,
with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,
with_conntrack
```

Implementation:

- `hiddify-core/platform/desktop/build_metadata.go:14-59`;
- `scripts/rebuild_hiddify_core.ps1:307-313`;
- commits `5bd4f784` and `8591066d`.

## 6. Portability matrix for Stage 2.1–2.5

The detailed machine-readable matrix is in `out/stage2-6/platform-fix-matrix.csv`.

Key conclusions:

- `StartedService.Close()`, observable-owner cleanup, replaceable `CoreLogFactory` cleanup, immutable `URLTestHistory`, and the Smart Active race fix live in the shared Go core.
- Android permission orchestration, PFD/TUN ownership, post-TUN protect probe, Bitmap downsampling and R8 hardening are Android-specific.
- Session generation, stale-result suppression, readiness gates, platform adapter ownership and status publication require per-platform bridges even when the core is shared.
- Windows now has generation and management-endpoint isolation, but Windows VPN behavior was deliberately not exercised.
- iOS source previously lacked the mobile bridge methods used by shared Dart (`set_session_generation`, `mark_core_started`) and published Started from raw Network Extension connection state.

## 7. iOS lifecycle implementation

Implemented source changes:

- monotonic generation and core-ready generation guarded by `NSLock`;
- `set_session_generation` and `mark_core_started` MethodChannel cases;
- generation propagation through manager preparation, start, stop, provider configuration and extension options;
- stale completion/error suppression;
- Started requires both the current generation and the Network Extension connected state;
- status events include generation and publish Starting until the core-ready gate;
- NotificationCenter connection callbacks validate the observed connection identity;
- `PacketTunnelProvider` records and clears its generation;
- deterministic Runner test for monotonic generation and non-inherited readiness.

Files:

- `ios/Runner/VPN/VPNManager.swift:29-243,411-469`;
- `ios/Runner/Handlers/MethodHandler.swift:35-58,145-260`;
- `ios/Runner/Handlers/StatusEventHandler.swift`;
- `ios/Runner/Handlers/AlertsEventHandler.swift`;
- `ios/ZeonPacketTunnel/SingBox/ExtensionProvider.swift:15-222`;
- `ios/RunnerTests/RunnerTests.swift:8-17`.

Commits:

- `8419eec3` (`fix(ios): gate tunnel readiness by generation`);
- `aa52cd00` (`test(ios): cover monotonic tunnel generation`).

### iOS artifact status

The existing `ios/Frameworks/Libcore.xcframework.zip` has SHA-256:

`AED5BE7D4EF111B13ADC654C8A074EB55CFB6A50D909A40A9ABB36B42DB58A38`

It contains `ios-arm64` and `ios-arm64_x86_64-simulator` slices and targets iOS 15.0, but binary-string inspection found neither `v1.13.14`, current revision `e8c06439…`, nor the new provenance metadata. It is therefore a **stale core artifact** and was not promoted.

This host has no Xcode, iOS signing identity, provisioning profile or physical iPhone. Swift compilation, entitlement validation, app/extension launch and Network Extension data plane are unavailable.

iOS verdict: **DEVICE VALIDATION BLOCKED**.

Required next environment:

1. macOS with the pinned Flutter/Xcode toolchain;
2. Network Extension and App Group provisioning;
3. rebuilt XCFramework from the current shared-core revision;
4. physical-iPhone permission, connect/stop/restart and stale-callback tests.

## 8. Android cellular test environment

Device:

- OnePlus GM1901;
- Android 16 / API 36;
- production package `com.zeon.hiddify`;
- Android core/AAR was not changed in Stage 2.6.

Wi-Fi was explicitly disabled and Android connectivity proved the underlying transport was cellular LTE. Evidence did not rely on the status-bar icon. Sanitized radio snapshot:

| Metric | Value |
|---|---:|
| Radio | LTE |
| RSRP | -99 dBm |
| RSRQ | -14 dB |
| reported RSSNR/SINR indicator | 4 dB |
| Android signal level | 3 |
| Roaming | false |
| Link MTU observed | 1440 |

Battery was full, battery saver was off, the device was USB-powered, and temperature was approximately 33 °C. Phone number, IMSI, IMEI, Cell ID, location, BSSID, IP addresses, carrier/APN identifiers and server labels are excluded.

After the run, VPN was stopped, zero VPN NetworkAgents remained, and Wi-Fi was returned to its original enabled state.

## 9. Direct/VPN alternating results

The intended order was retained:

```text
Direct 1 → VPN 1 → Direct 2 → VPN 2 → ... → Direct 5 → VPN 5
```

The detailed rows are in `out/stage2-6/mobile-speed-direct-vpn.csv`.

Summary:

- Direct short HTTPS: 2 successful transfers of 65,536 bytes; two TCP/TLS attempts did not complete in the observation window; one attempt occurred while cellular validation was transitioning and is excluded.
- Validated VPN: 5/5 attempts stopped at DNS with `UnknownHostException`; active network was VPN over cellular and Android marked it validated.
- Direct upload: TCP connect timeout.
- VPN upload: DNS failure.
- Browser direct access to the selected public speed services was intermittently unavailable/time-limited.
- HTTP/3 over VPN failed during DNS preflight, before UDP socket creation, protect, QUIC handshake or ALPN. It is **NOT PROVEN**, not a QUIC protocol failure.

The short 64-KiB direct samples are not a Speedtest replacement. Their approximate rates (0.846 and 0.951 Mbit/s using total transaction time) are recorded only as evidence that direct TLS could pass; they are too small for capacity conclusions.

No valid VPN throughput sample exists, therefore:

- throughput ratio: not computable;
- upload ratio: not computable;
- latency delta: not computable;
- jitter/packet loss comparison: not computable.

### Bottleneck classification

**Android mobile speed: INCONCLUSIVE.**

The result does expose a separate risk: in this LTE environment, the VPN NetworkAgent and TUN can be validated while the controlled user-space resolver probe still fails. The present evidence cannot distinguish among:

- selected outbound/server DNS path;
- mobile-operator route to the VPN server;
- current profile's remote DNS behavior;
- a client DNS path that manifests only over cellular.

It does not prove a CPU, MTU, mux, QUIC, or Android encryption throughput bottleneck. No one-factor tuning was performed because there was no stable baseline and no independent test outbound/server. Changing production defaults would violate the required evidence threshold.

## 10. Android resource and crash checks

Final state after VPN stop:

- active VPN NetworkAgent: 0;
- app process remained alive as expected for the UI;
- threads: 72;
- PSS: 428,604 KiB;
- RSS: 573,644 KiB;
- crash/ANR/SIGSEGV/SIGABRT/Go-panic scan: no matches.

The app's `/proc/<pid>/fd` directory was not readable by shell UID on this Android build, so no fabricated FD count is reported. This short run is not a resource-soak proof; it found no orphan VPN session or immediate crash signature.

## 11. Tests

| Test | Result |
|---|---|
| Flutter tests | PASS, 133/133 |
| Targeted Flutter analyze (`CoreInterfaceDesktop`) | PASS |
| Windows production build | PASS |
| Windows startup validation build | PASS |
| Desktop Go package, Go 1.25.6 | PASS |
| `go test -race` monitoring/urltest/group/balancer | PASS |
| Smart Active regression race x100 | PASS |
| Desktop build-metadata unit test | PASS |
| `git diff --check` | PASS |
| Windows Application Error/WER scan | no ZEON matches |
| iOS unit/build | BLOCKED: no Xcode/macOS |
| iOS device/Network Extension | BLOCKED: no physical iPhone/signing |
| Android direct/VPN capacity test | INCONCLUSIVE |

The Go tests used exact `go1.25.6` under WSL2. No system Go 1.26 toolchain was substituted.

## 12. Commits

| Commit | Purpose | Independent rollback |
|---|---|---|
| `1cddb740` | Windows startup diagnostics and single-instance serialization | yes |
| `d1bc9bc7` | Preserve unowned system proxy | yes |
| `e5cd4930` | Desktop core endpoint/generation ownership | yes |
| `8419eec3` | iOS generation/readiness bridge | yes |
| `aa52cd00` | iOS generation tests | yes |
| `5bd4f784` | Desktop core provenance API | yes |
| `8591066d` | Link provenance into c-shared main | yes |
| `9ca355df` | Validation-only Windows no-VPN guard | yes |

No Android speed-fix commit exists because no root cause met the production-change threshold.

## 13. Rollback

Windows:

1. restore the previous release-folder/ZIP artifact;
2. independently revert the relevant Windows commit(s);
3. retain the user's profile directory;
4. repeat UI-only launch and before/after network-state comparison;
5. do not infer Windows VPN behavior from the UI test.

iOS:

1. revert `8419eec3` and `aa52cd00` independently if necessary;
2. retain the previous XCFramework/app artifact;
3. rebuild only on the signed macOS environment;
4. verify App Group and Network Extension data preservation.

Android:

- Stage 2.5 Android AAR/artifacts were not replaced;
- no Android source/network setting needs rollback;
- no `adb uninstall` or `pm clear` was executed.

No `git reset --hard` was used.

## 14. Evidence and privacy

Required tables:

- `out/stage2-6/windows-startup-results.csv`;
- `out/stage2-6/platform-fix-matrix.csv`;
- `out/stage2-6/mobile-speed-direct-vpn.csv`.

Evidence root:

`out/stage2-6/evidence/20260730T133517Z/`

Only curated redacted Android logs are included in the final manifest. Generated validation profile contents, endpoints, credentials, UUIDs, subscription URLs, phone identifiers, network addresses and server labels are excluded.

Final SHA-256 manifest:

`out/stage2-6/SHA256SUMS.txt`

Manifest SHA-256: `627233D31F6644C734B9906D2B9C7C3ADBCDDD881E3151207ED39CAE448C4C40`.

## 15. Remaining limitations

1. Windows VPN was intentionally not started; the result is UI/startup only.
2. The Windows ZIP is unsigned and the copied long-path layout remains unverified.
3. The iOS XCFramework is stale; current Swift changes are not compiled or device-tested.
4. No physical iPhone/Network Extension data-plane result exists.
5. LTE did not provide a stable, symmetric Direct/VPN capacity test; VPN DNS failed in the controlled probe.
6. No independent managed VPN server/outbound or server-side logs were available.
7. HTTP/3 was not reached beyond DNS preflight on LTE.
8. No 6–12-hour soak, city travel, tower/operator matrix or prolonged Doze was performed, as required.

## 16. Final verdicts

```text
Windows UI/startup:
PASS
VPN NOT STARTED

iOS:
DEVICE VALIDATION BLOCKED

Android mobile speed:
INCONCLUSIVE

Overall Stage 2.6:
CONDITIONAL PASS
```
