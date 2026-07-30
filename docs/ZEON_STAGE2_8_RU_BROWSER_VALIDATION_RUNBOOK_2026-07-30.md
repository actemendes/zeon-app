# ZEON Stage 2.8 — real-browser validation on OnePlus GM1901

Status: **NOT RUN / NO PASS**.

This runbook and `scripts/validate_stage2_8_ru_browser.ps1` define the
physical-device evidence gate for Stage 2.8. They do not contain results from a
OnePlus, do not turn an HTTP probe into a browser result, and never assign a
Stage 2.8 PASS automatically.

## Scope and safety boundary

The test must use the real `com.android.chrome` UI on the physical OnePlus
GM1901 (Android 16 / API 36). `HttpsURLConnection`,
`RussianServicesValidationActivity`, `curl`, and host-side HTTP clients are not
substitutes.

Use the isolated ZEON package whose application ID ends in `.validation` for
instrumentation and tests that do not need production data. Migration and
same-package physical browser validation may instead use the install-only
`physicalValidation` APK. That build has the production application ID and
release certificate, is debuggable, and must contain the
`ZEON_ROUTE_VALIDATION` marker. It may be assembled or installed, but Gradle
rejects its AAB/publish tasks.

The harness rejects `com.zeon.hiddify` by default. Allowing it requires both
`-AllowProductionPhysicalValidation` and the exact artifact hash through
`-ExpectedZeonApkSha256`. The harness hard-fails if the expected device,
browser, package, telemetry marker, or pinned hash is absent. It also pins the
installed APK SHA-256 to the evidence session, so a reinstall cannot silently
mix builds in one matrix. Android instrumentation remains restricted to the
isolated `.validation` target.

Before testing:

- use a dedicated validation device/browser state, signed out of personal
  accounts;
- do not enter credentials, one-time codes, bank details, addresses, or other
  personal data;
- do not log in, pay, place an order, buy a ticket, or submit an application;
- do not clear a personal Chrome profile as part of this procedure;
- disable Chrome sync and close unrelated tabs before capture;
- keep Android language, timezone and network unchanged across the three
  presets unless the test explicitly records the change;
- make sure per-app bypass is OFF. Every application, including Chrome, must
  remain inside ZEON's normal TUN when ZEON is connected.

The harness does not read Chrome history, cookies, request headers, response
bodies, or an unrestricted logcat. It records a device epoch before each page,
uses logcat's server-side `ZEON_ROUTE_VALIDATION` regex, and stores only
structured events at or after that boundary; it does not erase the device's
log buffers. Resolved destination IPs must be HMAC hashes. Local
screenshots and manually recorded public exit IPs are sensitive evidence and
stay under the git-ignored `.codex-artifacts/` directory; do not publish them
without a privacy review.

## Exact comparison matrix

Every mandatory site must be inspected in all three states:

| Preset | Device state | Expected route for a mandatory Russian resource | Expected DNS |
|---|---|---|---|
| Direct | ZEON disconnected; no other VPN | ordinary physical Russian path | physical/direct baseline |
| Russia | ZEON connected; region `Russia` | `DIRECT` | `DIRECT` |
| Global | ZEON connected; global/other preset | `VPN` | remote/global |

For a Russia-mode page, a DIRECT main document with a VPN API, image, CDN,
WebSocket or other mandatory resource is:

```text
MIXED ROUTING FAILURE
```

It is not a partial PASS. Record the failing hostname and its telemetry, prove
that the resource is mandatory in the browser, then add only that resource
family to an independently reviewable direct rule. Advertising and optional
analytics are not grounds for a direct exception.

Run two separate, APK-pinned sessions for the DNS A/B:

1. `REMOTE_DNS_BASELINE` — the existing remote-DNS behavior, kept only as a
   comparison artifact.
2. `DIRECT_DNS` — the Stage 2.8 candidate: Russia DIRECT route plus DIRECT DNS.

Do not change the Global DNS policy merely to make this A/B pass. Compare CDN
selection, CNAME behavior, IPv4/IPv6 answers, page completeness, region
warnings and telemetry between the two sessions. Only the `DIRECT_DNS`
candidate can be considered for Stage 2.8 acceptance.

`-DnsVariant` only labels evidence from an APK/configuration that the operator
prepared beforehand. The harness does not switch DNS, edit ZEON preferences or
mutate the runtime routing policy.

## Commands

PowerShell 5.1 or later and Android platform-tools are required. Connect and
unlock exactly one GM1901 and authorize USB debugging. For an isolated
`.validation` APK, run:

```powershell
.\scripts\validate_stage2_8_ru_browser.ps1 -Action Preflight

.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action Initialize `
  -DnsVariant DIRECT_DNS `
  -BuildLabel stage2.8-direct-dns
```

For a release-signed, same-package `physicalValidation` APK, pass the explicit
opt-in and the expected lowercase or uppercase SHA-256 on every action that
runs preflight:

