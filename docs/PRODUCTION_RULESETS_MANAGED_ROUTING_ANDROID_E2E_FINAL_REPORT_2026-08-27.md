# ZEON production RULESETS, managed routing, and Android E2E report

Date: 2026-08-27
App branch: `bd-debug`
App HEAD before final Android fix: `32a20945d6a1a4b0c7156318e02e60e1fae31611`
App implementation HEAD: `bf5043da874bd6dac1677b97c54ba288efc0634a`

This report supersedes the earlier Windows/domain checkpoint. It records the
subsequent production RULESETS audit, production managed-routing deployment,
physical Android E2E, and controlled domain canary. The legacy production IP
listener remains active and VPN traffic nodes were not modified.

## A. Outcome

- existing production RULESETS pipeline: **VERIFIED end-to-end**;
- RULESETS reach generated sing-box core rules: **VERIFIED**;
- managed applications aligned with the established routing conventions;
- production DB migration, zeon-server endpoint, and ok24/admin: **DEPLOYED**;
- managed endpoint: **HTTP 200**, final version 26, exact 49-app baseline;
- physical Android fresh-install and upgrade E2E: **PASS**;
- admin -> DB -> API -> Android -> LKG/UI/core: **PASS**;
- per-app manual user override preservation: **PASS**;
- post-deployment existing RULESETS regression: **PASS**;
- Windows and Android internal domain canary: **PASS**;
- managed-routing controlled canary: **AUTHORIZED**;
- broad rollout: **NOT AUTHORIZED pending soak and remaining release gates**.

## B. Relevant production topology

| Server/component | Role | Relevant service | Deployed version/state | Routing responsibility |
| --- | --- | --- | --- | --- |
| `cv6924457.novalocal`, `130.49.151.173`, `api.zeon-vps.online` | Public edge | nginx/TLS | Existing parallel domain vhost retained | Public HTTPS/WSS and routing API proxy |
| Same host, `/opt/zeon-server` | Control-plane backend | systemd zeon-server, local Node on `127.0.0.1:3000` | integration SHA `eb9c789559cae4c748000892e1b1f69772172d29` | RULESETS and managed-applications public handlers |
| Same host | Canonical storage | Docker PostgreSQL/PostgREST, local ports `55432`/`3001` | migration 191 deployed; managed state v26 | Releases, active state, CAS/RPC and audit |
| `ok24-server.com` | Admin/BFF | Netlify production | canonical `main` `fadd3ce4`; Git deploy `6a9089560c84b90008f6a3fb` | Authenticated CRUD and version publish |
| VPN traffic nodes | Data plane | VPN protocols | Not inspected or changed | No discovered RULESETS responsibility |

No additional zeon-server, RULESETS, or database production replicas were
discovered. The verified topology is one control-plane host plus the Netlify
admin deployment; this report makes no multi-replica claim.

## C. Existing RULESETS architecture

Verified production flow:

`ok24 admin/source -> PostgreSQL releases/active state -> CAS/RPC publish -> zeon-server -> /routing/v1/rule-sets/current -> Dart validation -> atomic active/LKG -> routing model -> generated sing-box rules`

Canonical storage uses `releases`, `active_release`, `active_release_bundle`,
and `admin_audit`. Publication is guarded by the expected active version.

Current public state:

- generation: 6;
- format: 1;
- rule-set count: 2;
- checksum: `6e87e6bfdbf2ed449f432e5ece4c9a357e611b78f53809f2fde6e828cb429ae0`;
- ETag: `"routing-6-6e87e6bfdbf2ed449f432e5ece4c9a357e611b78f53809f2fde6e828cb429ae0"`;
- conditional request: HTTP 304;
- cache policy: `public, max-age=300, must-revalidate`.

On the physical Android device the active document was present under
`files/data/rule-sets/managed/active.json`. The captured generated core config
contains definitions `zeon-managed-ads` and
`zeon-managed-ru-force-vpn-overrides`, and effective route entries reference
those tags. This proves the server response reaches sing-box rather than only
the HTTP or Dart layer.

## D. Managed-applications compatibility decision

The managed-applications implementation reuses the established conventions:

