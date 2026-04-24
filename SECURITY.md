# Security Policy

## Reporting a Vulnerability

**Please do not file public GitHub issues for security vulnerabilities.**

Use GitHub's **Private Vulnerability Reporting** to submit reports privately:

1. Go to the [Security tab](https://github.com/Sora-bluesky/winsmux/security) of this repository.
2. Click **Report a vulnerability**.
3. Fill in the form with reproduction steps, affected version, and impact.

You can also open a private advisory directly:
https://github.com/Sora-bluesky/winsmux/security/advisories/new

## What to Include

- A clear description of the issue and its impact
- Steps to reproduce (minimal repro preferred)
- Affected version / commit SHA
- Any suggested mitigation, if known

## Response

We aim to acknowledge reports within **7 days** and provide a status update within **30 days**. Coordinated disclosure timelines are set on a per-case basis.

## Scope

In scope:
- Code in this repository
- Released artifacts published from this repository

Out of scope:
- Vulnerabilities in upstream dependencies (please report those to the respective maintainers; we will update once fixes are available)
- Social engineering, physical attacks, or issues requiring root-level access to a user's machine

## Supported Versions

Only the latest release on the `main` branch is actively supported with security fixes.
