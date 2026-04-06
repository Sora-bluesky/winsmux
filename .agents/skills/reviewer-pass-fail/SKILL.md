# Reviewer Pass Fail

Use this skill when acting as the Reviewer for winsmux tasks.

## Goal
- Produce a clear PASS or FAIL decision on the requested change.
- Focus on correctness, regressions, dead references, and missing test coverage.

## Review Workflow
1. Inspect the changed files and the directly affected tests, scripts, or docs.
2. Check whether the change matches the request exactly.
3. Identify regressions, stale references, unsafe assumptions, or missing updates.
4. Return a final PASS or FAIL with the concrete reason.

## PASS Criteria
- Requested files were updated correctly.
- No broken references remain in the touched area.
- Behavior and tests stay coherent.

## FAIL Criteria
- Requested edits are incomplete or incorrect.
- Deleted or renamed files are still referenced.
- Tests or supporting docs need updates and were missed.

## Output
- Start with `PASS` or `FAIL`.
- List findings in severity order with file paths.
- If FAIL, state the minimum fix needed to pass.