```powershell
$physicalValidationSha = "<64-hex APK SHA-256>"

.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action Preflight `
  -ZeonPackage com.zeon.hiddify `
  -AllowProductionPhysicalValidation `
  -ExpectedZeonApkSha256 $physicalValidationSha

.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action Initialize `
  -ZeonPackage com.zeon.hiddify `
  -AllowProductionPhysicalValidation `
  -ExpectedZeonApkSha256 $physicalValidationSha `
  -DnsVariant DIRECT_DNS `
  -BuildLabel stage2.8-physical-validation-direct-dns
```

ADB is resolved from `-AdbPath`, `PATH`, `ANDROID_SDK_ROOT`, or `ANDROID_HOME`
in that order. Use an explicit executable path when multiple SDKs exist:

```powershell
.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action Preflight `
  -AdbPath C:\Android\platform-tools\adb.exe
```

`Initialize` prints a new session path such as
`.codex-artifacts/stage2.8-ru-browser/<timestamp>-direct_dns`. Reuse that exact
path for each preset:

```powershell
.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action RunPreset `
  -Preset Direct `
  -SessionPath <session-path>

.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action RunPreset `
  -Preset Russia `
  -SessionPath <session-path>

.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action RunPreset `
  -Preset Global `
  -SessionPath <session-path>
```

For a same-package session, add `-ZeonPackage com.zeon.hiddify`,
`-AllowProductionPhysicalValidation`, and
`-ExpectedZeonApkSha256 $physicalValidationSha` to every `RunPreset` command.
`Finalize` reads the already pinned local session and does not preflight the
device again.

The script stops before each preset until the operator types `READY`, and
machine-checks that `tun0` is absent for Direct and present for Russia/Global.
The exact Russia-versus-Global selection is still an operator attestation
because Android exposes no reliable public API for ZEON's selected preset. The
script starts each URL after `OPEN` with an Android `ACTION_VIEW` intent constrained to
`com.android.chrome`, verifies that Chrome is in the foreground, captures a
real browser screenshot, and extracts the allowlisted route/DNS events. It
never interprets a successful `am start` as a page PASS.

An interrupted preset run is resumable. Completed site directories are
immutable and skipped on the next invocation; a partial site directory is
never overwritten and requires manual review.

After all captures, edit only the generated
`operator-observations.csv`. Use:

- `PASS` or `NOT_APPLICABLE` for functional checks;
- `NONE` or `PRESENT_EXPLAINED` for CAPTCHA, anti-bot, VPN/proxy warning,
  foreign-region warning and rate limiting;
- `PASS` for route and DNS telemetry only after inspecting the corresponding
  JSONL;
- `NONE` for `MixedRouting` only after every observed mandatory Russia-mode
  resource is DIRECT;
- `RECORDED` for diagnostic pages after their required fingerprint fields are
  recorded;
- `Notes` for every `NOT_APPLICABLE` or `PRESENT_EXPLAINED` judgment that is
  not self-evident.

Use the ISO code `RU` in `PublicCountry`. For an unavailable public address
family, record `UNAVAILABLE` rather than leaving IPv4/IPv6 blank. The Direct and
Russia `ru_public_exit` rows must classify the ordinary Russian ASN as
`residential` or `mobile`; `unknown`, `hosting`, and `datacenter` do not satisfy
that acceptance check.

Then run:

```powershell
.\scripts\validate_stage2_8_ru_browser.ps1 `
  -Action Finalize `
  -SessionPath <session-path>
