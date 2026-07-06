# Compatibility and Deprecation Policy

TASK-631 deliverable for the v0.36.24 design-debt inventory lane. This policy
defines which winsmux surfaces must remain compatible, which internal surfaces
may change before v1.0.0, and how duplicated contracts are deprecated or
removed. TASK-632 turns these policy decisions into a design-freeze gate.

## Source documents

| Source | Evidence used by this policy |
| --- | --- |
| `docs/project/component-map.md` | Component ownership, dependency direction, desktop-to-core boundary, and `sdk/` / `git-graph/` classification needs (`docs/project/component-map.md:16`, `docs/project/component-map.md:19`, `docs/project/component-map.md:24`, `docs/project/component-map.md:26`, `docs/project/component-map.md:100-135`). |
| `docs/project/contract-source-of-truth-inventory.md` | Current canonical contract files, confirmed drift cases, and duplicated vocabularies (`docs/project/contract-source-of-truth-inventory.md:19-31`, `docs/project/contract-source-of-truth-inventory.md:35-75`, `docs/project/contract-source-of-truth-inventory.md:197-207`, `docs/project/contract-source-of-truth-inventory.md:224-234`). |
| `docs/project/metrics-baseline.md` | Size, coupling, test duration, release density, and process-launch baselines (`docs/project/metrics-baseline.md:15-27`, `docs/project/metrics-baseline.md:144-193`, `docs/project/metrics-baseline.md:251-296`). |

## Surface classes

| Class | Compatibility promise | Examples | Change rule |
| --- | --- | --- | --- |
| Public user surface | Preserve documented user behavior within the support window. | Installed CLI behavior, npm package entrypoints, desktop launch and runtime behavior, release assets, documented commands, user-editable configuration. | Breaking changes require a release-note entry, migration notes, and at least one release of notice unless the old behavior creates a security or data-loss risk. |
| Public-adjacent integration surface | Preserve machine-readable command shape while known callers exist. | `scripts/winsmux-core.ps1`, `winsmux-core/mcp-server.js`, release scripts, SDK stubs if promoted from reference-only. | New fields and flags must be additive. Removing fields, flags, enum values, or command shapes requires a caller inventory and support window. |
| Internal compatibility-sensitive surface | May change before v1.0.0, but only when known producers and consumers are updated together. | Manifest schema, mailbox envelope, provider/backend vocabulary, readiness markers, route roles, bridge settings schema. | Change requires a validation test, a generated contract, or an explicit compatibility shim in the same PR. |
| Internal implementation surface | May change when normal tests and release gates pass. | Generated internal docs, local operator hooks, test helpers, standalone tooling with no product caller. | No deprecation notice is required unless the surface is promoted to another class. |
| Reference-only surface | Exists in the tree, but has no user compatibility promise yet. | `sdk/` until its default server path and coverage are fixed; `git-graph/` until a product caller exists. | Do not add new product callers without first assigning an owner, support window, and test coverage. |
| Removal candidate | Not promised long term. | Any reference-only surface that remains ownerless before v1.0.0. | Must block new callers and carry either a migration issue or an explicit v1.0.0 removal decision. |

## Source-of-truth rule

Every duplicated contract fact must be classified before the release that changes
it:

| Classification | Meaning | Requirement |
| --- | --- | --- |
| `generated-from` | Other declarations are produced from the canonical source. | Code generation or checked-in generated output must be updated in the same change. |
| `validated-against` | Other declarations remain hand-written but are tested against the canonical source. | CI must fail when the duplicate drifts. |
| `compat-shim` | A legacy declaration remains for existing callers. | The shim must name its owner, support window, and removal condition. |
| `reference-only` | The surface is usable as an example but not promised. | Public docs must not describe it as supported. New product callers are blocked. |
| `removal-candidate` | The surface is expected to disappear unless an owner promotes it. | Add a migration/removal issue or record an explicit v1.0.0 decision. |

## Canonical contract decisions

| Fact | Canonical source | Classification for v0.36.24 | Policy |
| --- | --- | --- | --- |
| Provider ID list | `winsmux-app/src/modelCapabilities.ts` | `validated-against` | PowerShell, Rust, JSON, and UI references must be members of the canonical TypeScript provider set. |
| Reasoning effort enum | `modelCapabilities.ts` | `validated-against` | Add or remove values only when PowerShell and Rust validators are updated or generated in the same change. |
| Provider auth mode | `modelCapabilities.ts` provider metadata | `validated-against` | Settings, readiness, and route code must agree on auth mode for every provider. |
| Backend capability category | `modelCapabilities.ts` | `validated-against` | Keep capability categories distinct from concrete worker-backend values. |
| Concrete worker-backend enum | `core/src/machine_contract.rs` | `compat-shim` until bridge settings match | Rust `WORKER_BACKENDS` is canonical. Bridge settings may retain only the existing bridge-only value through the backend bridge shim below; new concrete worker-backend values must update Rust and bridge settings in the same change. |
| Route role taxonomy | `core/src/machine_contract.rs` plus the route alias shim below until TASK-632 adds an explicit dispatch/coordinator map | `compat-shim` until reconciled | Current aliases are the named shim below. Adding a new role or alias before the explicit map exists is not allowed. |
| Worker readiness markers | `winsmux-app/src/workerReadinessPrompt.ts` | `validated-against` | Runner and PowerShell readiness detectors must use exported constants, generated fixtures, or tests tied to the TypeScript source. |
| Manifest schema | `core/src/manifest_contract.rs` | `validated-against` | PowerShell writers must produce fields accepted by Rust. Version changes require producer and consumer tests. |
| Mailbox envelope | `winsmux-core/scripts/agent-monitor.ps1` producer until a Rust mirror exists | `compat-shim` | Expanding mailbox versions requires consumer-side validation and idempotency behavior. |
| Settings schema | `winsmux-core/scripts/settings.ps1` plus provider capability metadata | `validated-against` | Cross-layer enum additions require settings and operator CLI validation in the same release lane. |

