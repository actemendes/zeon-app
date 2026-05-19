# VPN USB Incident Report: Root Causes and Mitigation Plan

Date: 2026-05-19
Scope: Android/USB tethering runtime logs and current DNS/routing config behavior.

## Symptoms (Observed)

From runtime logs (`stage12_1_runtime/data/box.log`):
- `i/o timeout`: 4650
- `dns-remote failed`: 1228
- `use of closed network connection`: 1391
- `UNAVAILABLE`: 869
- `outbound/balancer`: 637

Yandex-related failures are frequent and repeated:
- `dns-direct failed for yandex.ru ... dial tcp 1.1.1.1:443: i/o timeout`
- Similar failures for `log.strm.yandex.ru`, `frontend.vh.yandex.ru`, `favicon.yandex.net`

## Root Cause Analysis

### 1) Primary failure domain: outbound pool instability

The most consistent trigger is outbound node unavailability/degradation:
- connection refused
- connection reset by peer
- i/o timeout
- deadline exceeded

When the balancer cannot establish stable upstream connections, all dependent paths degrade.

Impact chain:
1. `outbound/balancer` errors spike
2. `dns-remote` requests fail through detour/upstream
3. app traffic and RPC transport surface `UNAVAILABLE`
4. in-flight sockets close -> `use of closed network connection`

### 2) Direct DNS fragility on mobile/USB path

Direct DNS traffic repeatedly fails against DoH endpoint `1.1.1.1:443` on this network path.
This is a high-impact issue for domains explicitly routed to direct DNS (including Yandex domains).

Observed effect:
- Name resolution fails before TCP/TLS to destination can even start reliably.
- Yandex appears "down" from app perspective while the actual failure is DNS transport reachability.

### 3) IPv6 reachability gaps amplify the issue

Logs include repeated direct-path IPv6 destination failures (`network is unreachable` to `2a02:6b8::...`).
Where domain strategy returns/tries IPv6 first or dual-stack fallback is slow, failure latency increases.

## Why Errors Correlate with Each Other

- `i/o timeout` is the base transport symptom.
- `outbound/balancer` is the selector-level manifestation of repeated timeout/refusal.
- `dns-remote failed` is downstream impact when DNS queries depend on unstable outbounds.
- `UNAVAILABLE` is transport-layer wrapping of unreachable upstreams.
- `closed network connection` is a consequence of aborted/expired in-flight sockets.

## Configuration Risks Identified

- Direct DNS path can become single-point fragile when tied to one DoH endpoint on constrained mobile/USB routes.
- DNS multi-server fallback behavior must be explicit and active for direct path.
- Domain strategy should avoid ineffective IPv6 attempts on known-broken links.

## Recommended Remediation Plan

### A) DNS resilience (highest priority)

1. Ensure direct DNS uses a true multi-server fallback chain, not a single endpoint.
2. Include heterogeneous transports/endpoints (e.g., local/system resolver fallback + multiple DoH providers).
3. Keep fast failover and avoid long per-endpoint blocking timeouts.

Expected outcome:
- sharp reduction in `dns-direct failed` and Yandex resolution failures.

### B) Outbound pool health control

1. Tighten health checks and eviction for bad nodes.
2. Increase penalty/cooldown for repeatedly failing outbounds.
3. Prefer sticky + tolerance tuning for mobile to reduce frequent rebalance churn.

Expected outcome:
- fewer `outbound/balancer` and `UNAVAILABLE` bursts.

### C) IPv6 strategy on problematic links

1. For mobile/USB diagnostics profile, prefer IPv4 or IPv4-only for direct DNS answers.
2. Avoid unnecessary IPv6 attempts where network path is known unreachable.

Expected outcome:
- lower connect latency and fewer synthetic timeout cascades.

### D) Validation protocol

After changes, validate with the same workload and compare:
- `i/o timeout`
- `dns-remote failed`
- `dns-direct failed`
- `outbound/balancer`
- Yandex domain success rate and median lookup latency

Success criteria:
- DNS failures reduced by at least 70%
- Balancer errors reduced by at least 50%
- No persistent Yandex lookup failures over 10-minute run

## Conclusion

This is a cascading network-path reliability issue, not a single-domain outage.
Core trigger is unstable outbounds plus fragile direct DNS reachability on USB/mobile routing.
Fix priority should start with DNS fallback hardening and outbound health gating.
