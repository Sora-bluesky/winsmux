# Claude Code, Codex, and Antigravity CLI comparison bakeoff

This page defines the public test plan for comparing Claude Code, Codex, and
Antigravity CLI inside winsmux.

Status: planned for `v1.0.2`.

The goal is not to declare one universal winner. The goal is to collect
repeatable first-party evidence about which model is strongest for each task
shape when it runs inside a real winsmux worker pane.

## Evaluation principles

The test must not infer task fit from a model name. Assumptions that pin one
model to speed and another model to quality are hypotheses, not conclusions.
Final recommendations come from winsmux evidence, tests,
anonymous review, resource samples, and screen recordings collected under the
same conditions.

External benchmarks are used only to select candidates and set expectations.
They are not added directly to the final score because public benchmark
conditions do not match winsmux tasks, local desktop behavior, CLI permissions,
subagent orchestration, or terminal wait handling.

Model fit is reported as a capability vector:

- Quality: requirements met, tests passed, and severe review findings avoided.
- Speed: time to useful output, correct plan, and reviewable result.
- Autonomy: intervention count, approval handling, and recovery after failure.
- Parallelism: independent work completed without duplication or conflicts.
- Terminal operation: long command handling, process cleanup, and memory use.
- Evidence: commands, failures, reasoning, and diffs are clear to a third party.
- Safety: secrets, non-public information, dangerous commands, and noisy diffs
  are avoided.
- Continuity: long context, session resume, review fixes, and follow-up work
  remain coherent.

The final task-fit score applies task-specific weights to this vector.

## HarnessBench as methodology reference

winsmux adopts nyosegawa HarnessBench as the external methodology reference for
CLI and model comparisons. This does not mean copying HarnessBench blindly.
winsmux keeps a local reference checkout at `.references/nyosegawa/harness-bench`.
The `.references/` directory is ignored by git, so upstream source stays out of
the winsmux public diff while still being available for local reproduction. If
the upstream runner or schema fails during winsmux integration, reproduce the
smallest failing case in that checkout and send an issue or PR to
`nyosegawa/harness-bench`.

winsmux keeps its own worker-pane, desktop app, and evidence requirements, but
the official comparison design follows these HarnessBench principles:

- Compare candidates on the same real-repository debugging tasks, not synthetic
  prompts or unrelated task packets.
- Score with hidden deterministic tests. Core tests and regression tests are
  the authoritative correctness signal.
- Use LLM review, including `gpt-5.5` review, only as auxiliary failure audit
  and quality control. It can explain likely bugs, missing tests, or unsafe
  changes, but it does not replace deterministic tests.
- Run each candidate in a sanitized fresh one-commit workspace with upstream
  steering and unrelated configuration removed.
- Use a 60-minute timeout for official agent runs unless a task-specific public
  note explicitly changes the limit.
- Record version and configuration snapshots, run artifacts, and summary
  reports for every scored run.
- Interpret small samples cautiously. HarnessBench reports a 27-task design;
  winsmux should treat `n=27`-style results as directional until repeated
  across enough task classes and local configurations.

The HarnessBench Antigravity article is an external reference point, not a
winsmux final score. It reports Antigravity CLI / `Gemini 3.5 Flash (High)` on
the same 27 tasks with `17/27`, median `14.3` minutes, and `1` timeout. winsmux
may use this to set expectations for local runs, but final winsmux conclusions
must come from winsmux evidence and the scoring rules below.

## HarnessBench-style packs

Read-only diagnosis and one-off demo runs are not enough to produce a model-fit
ranking. For official comparisons, winsmux only admits cases that satisfy this
contract:

- The task is a real-repository fix.
- Every comparable worker receives the same task packet.
- Worker-facing packets do not include hidden test commands or expected values.
- Scorer-only `*.hidden-checks.json` files separate core and regression tests.
- Each candidate works in an isolated worktree at the same `base_ref`.
- `runs_per_case` is used so repeated runs exist before a ranking is published.

To use upstream HarnessBench cases, first convert upstream YAML cases and
condition JSON into a winsmux `cases.json`. Start with one case, one condition,
and `RunsPerCase 1` for a smoke run, then move to `n=5` and later to broader
task coverage.

