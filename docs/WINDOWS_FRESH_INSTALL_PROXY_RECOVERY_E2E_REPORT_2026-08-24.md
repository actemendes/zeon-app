# Windows fresh-install, proxy recovery, and VM E2E report

> Superseded by `WINDOWS_DOMAIN_MANAGED_ROUTING_REPORT_2026-08-25.md`, which
> records the successful Windows 10 desktop/fresh-install attempt, the reproduced
> registry-string recovery defect, its fix, and the remaining RunOnce blocker.

Date: 2026-08-24  
Branch: `bd-debug`  
HEAD: `ca2472315c9ea88e7f1b5ef3993796e65bc6d038`  
Host: Windows 10 IoT Enterprise LTSC 19044  
Host ZEON, host system proxy, VPN/TUN/WFP, certificate stores, and backend infrastructure: **not changed**

> The VM attempt was stopped on 2026-08-25 after Windows Setup failed to reach
> a clean desktop. No prepared or unit-tested scenario is recorded as a VM
> PASS, and ZEON was never installed or launched in the guest.

## A. VM

- Hyper-V management was not already available without feature-state changes or a host reboot, so it was not enabled.
- Portable QEMU 11.1.0 was selected. It uses user-mode NAT only and installed no host driver, service, or network adapter.
- WHPX probes reproducibly stalled while loading Windows PE. The persistent VM therefore uses TCG and is slow but continues to execute and perform disk I/O.
- Guest source: official Windows 11 Enterprise Evaluation 25H2 x64 ISO, SHA-256 `A61ADEAB895EF5A4DB436E0A7011C92A2FF17BB0357F58B13BBC4062E535E7B9`.
- The guest reported Windows build `10.0.26200.6584` from the Setup console.
- Setup reached 42%, then the QEMU process exited without a QEMU stderr entry.
  On the next boot Windows reported an unexpected restart. `setuperr.log`
  contained compatibility/settings-endpoint and BitLocker auto-unlock errors;
  the latest `setupact.log` entries showed successful AppX pre-registration.
- The interrupted `ChildCompletion\\setup.exe` value was `0x1`. After setting
  it to `0x3`, Setup continued from 42% through 95% and entered OOBE.
- OOBE then looped on `Why did my PC restart?`. Its network selector was empty
  with the QEMU `e1000e` device, so the requested recovery update could not be
  proven to have network access. A restart with `rtl8139` was prepared, but the
  attempt was stopped before that path could be validated.
- A clean desktop was never reached, so the `clean-windows` checkpoint was not
  created. The failed qcow2, plaintext answer files, screenshots, and source
  Windows ISO were deleted after the attempt. The verified ZEON payload ISO was
  preserved separately with SHA-256
  `199B2D42E675FC5984F2E9B0430C432ABFE23C7FBEB77D6B50A2CB2D965D4FEE`.
- QEMU used user-mode NAT only. Host ZEON and host networking were not changed.

## B. Old proxy fix history

- `a56d806c7a180046c27c17bf51d66a3139e00414` (2026-06-19) added unconditional `DisableSystemProxy()` calls at runner create/destroy and `WM_ENDSESSION`.
- That prevented a dead localhost proxy, but it always forced `PROXY_TYPE_DIRECT` and therefore destroyed any pre-existing user/corporate proxy or PAC state.
- `d1bc9bc79362d7a0ad20a32b5b8a7b62894990b9` (2026-07-30) removed that mechanism to preserve unowned proxy state.
- No ownership-aware replacement was added, so a core crash or interrupted shutdown could again leave the persistent WinINet proxy pointing at a dead ZEON loopback port.
- The old commit was not cherry-picked.

## C. Root cause

`set_system_proxy` starts the mixed listener and persistently changes the current user's WinINet LAN proxy to `http://127.0.0.1:<mixed-port>`. A normal listener close restores proxy state, but abrupt process termination or interrupted Windows shutdown skips that asynchronous core close. Windows retains the loopback proxy after process death/reboot, no process listens on the old port, and applications using WinINet/system proxy lose network access.

## D. Fix

