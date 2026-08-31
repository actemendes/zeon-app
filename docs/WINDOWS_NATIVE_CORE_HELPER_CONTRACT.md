# Future native-core/helper contract required

This is a specification only. It does not implement a helper, install a service, transition TUN, mutate BFE, or create/delete WFP filters.

## Stable ownership identity

The native core must publish permanent compile-time identifiers for:

- a ZEON WFP provider GUID;
- a ZEON sublayer GUID;
- deterministic filter keys or a documented filter-key namespace;
- the expected provider display name and Windows service identity;
- an ownership metadata schema/version.

Every ZEON filter must reference that provider and sublayer and carry an ownership tag containing product ID, installation ID, config generation, and contract version. Display names or random filter keys alone do not prove ownership.

## Required lifecycle API

The native core/helper must expose idempotent operations:

1. `EnsureProviderAndSublayer`: create or validate only the known ZEON provider/sublayer.
2. `CreateGeneration`: atomically install filters for a monotonically increasing configuration generation.
3. `ActivateGeneration`: switch active ownership state only after the generation is complete.
4. `DeleteGeneration`: delete only when provider GUID, sublayer GUID, installation ID, and generation all match.
5. `ReconcileOwnedState`: enumerate only the ZEON provider/sublayer and repair interrupted ZEON generations.
6. `RemoveOwnedInstallation`: remove only objects matching the current installation ID; remove provider/sublayer only when no ZEON-owned filters remain.
7. `QueryState`: return BFE state, active generation, owned filter count, exact HRESULT, and operation stage without changing state.

The API must not contain “delete all filters”, delete by display name, or deletion outside the permanent ZEON provider/sublayer.

## Versioned service IPC

The future signed service protocol must provide:

- an ACL limited to the installed ZEON UI identity and Administrators;
- authenticated local caller identity;
- request ID, operation, contract version, installation ID, desired generation, and SHA-256 of canonical configuration;
- bounded deadlines and explicit cancellation;
- structured replies with stage, HRESULT, derived Win32 code, BFE state, generation, and ownership counts;
- replay protection and rejection of stale generations;
- compatibility negotiation between UI, service, and native core;
- redacted logs with no profile, subscription URL, token, or user data.

The UI must never supply arbitrary WFP GUIDs or filter-delete expressions. Privileged policy construction belongs to the signed helper/native core.

## Privilege boundary

- Flutter UI remains `asInvoker`.
- Only the service performs WFP/provider/sublayer/filter mutations and other privileged TUN operations.
- Read-only state queries may remain available without elevation.
- Service install/update/removal is performed only by the installer after Authenticode identity verification.
- The service rejects callers, signer identities, installation IDs, and protocol versions that are not trusted.

## Crash, update, and rollback recovery

- Mutations use a durable journal containing installation ID, previous generation, desired generation, and completion state.
- Startup reconciliation removes only incomplete ZEON generations and preserves the last complete generation.
- A UI crash must not remove active filters or leave an elevation prompt pending.
- A helper crash during create leaves the previous generation active.
- Update performs signer verification, version negotiation, and owned-state reconciliation.
- Rollback understands both adjacent contract schemas and never removes objects whose ownership cannot be proven.
- Uninstall removes only the current installation ID after an explicit user-authorized stop workflow.

## Validation required before implementation is release-ready

- Windows 10 and 11 with BFE running, stopped, and restart-in-progress;
- non-admin UI driving the privileged service;
- crash injection at every lifecycle stage;
- update and rollback across two protocol versions;
- foreign and system filters present during every scenario;
- proof that foreign provider/sublayer/filter keys remain unchanged;
- exact HRESULT assertions for access denied, BFE unavailable, transaction failure, and ownership mismatch;
- signed service, signed IPC client, and final installer payload verification.
