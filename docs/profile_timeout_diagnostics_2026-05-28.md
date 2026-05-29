# Profile Rebind/Create Timeout Diagnostics (2026-05-28)

## Scope

Diagnostics for profile import/rebind path:

- app startup/import flow (`lookup -> create -> import -> rebind`)
- backend route latency on `130.49.151.173`
- primary vs fallback behavior
- device-side connectivity behavior via adb

All timestamps below are from **May 28, 2026**.

## Artifacts

- Full external + server-local benchmark (100 iterations): `out/diagnostics/profile_timeout_diag_20260528_103643/`
- Device benchmark (100 iterations): `out/diagnostics/profile_timeout_diag_20260528_110741/`
- Device startup log capture: `out/diagnostics/mobile_flow_log_20260528_150321.txt`
- Parsed server route stats for key endpoints: `out/diagnostics/profile_timeout_diag_20260528_103643/journal_route_summary_interesting.json`

## Key Findings

### 1) Backend core path (primary host) is fast and stable

From full run `profile_timeout_diag_20260528_103643`:

- `open_primary_follow@external`: p50 `0.222s`, p95 `0.247s`, fail `0/100`
- `lookup_primary@external`: p50 `0.106s`, p95 `0.122s`, fail `0/100`
- `subscription_primary@external`: p50 `0.193s`, p95 `0.222s`, fail `0/100`
- `connections_primary@external`: p50 `0.192s`, p95 `0.208s`, fail `0/100`

From server-local (same run):

- `open_primary_follow@server-local`: p95 `0.074s`
- `lookup_primary@server-local`: p95 `0.051s`
- `subscription_primary@server-local`: p95 `0.065s`
- `connections_primary@server-local`: p95 `0.072s`

### 2) Fallback domain is a different chain and is unstable

From full external run:

- `open_fallback_follow@external`: **fail `30/30`**
- error pattern: `curl (28) Operation timed out ... with partial body received`

Header check:

- `https://zeon-vps.link/open/<id>` returns redirect to:
  `https://ok24-server.com/.netlify/functions/subscription/<uuid>`

So fallback is not the same direct path as primary (`130.49.151.173/subscription/...`).

### 3) Device-side path is intermittent (connect stalls + partial body stalls)

From device run `profile_timeout_diag_20260528_110741`:

- `open_primary_follow@device`: success `48/100`, fail `52/100`, p95 `2.190s`, p99 `7.223s`
- `lookup_primary@device`: success `70/100`, fail `30/100`
- `subscription_primary@device`: success `57/100`, fail `43/100`, p99 `8.347s`
- `connections_primary@device`: success `56/100`, fail `44/100`, p99 `8.533s`
- `open_fallback_follow@device`: success `18/20`, fail `2/20`, p50 `3.630s`

Device error signatures:

- `curl (28) Connection timed out after ~5002ms` (connect-timeout hits)
- `curl (28) Operation timed out after ~20s with partial bytes received`
  - examples: `15901 / 619920` and `16202 / 520519` bytes

This means requests often either do not connect in 5s or stall while downloading large bodies.

### 4) Server logs confirm requests that reached backend were still fast

Window aligned with device load test (`14:07:30` to `14:53:30` MSK):

- `GET /open/649669380`: count `69`, p95 `0.037s`, max `0.043s`, `>=5s` = `0`
- `GET /subscription/<uuid>`: count `147`, p95 `0.115s`, max `0.197s`, `>=5s` = `0`
- `GET /api/v1/subscriptions/lookup`: count `71`, p95 `0.091s`, max `0.179s`, `>=5s` = `0`
- `GET /api/v1/connections?...format=v2ray`: count `77`, p95 `0.135s`, max `0.172s`, `>=5s` = `0`

Important: device attempted 100 calls per endpoint, but server saw fewer for several routes, consistent with client-side connect timeouts before requests reached backend.

Historical log stats for mutation endpoints (same server log dataset):

- `POST /api/v1/users/create`: p95 `0.761s`, max `1.170s`
- `POST /api/v1/devices/rebind`: p95 `0.033s`, max `0.037s`

## Attribution (whose side)

Primary timeout source is **not backend processing/DB latency** on `zeon-server`.

Most probable causes are:

1. **Client/network path instability on device side** (intermittent connect timeouts and transfer stalls).
2. **Fallback chain mismatch** (`zeon-vps.link -> ok24-server.com/.netlify/functions/...`) introducing additional instability.
3. Client import orchestration amplifies this via sequential attempts + retry strategy, reaching user-visible `90s` timeout.

## Implemented Tooling

Added reusable diagnostics tooling:

- `scripts/diagnostics/profile_timeout_diag.py`
  - external, server-local (SSH), and device (adb) probes
  - p50/p95/p99/max and timeout-share stats
  - server journal parsing by route
- `scripts/diagnostics/parse_mobile_flow_log.py`
  - parse logcat and extract flow timeline markers
- `scripts/diagnostics/capture_mobile_flow_log.ps1`
  - adb log capture with optional auto-launch of app package
- `scripts/diagnostics/README.md`
  - usage guide
