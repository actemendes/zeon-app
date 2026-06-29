# Smart Active Auto: debug fault injection

This facility exists only in a core built with the Go tag `smart_active_debug`.
The regular and release core build uses a no-op implementation: the fields below
may be present in a shared config, but they cannot alter health or switching.
There is no UI control for it.

Build a debug device core with:

```powershell
.\scripts\rebuild_zeon_core.ps1 -Platform android -SmartActiveDebug
```

The Flutter debug build can inject the same hidden options with Dart defines,
for example:

```powershell
flutter build apk --debug --target lib/main_prod.dart --target-platform android-arm64 `
  --dart-define=SMART_ACTIVE_DEBUG_FORCE_STATUS=CRITICAL `
  --dart-define=SMART_ACTIVE_DEBUG_FORCE_ERROR=refused
```

Other define names are `SMART_ACTIVE_DEBUG_FORCE_DEGRADATION`,
`SMART_ACTIVE_DEBUG_RUNTIME_PENALTY`, `SMART_ACTIVE_DEBUG_REAL_USER_PENALTY`,
`SMART_ACTIVE_DEBUG_FORCE_CANDIDATE`, and
`SMART_ACTIVE_DEBUG_CANDIDATE_SCORE`. The Dart bridge runs only when
`kDebugMode` is true and is not shown in settings.

Add these temporary fields to the ZEON options config while
`balancer-strategy` is `smart-active-auto`:

```json
{
  "balancer-strategy": "smart-active-auto",
  "smart_active_debug_force_status": "CRITICAL",
  "smart_active_debug_force_candidate": "<existing healthy server tag>",
  "smart_active_debug_candidate_score": 95
}
```

Supported active-status values are `GOOD`, `SUSPECT`, `DEGRADED`, `BAD`, and
`CRITICAL`. Supported `smart_active_debug_force_error` values are `timeout`,
`deadline`, `refused`, `reset`, `eof`, `dns_timeout`, `tls_handshake_failed`,
and `quic_timeout`. The optional degradation inputs are
`smart_active_debug_force_degradation`, `smart_active_debug_runtime_penalty`,
and `smart_active_debug_real_user_penalty`.

The candidate must be an existing member of the Smart Active balancer. It is
made a clean successful URLTest result with `error_type=none`; the requested
score is synthesized using normal health-score penalties, not a decision-only
override. Nothing is injected into the URLTest store and no network request is
changed.

Device check: connect through Auto Select, inject `CRITICAL` with a different
healthy candidate, and wait for the next monitoring update. Confirm the active
server label changed and inspect `[SmartActiveState]`, `[SmartActiveDecision]`,
`[SmartActiveSwitch]`, `[SmartActiveEmergency]`, `[SmartActiveRecovery]`, and
`[RealUserHealth]`. Remove the temporary fields or rebuild without
`-SmartActiveDebug` afterwards.
