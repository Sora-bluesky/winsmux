# Contributing

Thanks for helping improve winsmux. This repository accepts public bug reports,
support discussion, feature requests, documentation fixes, and scoped pull
requests that fit the repository surface policy.

## Before You Start

- Read [Repository surface policy](docs/repo-surface-policy.md) before adding or
  changing tracked files.
- Read [Public distribution boundary](docs/source-access.md) before proposing
  changes that affect release packaging, redistribution, or source access.
- Use [SECURITY.md](SECURITY.md) for vulnerabilities. Do not file public GitHub
  issues for security reports.
- Do not include secrets, credentials, private local paths, browser profiles,
  account IDs, customer data, or raw private logs in issues, pull requests, or
  test artifacts.

## Issues

Use the issue templates when possible. A good issue includes:

- the winsmux version or commit
- Windows version and install path, such as desktop installer, npm package, or
  source build
- the exact command or workflow that failed
- expected behavior and actual behavior
- the smallest reproducible example or sanitized evidence

For support questions, start with [Documentation overview](docs/README.md) and
[Troubleshooting](docs/TROUBLESHOOTING.md). Security reports belong in the
private vulnerability reporting flow described in [SECURITY.md](SECURITY.md).

## Pull Requests

Keep pull requests narrow and reviewable.

1. Classify changed files using [Repository surface policy](docs/repo-surface-policy.md).
2. Explain the behavior or responsibility being replaced.
3. Describe the user-visible or maintainer-visible outcome.
4. Identify the source of truth for the changed behavior.
5. State which old paths are preserved, redirected, deprecated, or removed.
6. Include verification evidence beyond "it compiles" when the change affects
   release behavior, user workflows, routing, automation, security, privacy, or
   public documentation.

## Local Validation

Use the narrowest relevant checks for your change. Common entry points include:

```powershell
cargo test --workspace
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-tests.ps1
npm --prefix winsmux-app run build
npm --prefix winsmux-app run test:composer-text
```

For desktop or release-surface changes, include the relevant E2E, package, or
release-gate evidence in the pull request. Do not claim release readiness from a
partial local check.
