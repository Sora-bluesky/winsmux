# v0.36.20 Coordinator Offline Baseline

This baseline report is generated from deterministic fixture cases only. It
does not call providers, does not include raw prompts, and does not assert real
model quality.

## Fixture Scope

| Case | Intent | Expected slot | Reason |
| --- | --- | --- | --- |
| `case-implementation` | Worker implementation route | `worker-2` | The slot is ready, has `Worker`, and advertises implementation capability. |
| `case-verifier` | Verifier route | `worker-1` | The slot is ready, has `Verifier`, and advertises review/verification capability. |

## Baselines

| Baseline | Purpose |
| --- | --- |
| deterministic capability router | Proposed v0.36.20 rule-based route selection. |
| strongest single slot | A static strongest-slot assumption. |
| round robin | A fixed alternating assignment baseline. |
| seeded random | A deterministic pseudo-random baseline for repeatable tests. |
| static task-type rule | A simple task-type to capability rule. |

## v0.36.20 Local Result

| Metric | Value |
| --- | ---: |
| provider calls | 0 |
| deterministic success rate | 1.0 |
| fixture cases | 2 |
| coordination turns | 2 |
| conflict rate | 0 |
| fallback rate | 0 |

## Interpretation

This report proves only that the coordinator substrate can make explainable
offline route decisions and compare them with simple baselines. It is not a
Harness Bench result, not a live-provider benchmark, and not a replacement for
operator judgement.