- canonical PostgreSQL state and authenticated admin/BFF;
- expected-version CAS and audit;
- deterministic versioned JSON and checksums;
- checksum-bound ETag and HTTP 304;
- strict schema validation;
- temporary write followed by atomic active/LKG activation;
- malformed, rollback, and same-version collision rejection;
- offline LKG and embedded fallback;
- diagnostics and generated core-rule inspection.

RULESETS and applications remain separate versioned documents because their
schemas, update rates, backward compatibility, and client availability differ.
They are combined only while compiling a complete valid core snapshot. The
effective priority verified by conflict tests is mandatory control-plane,
explicit user rules/per-app overrides, managed applications, then existing
managed/profile routing and defaults.

## E. Production database

Pre-migration dump:

`/var/backups/zeon/managed-routing-e2e-20260827T180200Z/zeon-before-admin-e2e.dump`

- size: 35,115,627 bytes;
- SHA-256: `9ea947c0...758`;
- owner/mode: root, 0600;
- `pg_restore --list`: PASS.

Migration `191_managed_applications.sql` was reviewed and applied once to the
production canonical DB. Constraints, duplicate protection, deterministic
ordering, audit, expected-version CAS, and RPC were verified.

Final state:

- version: 26;
- total/enabled applications: 49/49;
- route distribution: 49 DIRECT, 0 VPN/BLOCK;
- no test/canary package remains;
- audit contains the initial seed and reversible CRUD actions through version 26;
- existing RULESETS generation remained 6.

Historical package baseline is the exact list from
`d34aa902a3b86e1424194d2a628a64e01aa31717`. Count is 49 and the LF-list
SHA-256 is
`a03f95ed90fcd1ab34692d8841a2e03c4d104b5c91d6c562d97ae6e0932184bb`.

## F. zeon-server and public API

Production integration SHA:
`eb9c789559cae4c748000892e1b1f69772172d29`.

`GET https://api.zeon-vps.online/routing/v1/applications/current`:

- HTTP 200;
- version 26;
- 49 deterministic entries;
- body/header checksum:
  `357283401f36dc363bf9d1984525cb66780ae5571d7becab3f52165915640215`;
- ETag:
  `"managed-apps-26-357283401f36dc363bf9d1984525cb66780ae5571d7becab3f52165915640215"`;
- conditional request: HTTP 304;
- disabled entries are omitted from client effect.

Health and pricing remained HTTP 200. The legacy listener was retained.

## G. ok24/admin production

The original controlled deployment ID was `6a9024775ac75eba8d0cc00e`.
Canonical GitHub PR #11 was subsequently merged, followed by navigation fix
PR #12. Netlify Git integration then published production deployment
`6a9089560c84b90008f6a3fb` from canonical `main` commit
`fadd3ce40d4429c5cbe5d6333aeb061a8941eabb`. No second CLI/API production
upload was used. Previous deploy `6a7f45c291786e00085edec4` remains recorded
as an older rollback point.

Authenticated production checks covered load, version, platform, identifier,
display name, DIRECT/VPN/BLOCK route, enable/disable, order, create, edit,
delete, and stale-version conflict. Reversible mutations incremented the public
version and were returned to the exact 49-entry DIRECT baseline at final
version 26.

## H. Physical Android E2E

Device: OnePlus GM1901, Android 16/API 36. The isolated package
`com.zeon.hiddify.validation` was used; the installed production package was
not modified.

Fresh-install results:

- clean app state and install: PASS;
- embedded version 1: exact 49 packages;
- routing UI non-empty: PASS;
- installed-app matching, names, and icons: PASS;
- DIRECT defaults: PASS;
- initial production sync to version 19: PASS; subsequent visual UI/core
  finalization advanced the clean production state to version 26;
- generated `package_names` rules: PASS;
- generated effective core configuration: PASS.

Admin-driven E2E covered create, BLOCK, disable, re-enable, delete, and version
increments through versions 15-19. The version 18 captured core config contains
the canary BLOCK effect as `action: "reject"`; version 19 contains no canary.

User override E2E used RuStore:

1. server managed value was DIRECT;
2. the user selected VPN;
3. admin changed the managed value to BLOCK and later DIRECT;
4. the client received the higher versions;
5. the effective user VPN selection remained unchanged;
6. the managed compiler did not reinsert a conflicting RuStore rule.

Failure-mode results:

