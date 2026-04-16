# Public-Safe Agent Boundary

This directory remains in the public repository only for public-safe boundary notes.

## Boundary

- Internal maintainer skill packs are maintained outside the public repository.
- Public repo files under `.agents/**` must stay safe to expose on GitHub.
- Files here are not part of the public product guide, runtime contract, or end-user onboarding flow.

## Rules

- Do not link this directory from `README.md`, `README.ja.md`, or other public product entrypoints.
- Keep maintainer-local paths, live handoff state, and private planning roots out of tracked files here.
- Do not track `.agents/skills/**` in this repository.
- Resolve maintainer-only skills through `WINSMUX_PRIVATE_SKILLS_ROOT` or `%LOCALAPPDATA%\\winsmux\\private-skills-root.txt`.
