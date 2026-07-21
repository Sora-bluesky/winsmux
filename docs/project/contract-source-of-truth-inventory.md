# Contract Source-of-Truth Inventory

TASK-629 deliverable for the v0.36.24 design-debt inventory lane. This catalogs,
for each cross-cutting contract, the single definition that should be
authoritative, every place the same contract facts are re-declared, and the
concrete duplications that can drift. It is the input for TASK-631
(compatibility / deprecation policy) and TASK-632 (design-freeze gate).

Produced by a parallel first-source sweep (7 read-only agents over
`git`-tracked files, 2026-07-06, main at `3aea74df`). Every location is a real
`file:line`; the load-bearing claims below were spot-verified by hand (see
Method). Treat unverified `file:line` refs as leads to confirm during
TASK-631/632, not as a frozen spec.

## Source of truth at a glance

| Contract | Authoritative definition | Layers that re-declare it |
| --- | --- | --- |
| Provider / backend catalog | `winsmux-app/src/modelCapabilities.ts` (`ProviderCapabilityId` + `providerCapabilities`) | TypeScript (main.ts), PowerShell (settings.ps1, winsmux-core.ps1), Rust (machine_contract.rs), JSON (benchmark-pack.json) |
| Worker readiness heuristics | `winsmux-app/src/workerReadinessPrompt.ts` | main.ts, bakeoff-runner-lib.mjs, agent-readiness.ps1, Pester (AgentReadiness.Tests.ps1) |
| Manifest schema | `core/src/manifest_contract.rs` | manifest.ps1, orchestra-start.ps1, bakeoff-runner-lib.mjs |
| Route / dispatch roles | `core/src/machine_contract.rs` (`ROLES`) — but see the taxonomy split below | dispatch-router.ps1, coordinator-router.ps1, router weights JSON |
| Mailbox v2 message | `winsmux-core/scripts/agent-monitor.ps1` (`New-MonitorOperatorMailboxPayload`) | operator-poll.ps1, ledger.rs, event_contract.rs |
| Settings schema / enums | `winsmux-core/scripts/settings.ps1` (`BridgeSettingsSchema`) + `modelCapabilities.ts` for the capability enums | settings.ps1, modelCapabilities.ts, operator_cli.rs, desktopClient.ts |

The headline: **there is no single-source enforcement across languages.** The
same enum or list is hand-declared in TypeScript, PowerShell, Rust, and JSON,
kept in sync only by convention. No codegen, no shared schema, and the
per-layer copies have already drifted in at least three confirmed cases (below).

Update for v0.36.25: the common provider/readiness/manifest/route/capsule/mailbox/settings
payload now has one public payload source: `winsmux-app/src/modelCapabilities.ts`
exports `commonContractPackage`. The drift gate is
`npm run test:common-contract-package` in `winsmux-app`; it checks generated
PowerShell bindings, Rust parity fixtures, and the previous-version fixture
against that source before merge or release.

Update for TASK-722: `tests/fixtures/rust-parity/common-contract-readiness-vocabulary-fixtures.json`
keeps two negative readiness fixtures tied to the common package. One fixture
copies the model availability vocabulary into worker-pane readiness; the other
removes the runtime worker `blocked` repair-action state. Both the JS drift
check and Rust validator must reject those mutations.

## Confirmed drift (hand-verified)

Three duplications have already diverged in the tree today:

1. **`model_source` enum disagrees inside one Rust file.**
   `core/src/operator_cli.rs:2692` accepts four values
   (`provider-default | cli-discovery | official-doc | operator-override`) while
   `core/src/operator_cli.rs:3036` accepts five (adds `provider-api`). The
   PowerShell schema (`settings.ps1`) and `modelCapabilities.ts` both define
   five. So one of the two Rust validators rejects a `provider-api` model_source
   the rest of the system considers valid.