- endpoint unavailable -> LKG: PASS;
- no LKG -> embedded baseline: PASS;
- malformed document -> previous valid active/LKG retained: PASS;
- lower version -> rollback rejected: PASS;
- interrupted temporary update -> no half-written active state: PASS;
- disabled application -> managed effect removed, override retained: PASS;
- deleted application -> no orphaned core rule: PASS;
- newly added application -> API/UI/core propagation: PASS.

Upgrade from an existing 1.4.2 state preserved manual application settings,
explicit routing rules, profile state, and the per-app user override.

## I. Android domain canary and log-feedback fix

The initial physical connect exposed a real Android-only failure: the hcore
debug/log bridge re-emitted sing-box messages into the same `box.log` source.
The feedback loop grew the file to 16.8 GB, starved `Mobile.start`, and prevented
the TUN callback.

Commit `00ef5a19` disables the affected native debug bridge and streaming log
RPC on Android while retaining bounded lifecycle/logcat diagnostics. Policy
tests preserve the previous non-Android debug semantics.

Final physical verification:

- `tun0` UP with `172.19.0.1/28`;
- Android VPN NetworkAgent CONNECTED and VALIDATED;
- connect, disconnect, reconnect, force-stop/restart/reconnect: PASS;
- real server latency observed at 64 ms and 103 ms;
- health, RULESETS, and managed endpoints through Android VPN: HTTP 200;
- no recursive `WARN H SERVICE ... WARN H SERVICE` signature;
- no panic/fatal signature.

Additional controlled soak on 2026-08-27 20:35-20:38 MSK:

- six sequential samples used one stable app PID;
- all 18 device-side endpoint requests returned HTTP 200;
- `tun0` remained UP and UI remained connected;
- `box.log` grew only from 41,695 to 51,253 bytes;
- canary was then disconnected and force-stopped;
- final state: `tun0` absent.

## J. Existing RULESETS post-deployment regression

Final public regression after managed DB/server/admin deployment and after the
Android fix:

- health: HTTP 200;
- pricing: HTTP 200;
- managed applications: HTTP 200/304, final version 26, count 49;
- managed baseline checksum: exact historical hash;
- RULESETS: HTTP 200/304, generation 6, count 2;
- RULESETS checksum and ETag unchanged;
- physical client active/LKG and generated core rules: PASS.

## K. Git safety

No `git add .`, `git reset --hard`, destructive checkout, or deletion of user
untracked files was used. Task files were staged explicitly after cached-diff
inspection.

zeon-app:

- branch: `bd-debug`;
- original base: `ca2472315c9ea88e7f1b5ef3993796e65bc6d038`;
- implementation HEAD: `bf5043da874bd6dac1677b97c54ba288efc0634a`;
- final Android commit: `00ef5a19 fix(android): prevent recursive native core log feedback`;
- managed VPN UI/core fix:
  `bf5043da fix(android): show managed VPN selections in app routing`;
- complete-history bundle:
  `B:\ZEON_SAFE_BACKUPS\20260827_133126\zeon-app-final-00ef5a19.bundle`;
- bundle SHA-256:
  `9A69D7F4F28C2EDA96123C1EA941DAA4312B4258A5E82E0DA47E6FDDDF86A0ED`.
- incremental bundle from `00ef5a19` through `bf5043da`:
  `B:\ZEON_SAFE_BACKUPS\20260827_133126\zeon-app-bf5043da-increment.bundle`;
  SHA-256
  `5AA8299F7E84434966254E590DAA8C64A9A0CE4867697BE2E6E13144A81FF6F9`.

zeon-server:

- local branch/HEAD: `main`, `6dd829160619688e605de30c736165438bafee73`;
- deployed integration SHA: `eb9c789559cae4c748000892e1b1f69772172d29`;
- deployment bundles were created and verified.

ok24-server:

- local branch/HEAD: `main`, `b02265daeabd4a3017858bff64052768aea9d68e`;
- local tree: clean;
- canonical GitHub `main`:
  `fadd3ce40d4429c5cbe5d6333aeb061a8941eabb`;
- merged feature head: `abd1a16c53cb0f1693b4716645bbda648e648443`;
- final Git-triggered Netlify deploy and rollback IDs are recorded above.

