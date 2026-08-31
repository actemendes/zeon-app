# Windows VM, API-domain, and managed application routing report

> Superseded by the verified continuation report dated 2026-08-27:
> `WINDOWS_DOMAIN_MANAGED_ROUTING_FINAL_REPORT_2026-08-27.md`. Historical
> `NOT READY` statements below describe the earlier checkpoint and are not the
> current domain/VM status.

Date: 2026-08-25  
ZEON app branch: `bd-debug`  
ZEON app HEAD: `ca2472315c9ea88e7f1b5ef3993796e65bc6d038`  
Production deployment: **not performed**  
Host ZEON/network/proxy/VPN/TUN/WFP/certificate store: **not changed**

## 1. Windows proxy recovery and VM

The ownership-aware WinINet recovery was exercised in a real clean Windows VM.
The VM exposed and allowed correction of one final interoperability defect in
the C++ registry reader. Final validation on the corrected implementation:

- full Flutter suite after the last production change: 482 PASS, 0 FAIL,
  24 environment-gated native tests skipped;
- targeted Windows/network/WebSocket/bootstrap/TUN/managed-routing suite with
  the real `zeon_windows_transport.dll`: 94 PASS, 0 FAIL, 0 SKIP;
- native WinHTTP WebSocket subset: 24 PASS;
- Go `common/settings` proxy ownership tests: PASS;
- WinHTTP WebSocket and proxy recovery native builds: MSVC `/W4 /WX` PASS;
- proxy recovery PowerShell self-test: PASS;
- changed managed-routing Dart analysis: no errors or warnings, 7 style-info;
- signing policy self-test: PASS;
- `git diff --check`: PASS (line-ending notices only).

History root cause:

- `a56d806c7a180046c27c17bf51d66a3139e00414` added unconditional system-proxy
  disable on runner create/destroy and `WM_ENDSESSION`;
- that avoided a dead loopback proxy but destroyed a pre-existing user or
  corporate proxy/PAC baseline;
- `d1bc9bc79362d7a0ad20a32b5b8a7b62894990b9` removed the unconditional reset;
- no ownership-aware replacement existed, so a crash/reboot could again leave
  persistent WinINet state pointing to a dead ZEON mixed port.

The replacement captures the baseline, binds ownership to expected proxy state,
PID plus process creation time, executable, port, and generation, commits the
marker in two phases, arms RunOnce recovery, restores only an unchanged ZEON
state, and protects a user/corporate/foreign proxy changed after ZEON activation.

The VM found an exact regression in that replacement. Go writes `REG_SZ`
payloads without relying on an extra terminator byte. The C++ two-call
`RegGetValueW` reader retained the size from the sizing call even when the data
call returned fewer bytes. The resulting `std::wstring` contained an invisible
trailing NUL; the exact expected-loopback comparison rejected a valid ownership
marker as `kInvalidMarker`. Consequently RunOnce left both `Armed=1` and the dead
`ProxyEnable=1` state.

The reader now uses `RegQueryValueExW`, validates type/alignment, allocates
terminator room, resizes to the actual returned byte count, and strips every
trailing NUL. Real-HKCU tests cover Go-shaped nonterminated and empty strings.
The Go side also resolves a sibling `ZEON.exe` as the recovery executable when
the proxy owner is `ZEONCli.exe`; it fails closed if that runner is unavailable.
An old generation cannot disarm a replacement generation.

VM environment and results:

- portable QEMU 11.1, TCG, 4 vCPU, 6 GB RAM, rtl8139, user-mode NAT;
- Windows 10 Enterprise LTSC 2021 Evaluation, build 19044.1288;
- clean desktop and guest internet: PASS;
- WinHTTP baseline `DIRECT`, WinINet `ProxyEnable=0`, no PAC;
- persistent clean base/overlay retained; host networking was not changed;
- ZEON 1.4.2 fresh installation: PASS; UI launch/responsiveness: PASS;
- bootstrap/profile/HTTP/WSS/bind: BLOCKED by production TLS hostname mismatch;
- real ZEONCli system-proxy activation followed by normal Ctrl+C stop: PASS;
  baseline restored, marker deleted, guest internet restored;
