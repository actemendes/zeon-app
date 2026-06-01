# Profile Timeout Diagnostics Report

- Started (UTC): `2026-05-28T10:36:43.298467+00:00`
- Finished (UTC): `2026-05-28T10:49:13.168199+00:00`
- User ID: `649669380`
- Primary: `https://130.49.151.173`
- Fallback: `https://zeon-vps.link`
- Iterations (default/fallback): `100/30`

## Resolved Context
- lookup ok: `True`
- vpn_uuid: `93c53af4-5f29-43c9-b9e0-7401039e59ab`
- subscription_id: `8489007b-8479-4f80-a463-2769e2656549`

## Endpoint Latency Summary

| target@vantage | count | p50(s) | p95(s) | p99(s) | max(s) | >=5s | >=15s | fail |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| connections_primary@external | 100 | 0.192 | 0.208 | 0.238 | 0.259 | 0 | 0 | 0 |
| connections_primary@server-local | 100 | 0.056 | 0.072 | 0.082 | 0.098 | 0 | 0 | 0 |
| lookup_primary@external | 100 | 0.106 | 0.122 | 0.307 | 0.380 | 0 | 0 | 0 |
| lookup_primary@server-local | 100 | 0.043 | 0.051 | 0.075 | 0.080 | 0 | 0 | 0 |
| open_fallback_follow@external | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 | 30 |
| open_primary_follow@external | 100 | 0.222 | 0.247 | 0.271 | 0.276 | 0 | 0 | 0 |
| open_primary_follow@server-local | 100 | 0.063 | 0.074 | 0.095 | 0.107 | 0 | 0 | 0 |
| subscription_primary@external | 100 | 0.193 | 0.222 | 0.247 | 0.251 | 0 | 0 | 0 |
| subscription_primary@server-local | 100 | 0.055 | 0.065 | 0.085 | 0.091 | 0 | 0 | 0 |

## Server Journal Route Stats (last window)

| route | count | p95(s) | max(s) | >=5s | >=15s |
|---|---:|---:|---:|---:|---:|
| unknown | 2740 | 0.154 | 1.170 | 0 | 0 |

## Notes
- This run uses GET-only probes to avoid mutating production data.
- Client-flow timing from real device still requires adb capture while reproducing timeout.