```

Finalization checks the complete 3-by-site matrix, screenshots, telemetry,
operator fields and automated route assessments. Its strongest result is
`OPERATOR_EVIDENCE_COMPLETE`; `stagePassAssigned` is always `false`.

## Mandatory browser sites

The harness contains all required entry points:

- Gosuslugi, ESIA, the Goskey public page, Nalog, Mos.ru, the Central Bank and
  SBP;
- Sber, T-Bank, Alfa-Bank, VTB, Gazprombank, Raiffeisen and Sovcombank;
- Yandex, Yandex Search, Yandex Maps, Yandex Music and Kinopoisk;
- Wildberries, Ozon, Avito, Megamarket and Yandex Market;
- VK, Mail.ru, OK, Dzen, 2GIS, Rutube and RuStore;
- RZD, Aeroflot, HH, RIA and Lenta.

The catalog is asserted as 36 mandatory services plus 8 diagnostics. Across
Direct, Russia and Global this is exactly 44 × 3 = 132 captures.

For every applicable site, inspect visual load, JavaScript, CSS, images, API
responses, CDN resources, redirects, search, public cards, video
preview/playback and WebSocket behavior. Also check for an infinite spinner,
CAPTCHA, anti-bot interstitial, VPN/proxy warning, foreign-region warning and
rate limiting. A home page screenshot alone is insufficient.

Specific high-risk checks:

- **Yandex:** run a public search, pan/zoom Maps until tiles and search results
  load, open public Music content and a preview where legally available, open a
  public Kinopoisk card/trailer preview, and correlate static/API/image/CDN and
  WebSocket hostnames. Follow public authentication redirects only far enough
  to prove the page renders; never enter an account.
- **Wildberries:** load the home page and catalog search, open several public
  product cards, inspect image variants, and verify bootstrap/API/CDN behavior.
  Adding a non-restricted item to a temporary cart and removing it is allowed
  only if no account is needed. Never proceed to checkout or purchase.
- **Banks and government services:** use public product/information pages and
  public search only. Do not enter an online bank, ESIA or tax account.
- **Video/media:** a thumbnail is not playback evidence. Start only freely
  available public preview/playback, observe startup and several seconds of
  stable media, then stop.
- **Travel/marketplaces/jobs:** public search and public cards are allowed;
  booking, ordering, payment and application submission are prohibited.

When a capability genuinely does not exist on a site, mark it
`NOT_APPLICABLE` and explain why. Do not use `NOT_APPLICABLE` to hide a failed
script, API, CDN, redirect, media request or WebSocket.

## VPN-detection and DNS evidence

The diagnostic pages are captured in Direct, Russia and Global:

- `2ip.ru` for the Russian-routed public exit;
- `ipinfo.io` for the global public exit, country and ASN;
- `test-ipv6.com` for IPv4/IPv6 reachability;
- BrowserLeaks DNS, WebRTC and JavaScript pages for DNS region, WebRTC,
  timezone and language;
- `ripn.su` and the punycode form of `Наука.рф` for explicit `.su` and
  `.xn--p1ai` suffix-route evidence.

Record:

- public country and exact IPv4/IPv6 where shown;
- ASN and the evidence-backed category
  `residential`, `mobile`, `hosting`, `datacenter`, or `unknown`;
- DNS region;
- WebRTC-visible addresses/behavior;
- timezone and language consistency;
- VPN/proxy and foreign-region warnings;
- CAPTCHA, anti-bot challenges and rate limiting.

In Russia mode the Russian diagnostic destination and mandatory Russian sites
must observe the ordinary direct Russian exit, not the foreign VPN server.
Global diagnostic destinations are expected to follow the preset's normal VPN
rules; do not infer the Russian site's exit merely from a non-Russian IP-check
page.

The `.su` and `.xn--p1ai` diagnostics are route gates: they require
hostname-correlated `DIRECT` routing in Russia, with DIRECT DNS in the
`DIRECT_DNS` session and remote DNS in the `REMOTE_DNS_BASELINE` session.
Global requires `VPN`/remote-DNS telemetry. These hosts remain in the
validation-only telemetry allowlist; adding them does not create a
service-specific production override.

## Telemetry review

Each JSONL event must contain:

```text
hostname
resolved IP hash
IPv4/IPv6
matched rule
matched rule set
DIRECT/VPN/BLOCK
DNS DIRECT/REMOTE
protocol
generation
```

For each mandatory Russia-mode site:

1. Confirm at least one separate `kind=dns` event and one `kind=route` event.
   A `dns` field copied into a route event does not replace DNS evidence.
2. Confirm a resolved-IP DNS event exists for the browser entry hostname.
3. Confirm every non-empty generation in the capture is identical and matches
   the active ZEON session. Mixed generations are rejected as reconnect/stale
   evidence.
4. Confirm route evidence contains the browser entry hostname, its resolved IP
   hash, IPv4/IPv6 family and a correlated DNS decision. Events without this
   hostname correlation are rejected by the harness.
5. Confirm every mandatory resource observed by the browser is represented by
   an allowlisted hostname or is explicitly investigated as a coverage gap.
6. Confirm every route outcome is `DIRECT`.
7. Confirm DNS is `DIRECT` for the direct-DNS candidate.
8. Confirm IPv4 and IPv6 decisions where both families were resolved.
9. Confirm the matched rule/rule-set explains the decision.

For Global, confirm the same Russian entry points still load and their
allowlisted route events use `VPN`. For Direct, ZEON telemetry must be absent
because ZEON is disconnected.

The telemetry build is validation-only. Do not publish its APK/AAB/AAR, do not
enable it in a production release, and do not expand its allowlist to ordinary
browsing.

## Acceptance boundary

Stage 2.8 remains **NO PASS** until a human reviews both DNS A/B sessions and
confirms:

- every mandatory Russian browser flow is complete in Direct, Russia and
  Global;
- Yandex and Wildberries are fully DIRECT in Russia;
- `.ru`, `.su`, `.xn--p1ai`, Russian IPv4 and Russian IPv6 decisions are
  represented in route evidence;
- all mandatory APIs/CDNs/resources are DIRECT in Russia with no mixed route;
- foreign destinations remain VPN in Russia and the Global preset is intact;
- Russian sites observe the ordinary Russian exit and no foreign VPN warning;
- no required CAPTCHA/anti-bot/rate-limit failure remains unexplained;
- validation telemetry covers each allowlisted resource and is absent from the
  production artifact.

Until those physical artifacts exist, the only accurate result is
`NOT RUN / NO PASS`.