- original crash/reboot recovery: FAIL reproduced with the old runner;
- corrected production recovery against a fresh real Go marker and dead owner:
  PASS (`kBaselineRestored`, marker absent, `ProxyEnable=0`);
- final full runner-v2 RunOnce reboot had valid pre-reboot state, but its
  post-logon execution is BLOCKED: the recovered OOBE installation no longer
  accepted its stored credential. Bounded layout/case/CapsLock attempts failed;
  the SAM was not modified.

The VM was gracefully powered off and preserved at
`B:\ZEON_VM_LAB\windows10-ltsc-2021-e2e\clean-win10-ltsc\clean-windows-zeon.qcow2`.
Windows 11 remains untested.

### VM proxy/reboot matrix

| Scenario | Internet before | After reboot before manual ZEON launch | Proxy state | Result |
| --- | --- | --- | --- | --- |
| Clean VM baseline | PASS | Not required | WinHTTP direct, WinINet off | PASS |
| Normal system-proxy stop | PASS | Not required | Baseline restored, marker removed | PASS |
| Crash/reboot with old runner | PASS before kill | Dead proxy remained after login | `Armed=1`, `ProxyEnable=1` | FAIL reproduced |
| Corrected recovery, real Go marker | Dead proxy deliberately staged | Recovery invoked directly | Baseline restored, marker removed | PASS |
| Corrected full RunOnce after reboot | PASS before reboot | Could not inspect after logon | Pending state preserved | BLOCKED |
| Existing manual proxy/PAC | Not run | Not run | Not run | NOT TESTED |
| Foreign loopback/generation A to B | Characterized by tests | Not run live | Not run live | PARTIAL |

Production TLS evidence is specific: Schannel rejects
`https://130.49.151.173` with `SEC_E_WRONG_PRINCIPAL` (`0x80090322`). The
default nginx certificate is for another hostname. A diagnostic request with
validation disabled returned HTTP 200, proving reachability, but ZEON was not
changed to bypass TLS. This blocks real bootstrap and `/ws/bind` until the
domain, certificate, and virtual host are correctly configured.

## 2. API domain migration

The purchased domain name could not be read because no authenticated Namecheap
browser session was available to the in-app browser. The supplied login secret
was not written to source, environment files, scripts, logs, or this report.
No domain was guessed.

Current audited flow:

`zeon-app -> https://130.49.151.173 -> nginx public edge -> ZEON services`

The same origin is used by bootstrap, user lookup/create, subscription/profile
delivery, bind token and `/ws/bind`, notifications, pricing, error reports,
managed rule sets, and the new managed-applications endpoint. The checked-in
`zeon-server` source does not implement `/ws/bind`; its actual production
upstream behind nginx must be identified before changing the WSS virtual host.

Domain-sensitive locations include the app `mobile_api_base_url` defaults,
control-plane matcher, embedded support/profile URLs, profile fallback host,
diagnostic scripts, `zeon-server` `PUBLIC_BASE_URL`, reverse-proxy/TLS config,
and admin `ZEON_SERVER_API_URL`. The control-plane rule generator already
supports a domain through a sing-box domain rule, but the app must not be
switched before DNS, TLS, HTTPS, WSS, and every relevant endpoint pass on the
new hostname.

No DNS, TLS, reverse-proxy, firewall, server environment, app default, or
production endpoint was changed. The production IP therefore remains required.

## 3. Application-routing regression

The last working baseline is commit
`d34aa902a3b86e1424194d2a628a64e01aa31717` (2026-07-22). It seeded 49 Android
package identifiers as the default bypass selection. Commit
`d0a26d00c3f64bf5aeaa0c28a7a511b9a21761ac` (2026-07-30) intentionally retired
the seed during the rules/core migration, and release 1.4.2
`df0acc9c0fc0ada38e79a4e96ca55c54d2059384` included that behavior. Fresh
installs consequently had no automatically selected applications.

