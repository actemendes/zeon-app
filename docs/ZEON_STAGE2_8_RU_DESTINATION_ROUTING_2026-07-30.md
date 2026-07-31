# ZEON Stage 2.8 — RU destination routing implementation record

Date: 2026-07-30  
Branch: `stage2.8/ru-destination-routing`  
Acceptance status: **PHYSICAL VALIDATION COMPLETE / FINAL VERDICT BELOW**

> The implementation narrative below is the preserved pre-validation baseline
> from 2026-07-30. Its `NOT RUN` statements are historical and are superseded
> by the physical-validation record and verdict appended to this same report on
> 2026-07-31.

Stage 2.8 is implemented locally as destination-based routing inside the
existing ZEON TUN. It does not use Android application allow/disallow lists to
classify Russian traffic, does not import ZapretKVN application selection or
VPN profiles, and does not connect an API/admin source for rule sets.

The code and unit/integration checks are complete. Physical browser validation
on the OnePlus GM1901, including the DNS A/B, is still mandatory before this
stage can receive PASS.

## Sole pinned reference

The only external architecture/rule-set reference used for this stage is:

```text
repository: https://github.com/youtubediscord/ZapretKVN-android
commit:     20794bfd2e4223c0d11dba73cab2a0f0fb354e07
tree:       490d86e6eea8dc16fd47e40c9914e6e942cc4963
```

Pinned links:

- [commit 20794bfd](https://github.com/youtubediscord/ZapretKVN-android/commit/20794bfd2e4223c0d11dba73cab2a0f0fb354e07)
- [RoutingConfigEditor.kt](https://github.com/youtubediscord/ZapretKVN-android/blob/20794bfd2e4223c0d11dba73cab2a0f0fb354e07/app/src/main/java/io/github/zapretkvn/android/routing/RoutingConfigEditor.kt)
- [zapret-ru-domains.json](https://raw.githubusercontent.com/youtubediscord/ZapretKVN-android/20794bfd2e4223c0d11dba73cab2a0f0fb354e07/rulesets/zapret-ru-domains.json)
- [reference rule-set manifest](https://raw.githubusercontent.com/youtubediscord/ZapretKVN-android/20794bfd2e4223c0d11dba73cab2a0f0fb354e07/app/src/main/assets/rule-sets/manifest.json)

No mutable `main` URL is used at runtime. `bol-van/zapret` was not used as an
architecture or rule-set source.

## Embedded rule-set snapshot

The exact pinned files and generated provenance are committed under
`hiddify-core/v2/config/rulesets/`.

| ID | Source file SHA-256 | SRS SHA-256 | Format | Counts |
|---|---|---|---|---|
| `zapret-ru-domains` | `311c8f5a2ef10b5ad2d52362db354e42dba45d34993816dae2cbf027867bea1b` | `a39faeb4a4c894a2ce665b8919322cee626f61dd12c63a63736fcf8b0a433053` | SRS v2 | 3 suffixes: `.ru`, `.su`, `.xn--p1ai` |
| `zapret-ru-ip` | `1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b` | `1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b` | SRS v1 | 10,842 CIDRs: 8,668 IPv4 and 2,174 IPv6 |

The copied reference manifest SHA-256 is
`7e231278c6d274428d80da7d92b42a62378a90ceaced913e7c9d69d627ccb37d`.
`manifest.json` records every required provenance field: ID, version, source
repository/commit/file/SHA-256, generated SRS SHA-256, license, generatedAt,
domain/CIDR counts and format version. `generatedAt` is explicitly documented
as the ZEON bundle assembly timestamp because the pinned reference does not
publish the original SRS generation time.

The reference manifest declares a pinned SagerNet source for the compiled IP
set. That declaration is preserved as unverified provenance; no second
repository was inspected or substituted.

At core startup the embedded SRS files are hash-verified and installed into the
working rule-set directory. Corrupt local copies are replaced atomically with a
recoverable Windows fallback.

## Effective Russia order

The generated route order is tested as:

1. internal/control-plane;
2. explicit user rules;
3. private/LAN `DIRECT` (always present in Russia, even if the general LAN
   toggle is off);
4. security/ad/QUIC block;
5. service-specific RU `DIRECT`;
6. `zapret-ru-domains` `DIRECT`;
7. `zapret-ru-ip` `DIRECT`;
8. profile/explicit global VPN rules;
9. final VPN.

The final Dart-to-Go payload re-numbers priority rules after semantic
deduplication, so Go's `list_order` sort cannot move a profile rule above an
explicit user rule. Profile rules are carried separately and inserted after
the RU IP rule only in Russia. Outside Russia they remain ahead of built-in
regional/final policy but after explicit user rules.

The Global preset does not install either bundled RU rule set and retains its
existing final VPN behavior.

## Domain and DNS preservation

Russia enables sing-box DNS reverse mapping. The reverse mapper now records
the original DNS question for returned IPv4/IPv6 addresses, rather than the
terminal A/AAAA record owner. Consequently:

```text
service.ru -> CNAME edge.example.com -> address
```

retains `service.ru` for the subsequent TUN connection. IPv4, IPv6 and CNAME
regressions are covered by tests. If a non-RU domain resolves to an address in
`zapret-ru-ip`, the post-resolution route rule sends that connection DIRECT.
FakeDNS is forcibly disabled only in Russia mode because a synthetic address
would otherwise hide the real IPv4/IPv6 destination from that IP matcher.
Global FakeDNS behavior is unchanged.

RU suffix and service-family DNS rules select direct DNS. The IP rule is not
installed as a pre-resolution DNS matcher. Global DNS policy is unchanged.
Actual CDN/CNAME answer differences between remote and direct DNS remain a
physical browser A/B gate.

## Yandex and Wildberries

The final service policies are independently isolated and independently
revertable:

```text
ab446d7d fix(routing): make Yandex override DIRECT
f427499d fix(routing): make Wildberries override DIRECT
```

Both literal `git revert --no-edit` operations were verified in a disposable
worktree. Neither service has an earlier effective VPN override.

The seed families are:

```text
Yandex:
  ya.ru yandex.ru yandex.net yastatic.net

Wildberries:
  wildberries.ru wb.ru wbbasket.ru wbstatic.net
  wbcontent.net rwb.ru wibes.ru
```

These are not claimed to be complete browser evidence. Cross-zone static, API,
image, CDN, authentication/bootstrap and WebSocket families must be added only
when the physical browser proves that they are mandatory. Advertising and
optional analytics must not be added.

## Android application routing

Fresh-install seeding of RU package exclusions was removed. Migration v17
removes only rows carrying the old ZEON-owned seed marker and preserves
unmarked explicit user choices, automatic/forced bits and non-empty modes.

Historic-data limitation: the legacy preference format cannot distinguish a
still-seed-owned package from a user who later manually re-selected that same
previously seeded package while the ownership marker remained. The one-shot
migration may clear that package's `userSelection` bit. This limitation cannot
be reconstructed without historic data and is disclosed rather than hidden.

No package-name rule or Android `allowedApplications`/`disallowedApplications`
mechanism was added for RU site classification.

## Validation-only telemetry

The `zeon_route_validation` build tag enables allowlisted, in-memory telemetry
for the required services and explicit `.su`/`.xn--p1ai` route gates. Events
contain:

```text
hostname
HMAC resolved-IP hash
IPv4/IPv6
matched rule
matched rule set
DIRECT/VPN/BLOCK
DNS DIRECT/REMOTE/BLOCK/UNKNOWN
protocol
generation
```

Plain IP destinations are not logged. The HMAC salt is per process; DNS
correlation is capped at 256 entries, expires after 10 minutes and is never
persisted. Ambiguous shared-IP correlation is not attributed. `DNS UNKNOWN` is
a validation failure, and a failed resolver exchange is explicitly marked
`DNS_EXCHANGE_FAILED` rather than being represented as a successful lookup.

The production build compiles no-op stubs. The production verifier rejects the
build tag and log marker unless validation mode is explicitly authorized.

## Browser evidence gate

`scripts/validate_stage2_8_ru_browser.ps1` and the paired runbook define 123
real-Chrome captures:

```text
33 mandatory services + 8 diagnostics
x Direct / Russia / Global
= 123 captures
```

The harness pins the installed validation APK SHA-256, checks GM1901/API 36,
Chrome, TUN state and telemetry marker, requires an entry-host DNS event and
hostname-correlated route event, rejects mixed VPN generations, and never
assigns Stage 2.8 PASS. `DIRECT_DNS` and `REMOTE_DNS_BASELINE` are evidence
labels for separately prepared builds/configurations; the harness does not
mutate DNS policy.

Current device preflight result:

```text
Expected exactly one authorized physical ADB device; found 0.
```

Therefore no page, Yandex flow, Wildberries flow, DNS A/B, public-exit check or
Global browser regression has been marked PASS.

## Verified locally

- pinned SRS source/hash/format/count/repair tests: PASS;
- full `v2/config` tests with Android production tags: PASS;
- `v2/hcore` tests with Android production tags: PASS;
- sing-box DNS/route/telemetry tests, production and
  `zeon_route_validation`: PASS;
- CNAME original-domain IPv4/IPv6 tests: PASS;
- 51 focused Flutter route/control-plane/migration tests: PASS;
- focused Flutter static analysis: no issues;
- PowerShell browser harness parser and `git diff --check`: PASS;
- browser preflight without a device: expected hard failure, no evidence
  session and no PASS.

Local implementation is ready for an isolated validation APK and the physical
OnePlus matrix. Stage 2.8 remains **NOT RUN / NO PASS** until those artifacts
are reviewed.

---

# Physical validation record — 2026-07-31

This section supersedes every preflight status above. Validation was performed
on the physical device and the exact installed artifacts described below. No
API or admin rule-set source was connected.

## Final verdict

```text
Browser RU services: CONDITIONAL PASS
VPN detection: INCONCLUSIVE
Local RU rule sets: PASS
Global regression: FAIL
Overall: FAIL
```

`Overall: FAIL` is mandatory because the exact production build did not
complete the required Global YouTube, Telegram and Cloudflare Speedtest
regression. The Russia destination-routing implementation itself passed its
strict hostname-correlated route gate. The verdict is not upgraded on the
strength of HTTP status codes alone.

## Device, browser and automation

```text
device: OnePlus GM1901
ADB serial: 18bfc103
Android: 16
API: 36
browser package: com.microsoft.emmx
browser version: 150.0.4078.96 (versionCode 407809623)
production package: com.zeon.hiddify
versionCode/versionName: 103001 / 1.3.0
```

`adb devices -l` returned exactly one authorized physical device:

```text
18bfc103 device product:OnePlus7 model:GM1901
```

The test used the installed real Chromium browser through its on-device CDP
socket. Each targeted retry force-stopped the browser first, used a clean test
tab, closed the scenario afterwards and did not inspect other tabs, history,
cookies, passwords or personal accounts. The browser was visually inspected
through contact sheets in addition to DOM and network capture. No login,
purchase or payment was performed.

## Exact artifacts

The production artifact was built from ZEON revision `07158f91`. The final
validation-only diagnostics allowlist is revision
`f9f523ab8324127168a9e0e43b4b0e2681a206d6`; it changes only code compiled with
`zeon_route_validation` and does not alter production routing.

| Artifact | SHA-256 |
|---|---|
| production core AAR | `6190b8a5396a105f4f3b9c966dfb340bc8f00045bc49975c9a149d57798eac96` |
| production arm64 APK | `adbb338b3312dc39353de7f43bc6c17866263d4fdc0e358872f82e51f64c80d9` |
| production AAB | `04ea72765112d86c7dd83669594d2b5b8342d528e76f476a522456895bc88ded` |
| full-matrix DIRECT_DNS validation APK, revision `35e98971` | `5dffe6e43181613bfb59b9600d9b25f256815e5259794684fdc81be0a4d54619` |
| final DIRECT_DNS validation core AAR, revision `f9f523ab` | `1e0f81da0aa0b14a6a0ee3aa8e13130b92afb6845cabc9361aacfe613eb6295e` |
| final DIRECT_DNS validation APK, revision `f9f523ab` | `1f798e19538fdfa05b8e098639374ba95272ff5654879d76eb23e04b61948a51` |
| REMOTE_DNS_BASELINE validation core AAR | `cc47b3455a9c5b643e5ea23c2bfc1826e830892ca773bf946a26f64e06cbcf62` |
| REMOTE_DNS_BASELINE validation APK | `052f2f3b8ed509fa130ac97c85c3b2c0935292d647daa37259677873b8efd798` |

Core build tags were
`with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack`.
Validation builds add `zeon_route_validation`; production does not.
DIRECT_DNS and REMOTE_DNS_BASELINE differ only in the tested DNS policy and
validation build identity.

Each installed APK was pulled back from `pm path` and hashed. The final
installed production `base.apk` is
`adbb338b3312dc39353de7f43bc6c17866263d4fdc0e358872f82e51f64c80d9`.

## Install and user-data preservation

All swaps used:

```text
adb -s 18bfc103 install -r -d <exact-apk>
```

No `adb uninstall`, `pm clear` or connected instrumentation against production
was run. `firstInstallTime` remained `2026-07-29 23:13:48` through validation,
DNS A/B and restoration of production. The profile database, subscription and
secure storage remained present. At handoff the original Russia preset was
restored, LAN bypass remained enabled and the app was left stopped.

## Migration v17

The migration implementation in `15f5d634` and `5c9c9ccc` satisfies the
required conservative rule: unknown origin is treated in favor of preserving
the user's explicit selection. The focused migration suite passed 24/24,
including:

1. unchanged seed-owned row removal;
2. user row preservation;
3. re-selected former seed package preservation;
4. automatic/forced bit preservation;
5. non-empty user mode preservation;
6. unknown-origin preservation;
7. idempotent rerun;
8. no RU package exclusions on fresh install.

Physical historic-data migration exposed a separate legacy bootstrap defect:
a preference stored as `String` was read as `StringList`, after which the old
production bootstrap cleared SharedPreferences and displayed onboarding. The
database, profile and secure subscription survived, but the exact pre-existing
package-selection preference state cannot be proven after that destructive
legacy fallback. The test therefore does **not** claim a physical migration
PASS for ambiguous old preferences. No attempt was made to reconstruct or
guess unavailable history.

## Production telemetry exclusion

Archive inspection of the exact production AAR/APK/AAB found none of:

```text
zeon_route_validation
ZEON_ROUTE_VALIDATION
route_evidence_logcat_enabled
route-telemetry.log
hostname_history
ip_history
```

The native library contains the local `zapret-ru-domains`,
`zapret-ru-ip` and `rulesets/manifest.json` payloads and does not contain a
mutable `raw.githubusercontent.com/.../main` RU-list URL. After a fresh
production connect/stop cycle, package-scoped logcat contained zero validation
markers. Production does not persist hostname or IP history.

## Final local rule-set manifest

Manifest SHA-256:

```text
17f10be4b391d753117c49445852bcc277773c9c98d49228adb062ca2fcecd92
```

| ID | Version | Source | Source file | Source SHA-256 | SRS SHA-256 | License | generatedAt | Counts | Format |
|---|---|---|---|---|---|---|---|---|---|
| `zapret-ru-domains` | `zapretkvn-20794bfd-manifest-v1` | `youtubediscord/ZapretKVN-android@20794bfd2e4223c0d11dba73cab2a0f0fb354e07` | `rulesets/zapret-ru-domains.json` | `311c8f5a2ef10b5ad2d52362db354e42dba45d34993816dae2cbf027867bea1b` | `a39faeb4a4c894a2ce665b8919322cee626f61dd12c63a63736fcf8b0a433053` | GPL-3.0-or-later | `2026-07-30T17:38:29.841Z` | domainCount 3; cidrCount 0 | SRS 2 |
| `zapret-ru-ip` | `zapretkvn-20794bfd-manifest-v1` | same pinned repository/commit | `app/src/main/assets/rule-sets/zapret-ru-ip.srs` | `1f4cccc9bb9510bb29d8a4b7d326b869bff94e9911d555acc0570545dabfaa7b` | same | GPL-3.0-or-later | `2026-07-30T17:38:29.841Z` | cidrCount 10,842: IPv4 8,668; IPv6 2,174 | SRS 1 |

The only architecture/rule-set reference was
`https://github.com/youtubediscord/ZapretKVN-android` at the pinned commit
above. `bol-van/zapret` was not used. Mutable `main` was not used.

## Browser matrix

The explicit mandatory list in the task contains 36 services, although the
formula in the task says 33. To avoid dropping three named services, the run
used the larger exact catalog:

```text
36 mandatory services + 8 diagnostics
x Direct / Russia / Global
= 132 physical browser captures
```

All 132 scenarios produced a capture. Final classifications:

| Preset | Results |
|---|---|
| Direct | 42 PASS; 2 INCONCLUSIVE |
| Russia | 41 PASS; 2 PASS WITH ANTI-BOT; 1 INCONCLUSIVE |
| Global | 27 PASS; 5 VPN DETECTED; 8 TRANSPORT PASS / APPLICATION REJECTED; 1 FOREIGN GEO BLOCKED; 3 INCONCLUSIVE |

Direct exceptions were Alfa-Bank's Chrome
`NET::ERR_CERT_AUTHORITY_INVALID` page and a strict incomplete-DOM result for
Megamarket. Russia's only inconclusive service was Alfa-Bank with the same TLS
page in all three modes. Wildberries received `PASS WITH ANTI-BOT`; Megamarket
received `PASS WITH ANTI-BOT`.

The full results are in `out/stage2-8/browser-service-matrix.csv`. Network
evidence contains 17,147 resources, and route/DNS evidence contains 2,908
deduplicated rows with event counts.

## Strict validation telemetry

The initial full matrix exposed reused browser sockets for three roots and an
omitted diagnostic allowlist. These were not accepted as PASS. Targeted runs
with a force-stopped browser supplied strict root evidence for CBR, Yandex
Search and Dzen. Revision `f9f523ab` added only the six diagnostic hostnames to
the validation build and produced final Russia and Global diagnostic captures.

For all 44 Russia rows:

```text
hostname-correlated root route: known
root DNS decision: known
ambiguous root attribution: 0
mandatory RU services with any VPN route event: 0
```

Foreign diagnostic pages intentionally use the final VPN rule in Russia and
are excluded from mixed-RU-service classification. They are not evidence of a
mixed Russian page.

Representative strict roots:

| Site | Root route | DNS | Matched set |
|---|---|---|---|
| CBR | DIRECT | DIRECT | `zapret-ru-domains` |
| Sber | DIRECT | DIRECT | `zapret-ru-domains` |
| Yandex Search | DIRECT | DIRECT | `zeon-ru-yandex` |
| Wildberries | DIRECT | DIRECT | `zeon-ru-wildberries` |
| Ozon | DIRECT | DIRECT | `zapret-ru-domains` |
| Dzen | DIRECT | DIRECT | `zapret-ru-domains` |

The Russia matrix recorded:

```text
zeon-ru-yandex:       143 route events / 26 hostnames / DIRECT / DIRECT DNS
zeon-ru-wildberries:  22 route events / 17 hostnames / DIRECT / DIRECT DNS
zapret-ru-ip:          49 route events / 21 hostnames / DIRECT
Global RU-set matches: 0
```

`zapret-ru-ip` matched required cross-zone resources for Ozon, Avito, 2GIS, VK
and other Russian services. IPv4 and IPv6 were both exercised by diagnostic
pages; no public IPv6 leak was observed in WebRTC.

## Yandex

Russia browser PASS covered the main page, search, maps, music, Kinopoisk and
Yandex Market. Main documents and the observed essential search, bootstrap,
static, image, API and CDN resources used DIRECT. No Yandex resource in the
allowlisted mandatory captures used VPN. The prior explicit VPN override is
absent before RU rules.

No new broad `.com`, `.net` or shared-CDN suffix was added. Existing service
rules plus the local RU domain/IP sets covered the browser evidence without
adding advertising or optional analytics.

## Wildberries

The Russia capture loaded the public main/catalog UI, images, static/CDN,
catalog/bootstrap and basket bootstrap without purchase. The first attempt
observed HTTP 498, but subsequent real-browser navigation rendered the catalog
and essential resources over HTTP/3. Because this behavior was consistent
with anti-bot state rather than a route defect, the result is:

```text
PASS WITH ANTI-BOT
```

All 22 correlated route events across 17 hostnames were
`DIRECT / DIRECT DNS` through `zeon-ru-wildberries`. No broad CDN or analytics
domain was added.

## Ozon and banks

Ozon loaded in Russia with no fatal redirect loop. Its main root was
`DIRECT / DIRECT DNS`; cross-zone CDN resources that resolved to Russian IPs
were sent DIRECT by `zapret-ru-ip`.

Public pages for the tested banks loaded in Russia except Alfa-Bank. Alfa's
Chrome TLS-chain error was identical in Direct, Russia and Global, so it is
reported as `INCONCLUSIVE`, not as a ZEON routing defect. No bank login was
attempted.

## DNS A/B

The full matrix used DIRECT_DNS. REMOTE_DNS_BASELINE was then used for 14
targeted paired cases: Yandex, Wildberries, Ozon, Gosuslugi/ESIA, two banks,
2GIS `.com`, CDN/IP and public-IP/DNS diagnostics.

```text
paired rows: 14
DIRECT_DNS readyState=complete: 14/14
REMOTE_DNS readyState=complete: 14/14
DIRECT_DNS not visually worse: 14/14
aggregate failed resources, DIRECT_DNS: 156
aggregate failed resources, REMOTE_DNS: 251
```

The aggregate failure counts are observational and order/cache sensitive, so
they are not used as a performance benchmark. CDP did not expose canonical
CNAME chains; this is recorded as `NOT_EXPOSED_BY_CDP`. DIRECT_DNS is retained
for production because the browser result was not worse and it avoids known
remote-edge ambiguity for matched RU domains.

## CNAME/CDN additions and routing before/after

No mandatory Russia resource was proven to require a new service-family domain:
all correlated mandatory resources were DIRECT. Therefore no speculative
service domain, shared CDN, broad `.com`/`.net` suffix or CIDR was added during
physical validation.

`out/stage2-8/cname-cdn-discovery.csv` records the 28 observed RU-IP/CDN
evidence rows. `out/stage2-8/routing-before-after.csv` records the independently
revertable Yandex and Wildberries changes and the bundled domain/IP behavior.

## VPN detection

Redacted HMAC evidence showed:

- Direct and Russia shared the physical public-exit hash for the Russian
  public-exit diagnostic;
- Global exposed a distinct VPN hash;
- Russia/Global WebRTC showed no public IPv6;
- Russian services showed no VPN warning in Russia;
- Gosuslugi, ESIA, Wildberries, Ozon and 2GIS showed explicit VPN warnings in
  Global.

Country, ASN number/category and DNS-resolver country were not captured in a
reliable redacted form. One Global diagnostic also contained a hash shared
with physical/static evidence whose attribution could not be proved. The
required country/ASN matrix therefore remains:

```text
VPN detection: INCONCLUSIVE
```

No full IP address is stored in the output files.

## Global regression

Global route telemetry used `final -> VPN / REMOTE DNS`, and no
service-specific RU DIRECT or local RU rule set was installed. No public IPv6
leak was observed.

However, the exact production artifact failed mandatory foreign-service
regression on the currently selected VPN endpoint:

```text
YouTube public browser endpoint: ERR_CONNECTION_CLOSED
Telegram public browser endpoint: ERR_CONNECTION_CLOSED
Cloudflare Speedtest: ERR_FAILED
two full Cloudflare Speedtests: not completed
exact-production HTTP/3 proof: not obtained
```

Basic HTTPS to `example.com` worked during restart cycles, so the tunnel was
not wholly down. The result is still `Global regression: FAIL`. No profile,
credential or server selection was changed to hide this endpoint-level
failure.

## Lifecycle and resources

Exact production results:

```text
connect/stop: 10/10 CONNECTED -> STOPPED
restart: 5/5 CONNECTED -> STOPPED -> CONNECTED with browser HTTPS capture
background/foreground: connection and notification retained
screen off 15 seconds: process, service and notification retained
notification/UI agreement: confirmed
Mobile.close main-looper block: not observed
```

After the final production connect/stop and 15-second settling:

```text
stopped UI: true
VPN notification records: 0
foreground service: false
production telemetry markers: 0
FATAL EXCEPTION: 0
ANR: 0
Go panic: 0
native panic / SIGSEGV: 0
ApplicationExitInfo crash/ANR tokens: 0
```

The process remained because the foreground UI was open; the VPN service and
notification had settled. The original Russia preset was restored and the app
was left stopped.

## Evidence files

Final redacted outputs:

```text
out/stage2-8/browser-service-matrix.csv
out/stage2-8/browser-network-resources.csv
out/stage2-8/browser-vpn-detection.csv
out/stage2-8/route-match-evidence.csv
out/stage2-8/dns-ab.csv
out/stage2-8/cname-cdn-discovery.csv
out/stage2-8/routing-before-after.csv
out/stage2-8/SHA256SUMS-redacted.txt
```

The evidence contains hashes/classification rather than full public IPs and
does not include the HMAC key, credentials, profile names, browser history or
personal data.

## Rollback

- Yandex routing can be rolled back independently with
  `git revert ab446d7d`.
- Wildberries routing can be rolled back independently with
  `git revert f427499d`.
- Migration behavior can be rolled back through its isolated commits
  `15f5d634` and `5c9c9ccc`.
- The local RU bundle/routing commits can be reverted without enabling a
  mutable remote list or adding an API.
- Device rollback is an in-place install of the previous signed production
  artifact; do not uninstall or clear app data.

## Limitations

1. The historic SharedPreferences bootstrap loss prevents proving every old
   package-selection bit on this device.
2. Country, ASN/category and DNS-country detection is incomplete; only
   redacted exit-hash behavior and site warnings are proven.
3. Chrome did not expose CNAME chains through CDP.
4. Alfa-Bank remained inconclusive because the same TLS-chain page appeared in
   all modes.
5. Exact-production YouTube, Telegram, two full Cloudflare Speedtests and
   HTTP/3 did not pass, causing Global and overall FAIL.
6. Telegram and YouTube were checked through public browser endpoints; private
   app UI/content was not opened.

Stage 2.8 remains local and versioned. No API/admin integration, Android
package-name routing, ZapretKVN profile, credentials or application-selection
UI was imported.