```powershell
pwsh -NoLogo -NoProfile -File scripts\import-cli-bakeoff-harnessbench-reference.ps1 `
  -ReferenceDir .references\nyosegawa\harness-bench `
  -CasePath benchmark/cases/sharkdp__bat/low.yaml `
  -ConditionPath benchmark/conditions/antigravity-gemini-3.5-flash-high.json `
  -OutputPath .winsmux\private\cli-bakeoff\harnessbench-upstream\cases.json `
  -SuiteId harnessbench-upstream
```

The importer maps upstream `core_tests` and `regression_tests` into
scorer-only `hidden_checks`. Worker-facing `*.md` packets must not include
hidden test paths or commands.

Create a benchmark pack from case definitions with:

```powershell
pwsh -NoLogo -NoProfile -File scripts\new-cli-bakeoff-harnessbench-pack.ps1 `
  -CasesPath .winsmux\private\cli-bakeoff\harnessbench-upstream\cases.json `
  -OutputDir .winsmux\private\cli-bakeoff\harnessbench-upstream\pack `
  -RunsPerCase 5 `
  -ReviewModel gpt-5.5
```

The script writes `benchmark-pack.json`, worker-facing `*.md` packets,
scorer-only `*.hidden-checks.json` files, `run-matrix.csv`, and a scoring
rubric. The generated `benchmark-pack.json` can be passed to
`scripts\new-cli-bakeoff-benchmark-run.ps1`.

To create repeated run evidence directories from `run-matrix.csv`, use:

```powershell
pwsh -NoLogo -NoProfile -File scripts\new-cli-bakeoff-harnessbench-run-matrix.ps1 `
  -PackPath .winsmux\private\cli-bakeoff\harnessbench-upstream\pack\benchmark-pack.json `
  -AllowMissingRecording
