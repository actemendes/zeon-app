# Profile Timeout Diagnostics Report

- Started (UTC): `2026-05-28T12:42:59.373539+00:00`
- Finished (UTC): `2026-05-28T12:43:01.358070+00:00`
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
| connections_primary@server-local | 1 | 0.058 | 0.058 | 0.058 | 0.058 | 0 | 0 | 0 |
| lookup_primary@server-local | 1 | 0.047 | 0.047 | 0.047 | 0.047 | 0 | 0 | 0 |
| open_primary_follow@server-local | 1 | 0.091 | 0.091 | 0.091 | 0.091 | 0 | 0 | 0 |
| subscription_primary@server-local | 1 | 0.067 | 0.067 | 0.067 | 0.067 | 0 | 0 | 0 |

## Server Journal Route Stats (last window)

| route | count | p95(s) | max(s) | >=5s | >=15s |
|---|---:|---:|---:|---:|---:|
| GET /api/v1/connections?user_id=649669380 | 1 | 0.002 | 0.002 | 0 | 0 |
| GET /api/v1/connections?vpn_uuid=93c53af4-5f29-43c9-b9e0-7401039e59ab | 10 | 0.098 | 0.110 | 0 | 0 |
| GET /api/v1/connections?vpn_uuid=93c53af4-5f29-43c9-b9e0-7401039e59ab&format=v2ray | 426 | 0.076 | 0.172 | 0 | 0 |
| GET /api/v1/subscriptions/lookup?user_id=649669380 | 440 | 0.073 | 0.214 | 0 | 0 |
| GET /open/46513115 | 7 | 0.013 | 0.014 | 0 | 0 |
| GET /open/46513115?platform=hiddify | 3 | 0.012 | 0.012 | 0 | 0 |
| GET /open/649669380 | 647 | 0.442 | 0.988 | 0 | 0 |
| GET /open/649669380?platform=hiddify | 6 | 0.013 | 0.013 | 0 | 0 |
| GET /open/860281973 | 2 | 0.005 | 0.005 | 0 | 0 |
| GET /open/860296170 | 2 | 0.448 | 0.448 | 0 | 0 |
| GET /subscription/0fb6ac77-278e-49c8-97e2-273193f6a951 | 39 | 0.230 | 0.283 | 0 | 0 |
| GET /subscription/47338f43-3349-471e-8a15-8b87cf374355 | 34 | 0.228 | 0.267 | 0 | 0 |
| GET /subscription/54650a8b-b4b4-46dc-a302-d55169283966 | 1 | 0.017 | 0.017 | 0 | 0 |
| GET /subscription/82da2ac0-f3cb-4efc-a02d-a8a1de7b7ca3 | 1 | 0.891 | 0.891 | 0 | 0 |
| GET /subscription/93c53af4-5f29-43c9-b9e0-7401039e59ab | 985 | 0.163 | 1.121 | 0 | 0 |
| GET /subscription/a4192044-6880-4474-8222-1712bcc7ea62 | 10 | 0.086 | 0.091 | 0 | 0 |
| HEAD /open/649669380 | 1 | 0.054 | 0.054 | 0 | 0 |
| POST /api/v1/devices/rebind | 8 | 0.034 | 0.037 | 0 | 0 |
| POST /api/v1/users/create | 9 | 0.761 | 1.170 | 0 | 0 |

## Notes
- This run uses GET-only probes to avoid mutating production data.
- Client-flow timing from real device still requires adb capture while reproducing timeout.