The historical source stored package identifiers only. Display names and icons
were resolved dynamically from Android installed applications. The exact 49-ID
baseline is restored as managed configuration version 1; its LF-joined SHA-256
is `a03f95ed90fcd1ab34692d8841a2e03c4d104b5c91d6c562d97ae6e0932184bb`.

## 4. Managed-routing architecture

`Admin UI -> authenticated same-origin BFF -> zeon-server DB relay ->`
`CAS service/RPC -> PostgreSQL canonical tables -> versioned public JSON ->`
`zeon-app atomic LKG -> per-app user override -> core package rules`

`z-net-server` is not part of this data path and was not changed.

The admin BFF uses the fixed
`/rest/v1/_zeon/admin/routing/applications` relay path with the existing
server-only DB service credential. It does not expose the credential to the
browser. Direct ZEON admin routes keep their separate routing-admin credential.

## 5. Database and zeon-server

Migration `191_managed_applications.sql` adds:

- `routing.managed_applications`;
- singleton version state;
- append-only audit;
- a case-insensitive `(platform, stable identifier)` unique index;
- strict platform/identifier/route/order constraints;
- a guarded SECURITY DEFINER mutation RPC with `expectedVersion` CAS;
- the exact 49-package Android DIRECT seed as version 1.

Public API: `GET /routing/v1/applications/current`, deterministic ordering,
format/version/update metadata, ETag and 304. Disabled entries are omitted from
the public document and remain visible in admin state. Admin CRUD uses validated
create/PATCH/delete operations and increments the canonical version atomically.

The migration is additive. Rollback is to stop serving/administering the new
endpoint and revert application/server code while preserving tables and audit;
destructive audit deletion is not part of rollback.

No live PostgreSQL migration was run because local Docker/psql were unavailable.
A reviewed staging execution plus backup remains a deployment gate.

## 6. Admin

The Tabler admin page now shows version, name, platform, stable identifier,
route, enabled state, and order. It supports create, edit, enable/disable,
delete, and movement/reordering. Mutations require the current version and show
validation, upstream, and CAS conflict errors.

## 7. zeon-app behavior

Android fresh install uses an embedded safe version-1 baseline immediately and
then syncs the server document. A dedicated pending/completed marker makes
fresh-default initialization idempotent across a crash during early bootstrap;
an existing install without that first-launch marker is not silently changed.

The client validates the exact schema, atomically writes `active.json`, retains
the previous file as LKG, rejects version rollback and malformed data, uses ETag
304, and falls back to LKG then embedded version 1 while offline.

Managed baseline and user choice are separate. Deselecting a managed package
stores a per-package override. Server version changes may add/remove/update the
managed baseline but do not erase that override. Existing explicit user route
rules remain above managed rules.

Managed entries are not inserted into Android VPNService's OS-level disallowed
application list. Instead they compile to real core `package_names` rules:
VPN outbound 0, DIRECT outbound 1, BLOCK outbound 3. Final rule priority is:
mandatory control-plane, explicit user rules, managed applications, then profile
rules. This ensures the configuration reaches sing-box rather than only the UI.

Windows application identifiers exist in the canonical schema and validation,
but the current client does not yet compile Windows executable routing rules;
the implemented runtime behavior is Android-only.

## 8. Deployment

Updated production components: **none**.

No DB migration, zeon-server deploy, ok24 deploy, DNS mutation, certificate
issuance, reverse-proxy change, app endpoint switch, or backend rollout occurred.
Clients 1.4.1/1.4.2 therefore continue using the current API unchanged.

## 9. Tests and build

- Final Flutter suite after the last production change: 482 PASS, 0 FAIL,
  24 native integration tests skipped by their environment gate.
- Final targeted Windows/network/WebSocket/bootstrap/TUN/managed-routing suite
  with the real native DLL: 94 PASS, 0 FAIL, 0 SKIP.