```

Use `-AllowMissingRecording` only for preparation. For official recorded runs,
start screen recording first, then run `operator-start.ps1` and each
`run-worker-*.ps1` script inside the desktop app.

Minimal `cases.json` shape:

```json
{
  "version": 1,
  "suite_id": "harnessbench-local",
  "default_workers": [
    {
      "pane": "worker-1",
      "role": "solver",
      "cli": "Claude Code",
      "model": "sonnet",
      "effort": "high",
      "display_model": "Claude Sonnet 4.7"
    }
  ],
  "cases": [
    {
      "case_id": "HB-001",
      "title": "Fix parser newline handling",
      "repo": "https://github.com/example/parser",
      "base_ref": "abc1234",
      "difficulty": "mid",
      "public_prompt": "Fix the parser so trailing newlines are accepted without changing valid token handling.",
      "allowed_paths": ["src/parser.ts", "tests/parser.public.test.ts"],
      "public_checks": ["npm test -- parser.public"],
      "hidden_checks": [
        { "id": "core", "command": "npm test -- hidden/core", "weight": 0.7 },
        { "id": "regression", "command": "npm test -- hidden/regression", "weight": 0.3 }
      ],
      "success_criteria": [
        "trailing_newline_is_accepted",
        "existing_valid_tokens_still_parse"
      ]
    }
  ]
}
```

For recording demos, `n=5` is the minimum useful repeat count. Rankings need
more task classes and difficulty levels, then should be read by pass rate,
median time, timeout count, review findings, and variance. Small differences
should be reported as broad upper, middle, and lower bands.

## GLM-5.2 and cloud-baseline E2E matrix

GLM-5.2 is evaluated in two phases. Phase 0 proves that the model can run as a
winsmux `colab_llm` worker before it is compared against hosted cloud models.
Phase 1 uses the same HarnessBench-style task pack for every worker.

| Phase | Worker | Candidate | Purpose | Required evidence |
| --- | --- | --- | --- | --- |
| 0 | `worker-1` | `zai-org/GLM-5.2` through `colab_llm` on Colab H100/A100 | Prove load, generation, artifact capture, failure classification, and Colab cost boundaries. | Colab runtime log, model cache location, GPU RAM, load time, generation time, redacted worker result. |
| 1 | `worker-1` | `zai-org/GLM-5.2` through `colab_llm` | Open-weight Colab baseline on the same real-repository task. | Hidden core/regression tests, scorecard, resource metrics. |
| 1 | `worker-2` | Claude Code with a current high-level Claude model such as Fable 5 or Opus 4.8 | Hosted Claude coding baseline. The exact locally selectable model and effort must be recorded before each run. | Model picker or CLI evidence, effort setting, transcript, hidden tests, review packet. |
| 1 | `worker-3` | Codex with a current high-level OpenAI model such as `gpt-5.5` | Hosted OpenAI coding baseline. If `gpt-5.5` is a worker, it cannot be the sole independent reviewer for that run. | Codex model evidence, effort setting, transcript, hidden tests, review packet. |
| 1 optional | `worker-4` | Antigravity CLI with Gemini 3.5 Flash High or another locally verified high-level Gemini condition | Hosted Gemini/Antigravity baseline, especially speed, subagents, and async terminal behavior. | `agy --help`, model setting evidence, transcript, hidden tests, review packet. |

The comparison is invalid if these workers receive different task packets,
different hidden tests, or extra steering. Phase 1 starts with one low-difficulty
HarnessBench case at `n=1`, moves to `n=5`, and only then expands to the full
27-task HarnessBench shape. Phase 0 is allowed to fail on capacity or runtime
support, but it must still produce a classified result and reusable evidence.

Recommended first cases:

1. `sharkdp__bat/low.yaml`: small Rust CLI task, good smoke test for harness and
   hidden-test plumbing.
2. `axios__axios/low.yaml`: JavaScript/TypeScript repository task, useful for
   code-edit and test-loop behavior.
3. `fastapi__fastapi/low.yaml`: Python web framework task, useful for dependency
   and test-environment behavior.

Do not use Design Arena, Code Arena, or vendor benchmark charts as direct
winsmux scores. They can explain why GLM-5.2 is worth testing, but the winsmux
score must come from the local run artifacts and deterministic hidden tests.

## Upstream facts to lock before testing

- Google announced the transition from Gemini CLI to Antigravity CLI on
  2026-05-19.
- Gemini CLI remains available, but `@google/gemini-cli` is limited to critical
  bug fixes and security patches.
- Individual Gemini CLI request serving ends on 2026-06-18.
- Enterprise Gemini CLI usage through Gemini Code Assist Standard,
  Gemini Code Assist Enterprise, Google Cloud GitHub integration, paid Gemini,
  and Gemini Enterprise Agent Platform API keys remains unchanged according to
  Google's transition notice.
- Gemini 3.5 Flash is available through Google Antigravity and is positioned by
  Google for fast agentic coding workflows.
- The local `agy --help` output must be checked before each run.
  On 2026-05-24, `agy 1.0.2` was available locally and Antigravity reported
  `Gemini 3.5 Flash (High)` as the current model in its model picker. Because
  `agy --help` does not expose a `--model` flag, the test must verify model
  selection through Antigravity's own model picker, `/model`, or settings file
  before recording a run as Gemini 3.5 Flash evidence.
- Antigravity CLI migration is not perfect parity with Gemini CLI, but the
  official migration path covers plugins, Agent Skills, MCP servers, hooks, and
  subagents. Existing Gemini CLI extensions should be imported with
  `agy plugin import gemini` before winsmux treats an Antigravity run as a
  like-for-like migration test.

## Test roles

| Role | CLI | What it should prove |
| --- | --- | --- |
| Operator | Claude Code | Owns task framing, approvals, final judgement, and evidence acceptance. |
| Review worker | Claude Code | Produces architectural review, risk notes, and judgement-heavy feedback. |
| Build worker | Codex | Produces bounded patches, runs tests, and reports exact changed files. |
| Antigravity worker | `agy` with Gemini 3.5 Flash | Tests speed, quality, parallel subagents, and asynchronous terminal work under the same conditions. |

## Desktop app and recording requirement

The official comparison runs must be executed through the winsmux desktop app.
CLI-only runs can be kept as reference data, but they do not count as desktop
comparison results.

Every run must be screen recorded. Recording starts before the task packet is
assigned to the worker pane and ends after `scorecard.md` and the required
evidence files are present. The recording must include the winsmux desktop app,
operator pane, worker panes, Agent Vault, status bar, approval prompts, and test
result surfaces.

If secrets, account-specific quota, or non-public operating details appear on
screen, the raw recording must not be published. Keep that run as private
evidence and publish only redacted notes plus aggregate metrics.

## Worker launch validity

A worker timeout is not automatically a model failure. Before excluding a
candidate from a comparison, the run must prove that the worker pane was started
with a valid launch method and that the harness did not block the child process.

For Claude Code, Codex, Antigravity CLI, and custom runners, winsmux comparison
runs must use one of these launch methods:

- Direct interactive launch inside the worker pane.
- `scripts/invoke-cli-bakeoff-worker.ps1`, which drains stdout and stderr before
  waiting for process exit and writes stdin on a timeout-bound background task.

Do not create ad hoc wrappers that redirect stdout or stderr and then call
`WaitForExit` before reading the streams. Also do not perform an unbounded
synchronous stdin write before timeout handling starts. Either pattern can
deadlock when a pipe buffer fills. If that pattern appears in a run, mark the
result as invalid harness evidence, fix the runner, and rerun the same task. The
candidate must remain in the comparison until a valid run succeeds or the CLI
itself fails under a verified safe launch path.

## Candidate models

The comparison is model-aware. Each run records the selected model, reasoning
level, permission mode, and sandbox settings in `manifest.json`.

| CLI | Candidate model | Effort / mode | Purpose |
| --- | --- | --- | --- |
| Claude Code | Claude Sonnet 4.7 | `high` in the demo run | Measure design, review, task decomposition, and written judgement. |
| Codex | `gpt-5.3-codex-spark` | `medium` in the demo run | Measure implementation, review, long-context, and review-fix behavior without using the judge model as a worker. |
| Antigravity CLI | Gemini 3.5 Flash (High) | model mode is High | Measure speed, quality, review resistance, parallelism, and resource use. |
| Antigravity CLI | Gemini 3.5 Flash (Medium) | model mode is Medium | Compare High against Medium on speed, quality, findings, and resources. |
| Codex expansion set | `gpt-5.5` | `medium` / `high` / `xhigh` | Optional HarnessBench-style matrix when the judge model is allowed as a worker. |
| Claude Code expansion set | Claude Opus 4.7 | `high` / `xhigh` / `max` | Optional HarnessBench-style matrix for high-effort Claude conditions. |

## Workloads

| Workload | Purpose | Expected evidence |
| --- | --- | --- |
| Shared read-only diagnosis | Give every candidate the same repository packet and ask for top risks and next patch plan. | Time to useful answer, factual accuracy, missed constraints, and citation quality. |
| Bounded code change | Give every candidate an equivalent small fix in an isolated worktree. | Diff size, test result, intervention count, and mergeability. |
| Cross-cutting implementation | Ask for a change across multiple modules and contracts. | Plan accuracy, conflict avoidance, test coverage, and evidence quality. |
| Parallel fan-out | Split one feature into independent subtasks and run them at the same time. | Useful parallel tasks, conflict rate, duplicate work, and integration quality. |
| Asynchronous terminal wait | Start a long-running check, then assign another task while the terminal is busy. | Whether the worker keeps progress without blocking the operator. |
| Evidence handoff | Ask each candidate to produce a final review packet. | Whether winsmux can compare output without reading a long transcript. |
| Migration compatibility | Run one migrated Gemini CLI workflow through Antigravity CLI after `agy plugin import gemini`. | Which skills, plugins, MCP servers, hooks, or settings did not migrate cleanly. |

## Task taxonomy

Every run is tagged with one or more task classes.

| Class | Examples | Main evaluation axes |
| --- | --- | --- |
| Bounded fix | One-file or few-file bug fix, config fix, type error fix. | Accuracy, tests, small diff, review findings. |
| Cross-cutting implementation | Feature work, contract change, migration across modules. | Planning, conflict avoidance, test scope, evidence. |
| Investigation and design | Root-cause analysis, spec cleanup, risk discovery. | Factual accuracy, references, missed constraints. |
| Code review | Bug, security, spec gap, and test gap detection. | Severe finding detection, false positives, reproducibility. |
| Documentation | README, guide, release note, migration docs. | Accuracy, readability, public-surface safety. |
| UI / E2E | Desktop app, browser, installer, screenshot checks. | Visual evidence, reproducibility, wait handling. |
| Parallel fan-out | Independent research, fixes, and verification. | Parallelism, duplicate work, integration quality. |
| Long-running commands | Build, E2E, audits, heavy tests. | Async terminal handling, process cleanup, progress reporting. |
| Release work | Version, release notes, CI, issues, docs, artifacts. | Procedure adherence, omissions, evidence, public safety. |

Each task also records these attributes:

| Attribute | Examples | What it separates |
| --- | --- | --- |
| Scope | One file, multiple files, multiple subsystems | Small fixes from broad changes. |
| Ambiguity | Clear, mildly ambiguous, exploratory | Instruction following from requirement discovery. |
| Context length | Short, long, prior history required | Long-context robustness. |
| Verification | Unit test, E2E, manual check, review only | Executable correctness from judgement-only tasks. |
| Parallel potential | Low, medium, high | Whether subagent ability matters. |
| Risk | Low, medium, high | Security, public docs, and release weight. |
| Artifact | Diff, review, plan, docs, execution log | Polished prose from adoptable changes. |

## Scoring design

Final results are not reduced to one winner. Each workload and task class gets
its own score.

Hidden deterministic tests are the primary scoring authority. The same hidden
core and regression test suites must evaluate every comparable worker result.
LLM reviews, including `gpt-5.5` review, are auxiliary failure review and QC
signals. They can cap or annotate a run when they identify a reproducible
defect, but they cannot promote a run that failed the required deterministic
tests.

| Axis | Points | Measurement |
| --- | ---: | --- |
| Accuracy | 30 | Requirements met, tests pass, no invented files or APIs. |
| Review findings | 20 | Independent review findings weighted by severity. |
| Speed | 15 | Useful output, correct plan, first test, and accepted result timing. |
| Parallelism | 15 | Useful parallel tasks, overlap, duplicate work, conflicts, integration. |
| Async terminal | 10 | Progress during long commands and correct wait-state handling. |
| Evidence quality | 10 | Reasoning, commands, failures, and decisions are auditable. |

Hard caps apply:

| Condition | Cap |
| --- | ---: |
| Tests do not start or the primary feature is unusable | 40 |
| Any `P0` finding exists | 50 |
| Two or more `P1` findings exist | 70 |
| Evidence is missing and the run cannot be reproduced | 60 |

Review findings use this score:

```text
review_score = max(0, 100 - P0*45 - P1*20 - P2*6 - P3*2)
```

Additional derived metrics:

- Quality efficiency: `accepted_quality_score / elapsed_minutes`
- Operator efficiency: `accepted_quality_score / operator_blocked_minutes`
- Review resistance: `review_score` and improvement after review fixes
- Resource efficiency: `accepted_quality_score / peak_memory_mb`
- Stability: score variance across repeated runs in the same class

## Independent review

Correctness is not judged by the candidate model's self-report. Each result is
anonymized into a review packet that hides CLI and model names.

Required review:

- Rule-based checks: required tests, public-surface audit, diff size, changed
  files, and forbidden public information.
- Codex review: use `codex review` for bugs, spec gaps, missing tests, and
  security issues.
- Cross-family review: use Claude Code or another model on the same anonymous
  packet and record agreement or disagreement with Codex review.

If a candidate and reviewer use the same model family, that review is kept as a
reference note, not as the direct scoring source.

QC rule: every compared worker must receive the same task packet and be
evaluated by the same deterministic tests. If one worker receives a different
packet, extra steering, different hidden tests, or a non-equivalent workspace,
the comparison run is invalid and must be rerun.

## Speed, parallelism, and async terminal metrics

Speed measures time until the work moves forward, not raw output rate.

- `time_to_first_output`
- `time_to_first_useful_plan`
- `time_to_first_test`
- `time_to_accepted_result`
- `operator_blocked_seconds`

Parallel subagents are scored by useful work, not by count.

- `useful_parallel_tasks`
- `parallel_overlap_ratio`
- `duplicate_work_ratio`
- `merge_conflict_count`
- `subagent_trace_quality`

Async terminal behavior is measured while long commands are running.

- Can the worker continue another task during a long check?
- Does it notice terminal output, approval waits, and failures?
- Does it clean up processes after the run?
- Do memory and child-process counts stay bounded?
- Does the final report include the result of the waited command?

## Model fit table

The final report generates this table from `result.json`. It is not filled from
pre-test assumptions.

| Model | Task class | Fit | Confidence | Caveat | Evidence |
| --- | --- | --- | --- | --- | --- |
| Gemini 3.5 Flash (High) |  | best / strong / conditional / avoid | high / medium / low |  |  |
| Gemini 3.5 Flash (Medium) |  | best / strong / conditional / avoid | high / medium / low |  |  |
| Gemini 3.1 Pro family |  | best / strong / conditional / avoid | high / medium / low |  |  |
| `gpt-5.5` |  | best / strong / conditional / avoid | high / medium / low |  |  |
| `gpt-5.3-codex-spark` |  | best / strong / conditional / avoid | high / medium / low |  |  |
| Claude Sonnet 4.7 |  | best / strong / conditional / avoid | high / medium / low |  |  |
| Claude Opus family |  | best / strong / conditional / avoid | high / medium / low |  |  |

Each cell must explain the assignment. A statement like "fast" is not enough.
For example: "High score on clear investigation tasks, but cross-cutting
implementation produced more `P1` findings; require cross-family review before
adoption."

Confidence is based on run count, task diversity, review agreement, and score
variance. A single good run remains a hypothesis.

## Evidence contract

### Benchmark pack and recording preparation

The first formal winsmux pack lives at:

```text
tasks/cli-bakeoff/v1/benchmark-pack.json
```

The pilot pack contains 9 task classes. It is large enough to avoid drawing a
conclusion from a single easy prompt, but it is still a pilot. Treat its results
as directional until the full 27-task target has enough repeated runs.

Create a recording run from the pack with:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\new-cli-bakeoff-benchmark-run.ps1 `
  -TaskId WB-001 `
  -DesktopAppVersion "v1.0.2" `
  -AllowMissingRecording `
  -Json
```

