# ZEON route validation telemetry

This package is active only with the `zeon_route_validation` Go build tag.
The default build compiles production no-op stubs and contains neither the
validation allowlist nor correlation state.

Tagged builds emit `ZEON_ROUTE_VALIDATION` JSON records only for the explicit
Stage 2.8 service allowlist. Destination addresses are represented by a
per-process, session-generation-scoped HMAC-SHA-256 value; plaintext IP
addresses are never emitted. DNS correlation is in-memory, capped at 256
hostnames, expires after 10 minutes, and is never persisted.

A route event with `dns: "UNKNOWN"` also carries:

```json
{"validationFailure":"DNS_UNKNOWN_OWN_DOH_OR_UNOBSERVED"}
```

That state is a validation failure, not DIRECT or REMOTE evidence. It can mean
the application used its own DoH path, the connection reused DNS state from
before the validation session, or the matching DNS observation was otherwise
missed. A browser validation row cannot receive PASS until DNS is observed as
`DIRECT` or `REMOTE` and agrees with the expected route.

Build a validation artifact explicitly:

```powershell
.\scripts\rebuild_hiddify_core.ps1 -Platform android -RouteValidationTelemetry
```

Production core verification rejects `zeon_route_validation` and
`ZEON_ROUTE_VALIDATION` markers by default. `-AllowValidationTelemetry` exists
only for verifying a non-production device-validation artifact.