- Before changing WinINet, the core captures flags, proxy server, bypass list, and PAC URL.
- It writes an HKCU ownership record containing the exact expected ZEON state, baseline, PID plus creation time, executable, port, and random non-zero generation.
- Marker persistence is a two-phase commit: `Armed=0`, all fields, then `Armed=1`.
- A per-user RunOnce recovery command is armed before WinINet is changed.
- Normal core close restores only when the current state exactly equals the recorded expected ZEON state.
- The runner performs recovery before Flutter/bootstrap and synchronously on current-process window teardown/`WM_ENDSESSION`.
- Recovery keeps a live recorded owner, rejects invalid/non-IPv4-loopback markers, and preserves changed user/corporate state.
- Generation binding prevents an old listener's delayed close from disarming/restoring a replacement listener's state.
- The uninstaller runs ownership-aware recovery before deleting the executable.

## E. VM fresh-install

**BLOCKED before ZEON installation.** Windows Setup/OOBE did not reach a clean
desktop. ZEON was never installed or launched, so bootstrap, profile import,
HTTP, WebSocket, bind, local proxy, system proxy, and TUN have no VM result.

## F. Reboot matrix

| Scenario | Internet before | After reboot before ZEON launch | Proxy state | Result |
| --- | --- | --- | --- | --- |
| Clean baseline | Not reached | Not reached | Not captured | NOT TESTED |
| System proxy active | Not reached | Not reached | Not reached | NOT TESTED |
| ZEON killed while system proxy active | Not reached | Not reached | Not reached | NOT TESTED |
| Mixed port A to B | Not reached | Not reached | Not reached | NOT TESTED |
| Existing user proxy baseline | Not reached | Not reached | Not reached | NOT TESTED |
| PAC baseline | Not reached | Not reached | Not reached | NOT TESTED |
| Foreign localhost proxy state | Not reached | Not reached | Not reached | NOT TESTED |

## G. Proxy, PAC, and TLS

Not tested: the guest did not reach a usable desktop and ZEON was not installed.

## H. `/ws/bind`

Not tested: ZEON was not installed and `/ws/bind` was not executed in the VM.

## I. Defender and firewall

Defender remained part of the default Windows image, but no ZEON binary was
installed or scanned. Firewall/application behavior is therefore **NOT TESTED**.

## J. Update and uninstall

Not tested: ZEON was never installed.

## K. Tests and build

- Full Flutter suite after the latest production ownership change, with the real native WinHTTP DLL: **491 passed, 0 failed, 0 skipped**.
- Targeted Windows/network/WebSocket/bootstrap/TUN suite before the final ownership-only hardening: **79 passed, 0 failed, 0 skipped**; final rerun pending.
- Windows proxy Go characterization executable: **4 passed**.
- Native WinHTTP DLL and system-proxy recovery compile with MSVC `/W4 /WX`: **PASS**.
- System-proxy recovery PowerShell self-test: **PASS**.
- Changed-file analyzer: **0 errors, 0 warnings, 37 informational lints**.
- No production code changed after the recorded 491-test full-suite pass.
- The VM-only harness gained quoted QMP text input and selectable QEMU NIC
  models while diagnosing Setup; no final suite was required for those scripts.
- Post-VM application scenarios and a new production build were not run because
  the guest never reached the ZEON installation stage.
- VM-only unsigned installer 1.4.2: SHA-256 `15676FA7F76F9B07A389D9674458D7781B250E67FACEA67A9D4C8BBD2728720C`.

## L. Remaining blockers

- Clean Windows Setup/OOBE must be completed in a different VM environment or
  with a validated QEMU NIC before any ZEON fresh-install claim is possible.
- All application, reboot, crash, proxy/PAC/TLS, bind, Defender, update,
  uninstall, and TUN VM scenarios remain unexecuted.
- Production signing remains unavailable and is not claimed.

## M. Release readiness

- Fresh-install Windows VM: **FAIL** (guest Setup/OOBE blocker before ZEON)
- Bootstrap: **NOT TESTED**
- HTTP system proxy: **NOT TESTED**
- PAC/WPAD: **NOT TESTED**
- TLS inspection: **NOT TESTED**
- Windows WebSocket: **NOT TESTED in VM**
- `/ws/bind` idle/reconnect: **NOT TESTED**
- System-proxy normal exit cleanup: **NOT TESTED**
- System-proxy reboot recovery: **NOT TESTED**
- System-proxy crash recovery: **NOT TESTED**
- Existing user proxy restoration: **NOT TESTED**
- TUN: **NOT TESTED**
- Defender/firewall: **NOT TESTED**
- Update: **NOT TESTED**
- Uninstall cleanup: **NOT TESTED**
- Windows 11: **NOT TESTED for ZEON**
- signing pipeline: **READY**
- signed release: **NOT VERIFIED**
- safe for Windows canary: **NO**