2. **Incompatible role taxonomies coexist across four declarations.**
   The dispatch 5-role set (`Operator, Worker, Builder, Researcher, Reviewer`)
   appears in both `dispatch-router.ps1:5` and Rust `operator_cli.rs`
   (`canonical_role` :6882 / `canonical_manifest_role` :7283, WINSMUX_ROLE_MAP
   validation ~:6765). But `core/src/machine_contract.rs` `ROLES` defines only
   four (`operator, worker, reviewer, builder` — no `Researcher`), and
   `coordinator-router.ps1:103` uses a different set entirely (`Thinker, Worker,
   Verifier`). So `Researcher` is valid to the CLI + dispatch router but absent
   from `machine_contract.rs` `ROLES`; only `Worker`/`worker` is common to all.
   There are even two Rust role normalizers — `machine_contract.rs`
   `canonical_role_for()` and `operator_cli.rs` `canonical_role()` — that can
   disagree on `Researcher`.

3. **Backend enums use two distinct vocabularies.** The TypeScript
   `BackendCapabilityId` (`any | agent-cli | antigravity | api_llm`) is an
   abstract *capability category* that describes what kind of backend a provider
   needs. The concrete *worker-backend* enum is the actual execution context.
   Its PowerShell and Rust catalogs are synchronized as
   `local, codex, api_llm, antigravity, noop`. `noop` is intentionally concrete
   metadata rather than a provider capability. `requiredBackend`
   (`modelCapabilities.ts`, typed `BackendCapabilityId`) holds capability
   categories, not concrete worker-backends. A capability→backend map already
   exists (`BackendCapability.assignableBackends` —
   e.g. `agent-cli` → `["", local, codex, claude]`, `antigravity` →
   `["antigravity"]`), but its targets are not all in `WORKER_BACKENDS`
   (`claude` and `""` are missing). So the real gap is enforcing
   the existing map against the Rust contract, not defining a new one.

## Per-contract inventory

### Provider / backend catalog

- **Source of truth:** `winsmux-app/src/modelCapabilities.ts:1-7`
  (`ProviderCapabilityId`) and `:221-333` (`providerCapabilities`).
- **Re-declared in:** `main.ts:389` (`RuntimeProviderId`), `main.ts:565`
  (`AgentVaultProviderId`, a subset that also adds `opencode`), `main.ts:921-925`
  (`agentVaultProviders`), `main.ts:1357-1363` (`runtimeProviderOptions`),
  `benchmark-pack.json:59-131` (`default_workers`), `machine_contract.rs:213-261`
  (`WORKER_BACKENDS`), `winsmux-core.ps1:9888-9987` (OpenRouter base URL / env /
  endpoint validation).
- **Top drift risks:** the provider membership list (6+ hand-maintained copies);
  per-provider `authMode`; per-provider `requiredBackend` (declared in TS, not
  enforced by the Rust backend contract); OpenRouter base URL + `OPENROUTER_API_KEY`
  hardcoded in four places; the Agent Vault subset maintained by hand.

### Worker readiness heuristics

- **Source of truth:** `winsmux-app/src/workerReadinessPrompt.ts:15-85`
  (`hasWorkerReadyPrompt` and friends), the most documented copy and the one with
  a dedicated regression fixture (`worker-readiness-prompt-check.mjs`).
- **Re-declared in:** `main.ts:3873-4258` (pane-readiness state machine +
  blocker/pending detection + UI meta), `bakeoff-runner-lib.mjs:87-104`
  (`collectReadyWorkers` regex on the header badge), `agent-readiness.ps1`
  (a parallel PowerShell readiness detector — the compat-shim for
  non-desktop/CI contexts), `AgentReadiness.Tests.ps1`.
- **Top drift risks:** the Codex idle-status-line regex exists twice with
  different anchoring (TS tail-line vs PS embedded-percent); prompt marker
  characters (`>`, `›`, `❯`) hardcoded with inconsistent encodings across TS
  regex and a PS char-code array; the ready-badge strings
  (`ready for benchmark` / `ベンチ投入可能`) declared in `main.ts` but re-matched
  by a runner regex — changing the UI text silently breaks JP-desktop dispatch;
  blocker/pending keyword sets split across TS and PS with partial overlap.