Local `b02265d` is an unpushed alternative implementation commit based on old
parent `3d1db78`. It targets the superseded `admin-tabler` entry points and is
not an ancestor of GitHub `main`. The shared managed modules were carried into
`abd1a16c`, while the integration commit adapted navigation and tests to the
current `admin/index.html` / `assets/js/admin.js` layout. The local branch was
left untouched as recovery evidence; it is not canonical and was not deployed.

Pre-existing dirty app and zeon-server files remain unstaged because their
hunks are unrelated or user-owned. Production changes are represented in
source commits/integration bundles and do not exist only on a server.

## L. Tests after the final client change

- full Flutter suite after `bf5043da`: 493 PASS, 0 FAIL, 24 SKIP;
- targeted Android/core lifecycle: 38 PASS;
- targeted analyze: 0 issues;
- `git diff --check`: PASS, with only existing PowerShell LF/CRLF notices;
- Android arm64 validation build: PASS;
- APK SHA-256:
  `3682BF8FD8DFFEBB67B70AB663618D9C4C2B1C70A0CA9D9F293D28D4860603C`;
- physical Android connect/reconnect/restart and soak: PASS.

## M. Release readiness

- Git state safely preserved: **YES**
- domain internal canary: **PASS**
- Windows domain path: **PASS**
- Android domain path: **PASS**
- existing RULESETS pipeline: **VERIFIED**
- rulesets reach core: **VERIFIED**
- managed applications follow RULESETS conventions: **YES**
- DB production migration: **DEPLOYED**
- zeon-server managed API: **DEPLOYED**
- admin managed UI/BFF: **DEPLOYED**
- 49 baseline restored: **VERIFIED**
- fresh Android install: **PASS**
- names/icons: **PASS**
- managed rules reach core: **PASS**
- admin -> DB -> API -> Android -> core: **PASS**
- per-app user override: **PASS**
- offline LKG: **PASS**
- embedded fallback: **PASS**
- malformed config safety: **PASS**
- version rollback protection: **PASS**
- atomic activation/restart safety: **PASS**
- 1.4.2 upgrade migration: **PASS**
- existing RULESETS regression: **PASS**
- safe for managed-routing controlled canary: **YES**
- safe for domain broad rollout: **NO**
- safe for managed-routing broad rollout: **NO, production soak pending**
- Windows signed release: **NOT VERIFIED**

Broad domain rollout remains gated by an unsigned Windows release, Windows 11
coverage, replica proof, and production soak. Managed-routing broad rollout is
gated by a longer controlled-client soak and telemetry review. The legacy IP
listener must remain until a separate compatibility-removal task is completed.

## N. Git-triggered admin deploy and visual managed-app E2E finalization

### N.1 Canonical ok24 production

PR #11 (`integrate/production-managed-routing-20260827`) was rechecked as
mergeable with only the expected eight managed-routing files. Its 11 targeted
tests and production build passed; the full suite passed 213 tests with one
unchanged external Trojan live-TLS timeout. The Deploy Preview passed and the
Netlify secret scan reported no matches. PR #11 merged as `e64ae82c`; PR #12
fixed the discovered production navigation omission and merged into the final
canonical `main` SHA `fadd3ce4`.

Netlify automatically created deployment `6a9089560c84b90008f6a3fb` after the
GitHub merge. Its recorded provenance is:

- branch/context: `main` / `production`;
- commit ref: `fadd3ce40d4429c5cbe5d6333aeb061a8941eabb`;
- commit URL:
  `https://github.com/actemendes/ok24-server/commit/fadd3ce40d4429c5cbe5d6333aeb061a8941eabb`;
- build ID: `6a9089560c84b90008f6a3f9`;
- state: `ready`;
- URL: `https://ok24-server.com`;
- `manual_deploy=false`.

Netlify's API still labels `deploy_source` as `api` for this Git-connected
build, so that field alone is not used as provenance. Unlike the prior manual
upload, this deploy has the exact Git `main` branch, commit ref, commit URL and
build ID, appeared automatically after the merge, and is explicitly not a
manual deploy. No `netlify deploy --prod` or other CLI/API production upload
was executed during this finalization.

### N.2 Physical Android UI-to-core proof

The real installed test application was Microsoft Edge:
`com.microsoft.emmx`, display name `Edge`. It was not in the managed 49 and had
no user override before the test. ZEON resolved its installed application icon
on the physical OnePlus GM1901.

All mutations below were made by clicking the production ok24 UI, not by SQL or
direct mutation API:

