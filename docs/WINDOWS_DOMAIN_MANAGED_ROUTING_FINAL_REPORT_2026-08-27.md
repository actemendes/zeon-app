# ZEON production RULESETS, managed routing, domain canary, and Android E2E report

Date: 2026-08-27  
Scope: final continuation after the 2026-08-25/earlier 2026-08-27 checkpoints  
Legacy production listener `130.49.151.173`: retained and not repurposed  
VPN traffic/data-plane nodes: not changed

This document replaces the previous checkpoint. It records new production
RULESETS evidence, the controlled managed-routing deployment, and physical
Android E2E. It does not promote either client rollout to a broad rollout.

## A. Git safety

Before deployment, recoverable bundles, binary diffs, working-tree patches,
untracked manifests, status snapshots, and secret scans were created for every
repository in:

`B:\ZEON_SAFE_BACKUPS\20260827_133126`

The final application bundle is:

- `zeon-app-final-32a20945.bundle`;
- SHA-256 `D22F9079AA6942C3902C38C1ADA99D98A626C0802B3F062C99071B233523A681`;
- bundle verification: PASS.

No `git add .`, destructive checkout, or `git reset --hard` was used. Files
with unrelated/pre-existing user hunks were not staged. No credentials, auth
headers, profiles, subscription links, or production secrets were added to
Git or this report.

### Logical commits

| Repository | Branch/base | Task-owned commits | Current local HEAD |
| --- | --- | --- | --- |
| zeon-app | `bd-debug`, base `ca2472315c9ea88e7f1b5ef3993796e65bc6d038` | `723cbc2a` Windows network/proxy recovery; `29dcfd55` domain migration; `5e0c7811` managed baseline/overrides; `15c5c051` content-bound cache; `944f2cdb` ETag normalization; `32a20945` cache guard cleanup | `32a20945d6a1a4b0c7156318e02e60e1fae31611` |
| zeon-server | `main` | `17206b25` bind WebSocket; `6dd82916` managed applications service | `6dd829160619688e605de30c736165438bafee73` |
| ok24-server | `main` | `b02265da` managed routing admin/BFF; production integration branch commit `abd1a16c` | `b02265daeabd4a3017858bff64052768aea9d68e` |

The zeon-app working tree still contains identified user/unrelated edits in
workflow, Makefile, database/router/connection/diagnostics/profile/link code,
Windows packagers, older reports/tests, and local native object files. The
zeon-server tree still contains unrelated subscription/provisioning/certificate
work. They remain deliberately uncommitted. ok24-server `main` is clean.

This report itself remains an untracked evidence artifact because it replaced a
pre-existing untracked checkpoint after the code commits. A copy is retained in
the backup set; application/server production code is not left only in an
uncommitted working tree.

## B. Controlled domain canary

Production origin: `https://api.zeon-vps.online`.

- DNS A to `130.49.151.173`, no AAAA: PASS.
- trusted Let's Encrypt hostname validation, no raw-IP bypass: PASS.
- REST bootstrap/profile/pricing/notifications/routing paths: PASS.
- `wss://api.zeon-vps.online/ws/bind`, strict TLS, auth, send/receive,
  idle/reconnect/close: PASS.
- Windows 10 LTSC clean install/bootstrap/profile/connect/disconnect/reconnect,
  proxy cleanup, restart and ownership-aware RunOnce reboot recovery: PASS.
- Android production-domain bootstrap/profile/connect/refresh and managed
  fetch on the physical device: PASS.
- final live pricing check after the managed deployment: HTTP 200.

This is a controlled internal canary. The old listener remains online for
released clients. There is no runtime TLS-failure fallback to the raw IP.
Windows 11 and a production-signed Windows package remain unverified.

## C. Existing production RULESETS architecture

The audited pipeline is:

