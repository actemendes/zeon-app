# Verification Report — 2026-05-28

## Scope
- Verify app endpoints and request chain for profile import/bind.
- Re-check server reachability manually and from device.
- Confirm whether server receives requests and how fast it responds.

## Manual API check from workstation (same endpoints as app)
Source: `out/diagnostics/manual_api_check_live2_20260528_212747/summary_table.tsv`

- `GET /open/649669380` -> `302`, total `0.123948s`
- `GET /open/649669380` (follow redirect) -> `200`, total `0.342959s`
- `GET /api/v1/subscriptions/lookup?user_id=649669380` -> `200`, total `0.128538s`
- `POST /api/v1/users/create` -> `200`, total `0.110789s`
- `POST /api/v1/devices/rebind` -> `502`, total `0.095367s`, body `BIND_AUDIT_INSERT_FAILED` (`duplicate key ... bind_audit_pkey`)
- `GET https://zeon-vps.link/open/649669380` (HEAD) -> `302`, total `0.506890s`
- `GET https://zeon-vps.link/open/649669380` (follow redirect, max 25s) -> curl timeout at `25.345s` with partial body.

## Device-side direct network check (`adb shell curl`)
Source: `out/diagnostics/device_curl_check2_20260528_213953/*.txt`

- Primary `https://130.49.151.173/open/649669380` -> fast (`302`, total `0.126739s`)
- Primary follow redirect -> fast (`200`, total `0.363092s`)
- Lookup endpoint -> fast (`200`, total `0.114759s`)
- Fallback follow redirect (`zeon-vps.link`, max 25s) -> timeout at `25.554666s`, partial data.

## App E2E on device (clean data + clean reinstall)
- Clean-data run log: `out/diagnostics/mobile_flow_log_20260528_213424.txt`
  - app attempts on primary:
    - default -> directOnly -> no-validate
    - success on no-validate
  - no `ok24-server.com/.netlify/functions` usage in app log.
- Clean reinstall run log: `out/diagnostics/mobile_flow_log_20260528_214115.txt`
- Shared prefs after run:
  - `mobile_auto_import_conn_link = https://130.49.151.173/open/649669380`
  - `mobile_auto_import_done = true`

## Server received requests (confirmed)
Sources:
- `out/diagnostics/server_journal_30m_20260528_213356.txt`
- `out/diagnostics/server_journal_15m_device_run_20260528_213654.txt`
- `out/diagnostics/server_journal_since_reinstall_20260528_214348.txt`
- `out/diagnostics/nginx_access_routes_tail_20260528_213356.txt`

Confirmed incoming on server:
- `GET /open/649669380`
- `GET /subscription/93c53af4-...`
- `GET /api/v1/subscriptions/lookup?user_id=649669380`
- `POST /api/v1/users/create`
- `POST /api/v1/devices/rebind`

Typical server responseTime from journal:
- `/open/...`: ~`7–43ms`
- `/subscription/...`: ~`33–147ms`
- `/lookup`: ~`17–29ms`
- `/users/create`: ~`28–84ms`
- `/devices/rebind` (failing): ~`27–44ms` with `502`

## Conclusion
- Primary contour (`130.49.151.173`) is reachable and fast from app/device/workstation.
- Server definitely receives and responds quickly to bind/import chain requests.
- Fallback contour (`zeon-vps.link` -> redirect outside primary) shows unstable behavior and reproducible long-tail timeout.
- `devices/rebind` has a backend-side data error (`bind_audit_pkey` duplicate), but this is a fast `502`, not a long network timeout.

## Code changes in this verification pass
- No new code edits were made in this pass.
- Existing local changes (from previous pass) remained as-is and were re-validated by tests.
