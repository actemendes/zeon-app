# Windows startup profile TLS failure — root-cause report

Date: 2026-09-02
Scope: ZEON Windows client, current `dev-ios` source at `95c43cef`, installed/running client `1.4.1 (104011)`
Safety: no production/backend/deploy changes; TLS verification was never disabled; subscription secrets are redacted.

## Executive conclusion

The observed `WindowsSystemNetworkException(operation=send, stage=tls, win32=12175, hresult=0x80072f8f)` is caused by the active persisted profile still using the legacy HTTPS host `130.49.151.173`. That server currently presents a certificate whose only SAN is `DNS:api.zeon-vps.online`; it has no IP SAN. Windows therefore rejects a request addressed to the IP with a certificate-name mismatch.

This was reproduced through ZEON's actual WinHTTP transport with an explicit direct route:

```text
https://api.zeon-vps.online/health -> HTTP 200
https://130.49.151.173/health      -> operation=send, stage=tls,
                                      win32=12175, hresult=0x80072f8f
```

DNS, TCP reachability, the certificate chain, certificate dates, IPv6, system clock, and proxy routing do not explain this exact failure. The same IP and TCP endpoint succeeds when the TLS hostname is `api.zeon-vps.online` and fails when the TLS hostname is the IP.

The online refresh failure does **not** delete or overwrite the last valid profile/config. Current source can start the core from that cached config independently of refresh, so a hard `profile -> VPN -> profile` dependency loop is not present. Two secondary defects make the incident look like such a loop:

1. a legacy-IP fallback is enabled only when `proxyOnly == true`, which normally means the VPN is already connected;
2. the global `profiles_update_check` timestamp is stored even after a failed refresh, delaying the next automatic attempt.

An older released build can additionally leave Windows System Proxy pointing at a dead local port across reboot. That is a separate cold-start defect and does not produce the proven certificate-name failure; the current source already contains ownership-aware startup recovery for it.

## A. Reproduction

Observed/reconstructed startup state:

```text
cold Windows boot
-> ZEON starts, VPN OFF
-> active cached remote profile exists
-> stored subscription host = 130.49.151.173 (path/secret redacted)
-> foreground periodic scheduler runs its first due task immediately
-> profile download selects Windows system networking
-> WinHttpSendRequest performs TLS validation
-> 12175 / 0x80072f8f
```

The machine was not rebooted during this investigation because doing so would disrupt the user's session. The exact failing network operation was instead reproduced deterministically with `scripts/diagnostics/windows_bootstrap_tls_probe.dart`, using ZEON's production WinHTTP implementation and `WindowsProxyMode.direct`. This removes boot timing, PAC, WPAD, system proxy, and the VPN from the experiment while preserving the failing transport/TLS path.

Strict independent checks produced the same distinction:

- Windows curl/Schannel to the domain: HTTP 200;
- curl to the legacy IP: `SEC_E_WRONG_PRINCIPAL (0x80090322)`;
- .NET `SslStream` to the IP: `RemoteCertificateNameMismatch`;
- .NET `SslStream` to the domain forced to the same IP: validation succeeds.

## B. Request path

```text
App.build
  lib/features/app/widget/app.dart:84
-> foregroundProfilesUpdateNotifierProvider
  lib/features/profile/notifier/profiles_update_notifier.dart:34-64
-> NeatPeriodicTaskScheduler.start()
  first due task runs immediately; 15 minutes is the repeat interval
-> updateProfiles()
  lib/features/profile/notifier/profiles_update_notifier.dart:76-164
-> ProfileRepository.upsertRemote(profile.url, proxyOnly: vpnIsConnected)
  lib/features/profile/data/profile_repository.dart:148-223
-> ProfileParser.updateRemote() / _downloadProfile()
  lib/features/profile/data/profile_parser.dart:162-251
-> DioHttpClient.download(operation: profile_download)
-> DioHttpClient._resolveMode()
  lib/core/http_client/dio_http_client.dart:483-535
-> VPN OFF on Windows => HttpRouteMode.systemNetwork
-> DioHttpClient._sendSystem()
  lib/core/http_client/dio_http_client.dart:333-395
-> WinHttpWindowsSystemTransport.request()
-> worker isolate
-> _performWinHttpRequest()
  lib/core/http_client/windows_system_http_transport.dart:174-333
-> WinHttpOpen / WinHttpConnect / WinHttpOpenRequest
-> WinHttpSendRequest fails and GetLastError() returns 12175
-> worker serializes WindowsSystemNetworkException
-> _decodeWorkerResult() line 149 rethrows it
```