- **Note for TASK-634:** two distinct readiness vocabularies exist and must not
  be conflated — `WorkerPaneReadinessState` (`ready|blocked|pending`, is the
  pane idle) vs `modelCapabilities.ts` `ReadinessState`
  (`selectable|candidate|setup-required|runnable|blocked|reference-only|unavailable`,
  is the model available).
- **TASK-722 fixture gate:** the named readiness fixture file above is the
  regression input for this split. It prevents a future edit from treating pane
  idle-state labels as model availability, and it prevents dropping the
  `blocked` runtime worker state that carries the remediation path.

### Manifest schema

- **Source of truth:** `core/src/manifest_contract.rs:6-164` (the Rust structs +
  validation + normalization; handles both legacy list-style and current
  dict-style panes).
- **Re-declared in:** `manifest.ps1:252-541` (PowerShell YAML reader/writer via
  regex, no schema of its own), `orchestra-start.ps1:1280-1356` (builds the pane
  object with ~23 fields), `bakeoff-runner-lib.mjs:25-71` (`parseManifestPaneIds`,
  informational only), `tests/fixtures/rust-parity/manifest.yaml`.
- **Top drift risks:** PowerShell writes PascalCase→snake_case field names with
  no cross-language validation, so a Rust field rename fails silently (serde
  ignores the unmatched key); Rust runs extensive `validate_pane` /
  `normalize_pane_worktree` logic that PowerShell does not mirror, so an invalid
  manifest can be written and only fails when Rust reads it; the `pane_id`
  informational-only caveat (#1109/#1128) is documented in the JS runner but
  **not** in the Rust struct, inviting a future maintainer to wire `pane_id`
  into routing.

### Route / dispatch roles

- **Source of truth (nominal):** `core/src/machine_contract.rs:107-128`
  (`ROLES` + `canonical_role_for()`), but `operator_cli.rs` has its OWN
  `canonical_role()` that accepts `Researcher` (which `ROLES` omits), so even the
  two Rust maps disagree — see the taxonomy split under Confirmed drift #2.
- **Re-declared in:** `operator_cli.rs` (`canonical_role` :6882 /
  `canonical_manifest_role` :7283 + WINSMUX_ROLE_MAP validation),
  `dispatch-router.ps1` (keyword→role map + dispatch role
  ValidateSet), `coordinator-router.ps1` (Thinker/Worker/Verifier + role
  contracts), `local-router-shadow.ps1` + `router/local-small-router-v03621.weights.json`
  (role_heads / feature vector), `.claude/CLAUDE.md` + `.claude/rules/dispatch.md`
  (operator-facing role docs), `tests/bridge/*.Tests.ps1` (`WINSMUX_ROLE_MAP`).
- **Top drift risks:** the two PowerShell taxonomies never translate to each
  other or to the Rust canonical set; the keyword→role map is hardcoded in one
  function with no design contract; the router weights hardcode role names /
  feature dimension, so adding a role silently breaks the shadow router unless
  the weights are regenerated in lockstep.

### Mailbox v2 message

- **Source of truth:** `agent-monitor.ps1:643-667`
  (`New-MonitorOperatorMailboxPayload`) — the producer defines the envelope
  (`mailbox_version`, `message_id`, `correlation_id`, `causation_id`,
  `idempotency_key`, `message_type`, `state`, `ttl_seconds`, `ack_required`,
  `from`, `to`, `content`, `timestamp`).
- **Re-declared / consumed in:** `operator-poll.ps1:450-527`
  (`ConvertTo-OperatorPollMailboxRecord`, validates v2 and silently drops
  invalid messages), `event_contract.rs` (sees only the flattened event),
  `ledger.rs:3478-3569` (counts mailbox events, generates team_memory refs),
  `main.ts:8436` (surfaces `pending_mailbox_count`).
- **Top drift risks:** the producer always sets `mailbox_version=2` but the
  consumer defaults to `1` when the field is missing, so a v2 message that lost
  its version field would skip v2 validation entirely; and although the envelope
  carries `idempotency_key`/`correlation_id`, **no consumer actually
  de-duplicates today** — `operator-poll.ps1` only copies those fields into the
  record and the Rust ledger only counts mailbox events, so the v0.36.22
  "at-least-once + idempotent" intent is declared but not yet enforced. (The v2
  required-field check *does* enforce non-emptiness via `IsNullOrWhiteSpace`,
  `operator-poll.ps1:478-486`.)

### Settings schema / enums

- **Source of truth:** `settings.ps1:43-65` (`BridgeSettingsSchema`) for the
  bridge settings keys, plus `modelCapabilities.ts:1-333` for the capability
  enums (effort / backend / transport / model-source / provider).
- **Re-declared in:** `settings.ps1` (validation for reasoning-effort, model-source,
  transport, backend, per-provider capability switch at `:1392-1507`),
  `modelCapabilities.ts` (the same enums as TS unions + const arrays),
  `operator_cli.rs` (Rust validation — the site of Confirmed drift #1),
  `desktopClient.ts:629-1039` (worker launch/status interfaces).
- **Nine enumerated duplication points** (reasoning-effort, model-source,
  transport, worker-backend, provider IDs, auth-mode, OpenRouter model options,
  per-provider supported efforts, per-provider default effort), each hand-declared
  in two or three languages with no codegen.

## Cross-cutting duplications (act on these in TASK-631 / TASK-632)

Facts duplicated across more than one contract area, most drift-prone first:

| Fact | Areas | Source of truth to enforce | Enforcement idea |
| --- | --- | --- | --- |
| Provider ID list | provider, readiness, settings, manifest, route | `modelCapabilities.ts:1-7` | Validation test asserting every provider reference (settings.ps1, dispatch-router.ps1, operator_cli.rs) is a member of the canonical union |
| Reasoning-effort enum | provider, settings, readiness, route, manifest | `modelCapabilities.ts:16-22` | Export `REASONING_EFFORT_VALUES`; codegen/assert the PS + Rust validators from it; sync the Codex footer regex |
| Role taxonomy (4 declarations: `machine_contract.rs` `ROLES`, `operator_cli.rs` `canonical_role`, dispatch-router, coordinator-router) | route, manifest, machine-contract | `machine_contract.rs:107-128` | Reconcile the two Rust role maps first (`ROLES` lacks `Researcher` that `operator_cli.rs canonical_role` accepts); define an explicit dispatch↔coordinator map; reject cross-taxonomy role strings |
| Auth-mode per provider | provider, settings, route | `modelCapabilities.ts` (`authMode`) | Generate the settings.ps1 + operator_cli parsing from a canonical provider→authMode map |
| Required-backend per provider (capability category) | provider, readiness, settings | `modelCapabilities.ts` (`requiredBackend: BackendCapabilityId`) | Reuse the EXISTING capability→backend map (`BackendCapability.assignableBackends`, `modelCapabilities.ts:197-202`); assert its target backends all exist in `WORKER_BACKENDS` (currently `claude` and `""` do not) |
| OpenRouter base URL + `OPENROUTER_API_KEY` | provider, settings, readiness | `modelCapabilities.ts:180` + per-model `requiredEnv` | Single `openrouter-config` constant imported by settings.ps1, agent-monitor.ps1, main.ts; test all three use identical values |
| Backend *capability* categories (TS `BackendCapabilityId`: `any/agent-cli/antigravity/api_llm`) | provider, settings | `modelCapabilities.ts` | Keep distinct from the concrete worker-backend enum below — this is the abstract per-provider category, not an execution context |
| Concrete *worker-backend* enum (`local/codex/api_llm/antigravity/noop`) | settings, manifest, machine-contract | `machine_contract.rs` `WORKER_BACKENDS` | Generate or assert the PowerShell and Rust lists from one source so they remain synchronized |
| Readiness marker chars / badge strings / blocker keywords | readiness, settings, UI | `workerReadinessPrompt.ts` | Export the badge strings + blocker regex as constants; have the runner import instead of re-matching; per-CLI regression fixtures |
| Mailbox v2 envelope | mailbox, machine-contract | `agent-monitor.ps1:643-667` | Mirror the v2 schema in a Rust `mailbox-contract`; test producer output conforms; add the missing consumer-side idempotency de-dup |
| Manifest version + `pane_id` semantics | manifest, mailbox | `manifest_contract.rs` | Add the informational-only `pane_id` caveat to the Rust struct docs; keep the version literal single-sourced |

## Additional contract surfaces to bring into scope

The six areas cover the primary surfaces; the sweep flagged six more that a
complete source-of-truth audit should include (each already has scattered
hand-declared copies): the **ledger review-state / verdict vocabulary**
(`ledger.rs`, literal `PENDING/PASS/FAIL` strings, no canonical enum); the
**worker-backend adapter contract** (`machine_contract.rs:32-38`
`WorkerBackendContract`, no cross-layer validation); the **`model_source` enum**
(the Confirmed-drift case); the **transport enum** (`argv|file|stdin` — validated
in all three layers: TS type, `settings.ps1:662/821`, `operator_cli.rs:2081/3191`,
but the allowed-set literal is hand-duplicated in each); the **evidence-record
kind** enum; and the **Agent
Vault provider subset** (implicit — only `claude/codex/opencode`, no canonical
definition).

## Recommendation for TASK-631 / TASK-632

1. Designate the source-of-truth files above as authoritative in the
   compatibility policy (TASK-631), and mark every re-declaration as either
   *generated-from* (must add codegen) or *validated-against* (must add a test).
2. Make the three Confirmed-drift cases hard failures the design-freeze gate
   (TASK-632) checks: (a) all Rust `model_source` validators accept the same set;
   (b) an explicit role-taxonomy map exists and the two Rust role normalizers
   (`machine_contract.rs canonical_role_for` + `operator_cli.rs canonical_role`)
   agree; (c) the existing capability→backend map (`assignableBackends`) resolves
   only to backends present in `WORKER_BACKENDS`, and the concrete worker-backend
   enum matches between `BridgeWorkerBackendKinds` and `WORKER_BACKENDS`.
3. Prefer a single machine-readable contract emitted by the Rust core (via the
   operator CLI as JSON) that PowerShell and TypeScript consume, over N
   hand-maintained copies — the recurring root cause across all six areas.

## Method

- Parallel sweep: 6 per-area agents (provider/readiness/manifest/route/mailbox/settings)
  + 1 cross-cutting critic, all read-only over `git`-tracked files (2026-07-06,
  main `3aea74df`).
- Hand-verified before publishing: the role-taxonomy split
  (`dispatch-router.ps1:5`, `coordinator-router.ps1:103`, `machine_contract.rs`
  has no Thinker/Verifier/Researcher); the `model_source` disagreement
  (`operator_cli.rs:2692` = 4 values vs `:3036` = 5); and the distinction
  between capability categories and concrete worker backends. From review,
  also confirmed: `operator_cli.rs`
  holds a second Rust role map (`canonical_role` :6882) accepting `Researcher`;
  the capability→backend map already exists (`assignableBackends`,
  `modelCapabilities.ts:197-202`) but references backends absent from
  `WORKER_BACKENDS`; no consumer de-duplicates mailbox messages; and mailbox v2
  does enforce non-emptiness with transport validated in PS + Rust.
- This is a design-debt inventory, not a behavioral spec; TASK-631/632 should
  re-confirm each `file:line` before acting on it.
