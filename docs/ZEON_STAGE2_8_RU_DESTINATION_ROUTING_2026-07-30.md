# ZEON Stage 2.8 — RU destination routing implementation record

Date: 2026-07-30  
Branch: `stage2.8/ru-destination-routing`  
Acceptance status: **NOT RUN / NO PASS**

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
the RU IP rule only in Russia; their historical precedence is retained outside
Russia.

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
a validation failure.

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