- Native WebSocket integration subset: 24 PASS, 0 FAIL, 0 SKIP.
- Managed-app client targeted tests: 15 PASS.
- Native recovery decision and real-HKCU registry tests: PASS with `/W4 /WX`.
- Go proxy ownership package: PASS; earlier shipped CLI characterization: 4/4.
- zeon-server full Vitest: 167 PASS, 0 FAIL, 0 SKIP.
- zeon-server managed/DB targeted: 22 PASS; TypeScript build PASS.
- ok24 managed admin targeted: 11 PASS; static production bundle PASS.
- ok24 full: 188 PASS, 3 FAIL, 0 SKIP. The three failures are pre-existing/live
  network/tmp Trojan certificate-conversion checks; all 11 managed tests pass in
  the full run.
- Changed managed-routing Dart analysis: 0 errors, 0 warnings, 7 style-info.
- `git diff --check`: PASS in all three repositories (line-ending notices only).
- A patched runner-v2 was linked in an isolated output directory with `/W4 /WX`;
  SHA-256 `32025D4EC198D9BDC65E422C2D4674248768A190DB70339E74C42B3F1D3549DB`.
- The required Visual Studio Build Tools ATL component
  (`Microsoft.VisualStudio.Component.VC.ATL`, v143 x86/x64) was installed
  without a host reboot. The final isolated command
  `flutter build windows --release --target lib/main_prod.dart` then passed in
  335.6 seconds. The resulting unsigned `ZEON.exe` is 107,520 bytes with
  SHA-256 `E07623E9BEAF11431FD5D0F382313247026B970FA637AE69B121D9230B81B05C`;
  the isolated payload contains 21 EXE/DLL files and is 128,388,736 bytes.
  The artifact was inspected only and was not launched or installed. The
  already-running host ZEON process remained PID 11176 at its original path.

## 10. Current release readiness

- Windows proxy recovery: **NEEDS final RunOnce VM validation**; normal cleanup
  and exact real-marker recovery PASS
- Windows fresh install: **PARTIAL**; install/UI PASS, bootstrap blocked by TLS
- API domain DNS: **NOT READY**
- API domain TLS: **NOT READY**
- app switched to domain: **NOT READY**
- old IP dependency: **STILL REQUIRED**
- DB managed apps: **READY in code; staging migration required**
- zeon-server managed routing API: **READY in code; not deployed**
- admin managed routing UI: **READY in code; not deployed**
- zeon-app fresh-install defaults: **READY in code/tests; device E2E pending**
- user overrides preserved: **VERIFIED by tests; device E2E pending**
- routing actually reaches core: **VERIFIED in generated core config/tests**
- safe for Windows canary: **NO**, pending domain TLS/bootstrap and final
  RunOnce/reboot matrix
- safe for production domain rollout: **NO**
- safe for managed-routing rollout: **NO**, pending staging DB/deploy and Android E2E

No commit was created. The ZEON app and zeon-server trees contained pre-existing
unrelated changes, so automatic commits would risk mixing ownership. The
ok24-server changes are task-owned but remain uncommitted to keep the multi-repo
rollout atomic until DB/server/client staging gates pass.

## 11. No-big-bang domain inventory gate (continued 2026-08-25)

No production state was changed during this continuation. DNS, nginx,
certificates, firewall, deployed services, application endpoints, DB, and the
running host ZEON remained untouched.

### Public DNS and TLS facts

- `zeon-vps.online` uses Namecheap authoritative DNS and currently resolves to
  `130.49.151.173` with an observed TTL of approximately 1800 seconds.
- `api.zeon-vps.online` currently returns NXDOMAIN for both A and AAAA.
- The root hostname has no observed AAAA record.
- The public certificate served by `130.49.151.173` for the root hostname is a
  Let's Encrypt certificate whose SANs are `zeon-vps.online` and
  `www.zeon-vps.online`; it does not cover `api.zeon-vps.online`.
- Strict HTTPS to `https://zeon-vps.online/health` passes and returns HTTP 200.
  Strict HTTPS to the bare IP still fails with Schannel
  `SEC_E_WRONG_PRINCIPAL` (`0x80090322`). No validation bypass was added.

### Preliminary production topology

This table is deliberately marked preliminary until live server configuration,
service units, containers, deployed SHAs, and replica membership can be read
through an authenticated operations session.

