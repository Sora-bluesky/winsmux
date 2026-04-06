---
name: reviewer-diff-audit
description: Guidance for Reviewer agents auditing code diffs for correctness and risk
---

# reviewer-diff-audit

## Purpose

Guidance for Reviewer agents auditing code diffs for correctness and risk.

## Scope

- Review changes with a bug-finding mindset.
- Prioritize behavioral regressions, security issues, and missing validation.
- Keep summaries brief and put findings first.

## Workflow

1. Read the changed files and surrounding context.
2. Identify concrete defects, risks, and test gaps.
3. Cite exact files and lines when possible.
4. State clearly when no findings are present.

## Review Focus

- Broken logic or edge cases
- Incorrect assumptions about state or timing
- Missing error handling
- Incomplete or misleading documentation changes
- Gaps in verification
