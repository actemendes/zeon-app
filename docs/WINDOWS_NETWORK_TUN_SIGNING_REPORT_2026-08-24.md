# Windows network, bootstrap, TUN/WFP and signing final report

Date: 2026-08-24  
Branch: `bd-debug`  
Base/current HEAD: `ca2472315c9ea88e7f1b5ef3993796e65bc6d038`  
Host validation: Windows 10 IoT Enterprise LTSC 19044  
Installation, execution of the built app, VPN/TUN/WFP/system-proxy mutation, and production deployment: **not performed**

## A. What was incomplete before this pass

- The full Flutter suite had not been run after the latest proxy-auth change.
- Synchronous WinHTTP FFI calls could block the Flutter UI isolate during proxy/PAC resolution, DNS/connect, TLS, authentication, or response reads.
- Windows HTTP used system networking while `/ws/bind` still silently used Dart `HttpClient`, so proxy/PAC/trust behavior diverged.
- Proxy/PAC/auth/TLS behavior lacked isolated Windows integration coverage.
- Mixed-port readiness accepted too little protocol evidence.
- Bootstrap retry/fallback and saved `conn_link` failure policy needed explicit bounded tests.
- TUN diagnostics lacked a read-only BFE state and the future helper ownership/IPC contract was unspecified.
- Signing checks did not prove timestamp/signer consistency for nested payloads, and CI could sign after archive/manifest creation.

## B. What was fixed now

- Windows system HTTP uses WinHTTP automatic proxy mode, the Windows trust store, integrated proxy auth, structured failures, and a worker isolate. Missing native transport now fails closed instead of falling back to Dart `DIRECT`.
- Explicit route precedence is enforced on Windows: conflicting flags error; `proxyOnly`; `directOnly`; control-plane policy; adaptive policy.
- Local mixed readiness requires canonical IPv4 loopback, current-process listener ownership, and a valid SOCKS5 no-auth negotiation response.
- Bootstrap receives a single UI-ready retry only after a transport failure. HTTP/server/validation failures do not schedule it. A saved `conn_link` transport failure may continue to the existing lookup/create path on Windows.
- WebSocket callers use a route abstraction. Local-ZEON WebSockets retain the existing Dart implementation; Windows system-network WebSockets fail closed until an asynchronous native WinHTTP WebSocket backend exists.
- TUN failure records now include elevation, stage, exact HRESULT/derived Win32 code, and read-only BFE state. Dart still never enumerates or deletes WFP filters.
- Windows packaging now signs recursive EXE/DLL payloads before EXE/MSIX/portable ZIP creation, timestamp-signs final EXE/MSIX, verifies nested archive payloads, enforces a single signer thumbprint, and hashes only final artifacts. The release workflow supplies signing inputs to this fail-closed packager and no longer re-signs files after manifest generation.

Root causes were conflation of ZEON proxy/system network/forced direct, weak startup state assumptions, blocking synchronous native networking on the UI isolate, an incompatible WebSocket fallback, insufficient mixed-inbound proof, and signing performed too late in the packaging sequence.

## C. WinHTTP execution model

`WinHttpOpen`, automatic proxy/PAC resolution, `WinHttpConnect`, `WinHttpSendRequest`, `WinHttpReceiveResponse`, TLS negotiation, `WinHttpQueryAuthSchemes`/credential retry, and every `WinHttpReadData` run synchronously **inside a dedicated worker isolate**, never on the Flutter UI isolate.

The UI waits with `Future.any` for worker result, worker error, cancellation, or an outer watchdog. `WinHttpSetTimeouts` applies the request timeout separately to resolve/connect/send/receive. The outer watchdog is the phase timeout plus 10% grace clamped to 250–1500 ms and returns structured WinHTTP timeout code 12002. Cancellation kills the Dart worker immediately from the caller's perspective; an already-entered native synchronous call may continue only until its native phase timeout, without blocking UI progress. Handles are owned and closed by the worker lifecycle.

Covered: slow server with UI heartbeat, response timeout, connect/receive classification, cancellation during blocked receive, no deadlock, and five sequential isolated requests.

