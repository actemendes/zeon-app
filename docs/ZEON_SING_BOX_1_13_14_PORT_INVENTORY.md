# ZEON sing-box v1.13.14 port inventory

Date: 2026-07-29

This document records the source and semantic inventory prepared before replacing the Stage 1 Android core. It contains no production secrets or profile material.

## Provenance boundary

| Item | Verified value | Evidence |
| --- | --- | --- |
| ZEON Stage 1 implementation | `f6650c782c72d7e7260827b2f8f1eb9d3d95cd76` | `baselines/android-core/2026-07-29-stage2-source.json` |
| Stage 1 source/report head | `316173452161d925547082ef9b2071ca7be29532` | source manifest |
| Hiddify core build revision | `31c5987477d3cd02a099c2c0c01c3a07da05ce69` | embedded AAR build info |
| Hiddify sing-box source | `0a02b7729f6a211436bb8bdcd8696c283eb27767`, tree `7fab4eb50f74dc076867298b22621cfa4ead2b08` before ZEON patches | audit and Git object database |
| Stage 1 sing-box tree | `70dc263d60846a4fc66f357b7b227941d4d54d2c` | Stage 1 manifest |
| Official upstream | `https://github.com/SagerNet/sing-box.git` | external read-only clone origin |
| Target tag | `v1.13.14` -> `25a600db24f7680ad9806ce5427bd0ab8afe1114`, tree `ebe928ddfdf2273bc2ab7e0cba818db315cd6151` | forced tag fetch and `rev-parse v1.13.14^{commit}` |
| Toolchain held fixed | Go `1.25.6`, gomobile `v0.1.11`, NDK `28.2.13676358` | source manifest and rebuild script |

The official tag was checked in a clean external clone at `B:\1CODING\zeon-stage2-sing-box-20260729`. The integration candidate was built in `B:\1CODING\zeon-stage2-port-candidate-20260729`; ZapretKVN and sing-box-extended were not used as source patches.

## Layer A — upstream v1.13.14

Layer A is the exact official tag above. Relevant upstream changes retained by this port include the new per-core `adapter.ConnectionManager`, DNS connection pooling and deadline fixes, Android local-DNS changes, UDP/TUN NAT collision handling, UoT race fixes, QUIC close/ALPN fixes, WireGuard shutdown fixes, stale daemon instance cleanup, updated route matching, and the current libbox API.

## Layer B — Hiddify compatibility

| Patch | Source | Files/functions | Purpose/internal API | Conflict and port decision | Regression evidence |
| --- | --- | --- | --- | --- | --- |
| Module/replacement graph | Hiddify `0a02b772`; Stage 1 `go.mod` | `go.mod`, `go.sum`, `replace/*` | Preserve dnscrypt, sing-dns, WireGuard, Tailscale, Psiphon and other local forks | Shared dependencies follow official `1.13.14`; six Hiddify-only direct modules and existing replacements retained. No replacement version changed merely for freshness. | `go mod tidy`; package build |
| Libbox context hooks | Hiddify | `experimental/libbox/config.go`: `BaseContext`, `FromContext`, `baseContext` | Hiddify Core constructs and extends libbox contexts | Kept public Hiddify helpers and added the private upstream helper expected by `1.13.14`. | `go test ./experimental/libbox` |
| Command service compatibility | Hiddify | `daemon/started_service.go`, `daemon/instance.go`, protobuf files | Hiddify command/status and extra lifecycle services | Merged onto upstream stale-instance and connection-manager lifecycle; no second manager introduced. | daemon/libbox compile and tests |
| Legacy WireGuard outbound | Hiddify | `include/wireguard.go`, `include/registry.go`, `protocol/wireguard/outbound.go`, `option/wireguard.go` | Existing Hiddify WireGuard profiles and WARP extensions | Official stub removal would drop legacy outbound. Registration and option types retained, endpoint adapted to `1.13.14` atomic readiness/API. | WireGuard package build; config corpus required |
| WARP cache/options | Hiddify | `experimental/cachefile/cache.go`, `option/*`, WireGuard code | Existing WARP profile support | Kept Hiddify binary cache without restoring upstream-reverted bbolt panic reset. RDRC uses current `DB.Batch`. | cachefile tests/build |
| Hiddify protocols | Hiddify | `protocol/hiddify/*`, `protocol/mieru/*`, `protocol/psiphon/*`, `protocol/awg/*`, related options/registry | Preserve supported protocols | Mieru no longer writes removed `InboundOptions`; destination/user behavior remains. | package compilation |
| DNS diagnostics/dnscrypt | Hiddify | `dns/transport/udp.go`, replacement graph | Existing DNS transport diagnostics and dnscrypt support | Logger field adapted from removed `Logger` to private `logger`; DNS selection policy unchanged. | DNS transport build/tests |
| Tailscale socket protection bridge | Official dependency `github.com/sagernet/tailscale v1.92.4-sing-box-1.13-mod.7`, commit `60874ec011f1fc5b6950e89e197382d24f253613` | `replace/tailscale/net/netns/netns.go`: `SetControlFunc`, `Listener`, `FromDialer` | New sing-box endpoint supplies platform socket control/protect hook | Existing replacement lacks the required API. Port only the atomic override hook; do not replace the full local fork. | Tailscale and DERP package compilation |
| SOCKS UDP timeout API | upstream `1.13.14` | `protocol/socks/inbound.go`, `protocol/mixed/inbound.go`, `protocol/tor/proxy.go` | New `HandleConnectionEx` timeout argument | Official call semantics retained; old auto-merged calls did not compile. | targeted package tests |

## Layer C — ZEON features

