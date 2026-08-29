# ZEON Windows firewall and security compatibility report

Date: 2026-08-29
Branch: `bd-debug`
Source HEAD at start of this pass: `ac0298511118d2946a45d442dd2353f07e0be093`
Host firewall, Defender, proxy, VPN, TUN and certificate stores: **not changed**

## A. New results

- Windows networking process/listener map: **VERIFIED on Windows 10**;
- Windows 10 Defender + default Firewall, Private profile: **PASS**;
- Windows 10 Defender + default Firewall, Public profile: **PASS**;
- Windows 11 Defender + Firewall E2E: **BLOCKED -- no bootable Windows 11 media/image exists in the lab**;
- Windows Defender Firewall prompt: **NOT OBSERVED** during install, first launch, bootstrap, connect, disconnect or reconnect;
- executable causing a Windows security prompt: the unsigned installer, not `ZEON.exe`; with Internet-zone metadata it produced a Microsoft Defender SmartScreen `Unknown Publisher` dialog;
- actual default-Firewall block: **NOT FOUND**;
- explicit outbound block: **REPRODUCED** with one temporary exact-program rule and confirmed by `pfirewall.log` `DROP ... SEND` records;
- fresh install without Firewall/Defender exclusions: bootstrap, profile and Private/Public connect **PASS**;
- `/ws/bind` on a clean LTSC guest exposed a non-Firewall packaging defect: the shipped native transport could not load because its MSVC 14.44 dependencies were paired with 14.34 runtime DLLs;
- minimal source fix: the small WinHTTP transport is now linked with the static MSVC runtime; the fixed DLL depends only on `WINHTTP.dll` and `KERNEL32.dll` and passed real Private and Public WSS flows;
- ZEON Firewall allow rule required: **NO**.

The default Windows Firewall is not the source of the observed user-facing
failure. The two real security/compatibility layers were unsigned-publisher
reputation UI and the native transport runtime mismatch.

## B. Windows networking process and listener map

Connected Win10 process inventory contained one application process:

| Process | Image | Responsibility |
| --- | --- | --- |
| `ZEON.exe`, observed PID 5948 | `C:\Users\e2eadmin\AppData\Local\Programs\ZEON\ZEON.exe` | Flutter UI, in-process hiddify core, control-plane HTTP/WSS and local proxy ownership |

No separate `ZEONCli.exe`, proxy daemon or core child process was present in
the connected snapshot. `hiddify-core.dll` and
`zeon_windows_transport.dll` were loaded/invoked by `ZEON.exe`.

| Protocol/local address | Observed port | Owner | Exposure interpretation |
| --- | ---: | --- | --- |
| TCP `127.0.0.1` | 12334 | `ZEON.exe` | loopback HTTP mixed proxy |
| TCP `127.0.0.1` | 12337 | `ZEON.exe` | loopback core service |
| TCP `127.0.0.1` | 16756 | `ZEON.exe` | loopback application/core control |
| TCP `127.0.0.1` | 51694 | `ZEON.exe` | dynamic loopback management listener |
| UDP `127.0.0.1` | 12337 | `ZEON.exe` | loopback core endpoint |
| UDP `0.0.0.0` | 57054 | `ZEON.exe` | ephemeral outbound socket, not a stable advertised service |
| TCP `0.0.0.0` | none | -- | no wildcard TCP listener |
| TCP/UDP `::1` | none | -- | no IPv6 loopback listener observed |
| TCP/UDP `::` | none | -- | no IPv6 wildcard listener observed |

The connected process also owned outbound established connections from guest
`10.0.2.15` to remote TCP 443/8443 endpoints. Windows system proxy state was
`ProxyEnable=1`, `ProxyServer=http://127.0.0.1:12334` only while the live local
core owned the loopback service.

## C. Default Win10 security baseline

Guest: Windows 10 Enterprise LTSC 2021 Evaluation, build 19044, QEMU TCG,
rtl8139 user-mode NAT. The base image was preserved; all work used disposable
overlay
`C:\Temp\zeon-firewall-win10-20260828\win10-firewall-overlay.qcow2`.

All three Firewall profiles reported:

- state: `ON`;
- policy: `BlockInbound,AllowOutbound`;
- inbound user notification: enabled;
- dropped/allowed connection logging: disabled by default.