The script writes one run directory with the shared `task-packet.md`,
`worker-spec.json`, `operator-start.ps1`, `run-worker-*.ps1`, `scorecard.md`,
and `recording-ready-checklist.md`. The operator script exists so the recording
shows the operator assigning the same task to each worker.

Before starting a recorded comparison, run:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\test-cli-bakeoff-preflight.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\<run-id> `
  -TimeoutSeconds 120 `
  -Json

pwsh -NoLogo -NoProfile -File .\scripts\test-cli-bakeoff-recording-ready.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\<run-id> `
  -RequirePreflight `
  -Json
```

Recording can start only after the second command reports `all_pass=true`.

Each run writes a run directory under:

```text
.winsmux/evidence/cli-bakeoff/<run-id>/
```

Create the run directory with:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\new-cli-bakeoff-run.ps1 `
  -Cli "Antigravity CLI" `
  -Model "Gemini 3.5 Flash (High)" `
  -TaskClass "bounded_fix" `
  -TaskPacketPath .\tasks\example-task.md `
  -DesktopAppVersion "v1.0.2" `
  -RecordingPath .\recordings\example.mp4 `
  -Json
```

Formal runs require `-RecordingPath`. Missing-recording scaffolds are allowed
only when `-AllowMissingRecording` is explicitly set for tests or preparation.

Required files:

- `manifest.json`: CLI, version, model, task packet hash, worktree, start time,
  end time, operator, desktop app version, and recording metadata.
- `pane-transcript.txt`: bounded terminal transcript.
- `commands.jsonl`: commands, exit codes, duration, and whether the operator
  approved them.
- `resource-samples.jsonl`: process count, CPU, memory, and child processes.
- `screen-recording.mp4`: recording of the full desktop app run.
- `screen-recording.json`: recording start, end, resolution, target windows,
  publishability, and redaction status.
- `review-findings.jsonl`: anonymous review findings, severity,
  reproducibility, and whether they were used for scoring.
- `result.json`: normalized score fields.
- `scorecard.md`: one-page human-readable result.

Antigravity CLI runs have an additional evidence requirement. The run must
record local Antigravity version `v1.0.2`, selected model label,
command shape, isolated home and configuration path,
full log, stdout or recovered transcript output, and timeout. A local
`agy --print` invocation that exits `0` with empty stdout is scoreable only when
the isolated Antigravity transcript contains a matching model response and the
required end marker. Otherwise it remains `blocked_empty_stdout`.

## Repeated Failures And Permanent Guards

The recorded test repeated these failures:

| Failure | Cause | Permanent guard |
| --- | --- | --- |
| CLI arguments were changed during recording | Long one-line commands were sent to worker panes without a preflight gate | Do not start a run until `preflight.json` has `all_pass=true` |
| Claude Code did not respond | It started from the repository root and loaded too much initial context for a marker prompt | Start from the run directory and add the repository with `--add-dir` |
| Claude Code sent side-channel messages | A globally installed Claude Code plugin exposed Telegram-style tools in a non-channel worker run | Do not pass `--channels` unless the worker spec explicitly requests it, and deny channel reply tools by default |
| Claude Code model selection failed | The visible label `Claude Sonnet 4.7` was passed as the CLI model argument | Split `display_model` from `model` and pass `sonnet` to the CLI |
| Codex could not start | The WindowsApps `codex.exe` path was selected and `Process.Start()` was denied | Prefer `.cmd` before `.exe` when resolving Windows command shims |
| Antigravity CLI output was treated as scoreable | `agy --print` exited with code `0` but produced empty stdout | Record empty stdout as `blocked_empty_stdout` and exclude it from machine scoring |

If one of these failures appears, the recording run stops. Fix the cause and
rerun `preflight` before starting again.

## Worker Execution Gate

Formal runs must pass preflight before recording starts:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\test-cli-bakeoff-preflight.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\example-run `
  -TimeoutSeconds 120 `
  -Json
```