`ok24 authenticated routing UI/BFF`
→ `PostgreSQL immutable routing releases and active pointer`
→ `zeon-server public current-release handler`
→ `/routing/v1/rule-sets/current` with generation/checksum/ETag`
→ `ManagedRuleSetSync`
→ schema/checksum/SRS validation
→ temporary release directory and atomic active-pointer activation
→ on-disk LKG/SRS assets
→ profile/routing model
→ zeon-core rule compilation
→ sing-box effective route rules.

### Source of truth and versioning

PostgreSQL is canonical. Admin mutations create an immutable release and then
advance the active release using expected-generation/CAS semantics; the audit
trail records the change. A client never consumes a half-authored admin row.
The public document exposes the active generation and deterministic checksum.

### Distribution, validation, and LKG

`/routing/v1/rule-sets/current` is public read-only. Its strong ETag is derived
from generation and checksum; `If-None-Match` returns 304; cache policy is
`public, max-age=300, must-revalidate`. The Dart sync implementation is in
`lib/features/route_rules/data/managed_rule_set_sync.dart`.

The client validates the document, release identity, checksum and referenced
SRS artifacts before activation. It writes a complete candidate release in a
temporary location and switches the active reference only after validation.
Malformed/incomplete downloads leave the previous active/LKG release intact.
Offline startup reads the active/LKG release; embedded/profile behavior remains
the final fallback for clients without a downloaded release.

### Core compilation and priority

The client does not treat HTTP 200 as success by itself. Active rules are fed
into the core options builder and compiled by zeon-core into sing-box rules and
SRS references. The effective ordering now proven in source and generated
configuration is:

1. mandatory control-plane route for `api.zeon-vps.online`;
2. explicit user rules;
3. managed application package rules after per-app user deselections;
4. profile/configured RULESETS in their preserved relative order;
5. core defaults.

`MobileApiProxyRoute.planCoreRules` re-numbers each transport bucket because
zeon-core sorts enabled rules by `list_order`. Generated application rules use
the current `package_names` field. Current outbound values were verified as
VPN `0`, DIRECT `1`, and BLOCK `3`.

## D. Production RULESETS evidence after deployment

Final live response:

- endpoint: `GET https://api.zeon-vps.online/routing/v1/rule-sets/current`;
- HTTP 200, JSON content length 631292;
- generation `6`;
- ETag `"routing-6-6e87e6bfdbf2ed449f432e5ece4c9a357e611b78f53809f2fde6e828cb429ae0"`;
- checksum `6e87e6bfdbf2ed449f432e5ece4c9a357e611b78f53809f2fde6e828cb429ae0`;
- two active rule sets in deterministic order;
- `If-None-Match`: HTTP 304;
- invalid/non-current request behavior and public-read semantics: PASS;
- sanitized generated config: the active SRS-backed rules reached the core,
  not merely the Dart model.

Generation, checksum and ETag are unchanged from immediately before the managed
deployment.

## E. Relevant production topology

| Server/component | Role in this pipeline | Storage/API | Source/deployed version | Result |
| --- | --- | --- | --- | --- |
| `130.49.151.173` nginx | public TLS edge for REST/WSS | proxies domain and retained legacy listener | backed-up parallel vhost | PASS |
| `130.49.151.173` zeon-server | RULESETS and managed-app public handlers; bind WSS integration | systemd service behind nginx | deployed integration `eb9c789559cae4c748000892e1b1f69772172d29`, contains task commit `6dd82916` | PASS |
| production PostgreSQL on the same private/server-local topology | canonical RULESETS and managed-app state/audit/RPC | Docker/private DB, not public | migration 191 applied once | PASS |
| `ok24-server.com` / production Netlify admin | authenticated admin UI and BFF | server-only DB relay | integration `abd1a16c53cb0f1693b4716645bbda648e648443`; deploy `6a9024775ac75eba8d0cc00e` | PASS |
| `api.zeon-vps.online` | public control-plane name | RULESETS, managed apps, bootstrap and WSS | resolves to the single observed edge | PASS |

No additional control-plane/routing replica was discovered in checked
production configuration. No multi-replica claim is made. VPN traffic nodes do
not host these components and were not touched.

## F. Managed applications design after RULESETS comparison

Managed applications remain a separate document at
`/routing/v1/applications/current`; they were not forced into the large
RULESETS release. They have different update frequency and independent legacy
client compatibility, and an application-only edit must not rebuild SRS
artifacts.

The implementation now follows the same conventions:

- canonical PostgreSQL state plus audit and expected-version CAS;
- deterministic versioned public JSON;
- content checksum, strong/normalized ETag and 304;
- strict model validation before activation;
- atomic `active.json` replacement and LKG;
- embedded version 1 fallback;
- monotonic rollback rejection;
- redacted diagnostics;
- deterministic core compilation.

The two versions are intentionally independent because neither document refers
to the other's version. The client reads only complete validated snapshots and
combines them deterministically at core-config generation. Therefore a mixed
RULESETS-generation/application-version pair is valid rather than a partial
cross-document transaction.

## G. Production database

Before migration, schema/inventory/collision/privilege checks and a production
backup were made under:

`/var/backups/zeon/managed-routing-20260827T112200Z`

Additive migration `191_managed_applications.sql` was reviewed and applied once
to the canonical production DB. Verified:

- version 1 initialization;
- exactly 49 Android entries;
- all initial routes DIRECT;
- LF-list historical SHA-256
  `a03f95ed90fcd1ab34692d8841a2e03c4d104b5c91d6c562d97ae6e0932184bb`;
- uniqueness/order/route constraints and duplicate protection;
- audit rows;
- expected-version CAS and stale conflict;
- RPC mutation path.

Rollback is additive: stop serving/administering the feature and retain tables
and audit. No destructive DB rollback was prepared or executed.

## H. zeon-server production deployment

