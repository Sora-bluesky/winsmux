# Binding Governance Rules

Binding is the governance control layer for shield-harness. It is NOT an LLM — it is a set of rules, gates, and contracts enforced by Claude Code (Orchestra).

## Operating Profiles

| Profile      | Gate Density                     | Use When                                    |
| ------------ | -------------------------------- | ------------------------------------------- |
| **Lite**     | STG0 + STG6 only                 | Low-risk tasks (docs, minor edits)          |
| **Standard** | All STG gates                    | Normal development tasks                    |
| **Strict**   | All STG gates + mandatory review | Security-sensitive or public-facing changes |

Profile is selected at `/startproject` time based on task risk level.

## STG Gates (Stage Gates)

| Gate | Name           | Purpose                            |
| ---- | -------------- | ---------------------------------- |
| STG0 | Requirements   | Task acceptance criteria confirmed |
| STG1 | Design         | Architecture/approach reviewed     |
| STG2 | Implementation | Code written and self-reviewed     |
| STG3 | Verification   | Tests pass, lint clean             |
| STG4 | Automation     | CI/CD checks pass                  |
| STG5 | Commit/Push    | Changes committed and pushed       |
| STG6 | PR/Merge       | Pull request created and merged    |

## fail-close Principle

- When safety conditions are NOT met, Binding STOPS execution
- On stop: output reason and recovery steps in Japanese
- Never skip a gate — always fail-close

## Layer Contract

### Orchestra -> Binding (Input)

| Field      | Type   | Description                    |
| ---------- | ------ | ------------------------------ |
| profile    | string | "lite" / "standard" / "strict" |
| task_id    | string | e.g., "TASK-001"               |
| intent     | string | What the task aims to achieve  |
| risk_level | string | "low" / "medium" / "high"      |
| request_id | string | Unique request identifier      |

### Binding -> Orchestra (Output)

| Field               | Type   | Description                                                      |
| ------------------- | ------ | ---------------------------------------------------------------- |
| decision            | string | "allow" / "stop"                                                 |
| failed_steps        | array  | List of failed gate checks                                       |
| required_actions    | array  | Steps needed to proceed                                          |
| evidence_paths      | array  | Paths to evidence files                                          |
| next_state          | string | backlog/STG update result                                        |
| quality_gate_source | string | Source of blocking/high judgments (CI results, review summaries) |
| quality_gate_counts | object | { blocking: number, high: number }                               |

## Single Source of Truth

- **Task state**: `tasks/backlog.yaml` is the ONLY authoritative source
- **Stage status**: Tracked in `stage_status` field within backlog.yaml
- **Evidence**: Recorded in `evidence` array within each task
- **Decision log**: Decision log is maintained per-project.