If `preflight.json` does not have `all_pass=true`, the operator must not start
the run. Do not switch models or experiment with CLI arguments during recording.
If Claude Code, Codex, or Antigravity CLI cannot produce the short preflight
marker with the selected model, the run remains a preparation failure. Preflight
checks only launch and connectivity. The task end marker is required for the
real worker run, not for preflight.

`preflight.json` stores hashes for `manifest.json`, `task-packet.md`, and
`run-worker-*.ps1`. The recording start script recomputes them immediately
before launch. If any hash changed, the stale preflight is rejected and the run
does not start.

When the user-visible model name differs from the actual CLI argument, write
both values in `manifest.json`: `display_model` for the visible label and
`model` for the invocation value. For example, Claude Code may be displayed as
`Claude Sonnet 4.7` while the CLI receives `--model sonnet`. A run that passes the
display label directly and fails is invalid.

Claude Code must use the run directory, not the repository root, as its working
directory and add the repository through `--add-dir`. This prevents a short
preflight prompt from loading the whole workspace as initial context and failing
on the token budget before the worker proves that it can respond.

Claude Code Channels are opt-in per session. The official contract is that a
channel server is not enough: the session must be started with `--channels`.
Therefore winsmux comparison workers do not pass `--channels` by default. When
no `claude_channels` worker setting is present, the guarded runner also denies
known channel reply tools such as Telegram replies. If a test is explicitly
about Claude Code Channels, put the channel plugin in the worker spec and keep
that run separate from model-quality comparison runs.