| Patch/source commits | Files/functions | Purpose | Internal API dependency | 1.13.14 port/risk | Tests |
| --- | --- | --- | --- | --- | --- |
| Round Robin (`14e1f418`, `b87dcfdc`) | `protocol/group/balancer/*`, `option/outbound.go`, `constant/proxy.go` | Deterministic rotating outbound strategy | outbound registry/group state | Retained; medium conflict risk in outbound manager and group APIs | balancer tests |
| Smart Active state and scoring (`b005ac52`, `4152fea4`, `bc48c797`, `cc3edf7b`, `aa26697a`) | `protocol/group/balancer/*`, `common/urltest/*`, `adapter/urltest.go` | Readiness, scoring, degraded/critical state and controlled selection | URLTest history, outbound manager, selector | Manually retained on new connection manager and URLTest APIs; high semantic risk | balancer, URLTest and decision tests |
| Quality/speed pipeline | same series | `common/urltest/*`, `common/monitoring/*`, libbox command types | Multi-signal measurements without changing profile format | Fields and readiness gates retained; medium risk from history schema changes | monitoring/urltest tests |
| Real-user health (`e997b4a6`) | `route/conn.go`: `recordRuntimePenalty`, `recordRuntimeSuccess`, `recordRuntimeTraffic`, `zeonOutboundTag` | Feed real data-plane outcomes to Smart Active | upstream connection copy and metadata | Reapplied around upstream `CopyWithIncreateBuffer` and handshake-close semantics; high risk | route compile plus Smart Active tests; device data-plane pending |
| UDP probe | `bc48c797`, `cc3edf7b` | `common/urltest/*`, balancer readiness | packet dialer, history generation | Retained; probe result remains separate from user UDP interruption | UDP probe tests; device QUIC pending |
| Check/session generation | `aa26697a`, Stage 1 `1aeca27b` | URLTest history and balancer switch gate | generation fields and environment mapping | Retained; stale results cannot switch selector | generation/stale decision tests |
| ZEON monitoring | `5d72d044`, `e997b4a6` | `common/monitoring/*`, route/libbox integration | context service registry | Retained on `1.13.14` lifecycle stages | monitoring tests |
| Dynamic MTU | `51d6c515` and Hiddify Core/Android caller | TUN options/build path | option structs and libbox bridge | Policy unchanged; only target structs are adapted | config corpus and Android tests |

## Layer D — Stage 1 fixes

| Patch | Source | Files/functions | Required invariant | Port decision/test |
| --- | --- | --- | --- | --- |
| Explicit selector interrupt policy | `1aeca27b` | `common/interrupt/group.go`, selector/balancer switch methods | Manual, regular and preventive switches preserve external TCP/UDP | Retained without changing defaults; interrupt tests and balancer policy tests |
| Emergency predicate | `1aeca27b` | `protocol/group/balancer/*` decision/evidence helpers | Only fresh outbound-specific confirmed failure may interrupt | Retained; one timeout, DNS/device failure, physical-network change and stale generation remain insufficient |
| Stale-generation rejection | `1aeca27b` plus Android Stage 1 commits | balancer/session-generation fields and diagnostics | Old session cannot switch current selector | Retained; stale decision tests plus Android generation tests |
| Interruption counters/logging | `1aeca27b` | interrupt group and selector diagnostics | Report TCP/UDP closes without secrets | Retained; logs use opaque tags/generation |
| Build metadata hooks | Stage 1 core build `31c5987` | Hiddify Core `platform/mobile`, rebuild/verifier scripts | Embedded source/toolchain/AAR provenance | Must be updated to `1.13.14` values, not removed |

## Semantic conflict register

| Area | Conflicting semantics | Resolution |
| --- | --- | --- |
| Connection tracking | Hiddify had a global `common/conntrack`; upstream has a session-owned `adapter.ConnectionManager` | Use upstream manager as the single owner. ZEON balancer reads `s.connection.Count()`. This preserves counting/close behavior and prevents double wrappers. |
| `box.Close` | Hiddify bounded close versus upstream elapsed-stage logging | Preserve bounded close and upstream stage logging. |
| DNS router | Hiddify response filtering/logging versus upstream address-limit check | Keep both in one response validation path. |
| Cache RDRC | Upstream safe helper methods versus Hiddify's later direct DB/reverted reset behavior | Preserve current Hiddify direct DB behavior and apply upstream expiry logic; no duplicate reset layer. |
| WireGuard readiness | Upstream atomic readiness versus ZEON probe-confirmed readiness | Use atomic state, publish ready only after the existing ZEON probe succeeds. |
| Route copy | Upstream copy/handshake fixes versus ZEON real-user telemetry | Keep upstream copy/close semantics and wrap their results with ZEON telemetry. |
| Tailscale protect | New endpoint requires `netns.SetControlFunc`; existing replacement has no symbol | Backport only the exact control-override API into the existing replacement. |
| Geosite serialization | Hiddify retained reflection serialization; upstream fixes non-addressable struct writes | Use upstream manual wire-compatible encoding and upstream compatibility tests. |
| Legacy WireGuard deprecation symbols | Official deprecation constants are removed while Hiddify still supports the profile | Keep the outbound but remove calls to non-existent deprecation constants; do not reject existing profiles. |

## Stop-gate status before AAR replacement

- Official origin/tag/commit: passed.
- Stage 1 verifier and immutable rollback artifacts: passed.
- Host package compilation: passed on fixed Go `1.25.6` (gomobile/NDK not changed).
- Full Go suite: all compiled packages pass except environment-dependent `dns/transport/hosts.TestHosts`; this must be reproduced against pristine upstream and recorded.
- Android AAR/API/ABI, config corpus, Flutter/Android tests and rollback verifier: not yet passed; the working Stage 1 AAR must not be replaced until they pass.

