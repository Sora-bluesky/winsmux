# Customization

Use customization to make winsmux fit your local operator workflow without turning it into a shared credential broker.

## Workspace lifecycle

`winsmux init` defaults to managed worker worktrees:

```powershell
winsmux init --workspace-lifecycle managed-worktree
```

Use managed worktrees when multiple agents may edit files in parallel. They keep changes separated until the operator chooses what to accept.

## Launcher presets

Inspect the presets before launching a compare-oriented run:

```powershell
winsmux launcher presets --json
winsmux launcher lifecycle --json
```

Presets describe the intended workspace shape. They should not execute arbitrary project setup or teardown scripts.

## Agent slots

winsmux uses slot and capability concepts rather than permanent vendor roles. A slot may advertise work, review, or consultation capability. The operator chooses which pane receives each task.

Use this model when assigning work:

- send implementation tasks to work-capable slots
- send review tasks to review-capable slots
- use consultation only for difficult, ambiguous, or non-converging work

## Credentials

Store credentials that must be injected into a pane with Windows DPAPI:

```powershell
winsmux vault set <name> <value>
winsmux vault inject <name> <pane>
```

winsmux does not broker OAuth flows, receive callback URLs, or share local interactive login tokens across panes.

## Desktop preferences

The desktop app follows the same operator contract as the CLI. It may expose theme, density, wrapping, code font, and focus preferences, but raw PTY output stays in the terminal drawer for diagnostics.

Use the desktop app for:

- scanning run evidence and decision gates
- comparing recorded work
- drilling into source-level context
- keeping terminal diagnostics available without making them the primary surface
