# Profile Timeout Diagnostics Report

- Started (UTC): `2026-05-28T11:07:01.472259+00:00`
- Finished (UTC): `2026-05-28T11:07:27.809847+00:00`
- User ID: `649669380`
- Primary: `https://130.49.151.173`
- Fallback: `https://zeon-vps.link`
- Iterations (default/fallback): `1/1`

## Resolved Context
- lookup ok: `True`
- vpn_uuid: `93c53af4-5f29-43c9-b9e0-7401039e59ab`
- subscription_id: `8489007b-8479-4f80-a463-2769e2656549`

## Endpoint Latency Summary

| target@vantage | count | p50(s) | p95(s) | p99(s) | max(s) | >=5s | >=15s | fail |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| connections_primary@device | 1 | 6.827 | 6.827 | 6.827 | 6.827 | 1 | 0 | 0 |
| lookup_primary@device | 1 | 1.015 | 1.015 | 1.015 | 1.015 | 0 | 0 | 0 |
| open_fallback_follow@device | 1 | 3.983 | 3.983 | 3.983 | 3.983 | 0 | 0 | 0 |
| open_primary_follow@device | 1 | 0.670 | 0.670 | 0.670 | 0.670 | 0 | 0 | 0 |
| subscription_primary@device | 1 | 1.270 | 1.270 | 1.270 | 1.270 | 0 | 0 | 0 |

## Notes
- This run uses GET-only probes to avoid mutating production data.
- Client-flow timing from real device still requires adb capture while reproducing timeout.
