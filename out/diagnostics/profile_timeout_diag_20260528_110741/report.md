# Profile Timeout Diagnostics Report

- Started (UTC): `2026-05-28T11:07:41.869130+00:00`
- Finished (UTC): `2026-05-28T11:53:21.257405+00:00`
- User ID: `649669380`
- Primary: `https://130.49.151.173`
- Fallback: `https://zeon-vps.link`
- Iterations (default/fallback): `100/20`

## Resolved Context
- lookup ok: `True`
- vpn_uuid: `93c53af4-5f29-43c9-b9e0-7401039e59ab`
- subscription_id: `8489007b-8479-4f80-a463-2769e2656549`

## Endpoint Latency Summary

| target@vantage | count | p50(s) | p95(s) | p99(s) | max(s) | >=5s | >=15s | fail |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| connections_primary@device | 56 | 0.735 | 4.193 | 8.533 | 11.183 | 2 | 0 | 44 |
| lookup_primary@device | 70 | 0.498 | 0.849 | 1.238 | 1.315 | 0 | 0 | 30 |
| open_fallback_follow@device | 18 | 3.630 | 4.559 | 5.435 | 5.654 | 1 | 0 | 2 |
| open_primary_follow@device | 48 | 0.843 | 2.190 | 7.223 | 8.616 | 2 | 0 | 52 |
| subscription_primary@device | 57 | 0.834 | 2.835 | 8.347 | 9.245 | 2 | 0 | 43 |

## Notes
- This run uses GET-only probes to avoid mutating production data.
- Client-flow timing from real device still requires adb capture while reproducing timeout.