Before install and again after install, `netsh` found no `ZEON` or `Hiddify`
Firewall rule. No manual allow rule or Defender exclusion was created.

Defender evidence after all Win10 tests:

- antimalware, antivirus, antispyware, real-time protection, behavior monitor,
  IOAV and network inspection: enabled;
- Defender platform: `4.18.26070.9`;
- signature version: `1.457.393.0`, updated 2026-08-29 06:54:13 guest time;
- threat detections since test start: **0**;
- ZEON/Hiddify exclusions: none found.

## D. Win10 Private profile E2E

An earlier installation belonging to another test account first caused the
installer to target
`C:\Users\zeonadmin\AppData\Local\Programs\ZEON\ZEON.exe`, then fail with
`CreateProcess failed; code 5. Access is denied`. This was stale cross-account
installer state, not Firewall. The exact old uninstaller was run inside the
disposable guest and the current-user install state was verified clean before
the actual fresh-install run.

Fresh current-user installation then used
`C:\Users\e2eadmin\AppData\Local\Programs\ZEON` and, with no manual security
exceptions:

- install: PASS;
- first launch: PASS;
- bootstrap through `https://api.zeon-vps.online`: PASS;
- profile `MERRY FROST 638`: PASS;
- connect on Private profile: PASS, UI `Connected`, 128 ms;
- system proxy activation with live core: PASS;
- disconnect UI: PASS;
- Windows Defender Firewall prompt: none;
- Defender detection/quarantine: none.

Private-profile UI evidence is preserved at
`C:\Temp\zeon-firewall-win10-20260828\connect-private-current.png`.

### Native WSS finding

The installed `zeon_windows_transport.dll` had SHA-256
`35AC9848EA276A514AD21EC208B9D44A715D5D3122A9911F0E02C39864142B51`.
The current harness failed before networking with Win32 loader error 126:

`Failed to load dynamic library ... zeon_windows_transport.dll: The specified module could not be found.`

Dependency inspection showed that the transport required `MSVCP140.dll`,
`VCRUNTIME140.dll` and `VCRUNTIME140_1.dll`; the installed copies were version
14.34.31938 while the transport was built by MSVC 14.44. This is a release
payload/runtime mismatch. It is not a Firewall rejection.

After the static-runtime fix, the same real Win10 guest and endpoint completed:

- WSS connect/upgrade: PASS;
- idle connection: PASS;
- event receive and confirmed status: PASS;
- normal close: PASS.

## E. Win10 Public profile E2E

The existing Ethernet connection was changed from Private to Public using
`Set-NetConnectionProfile`; default Firewall remained
`BlockInbound,AllowOutbound`.

- application launch/profile load: PASS;
- connect: PASS, UI `Connected`, 118 ms;
- data transfer: observed;
- no Firewall prompt and no generated ZEON/Hiddify rule;
- fixed native `/ws/bind`: connect, idle, event, confirm and close PASS;
- direct HTTPS health after recovery: HTTP 200.

Public-profile UI evidence is preserved at
`C:\Temp\zeon-firewall-win10-20260828\public-connect.png`.
The guest was returned to Private before shutdown.

## F. Explicit outbound-block reproduction

One temporary rule was added only in the disposable guest:

`ZEON E2E temporary outbound block`

Its scope was exact program
`C:\Users\e2eadmin\AppData\Local\Programs\ZEON\ZEON.exe`, direction outbound,
action block, all profiles. Dropped-connection logging was enabled only for the
test.

Result:

- ZEON connect failed and displayed a core/control-channel failure;
- `pfirewall.log` recorded real outbound `DROP ... SEND` rows for DNS, remote
  VPN endpoints and `130.49.151.173:443`;
- this proves how an actual Firewall block differs from the default-profile
  behavior;
- Security event 5157 was not available because packet-filter auditing was not
  enabled; the Firewall text log is the authoritative evidence for this run.

After reproduction:

- the exact rule was deleted and verified absent;
- dropped logging was returned to disabled for all profiles;
- direct HTTPS health returned HTTP 200;
- the fixed Public-profile WSS harness returned PASS;
- `ProxyEnable` was restored to 0 by the shipped ownership-aware recovery
  entry point;
- no test file or test Firewall rule remains in the overlay.