| Server/component | Role | Public/private | Current IP/host | HTTPS | WSS | Needs domain change |
| --- | --- | --- | --- | --- | --- | --- |
| Root production edge | nginx and public ZEON HTTP control-plane edge | Public | `130.49.151.173`, `zeon-vps.online` | Root hostname PASS | `/ws/bind` not present on the observed root vhost | Add parallel `api` vhost/certificate only after backup |
| Node `zeon-server` | Health, users, subscriptions, profile delivery, REST bind, notifications, pricing, reports and routing APIs | Private upstream behind root edge | Deployment host/port not yet verified live | Via edge | No checked-in WebSocket handler | Public base/origin may need staged domain values |
| PostgreSQL/PostgREST gateway | Canonical application and admin data | Private | Local service topology indicated by operations scripts; live state unverified | Via edge/BFF | No | Managed-routing staging migration only |
| Legacy/public `zeon-vps.link` edge | Public open links, REST relay and possibly a separate Python service | Public | `92.46.41.206`, `zeon-vps.link` | Existing hostname responds | Documented `/ws/bind`, but no handler exists in either checked-in Python worktree; live owner unverified | Do not change until live upstream is identified |
| ok24 admin | Netlify-hosted admin/BFF | Public | `ok24-server.com` | PASS independently | No | BFF origin changes only after API domain passes |
| VPN traffic nodes | Data-plane proxy servers | Public/private mix | Inventory requires DB/operations access | Protocol-specific | Not control-plane WSS | No blanket domain change |

The local operations health script indicates that the root/origin stack checks
local nginx, Docker, PostgreSQL, PostgREST and a REST gateway, and separately
SSHes to `92.46.41.206` to inspect an nginx/Docker `zeon-server` edge. This is
evidence of at least two relevant public hosts, not proof of their exact live
request routing. VPN traffic nodes remain outside this domain migration unless
live inventory proves a control-plane role.

### Read-only endpoint observations

| Endpoint | Existing path | Proposed `api` path | Existing status | Proposed status | TLS/notes |
| --- | --- | --- | --- | --- | --- |
| Health | `https://zeon-vps.online/health` | `https://api.zeon-vps.online/health` | 200 | DNS failure | Root TLS PASS; `api` absent |
| Public pricing | `https://zeon-vps.online/api/v1/pricing/public` | Same path on `api` | 200 | DNS failure | Read-only GET |
| Current routing rule sets | `https://zeon-vps.online/routing/v1/rule-sets/current` | Same path on `api` | 200 | DNS failure | Read-only GET |
| Managed applications | `https://zeon-vps.online/routing/v1/applications/current` | Same path on `api` | 404 | DNS failure | Code exists locally; not deployed |
| PostgREST root | `https://zeon-vps.online/rest/v1/` | Same path on `api` | 401 | DNS failure | Expected unauthenticated boundary evidence only |
| WebSocket bind | `wss://zeon-vps.online/ws/bind` | `wss://api.zeon-vps.online/ws/bind` | Root vhost returns 404 to upgrade probe | DNS failure | Actual live WSS upstream still unidentified |

Mutating bind/user/report/receipt endpoints were not called during inventory.
They require a controlled canary identity and verified rollback, not production
probing with invented payloads.

### Blocking access required before production changes

- No browser backend is connected to the current Codex session, so Namecheap
  records cannot be inspected or changed through an authenticated UI yet.
- SSH key authentication to `130.49.151.173` is not currently authorized. A
  safe interactive/key-based operations session is required to inventory and
  back up live nginx, certificates, services, environment, firewall and
  deployed SHAs. Passwords will not be placed in command lines or repository
  files.
- Because live WSS ownership and all relevant replicas are not yet proven, no
  DNS record, certificate, nginx vhost, app endpoint or migration fallback was
  added.

Current gate status after this continuation:

- `api.zeon-vps.online` DNS: **NOT READY**
- `api.zeon-vps.online` TLS: **NOT READY**
- all relevant production replicas: **NOT VERIFIED**
- Windows release build: **PASS** (unsigned static artifact; not executed)
- zeon-app domain migration: **NOT READY**
- safe for domain canary: **NO**