Formal runs must execute the worker task through the guarded runner:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\invoke-cli-bakeoff-worker.ps1 `
  -RunDir .\.winsmux\evidence\cli-bakeoff\example-run `
  -PaneId worker-1 `
  -Cli "Codex" `
  -Model "gpt-5.3-codex-spark" `
  -PromptPath .\.winsmux\evidence\cli-bakeoff\example-run\task-packet.md `
  -Json
```

## Report And Chart Outputs

`summarize-cli-bakeoff.ps1` writes both machine-readable data and a
blog-quality report scaffold:

- `article-report.md`: HarnessBench-style written report with conditions,
  results, wall time, timeout, quality-control notes, cautious interpretation,
  and references.
- `chart-data.json`: normalized chart source data for completion or pass rate,
  median wall time, speed-quality scatter, capability radar, and task-class
  heatmap.
- `gpt-image-2-chart-prompts.md`: prompts that explicitly require GPT image 2.0
  for high-quality chart images.

The report must not over-claim from a small sample. It should separate
completed runs, scored passes, timeouts, and review findings. If hidden or
deterministic scoring is unavailable, the chart should say completion rate
rather than pass rate.

The runner writes separate `*-stdout.txt`, `*-stderr.txt`,
`*-pane-transcript.txt`, and `*-result.json` files. Standard error is saved as
evidence but is not mixed into the visible pane transcript, so provider warnings
cannot look like model output.

A run is scored only when `status` is `completed`. Every other status is
blocked from scoring. The runner records a blocked status when any of these
conditions occurs:

- `blocked_empty_stdout`: the process exits with code `0` but produces empty
  stdout.
- `blocked_missing_end_marker`: the expected `BAKEOFF_ROUND_A_END` marker is
  missing.
- `blocked_timeout`: the process times out.
- `blocked_nonzero_exit`: the CLI exits with a non-zero code.
- `blocked_start_failure`, `blocked_command_line_too_long`, or
  `blocked_stream_read_timeout`, or `blocked_stdin_write_timeout`: the worker
  could not produce reliable machine-readable evidence.

This is especially important for Antigravity CLI. If `agy --print` returns no
stdout, the runner may recover the model response from Antigravity's isolated
`transcript.jsonl`. The run is scoreable only when that recovered transcript
contains the expected marker, the required end marker, model evidence, and
generated-text evidence. Interactive TUI output may be kept as screen evidence,
but it is not sufficient for machine-scored comparison.

The recording operator must not paste long raw CLI invocations into worker
panes. It should launch only preflight-verified scripts such as
`run-worker-1.ps1`. This prevents quoting, newline, PowerShell continuation, and
provider-specific argument parsing failures from being discovered during the
recorded run.

## One-glance scorecard

`scorecard.md` uses this table shape:

| CLI | Model | Task class | Accuracy | Review findings | Speed | Parallelism | Async terminal | Evidence | Overall | Verdict |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Claude Code | provider selected |  |  |  |  |  |  |  |  |  |
| Codex | provider selected |  |  |  |  |  |  |  |  |  |
| Antigravity CLI | Gemini 3.5 Flash |  |  |  |  |  |  |  |  |  |

The verdict is task-specific. A model may be strong for a task class and weak
for another.

## Final report

After all runs, publish:

- `model-task-fit.md`: model fit, caveats, and tasks to avoid.
- `assignment-policy.md`: recommended winsmux worker-pane assignment policy.
- `raw-score-matrix.csv`: model, CLI, task class, axes, score, findings, and
  timing data.
- `model-evidence-profile.json`: capability vector, confidence, and evidence
  runs per model.
- `benchmark-report.html`: rich static benchmark report with a SWE-bench
  Pro-style score grid, speed-quality scatter plot, capability radar, and
  task-class heatmap.
- `.references/benchmark-reports/cli-bakeoff-benchmark-report.html`: local
  reference copy of the latest rich report. This path is ignored by git and is
  for local review, recording, and article drafting only.

Generate the summary with:

```powershell
pwsh -NoLogo -NoProfile -File .\scripts\summarize-cli-bakeoff.ps1 -Json
```

Every recommendation is conditional. It must include task class, task
attributes, recommended model, required reviewer, avoid conditions, evidence
runs, and confidence.

This keeps the result usable for worker-pane assignment instead of reducing it
to a broad claim like "`gpt-5.5` is best" or a simple speed label.

## Guardrails

- Do not compare CLIs using different task packets.
- Do not score a comparison unless every worker used the same task packet and
  the same deterministic test set.
- Do not count a run as Gemini 3.5 Flash unless Antigravity itself reports or
  persists that model selection.
- Do not accept a result without a transcript, command log, changed-file
  summary, and desktop app screen recording.
- Do not publish non-public access details, tokens, or account-specific quota
  data in public artifacts.