One relevant zeon-server instance was updated after backup and tests. Source
and production match integration SHA
`eb9c789559cae4c748000892e1b1f69772172d29`; service and nginx health passed.

Final managed endpoint evidence:

- HTTP 200 and valid deterministic JSON;
- version `12`, exact 49-entry baseline;
- checksum `a34bca69f77779a11b9e7a8154813f620f54aa28280b3530752cef21fe8dae08`;
- ETag `"managed-apps-12-a34bca69f77779a11b9e7a8154813f620f54aa28280b3530752cef21fe8dae08"`;
- `If-None-Match`: HTTP 304;
- cache policy `public, max-age=300, must-revalidate`;
- disabled rows omitted from client effect while retained for administration.

## I. Production admin

The authenticated BFF and managed-app UI were deployed through the production
ok24 integration. Rollback deployment is `6a7f45c291786e00085edec4`.

Real reversible production mutations proved:

- create version 2; stale CAS returned 409;
- route VPN version 3; BLOCK version 4;
- disable version 5; re-enable/reorder version 6; delete version 7;
- physical-device test row: create DIRECT v8, BLOCK v9, disable v10,
  re-enable v11, delete v12.

For each mutation, DB version and public endpoint advanced together. Final
state was restored to the exact 49-entry baseline at version 12.

The deployed production bundle, BFF tests, and authenticated CRUD path pass.
An additional visual click-through could not be run because this environment
reported zero connected browser backends; no alternate unauthenticated browser
or credential extraction was used. This is recorded as a UI-automation evidence
gap, not hidden as an API failure.

## J. Physical Android fresh-install E2E

Device: OnePlus GM1901 (`OnePlus7`), Android 16/API 36, connected through ADB.
Tests used an isolated debuggable application id so the installed production
client and its data were not overwritten.

- clean state had embedded version 1 with exactly 49 packages: PASS;
- routing UI was non-empty: PASS;
- installed packages resolved display names and icons (including RuStore and
  ZEON): PASS;
- default managed route was DIRECT: PASS;
- production-domain sync activated server version 8/count 50 during the
  reversible test: PASS;
- final server version 12 returned to exact baseline count 49: PASS;
- effective generated core config contained one DIRECT `package_names` rule
  covering all 49 baseline packages: PASS;
- final generated config had 26/26 SRS chunks, 12 rules, and no deleted canary
  package: PASS.

The original 1.4.2 defect (empty zero-install application routing) is therefore
reproduced as fixed on a real device, not inferred from unit tests.

## K. Admin → DB → API → Android → core

The canary package was created as DIRECT at version 8. The public document and
device active state became version 8/count 50, the UI displayed the item, and
the generated core configuration contained its `package_names` route. Admin
then changed it to BLOCK at version 9; the device downloaded version 9 and the
core plan reflected the changed managed state subject to the user override
described below. Versions 10–12 proved disable, re-enable and delete propagation.

This establishes the complete real path:

`production admin/BFF → PostgreSQL RPC/audit → versioned public API → Android
validation/LKG → routing UI → generated core configuration`.

## L. Per-app user override

On the device, the user manually deselected the canary application. The server
then changed its managed route to BLOCK at version 9. After synchronization:

- the application remained deselected in UI;
- the user override survived the server version increase;
- no BLOCK/core rule for that package was emitted;
- later disable/delete did not damage the override store or other application
  choices.

This is the current product's per-app manual override semantics: explicit user
deselection wins over the managed route. The test does not invent a separate
three-state UI that the current application does not expose.

## M. Offline, LKG, malformed, rollback, and atomicity

Real-device negative tests used only the isolated validation package and
`adb reverse` to a controlled localhost response. The response was derived
from the exact production 49-entry baseline. Production DNS/API and the normal
client were not modified.

- offline restart after server sync loaded the active LKG: PASS;
- clean state with backend unavailable and no LKG loaded embedded v1/count49:
  PASS;
- valid controlled v100 activated count49: PASS;
- malformed JSON on restart was rejected; active v100/count49 stayed byte-for-
  byte unchanged (SHA-256
  `EEE882B56609CE71119E80193F3FB7822D81E6E999166A9244EB949EC8EABE0E`),
  UI remained populated, and a redacted sync warning was emitted: PASS;
- server rollback v99 after v100 was rejected by
  `ManagedApplicationStore.install`; active bytes/version remained unchanged:
  PASS;
- an injected half-written `active.json.tmp` followed by process restart was
  ignored; the complete v100 active file remained unchanged: PASS.

Afterward the reverse mapping, temporary device file and isolated app data were
removed, the original production-domain validation APK (SHA-256
`D370F3B05D2A89DA7C7A18D90B444C7DE19E465000F7346A5993BFCEF9AD8E88`)
was restored and force-stopped. Final ADB state has no reverse mappings and no
ZEON/validation process running.

