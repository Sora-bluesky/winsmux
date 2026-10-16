# Workflow gate examples

These executable examples are consumed by `winsmux workflow-gate --json` and
the workflow and context-pack contract tests. Keep each marker and its YAML
fence unique.

## Workflow v1

<!-- TASK659-RUNNABLE-WORKFLOW-V1:START -->
```yaml
config-version: 1

# Lane B-owned; shown only to make the reference boundary explicit. The selected
# preset supplies the remaining resolved slots with concrete provider/model IDs.
team-profile:
  schema-version: 1
  preset: official-balanced-v1
  preset-revision: 1
  update-policy: retain-overrides
agent-slots:
  - slot-id: worker-1
    provider: codex
    model: codex-gpt-5-6-sol

# Lane A-owned.
workspace-recipes:
  bugfix-two-slot:
    schema-version: 1
    panes:
      - pane-key: implement
        workflow-role: implementer
        slot-ref: worker-1
        requires-capabilities: [file-edit]
        region: main
        worktree:
          mode: managed
          name-template: "{{workflow-id}}-implement"
      - pane-key: verify
        workflow-role: verifier
        slot-selector:
          requires-capabilities: [review]
        region: side
        worktree:
          mode: read-only-reference
    startup-actions:
      - action-id: prepare-implement-worktree
        kind: ensure-managed-worktree
        pane-ref: implement
      - action-id: start-verify-slot
        kind: ensure-slot-ready
        pane-ref: verify

workflows:
  bugfix:
    schema-version: 1
    recipe-ref: bugfix-two-slot
    nodes:
      - node-id: inspect
        pane-ref: implement
        action: operator-dispatch
      - node-id: implement
        pane-ref: implement
        depends-on: [inspect]
        action: operator-dispatch
      - node-id: verify
        pane-ref: verify
        depends-on: [implement]
        action: operator-dispatch
```
<!-- TASK659-RUNNABLE-WORKFLOW-V1:END -->

## Context-pack preview

<!-- TASK660-RUNNABLE-CONTEXT-PACK-V1:START -->
```yaml
context-packs:
  review-pack:
    schema-version: 1
    include: [code-map, changed-files, tests, evidence-refs]
    limits:
      max-files: 100
      max-bytes: 262144
      max-evidence-refs: 50
    privacy:
      raw-transcript: false
      prompt-bodies: false
      secrets: false
      private-local-paths: false
```
<!-- TASK660-RUNNABLE-CONTEXT-PACK-V1:END -->

The public `winsmux workspace-plan` entry supports a read-only context-pack preview.
It does not persist the context-pack result. The public envelope contains exactly
`canonical_json`, `digest`, and `byte_count`. The digest is computed from the exact
canonical UTF-8 bytes; byte_count is their byte length. Rejection emits no public
output and preserves project and runtime bytes.

`winsmux workflow-gate` validates the preview and does not implement context-pack persistence.
Existing ledger context-pack references are a separate pre-existing mechanism;
the preview does not create ledger references or supply route/resume authority.