## Known drift is invalid

The following are confirmed current drift cases, not optional cleanup:

1. `model_source` validators disagree.
2. Route role taxonomies disagree across Rust and PowerShell declarations.
3. Backend capability values and concrete worker-backend values are conflated.

For v0.36.24, these three cases are grandfathered only as named inventory
findings. TASK-632 must turn them into explicit gate exceptions with owners and
removal conditions; after that gate exists, expanding any of these drift
patterns or adding new drift in the same mechanisms is a release blocker.

| Exception | Owner until removal | Support window | Removal condition |
| --- | --- | --- | --- |
| `model_source` validator mismatch | Provider catalog owner (`winsmux-app/src/modelCapabilities.ts`) | v0.36.x only | All Rust, PowerShell, and TypeScript validators accept the same value set, or a generated source replaces the hand-written copies. |
| Route role taxonomy split | Core route-contract owner (`core/src/machine_contract.rs`) | v0.36.x only | An explicit dispatch-to-coordinator map exists and the Rust normalizers agree. |
| Backend capability vs worker-backend split | Provider/backend compatibility owner (`winsmux-app/src/modelCapabilities.ts` and `core/src/machine_contract.rs`) | v0.36.x only | Capability-to-backend mapping validates only concrete worker backends present in the Rust contract, and bridge settings match that contract. |

## Compatibility shims

The canonical decisions table uses `compat-shim` only for three current surfaces:

| Shim | Owner | Support window | Removal condition |
| --- | --- | --- | --- |
| Route role taxonomy aliases | Core route-contract owner (`core/src/machine_contract.rs`) | v0.36.x only | Replace aliases with an explicit dispatch/coordinator map, then reject cross-taxonomy role strings in the gate. |
| Concrete worker-backend bridge enum | Core worker-backend contract owner (`core/src/machine_contract.rs`) | v0.36.x only | Remove bridge-only concrete backend values or add them to Rust through the same PR; after that, `BridgeWorkerBackendKinds` must match Rust `WORKER_BACKENDS` exactly. |
| Mailbox envelope producer-first contract | Monitor mailbox producer owner (`winsmux-core/scripts/agent-monitor.ps1`) | v0.36.x only | Add a Rust mirror or generated schema, producer fixture, consumer validation, and idempotency behavior before expanding mailbox versions. |

## Component decisions

### PowerShell bridge

The desktop app reaches the runtime through `scripts/winsmux-core.ps1`, not by
linking the Rust crate (`docs/project/component-map.md:100-111`). Treat the
bridge command surface as a public-adjacent integration surface for v0.36.x.

Breaking the bridge command shape requires:

- a desktop call-site inventory
- an SDK and MCP server call-site inventory
- a release script call-site inventory
- one release of deprecation notice unless the old shape is unsafe

### `sdk/`

Classify `sdk/` as **reference-only** for v0.36.24. The component map records
that the default server path is broken and that no CI coverage asserts the SDK
stubs (`docs/project/component-map.md:26`, `docs/project/component-map.md:124-127`).

Promotion to a maintained contract requires all of the following:

- fix the default server path to `winsmux-core/mcp-server.js`
- add Python and TypeScript smoke coverage, or explicitly defer one with an
  issue tied to the release lane
- document the support window and expected server path

If those requirements are not met before v1.0.0, `sdk/` becomes a removal
candidate.

### `git-graph/`

Classify `git-graph/` as **reference-only standalone tooling** for v0.36.24. It
builds as a workspace member but has no in-repo product caller
(`docs/project/component-map.md:24`, `docs/project/component-map.md:119-123`).

Adding a product dependency on `git-graph/` requires an owner, a test, and a
compatibility promise in the same PR. If no owner is named before v1.0.0, it
becomes a removal candidate.

## Version and support windows

| Change type | Required support window |
| --- | --- |
| Additive config or schema field | No notice if old consumers ignore it safely; document producer and consumer behavior. |
| Enum value addition | Same release only if every consumer validates, maps, or safely ignores the value. |
| User-facing command removal | At least one release of notice plus migration notes. |
| Public-adjacent bridge shape removal | At least one release of notice plus caller inventory. |
| Internal schema break | Allowed before v1.0.0 only when all known producers and consumers are updated and tests prove the new contract. |
| Security or data-loss fix | May remove immediately; release notes must explain the risk and migration. |

## TASK-632 gate handoff

TASK-632 should add checks or explicit release-gate steps for these rules:

- `model_source` validator sets match.
- Route role maps are explicit and Rust normalizers agree.
- Backend capability values are not accepted where concrete worker backends are
  required.
- Manifest output written by PowerShell is accepted by Rust.
- Mailbox producer output validates against the chosen envelope contract and
  idempotency fields are not ignored silently.
- High fan-in bridge and desktop files stay within the TASK-630 size/coupling
  baseline unless the PR records the owner and release-gate reason.

## Verification checklist

Before a PR changes a compatibility-sensitive surface:

- identify the surface class
- name the canonical source
- choose `generated-from`, `validated-against`, `compat-shim`,
  `reference-only`, or `removal-candidate`
- update every known caller or document why the caller is intentionally outside
  the support window
- run the relevant release gate or add a TASK-632 check when no gate exists
- compare bridge, desktop, test, SDK, and process-launch impact against
  `docs/project/metrics-baseline.md`