## N. Upgrade from existing 1.4.2

A same-package upgrade over the existing 1.4.2 device state preserved the
production profile and user application-routing data. Managed initialization
added only missing managed defaults and did not clear existing explicit
choices. The upgraded build synchronized, generated the new rules and could be
returned to the original production package/data state. PASS.

## O. Existing RULESETS regression

After DB, zeon-server, admin, all production mutations, Android E2E, and final
cleanup:

- RULESETS endpoint: HTTP 200;
- generation: 6 unchanged;
- checksum/ETag: unchanged;
- conditional request: HTTP 304;
- SRS/cache/LKG path: PASS;
- generated core RULESETS output: PASS;
- managed endpoint: v12/count49, HTTP 200/304;
- pricing regression: HTTP 200;
- bind WSS/domain path: PASS from controlled canary.

Managed applications did not alter or invalidate the existing RULESETS release.

## P. Production changes and rollback

| Component | Backup/previous | Deployed | Health/rollback |
| --- | --- | --- | --- |
| PostgreSQL | `/var/backups/zeon/managed-routing-20260827T112200Z` | additive migration 191, final v12/count49 | constraints/CAS/audit PASS; disable feature and retain tables |
| zeon-server on `130.49.151.173` | pre-deploy source/config backup | `eb9c789559cae4c748000892e1b1f69772172d29` | systemd/nginx/endpoints PASS; restore backup/previous SHA |
| ok24 production | prior Netlify deploy `6a7f45c291786e00085edec4` | integration `abd1a16c...`, deploy `6a9024775ac75eba8d0cc00e` | bundle/API CRUD PASS; redeploy rollback id |
| Android test device | installed production package/data retained | isolated validation package only | test package restored/force-stopped; no reverse mapping |

No production-only source edit was made. The old IP/listener, VPN nodes,
host proxy/VPN/TUN/WFP, and installed host Windows client were not changed.

## Q. Tests after the last code/production change

### zeon-app

- full Flutter suite: **489 PASS, 0 FAIL, 24 SKIP**;
- managed-routing targeted: **17 PASS**;
- final domain/Windows/network/native target sets from this pass: PASS;
- targeted analyze of changed task files: 0 errors, 0 warnings, 1 info;
- `git diff --check`: PASS, with pre-existing PowerShell CRLF notices only;
- Android validation APK signature/package/arm64 install: PASS;
- whole-tree analyze is not a release signal: it reports 984 pre-existing
  issues in generated `out`, third-party and legacy paths.

### zeon-server

- managed integration: **19 PASS**;
- WSS/logging aggregate: **27 PASS**;
- TypeScript build: PASS;
- full Vitest: **174 PASS**, with 3 pre-existing unrelated failures.

### ok24

- managed admin targeted: **11 PASS**;
- production bundle: PASS;
- full suite: **213 PASS**, with 1 pre-existing live certificate timeout.

### Native/Windows

- native WinHTTP WebSocket, proxy recovery and `/W4 /WX` compilation: PASS;
- Windows release build: PASS;
- Authenticode: NOT VERIFIED; available artifact remains unsigned.

## R. Release readiness

- Git state safely preserved: **YES**
- domain internal canary: **PASS**
- Windows domain path: **PASS** (Windows 10; Windows 11 not tested)
- Android domain path: **PASS**
- existing RULESETS pipeline: **VERIFIED**
- rulesets reach core: **VERIFIED**
- managed applications follow rulesets conventions: **YES**
- DB production migration: **DEPLOYED**
- zeon-server managed API: **DEPLOYED**
- admin managed UI/BFF: **DEPLOYED**
- 49 baseline restored: **VERIFIED**
- fresh Android install: **PASS**
- names/icons for installed matching packages: **PASS**
- managed rules reach core: **PASS**
- admin → DB → API → client: **PASS**
- per-app user override: **PASS**
- offline LKG: **PASS**
- embedded fallback: **PASS**
- malformed config safety: **PASS**
- version rollback protection: **PASS**
- interrupted/half-written activation recovery: **PASS**
- 1.4.2 upgrade migration: **PASS**
- existing RULESETS regression: **PASS**
- safe for managed-routing canary: **YES**, controlled client group only
- safe for domain broad rollout: **NO** — Windows 11, signing, replica proof
  and production soak remain
- safe for managed-routing broad rollout: **NO** — controlled canary/soak and
  interactive admin UI evidence remain
- Windows signed release: **NOT VERIFIED**

TickTick task synchronization could not be performed: no TickTick connector is
installed/connected in this session, and the earlier installation request was
not accepted. No task status was guessed or changed outside the verified work.

The next authorized step is a small managed-routing client canary with soak and
aggregated redacted telemetry. It is not removal of the legacy IP listener and
not a broad client rollout.