The installed 1.4.2 payload did retain a stale core-generation failure after
the forced process termination used in the destructive block scenario. Its UI
alternated between a gRPC deadline and background-control startup failure even
after network recovery. Because direct HTTPS and native WSS both passed and no
block rule remained, that residual state is a core lifecycle/recovery issue,
not a Firewall block. It does not invalidate the clean default-Firewall
Private/Public passes, but it should receive a separate lifecycle regression
test before a release is cut.

## G. Defender, publisher and SmartScreen evidence

The installed `ZEON.exe`, `hiddify-core.dll` and native transport were
unsigned. The installer launched from CD/DVD origin showed `Publisher:
Unknown`; no Defender Firewall access dialog appeared.

For a controlled reputation test, a disposable copy of the same installer was
given an NTFS `Zone.Identifier` with `ZoneId=3` and opened without installing.
Windows displayed:

- `SmartScreen can't be reached right now`;
- `Publisher: Unknown Publisher`;
- explicit `Run` / `Don't Run` controls.

The test selected `Don't Run` and removed the copy. Screenshot:
`C:\Temp\zeon-firewall-win10-20260828\smartscreen-result.png`.

This is the most likely Windows UI that a user could describe as “firewall
blocking ZEON”. It is SmartScreen/reputation plus missing Authenticode, not
Defender Firewall. The “can't be reached” state is also not evidence that ZEON
itself was blocked: a simultaneous direct domain health check returned 200.

## H. Root cause and minimal fix

### Root cause

1. Standard Firewall did not block ZEON. Its stable TCP services are loopback
   only and the default profiles allow outbound traffic.
2. The visible Windows security friction is the unsigned installer/application
   reputation path (`Unknown Publisher`, SmartScreen).
3. The clean LTSC WSS defect was an MSVC runtime packaging mismatch.
4. A deliberately configured exact-program outbound deny blocks ZEON as
   expected; an application-created allow rule cannot override an administrator
   block rule because block rules take precedence.

### Minimal implemented source fix

`windows/CMakeLists.txt` now enables CMake policy `CMP0091`, and
`windows/transport/CMakeLists.txt` selects the static MSVC runtime only for
`zeon_windows_transport`.

The rebuilt DLL SHA-256 is
`399D5623DBF88F619E12F219F8DD9B913235817EBBBC285BD57A43D4C873F246`.
`dumpbin /dependents` now lists only:

- `WINHTTP.dll`;
- `KERNEL32.dll`.

The WinHTTP transport still compiles with `/W4 /WX`, CFG, CET, ASLR and DEP
linker options. The real Win10 Private and Public WSS tests passed with this
binary.

The WSS guest harness now emits a bounded loader diagnostic without request
headers, tokens, URLs or payload data. The WinRM lab helper gained explicit
NTLM selection required by this preserved guest; credentials remain DPAPI
stored and were not written to source/report/logs.

### Is a ZEON Firewall rule required?

**NO.** An inbound allow rule would not help outbound control/VPN traffic,
would unnecessarily broaden exposure, and is not needed for loopback-only TCP
listeners. A blanket outbound allow rule would be misleading and cannot
override enterprise/admin block policy.

For an enterprise `BlockOutbound` policy, the correct deployment action is an
administrator-managed allow policy for the signed `ZEON.exe` and the approved
destinations/protocols. ZEON should diagnose that policy and fail clearly; it
should not silently weaken it.

## I. Disconnect and reboot recovery

- normal UI disconnect returned to `Tap to connect`;
- after a reset from an active-proxy state and a real interactive sign-in,
  `ProxyEnable=0` and no ZEON process remained;
- the exact shipped command
  `ZEON.exe --recover-system-proxy` independently restored a deliberately dead
  owned proxy, removed the ownership marker and removed its RunOnce value;
- host-independent direct guest HTTPS after cleanup: HTTP 200;
- final guest state before shutdown: proxy disabled, temporary Firewall rule
  absent, Firewall logging restored, network profile Private.

Shutdown was requested through Windows, but the guest remained in Windows
Update finalization at `Getting Windows ready / Don't turn off your computer`
when this report was closed. QEMU was deliberately not force-terminated; this
is post-test lab cleanup, not a Firewall or ZEON test failure. The host ZEON
process, host proxy/network, host Firewall and host Defender were never
changed.

## J. Windows 11 blocker

