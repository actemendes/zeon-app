# Profile Timeout Diagnostics Report

- Started (UTC): `2026-05-28T11:06:16.792575+00:00`
- Finished (UTC): `2026-05-28T11:06:23.721638+00:00`
- User ID: `649669380`
- Primary: `https://130.49.151.173`
- Fallback: `https://zeon-vps.link`
- Iterations (default/fallback): `2/1`

## Resolved Context
- lookup ok: `True`
- vpn_uuid: `93c53af4-5f29-43c9-b9e0-7401039e59ab`
- subscription_id: `8489007b-8479-4f80-a463-2769e2656549`

## Endpoint Latency Summary

| target@vantage | count | p50(s) | p95(s) | p99(s) | max(s) | >=5s | >=15s | fail |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| connections_primary@device | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 | 2 |
| lookup_primary@device | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 | 2 |
| open_fallback_follow@device | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 | 1 |
| open_primary_follow@device | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 | 2 |
| subscription_primary@device | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 | 2 |

## Notes
- This run uses GET-only probes to avoid mutating production data.
- Client-flow timing from real device still requires adb capture while reproducing timeout.