| Step | Server version | Admin value | Physical ZEON UI | Generated core |
| --- | ---: | --- | --- | --- |
| Before add | 19 | absent | Edge not managed | no Edge managed rule |
| Create | 20 | DIRECT, enabled | Edge name/icon/package; checked in `В обход` | `package_name=com.microsoft.emmx`, outbound `direct` |
| Route change | 21 | VPN, enabled | checked in `Через VPN` | Edge rule outbound `select` (current VPN selector) |
| Disable | 22 | VPN, disabled | checkbox cleared | Edge managed rule absent |
| Re-enable | 23 | DIRECT, enabled | checked in `В обход` | DIRECT effect restored |
| Override/server updates | 24-25 | VPN, then DIRECT | manual effective VPN survived | conflicting managed Edge rule omitted |
| Delete | 26 | absent | Edge no longer managed; checkbox cleared | no orphaned Edge rule |

The exact visible state control is the application-row checkbox under the
selected route mode. The captures show the real Edge icon, name and package;
in `Через VPN` the route selector is visible at the top and the Edge checkbox
is green/checked. Disable and final delete show the same checkbox unchecked.

Device evidence includes active managed versions matching server versions,
and raw private generated configurations captured while the validation VPN was
actually connected. Version 21 contained the Edge `select` rule; version 22
contained zero Edge rules. After the final delete, device active version 26 had
49 applications and no Edge, final raw core had zero Edge rules, `tun0` was
then stopped, and the user's production package remained untouched.

The separate override scenario started with managed DIRECT. The user unchecked
Edge under `В обход`, producing client row
`exclude|com.microsoft.emmx|2` (forced deselection/effective VPN). Server
updates DIRECT -> VPN -> DIRECT advanced versions 23 -> 24 -> 25 without
removing that row or changing effective VPN. The compiler emitted no
conflicting Edge rule. The override was then cleared through the ZEON UI before
the production test row was deleted.

### N.3 Final requested matrix

| Check | Result |
| --- | --- |
| PR #11 merged into main | **YES**, merge `e64ae82c` |
| New GitHub main SHA | `fadd3ce40d4429c5cbe5d6333aeb061a8941eabb` |
| Netlify deploy triggered by Git integration | **YES** |
| Netlify production deploy ID | `6a9089560c84b90008f6a3fb` |
| Deploy `commit_ref` | `fadd3ce40d4429c5cbe5d6333aeb061a8941eabb` |
| Deploy `commit_url` | GitHub canonical-main commit URL above |
| Deploy `build_id` | `6a9089560c84b90008f6a3f9` |
| CLI production deploy used | **NO** |
| Test package | `com.microsoft.emmx` (`Edge`) |
| Version before / after add | 19 / 20 |
| Public API entry | **PASS**; version/checksum/ETag changed, conditional 304 |
| Android received new version | **PASS** |
| App appears in ZEON UI | **PASS** |
| Correct app name / icon | **PASS / PASS** |
| Managed route visibly active | **PASS** |
| Exact visible control | checked application-row checkbox under selected `В обход` or `Через VPN` mode |
| Generated `package_names` rule | **PASS** |
| Effective core route | **PASS**, DIRECT=`direct`; VPN=`select` selector |
| Admin route change reflected in UI/core | **PASS / PASS** |
| Disable reflected in UI/core | **PASS / PASS** |
| User override survives managed updates | **PASS** |
| Test app removed after test | **PASS**, delete version 26 |
| Final production baseline = 49 DIRECT | **PASS**, 49 total/enabled/DIRECT, zero VPN/BLOCK/test rows |
| Historical package-list SHA-256 | **PASS**, `a03f95ed90fcd1ab34692d8841a2e03c4d104b5c91d6c562d97ae6e0932184bb` |
| Existing RULESETS unchanged | **PASS**, generation 6, count 2, checksum unchanged, HTTP 304 |

Final managed endpoint state is version 26 with ETag
`"managed-apps-26-357283401f36dc363bf9d1984525cb66780ae5571d7becab3f52165915640215"`
and conditional HTTP 304. Production DB audit records the Edge operations at
versions 20-26 and contains no remaining Edge/test row. TickTick task
`[МП] маршрутизация приложений` was updated with these factual results; broad
rollout remains gated by the planned production soak.