Windows 11 was not substituted with unit tests or the Win10 guest.

The only Win11-named disks found were uninstalled sparse qcow2 containers:

| Path group | Allocated size | Virtual size | Bootable installed OS |
| --- | ---: | ---: | --- |
| `prepare-selftest/windows-11-e2e` | 197,632 bytes | 50 GiB | NO |
| `whpx-fresh/windows-11-e2e.qcow2` | 393,216 bytes | 50 GiB | NO |
| `windows-11-whpx-probe/windows-11-e2e.qcow2` | 393,216 bytes | 50 GiB | NO |

Their small `answer.iso` files are unattended-answer media, not Windows setup
media. No Windows 11 ISO larger than 1 GiB exists in the VM lab, Downloads,
Desktop or Documents. The only OS ISO found is the Win10 LTSC ISO. At final
inventory the B: drive had 1.99 GiB free and C: had 6.67 GiB free, insufficient
for a safe Windows 11 ISO plus installation/overlay growth.

Exact requirement to continue Win11 E2E: provide a bootable Windows 11 x64 ISO
or an already installed clean Win11 qcow2 and enough free storage for a
disposable overlay. No SSH credential, server access or source change can
remove this local-device blocker.

## K. Verification after the last source change

- native transport Release build: PASS;
- generated MSBuild runtime policy: `MultiThreaded` for Release/Profile and
  `MultiThreadedDebug` for Debug;
- native DLL dependencies reduced to WinHTTP/Kernel32: PASS;
- real Win10 guest `/ws/bind`, Private: PASS;
- real Win10 guest `/ws/bind`, Public: PASS;
- native WinHTTP WebSocket suite with the real fixed DLL: 24 PASS;
- Windows network/bootstrap/home-proxy targeted suite: 32 PASS, 24 native tests
  initially skipped before the DLL was supplied; the same 24 then passed above;
- native system-proxy decision and registry tests: PASS;
- Windows signing policy self-test: PASS;
- harness `dart analyze`: 0 issues;
- `git diff --check`: PASS, with the pre-existing PowerShell LF/CRLF notice.

A full main-workspace Windows bundle was not relinked because the user's running
host `ZEON.exe` owns the existing Release output and was deliberately not
stopped. Therefore a newly packaged installer containing the static-runtime
DLL remains a release-build follow-up, not a claimed completed artifact.

## L. Final Win10/Win11 matrix

| Check | Windows 10 Private | Windows 10 Public | Windows 11 |
| --- | --- | --- | --- |
| Defender real-time enabled | PASS | PASS | BLOCKED: no OS image |
| Firewall default policy | ON, BlockInbound/AllowOutbound | ON, BlockInbound/AllowOutbound | BLOCKED |
| Fresh install, no manual exclusions | PASS | same clean install | BLOCKED |
| Bootstrap/profile | PASS | PASS | BLOCKED |
| Application connect | PASS, 128 ms | PASS, 118 ms | BLOCKED |
| Native WSS with shipped DLL | FAIL: loader 126, non-Firewall | same shipped payload risk | BLOCKED |
| Native WSS with minimal fix | PASS | PASS | BLOCKED |
| Firewall prompt | none | none | BLOCKED |
| Defender detection | none | none | BLOCKED |
| Explicit outbound deny | reproduced; expected failure | reproduced rule covered all profiles | BLOCKED |
| Rule removal / direct network recovery | PASS | PASS | BLOCKED |
| Reboot proxy recovery | PASS | PASS/shared user state | BLOCKED |
| ZEON Firewall rule needed | NO | NO | not determined on device |

Release conclusion:

- standard Windows Firewall compatibility on Win10: **PASS**;
- static native transport fix: **validated, not yet packaged into a new signed installer**;
- Windows 11 Firewall/Defender compatibility: **NOT TESTED -- exact media/storage blocker**;
- Windows signed/reputation-clean release: **NOT VERIFIED**;
- broad Windows rollout: **NOT READY** until Win11 E2E and a signed packaged
  release containing the fixed transport pass.

## M. Short control-plane regression

After Firewall cleanup, strict HTTPS to
`https://api.zeon-vps.online/health` returned HTTP 200 and both Private/Public
native WSS bind flows passed. No server, RULESETS, managed-routing, Android,
admin or production DB component was changed in this firewall-security pass.
