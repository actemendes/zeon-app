# Profile Timeout Diagnostics

This folder contains reproducible diagnostics for timeout investigation in profile rebind/create flow.

## 1) Server + external latency benchmark

Run from repo root:

```powershell
$env:ZEON_SSH_PASSWORD = "<ssh-password>"
python scripts/diagnostics/profile_timeout_diag.py
```

Outputs are written to `out/diagnostics/profile_timeout_diag_YYYYMMDD_HHMMSS/`:

- `samples.json` raw per-request metrics
- `summary.json` aggregated metrics
- `report.md` human-readable report
- `journal_raw.log` (if remote probe enabled)

Defaults:

- user: `649669380`
- primary: `https://130.49.151.173`
- fallback: `https://zeon-vps.link`
- iterations: `100` (default endpoints), `40` (fallback open)

Useful overrides:

```powershell
python scripts/diagnostics/profile_timeout_diag.py --user-id 123456789 --iterations-default 150 --iterations-fallback 60
python scripts/diagnostics/profile_timeout_diag.py --skip-remote
```

## 2) Device flow capture (adb)

Capture live logcat while reproducing timeout on device:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/diagnostics/capture_mobile_flow_log.ps1 -DurationSec 180
```

If multiple devices are connected:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/diagnostics/capture_mobile_flow_log.ps1 -Serial <device-serial> -DurationSec 180
```

Auto force-stop + relaunch the app at capture start:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/diagnostics/capture_mobile_flow_log.ps1 -Serial <device-serial> -DurationSec 180 -LaunchPackage com.zeon.hiddify
```

The script automatically runs parser:

- `parse_mobile_flow_log.py`

Artifacts:

- `mobile_flow_log_*.txt`
- `mobile_flow_log_*_flow_summary.json`
- `mobile_flow_log_*_flow_summary.md`
- `mobile_flow_log_*_flow_events.json`

## Notes

- Benchmarks are GET-only by default (non-mutating).
- For `users/create` and `devices/rebind` throughput tests, use a staging/test dataset before production.
