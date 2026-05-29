# Profile Timeout Diagnostics Report

- Started (UTC): `2026-05-28T10:53:54.867267+00:00`
- Finished (UTC): `2026-05-28T10:54:05.704692+00:00`
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
| connections_primary@external | 1 | 0.183 | 0.183 | 0.183 | 0.183 | 0 | 0 | 0 |
| connections_primary@server-local | 1 | 0.062 | 0.062 | 0.062 | 0.062 | 0 | 0 | 0 |
| lookup_primary@external | 1 | 0.108 | 0.108 | 0.108 | 0.108 | 0 | 0 | 0 |
| lookup_primary@server-local | 1 | 0.049 | 0.049 | 0.049 | 0.049 | 0 | 0 | 0 |
| open_fallback_follow@external | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 | 1 |
| open_primary_follow@external | 1 | 0.232 | 0.232 | 0.232 | 0.232 | 0 | 0 | 0 |
| open_primary_follow@server-local | 1 | 0.080 | 0.080 | 0.080 | 0.080 | 0 | 0 | 0 |
| subscription_primary@external | 1 | 0.223 | 0.223 | 0.223 | 0.223 | 0 | 0 | 0 |
| subscription_primary@server-local | 1 | 0.059 | 0.059 | 0.059 | 0.059 | 0 | 0 | 0 |

## Server Journal Route Stats (last window)

| route | count | p95(s) | max(s) | >=5s | >=15s |
|---|---:|---:|---:|---:|---:|
| GET /api/v1/connections?user_id=649669380 | 1 | 0.002 | 0.002 | 0 | 0 |
| GET /api/v1/connections?vpn_uuid=93c53af4-5f29-43c9-b9e0-7401039e59ab | 10 | 0.098 | 0.110 | 0 | 0 |
| GET /api/v1/connections?vpn_uuid=93c53af4-5f29-43c9-b9e0-7401039e59ab&format=v2ray | 207 | 0.031 | 0.081 | 0 | 0 |
| GET /api/v1/subscriptions/lookup?user_id=649669380 | 224 | 0.045 | 0.214 | 0 | 0 |
| GET /open/46513115 | 7 | 0.013 | 0.014 | 0 | 0 |
| GET /open/46513115?platform=hiddify | 3 | 0.012 | 0.012 | 0 | 0 |
| GET /open/649669380 | 431 | 0.448 | 0.988 | 0 | 0 |
| GET /open/649669380?platform=hiddify | 9 | 0.013 | 0.013 | 0 | 0 |
| GET /open/860281973 | 2 | 0.005 | 0.005 | 0 | 0 |
| GET /open/860296170 | 2 | 0.448 | 0.448 | 0 | 0 |
| GET /subscription/ | 1 | 0.001 | 0.001 | 0 | 0 |
| GET /subscription/0fb6ac77-278e-49c8-97e2-273193f6a951 | 43 | 0.225 | 0.283 | 0 | 0 |
| GET /subscription/47338f43-3349-471e-8a15-8b87cf374355 | 34 | 0.228 | 0.267 | 0 | 0 |
| GET /subscription/4b6c7341-0649-40d9-bf2f-083eee680787 | 1 | 0.146 | 0.146 | 0 | 0 |
| GET /subscription/54650a8b-b4b4-46dc-a302-d55169283966 | 1 | 0.017 | 0.017 | 0 | 0 |
| GET /subscription/82da2ac0-f3cb-4efc-a02d-a8a1de7b7ca3 | 1 | 0.891 | 0.891 | 0 | 0 |
| GET /subscription/93c53af4-5f29-43c9-b9e0-7401039e59ab | 592 | 0.445 | 1.121 | 0 | 0 |
| GET /subscription/a4192044-6880-4474-8222-1712bcc7ea62 | 10 | 0.086 | 0.091 | 0 | 0 |
| POST /api/v1/devices/rebind | 12 | 0.033 | 0.037 | 0 | 0 |
| POST /api/v1/users/create | 9 | 0.761 | 1.170 | 0 | 0 |

## Notes
- This run uses GET-only probes to avoid mutating production data.
- Client-flow timing from real device still requires adb capture while reproducing timeout.