## D. WebSocket

Final Windows routing is explicit, but the production Windows system-network WebSocket backend is **not implemented**. `createWindowsSystemWebSocketTransport()` returns no backend and system-network `/ws/bind` fails closed with a structured unavailable error. It no longer silently bypasses Windows proxy/PAC semantics through Dart `DIRECT`.

This is deliberate: synchronous WinHTTP WebSocket receive plus concurrent close/cancellation would violate the documented handle concurrency contract. A safe implementation needs asynchronous WinHTTP status callbacks, a native receive/send state machine, bounded shutdown, and serialized close. Targeted tests cover route selection, injected system transport, `directOnly`, `proxyOnly` no-fallback, structured TLS failure, and idempotent close. Non-Windows WebSocket behavior was not changed.

References:

- https://learn.microsoft.com/windows/win32/api/winhttp/nf-winhttp-winhttpwebsocketcompleteupgrade
- https://learn.microsoft.com/windows/win32/api/winhttp/nf-winhttp-winhttpwebsocketreceive
- https://learn.microsoft.com/windows/win32/winhttp/concurrency-in-winhttp
- https://learn.microsoft.com/windows/win32/api/winhttp/nf-winhttp-winhttpclosehandle

## E. Bootstrap and final routing/retry state machine

Routing order on Windows:

1. `directOnly && proxyOnly` -> `ArgumentError`, no request.
2. `proxyOnly` -> only `127.0.0.1:<mixed-port>` after ownership plus SOCKS5 readiness; never system/direct fallback or VPN recovery.
3. `directOnly` -> Windows system networking; never local ZEON recovery.
4. Control-plane policy -> adaptive route.
5. Ordinary adaptive route.

Adaptive matrix:

| VPN state | ZEON mixed readiness | Result |
|---|---|---|
| `false` | any | Windows system network |
| `null` | not probed/trusted | Windows system network |
| `true` | ready and owned | local ZEON proxy |
| `true` | dead/foreign/not SOCKS5 | `VpnProxyUnavailableException`, no silent fallback |

Bootstrap sequence: active real profile stops blocking import; otherwise try saved `conn_link`; only a Windows transport failure continues to saved-user lookup -> create/reuse -> second lookup if needed -> import. Standard startup requests are `directOnly`/system-network; post-connection requests are `proxyOnly`. A startup transport failure arms one UI-ready retry; success, HTTP response, server error, or validation failure does not. The retry token is consumed at most once, so no loop exists.

## F. Tests

- Final full repository suite on the final Dart tree: **467 passed, 0 failed, 0 skipped**.
- Final targeted Windows/network/bootstrap/TUN suite: **56 passed, 0 failed, 0 skipped**.
- PowerShell parser: **PASS** for packager, wrapper, and signing self-test.
- Signing policy self-test: **PASS**.
- GNU Make was unavailable on this host; the Windows Makefile release route was checked by the signing self-test but not executed.
- Changed-file `dart analyze`: no errors/warnings; informational style/FFI lints only.
- `git diff --check`: PASS, apart from Git's LF-to-CRLF notice for existing PowerShell working-copy settings.

An interim targeted run failed after the new HTTP fail-closed guard because a legacy redirect test did not pin its intended non-Windows transport. The fixture was corrected with `isWindows: false`; this was a regression introduced in this pass, not a pre-existing product failure. A local TLS test also exposed a zero-code handshake classification edge; it now preserves stage `tls` without inventing a Win32 value.

Isolated scenarios actually exercised: local WinHTTP HTTP, slow response, cancellation, sequential calls, named HTTP proxy, unreachable proxy/no fallback, HTTP 407, Negotiate/NTLM selection and one app-level auth retry, untrusted TLS certificate rejection, TLS error-code classification, same-process SOCKS5 readiness, unrelated same-process listener rejection, foreign PID rejection, IPv4-only loopback, port-close race, route matrix for connected/disconnected/unknown, bootstrap retry classes, and BFE read-only mapping.

