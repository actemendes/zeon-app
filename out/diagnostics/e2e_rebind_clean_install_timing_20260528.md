# E2E clean-install timing (2026-05-28)

## Step A: uninstall + install
- Uninstall: success
- External traces removed: `/sdcard/Android/data/com.zeon.hiddify`, `/sdcard/Android/media/com.zeon.hiddify`, `/sdcard/Android/obb/com.zeon.hiddify`

## Step B: first true-clean launch (no profile in DB)
- App launch window (UTC): `2026-05-28 15:00:57.036` .. `15:03:03.405`
- `mobile auto import` start: `18:01:00.191` local
- first failure: `18:02:06.380` local
- time to failure: `66.189s`
- server journal in same UTC window: `-- No entries --`
  - no `/api/v1/users/create`
  - no `/open/...`
  - no `/subscription/...`

## Step C: rerun with same clean DB state (network recovered)
- App launch window (UTC): `2026-05-28 15:04:41.752` .. `15:06:17.513`
- `mobile auto import` start: `18:04:43.862` local
- first failure: `18:05:49.951` local (`66.089s`)
- first import attempt to `130.49.151.173/open/649669380`: `18:06:00.641` local
- server `POST /api/v1/users/create` incoming: `15:06:00.678Z`
- server `POST /api/v1/users/create` completed: `15:06:00.767Z`
- server processing time (`responseTime`): `88.086 ms`
- `mobile auto import succeeded`: `18:06:09.140` local
- from first import attempt to success: `8.499s`
- from auto-import start to success: `85.278s`

## Routing confirmation (client logs)
- Host mentions in rerun log:
  - `130.49.151.173`: 10
  - `zeon-vps.link`: 0
  - `ok24-server.com`/`.netlify/functions`: 0