Line 149 is not the failure source; it is only the worker-result deserialization boundary.

There are other transports. On Windows, ordinary disconnected requests use the native WinHTTP path; an active ZEON VPN uses the local mixed HTTP proxy. Non-Windows ordinary requests use Dio's direct Dart adapter. `directOnly` and `proxyOnly` are explicit routing overrides.

Startup and manual refresh share `ProfileRepository.upsertRemote`; their main difference is who invokes it. Both derive `proxyOnly` from current connection state, so the critical direct-versus-VPN asymmetry is shared.

## C. Meaning of 12175

The native implementation calls `WinHttpSendRequest` from `winhttp.dll`. Microsoft documents `ERROR_WINHTTP_SECURE_FAILURE` as one or more errors in the server SSL certificate. The more specific category is normally exposed through a WinHTTP secure-failure status callback; one possible flag is `WINHTTP_CALLBACK_STATUS_FLAG_CERT_CN_INVALID`, meaning the certificate hostname is incorrect.

Sources:

- [WinHttpSendRequest](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpsendrequest)
- [WINHTTP_STATUS_CALLBACK secure-failure flags](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nc-winhttp-winhttp_status_callback)
- [SSL in WinHTTP](https://learn.microsoft.com/en-us/windows/win32/winhttp/ssl-in-winhttp)

In ZEON, `hresult=0x80072f8f` is not a second native diagnosis. `_hresultFromWin32` mechanically converts Win32 code 12175 with `HRESULT_FROM_WIN32`: `(12175 & 0xffff) | 0x80070000`.

The transport uses WinHTTP, which delegates TLS/certificate processing to the Windows stack (Schannel). It is not WinINet or `Windows.System.Net.Http`. ZEON does not install a permissive certificate callback and does not set WinHTTP certificate-ignore flags.

## D. Root cause

### Primary cause

The active profile URL was created by a pre-domain client and remains addressed to `https://130.49.151.173/...`. The endpoint certificate is:

```text
Subject:    CN=api.zeon-vps.online
SAN:        DNS=api.zeon-vps.online
Issuer:     CN=YE1, O=Let's Encrypt, C=US
Not before: 2026-08-25 20:36:46 +03:00
Not after:  2026-11-23 20:36:45 +03:00
Chain:      leaf -> YE1 -> Root YE -> ISRG Root X2 -> ISRG Root X1
Windows validation for domain: valid
Windows validation for IP:     RemoteCertificateNameMismatch
```

Commit `29dcfd55` migrated new production defaults from the IP to `api.zeon-vps.online`, but it did not canonicalize already-persisted profile URLs. Its comment explicitly keeps the IP accepted for pre-domain profiles. That compatibility path is incomplete because attempting strict HTTPS to the IP occurs before fallback.

### Secondary contributing causes

- `ProfileParser._downloadProfile` permits `publicFallbackUrl()` only after a transport failure **and** only when `proxyOnly` is true (`profile_parser.dart:233`). Disconnected startup uses `proxyOnly=false`, so it never reaches the valid-domain fallback. Once VPN is connected, the same legacy URL first fails TLS, then the fallback succeeds. The VPN does not make the IP certificate valid.
- `profiles_update_notifier.dart:161-163` records `profiles_update_check` in `finally`, including failed cycles. The initial failure can therefore suppress another scheduled attempt for 15 minutes.
- There is no explicit Internet-readiness gate before the first due periodic refresh. This is worth hardening, but it is not the cause of the deterministic 12175: the IP request still fails after the network is fully ready.

## E. Direct vs VPN comparison

| Test | Direct | VPN/local proxy | Conclusion |
| --- | --- | --- | --- |
| DNS `api.zeon-vps.online` | A=`130.49.151.173`, no AAAA | same destination observed | DNS works; IPv6 not selected |
| TCP `130.49.151.173:443` | pass | pass | transport reachable |
| TLS to domain | pass | pass | chain/date/trust valid |
| TLS to legacy IP | name mismatch | name mismatch | VPN does not fix certificate identity |
| HTTP domain `/health` | 200 | 200 | backend is directly reachable |
| ZEON WinHTTP domain | 200 | not required for proof | native transport works |
| ZEON WinHTTP legacy IP | exact 12175/0x80072f8f | initial IP attempt would fail | exact reproduction |
| Profile refresh from legacy URL | fail, no fallback | initial failure then domain fallback | code-path asymmetry explains apparent VPN-only success |

The decisive comparison is not “direct versus VPN”; it is “IP as TLS hostname versus the certificate's domain name”.

## F. Startup dependency graph

```text
bootstrap initializes profile repository and core
-> App mounts
-> foreground refresh scheduler starts
   -> refresh uses online URL independently

user/core connect
-> load active profile row
-> read last valid encrypted config
-> generate runtime config
-> start core
```

No hard `profile -> VPN -> profile` loop is present in current source. `ConnectionRepository` reads the cached config directly (`connection_repository.dart:350-351`); it does not await a successful online refresh. The automatic refresh also starts after core initialization, not before it.

The user-visible sequence can still resemble a loop because only the VPN-connected refresh takes the legacy fallback. If VPN startup itself fails, that failure needs its own evidence. On this machine the cached profile later started successfully, which disproves refresh failure as an unconditional blocker.

## G. Cached profile behavior

`ProfileRepository.upsertRemote` downloads and parses to a temporary file first. Only after download, parse, validation, and config generation succeed does it write the stored config, refresh an existing runtime file, and edit the DB row (`profile_repository.dart:197-215`). Its `finally` block deletes only the temporary download (`:220-222`).

Therefore, on WinHTTP/TLS failure:

- the active profile row remains;
- the encrypted last-valid config remains;
- no empty/error payload replaces it;
- active selection is unchanged;
- core config generation can use the cached content.

The global scheduler timestamp is still updated on failure. That is retry bookkeeping damage, not cached-profile corruption.

## H. Windows state

| Area | Evidence | Result for 12175 |
| --- | --- | --- |
| Clock | local time 2026-09-02 +03; domain TLS succeeds inside certificate validity | ruled out |
| Windows Time service | service was not running during inspection | hardening concern, but not causal here |
| Certificate chain | full chain builds; domain validates | ruled out |
| Hostname/SAN | IP absent from SAN; domain present | **causal** |
| Pin/LKG | no app pinning or LKG certificate validation in this request path | ruled out |
| WinHTTP proxy | `netsh winhttp show proxy` = direct | not causal |
| User System Proxy | enabled to `127.0.0.1:12434` while VPN was active | direct diagnostic bypassed it and still reproduced |
| PAC/WPAD | production WinHTTP mode supports automatic proxy discovery | bypassed in deterministic direct probe |
| Stale proxy | possible in released 1.4.1 after shutdown; current source has recovery and its native tests pass | separate issue |
| TUN | service mode was System Proxy; no ZEON/Wintun adapter present in inspected state | not involved |
| WFP | no evidence that WFP blocks the endpoint; direct TCP/TLS domain passes | not involved in proven failure |
| DNS | domain resolves to the same IPv4 address used in IP test | ruled out |
| IPv4 | active Ethernet/default route works; TCP and HTTP domain pass | ruled out |
| IPv6 | endpoint has no AAAA record | ruled out |
| Network readiness | fully-ready network still reproduces exact IP-host failure | ruled out for 12175 |
| TLS version/revocation | domain succeeds through the same Windows TLS stack and endpoint | ruled out for this differential |

Current-source startup recovery calls `RecoverZeonSystemProxy(false)` before creating the Flutter window, with shutdown recovery in the window lifecycle. `scripts/tests/windows_system_proxy_recovery.test.ps1` passes. The running 1.4.1 state did not contain the newer ownership marker, so that fix appears unreleased on the inspected client.

## I. Android comparison

The exact Windows symptom and the reported Android behavior are not proven to be the same bug.

Shared architecture:

- the unified profile refresh derives `proxyOnly` from connection state;
- the legacy fallback is therefore VPN-state-dependent on every platform;
- strict TLS to an IP whose certificate contains only a DNS SAN is invalid on every compliant TLS client.

Differences:

- Windows surfaces the native WinHTTP error 12175; Android/Dart would surface a different TLS exception;
- current mobile connection-link import normalizes new links to the domain, so a normal new Android install is less likely to retain this legacy IP;
- the claim that an Android endpoint is directly unreachable needs separate DNS/routing evidence and should not be merged into this Windows incident.

Classification: shared URL/fallback design weakness; proven Windows root cause; Android equivalence not established.

## J. Proposed minimal fix (not implemented)

1. Add a narrowly scoped canonicalizer in `lib/features/profile/data/subscription_url_policy.dart`:
   - rewrite only ZEON-owned `https://130.49.151.173` profile URLs to `https://api.zeon-vps.online`;
   - preserve path, query, and fragment exactly;
   - do not rewrite unrelated hosts or allow HTTP.
2. Apply it before the first request in `ProfileParser._downloadProfile`, so VPN-OFF startup uses the certificate hostname directly.
3. After a successful validated refresh, persist the canonical URL atomically with the already-validated profile/config so the migration is one-way and repeatable.
4. Change automatic refresh bookkeeping to distinguish `last_attempt` from `last_success`, or update the existing success timestamp only when the cycle succeeds. Retry genuine transient failures with bounded state/backoff, not a fixed startup sleep.
5. Add a WinHTTP status callback only for bounded diagnostics so 12175 logs secure-failure flags such as CN/date/CA category. Keep strict validation; never set certificate-ignore flags.
6. Release/test the already-existing Windows stale-system-proxy recovery independently. It should not be coupled to the URL migration.

No backend change, timeout increase, random delay, or TLS relaxation is needed.

## K. Verification plan

Automated regression coverage before release:

1. Seed a remote profile whose stored URL uses the legacy IP; VPN OFF refresh must send TLS to `api.zeon-vps.online` and succeed.
2. Assert path/query/fragment and subscription identity are preserved, while secrets never enter diagnostics.
3. Assert unrelated third-party profile URLs are never rewritten.
4. Inject 12175/network timeout and verify the DB row, active selection, and encrypted cached config remain byte-for-byte usable.
5. Verify core starts from cached config while refresh is offline/failing.
6. Verify a failed automatic cycle does not set `last_success` and a bounded retry can occur.
7. Verify strict certificate checks remain enabled and no ignore flag/callback is introduced.
8. Verify WinHTTP diagnostics classify a synthetic CN mismatch without exposing the URL path.

Windows E2E matrix:

1. cold boot with VPN previously OFF;
2. cold boot after shutdown while VPN/System Proxy was ON;
3. startup with no Internet;
4. Internet appears several seconds after ZEON starts;
5. subscription endpoint temporarily unavailable;
6. cached profile present;
7. cached profile absent;
8. valid cached profile starts VPN while refresh fails;
9. manual refresh succeeds after connectivity returns;
10. second application restart;
11. IPv4-only;
12. IPv4+IPv6;
13. System Proxy mode;
14. TUN mode;
15. Android startup/import/refresh regression pass.

Additional endpoint assertions:

- domain and legacy-IP requests resolve/connect to the same server;
- domain TLS succeeds directly without VPN;
- legacy-IP TLS remains rejected (expected security behavior);
- canonicalized profile refresh does not rely on the VPN fallback.

## Diagnostics and checks completed

- `dart run scripts/diagnostics/windows_bootstrap_tls_probe.dart`: domain 200; legacy IP exact 12175.
- `dart analyze scripts/diagnostics/windows_bootstrap_tls_probe.dart`: no issues.
- targeted Flutter tests for Windows transport, profile fallback, and route selection: 60 passed.
- native Windows system-proxy recovery decision/registry tests: passed.
- no production code, backend, deployment, proxy setting, certificate store, or TLS policy was changed.
