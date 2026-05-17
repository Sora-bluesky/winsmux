# Review Latency Hardening

This maintainer-facing note is the operating rule for `TASK-372` and issue `#504`.
It applies when a small desktop UI or TypeScript change repeatedly produces
`no result yet` from a review subagent.

The goal is not to weaken review. The goal is to stop paying review startup
cost for every tiny change while still making delayed review output part of the
merge decision.

## Trigger

Use this rule when all of these conditions are true:

- The PR is a desktop UI or TypeScript change.
- The current review scope is small: usually `1` to `3` changed files.
- Local validation already passed for the current change.
- A fresh review subagent returns `no result yet` twice for the same PR or branch.
- The same PR is accumulating small follow-up commits rather than reaching a
  stable checkpoint.

Record the trigger in the branch notes, PR comment, or handoff note. The record
must include branch name, PR number when available, changed files, local
validation commands, first wait duration, second wait duration, and the review
agent identity when the tool exposes one.

## Stop Per-Change Review

After the trigger fires, stop spawning a fresh review subagent for each tiny
follow-up change on that PR.

Between checkpoints, continue:

- local diff review by the implementer,
- targeted tests for the changed surface,
- `git diff --check`,
- security and public-surface checks when relevant,
- recording any delayed review result that arrives.

Do not claim the review is complete merely because two waits returned
`no result yet`.

## Minimum Waits

For small desktop UI or TypeScript review, use these minimum waits before
changing strategy:

| Phase | Minimum wait | Required action |
| --- | ---: | --- |
| First wait | `10` minutes | Wait for the current review subagent before deciding the first response is only delayed. |
| Second wait | `10` minutes | Recheck the same review thread or agent. Do not spawn a replacement just to reset the timer. |
| Background hold | `20` minutes | Keep the same agent alive after the second `no result yet` so delayed findings can still arrive. |

If the review tool has a longer required timeout, use the longer timeout. For
`codex review`, the release gate still uses at least `600000` milliseconds and
the configured release-review model.

## Switch To Milestone Review

After the trigger fires, batch the next review at a milestone instead of each
individual change.

Use the next milestone that occurs first:

- the UI behavior is complete enough to test end to end,
- the PR is ready for a local release gate,
- changed files expand beyond the original `1` to `3` file scope,
- a delayed review result arrives with actionable findings,
- the branch is about to be pushed for PR review,
- the branch is about to merge.

The milestone review must cover all changes since the last accepted review
evidence. It must include the delayed result if one arrived.

## Merge Gate

The PR must not merge while a delayed review result is unexamined.

Before merge, one of these outcomes must be recorded:

- The delayed result arrived, all actionable findings were addressed or
  explicitly rejected with a reason, and the final review state is recorded.
- No delayed result arrived after the background hold, the milestone review ran,
  `codex review` passed with the release-review model, and the PR records that
  the subagent result remained unavailable.
- The review agent failed in a way that is distinct from latency, and the PR
  records the failure plus the replacement review evidence.

This rule is a merge gate. It is not a permission to skip the release review.

## Evidence Checklist

For each affected PR, preserve:

- the repeated `no result yet` observations,
- wait durations,
- whether the same review agent was kept alive,
- the milestone that replaced per-change review,
- delayed findings and their disposition,
- local validation commands,
- final `codex review` command and model,
- PR checks and release checks when this is part of release work.

## Public Boundary

This is an internal operating rule. Public product docs should not mention issue
`#504`, review-subagent latency, or maintainer-only review workflow details.