Not reproduced on this host: live PAC/WPAD discovery, enterprise Negotiate/NTLM/Kerberos proxy, trusted enterprise TLS inspection root, independent trusted-root PASS, independent hostname-mismatch and expired-certificate handshakes, Windows 11, SmartScreen, TUN transitions, and fresh-install E2E. Known WinHTTP certificate error codes for invalid date/name/CA/secure failure are unit-classified as TLS, but that is not reported as live PASS.

## G. Build

`flutter build windows --release --target lib/main_prod.dart`: **PASS** on the final Dart code, 276.4 s, in an isolated copy.

Static artifact check only: `ZEON.exe`, 94,720 bytes, SHA-256 `E1970C054B477DE05EDA3C22BE5041CB5A103AB0405B3A9B5A4DD2C84CE13C99`; 20 EXE/DLL files in the release payload; raw Flutter artifact status `NotSigned`, expected because no production certificate was available and the packaging/signing command was intentionally not run. The executable was never launched or installed. The isolated copy was removed afterward.

## H. Remaining blockers

- Windows 11 validation: not available.
- Live PAC/WPAD and system proxy: VM/corporate lab gate.
- Real enterprise proxy authentication: VM/domain lab gate.
- Trusted TLS inspection root: VM with controlled Windows trust store; the host trust store was not changed.
- Actual signed release and certificate chain/timestamp: not generated; production certificate and `signtool.exe` release environment required.
- SmartScreen/reputation: not tested.
- Windows system-network WebSocket: native asynchronous backend still required.
- TUN/helper/service: not implemented; exact future contract is in `WINDOWS_NATIVE_CORE_HELPER_CONTRACT.md`.
- Fresh-install E2E VM and real non-admin helper flow: not run.

## I. Files and scoped diff

Pure task-owned new files:

- `lib/core/http_client/adaptive_websocket.dart`
- `lib/core/http_client/local_zeon_proxy_readiness.dart`
- `lib/core/http_client/windows_network_diagnostics.dart`
- `lib/core/http_client/windows_system_http_transport.dart`
- `lib/utils/windows_tun_diagnostics.dart`
- `test/core/http_client/windows_network_transport_test.dart`
- `test/features/mobile/data/windows_bootstrap_retry_test.dart`
- `test/utils/windows_tun_diagnostics_test.dart`
- `scripts/tests/windows_signing_policy.test.ps1`
- `docs/WINDOWS_NATIVE_CORE_HELPER_CONTRACT.md`
- this report

Scoped tracked files, some of which already contained user edits and therefore require hunk-level review before staging:

- `lib/core/http_client/dio_http_client.dart`
- `lib/core/http_client/http_client_provider.dart`
- `lib/features/connection/widget/connection_wrapper.dart`
- `lib/features/mobile/data/mobile_bind_service.dart`
- `lib/features/mobile/data/mobile_bootstrap_import_service.dart`
- `lib/features/mobile/data/mobile_conn_link_import_service.dart`
- `lib/features/notifications/service/notifications_background.dart`
- `lib/features/profile/data/profile_parser.dart`
- `lib/zeoncore/zeon_core_service.dart`
- `test/core/http_client/dio_http_client_redirect_user_agent_test.dart`
- `test/core/http_client/mobile_api_proxy_route_test.dart`
- `scripts/package_windows_installers.ps1`
- `scripts/package_windows.ps1`
- `Makefile`
- `.github/workflows/build.yml`

No Android/iOS source was changed. The protected endpoint/API/domain/control-plane rules were not changed; added-line guard passed. No commit was created because the tree was dirty before this work and several tracked files contain inseparable pre-existing hunks. Current HEAD remains `ca2472315c9e`; commit SHA for this pass: **none**.

## J. Release readiness

- Windows bootstrap/API networking: **READY**
- Windows HTTP system proxy/TLS: **NEEDS VM VALIDATION**
- Windows WebSocket: **NOT READY**
- TUN/WFP diagnostics: **READY**
- TUN helper/service: **NOT IMPLEMENTED**
- signing pipeline: **READY** (static/parser/self-test; production certificate execution pending)
- actual signed release: **NOT VERIFIED**
- safe for VM/canary installation: **NO** (known Windows system WebSocket gap and no actual signed payload)
