# psmux-bridge

Cross-pane AI agent communication CLI — a core component of [winsmux](https://github.com/Sora-bluesky/winsmux).

Also available as a standalone psmux plugin.

## Install (as psmux plugin)

Add this to `.psmux.conf`:

```tmux
set -g @plugin 'psmux-plugins/psmux-bridge'
```

## Install (as part of winsmux)

```powershell
irm https://raw.githubusercontent.com/Sora-bluesky/winsmux/main/install.ps1 | iex
```

## Keybindings

- `Prefix+O` — Orchestra start
- `Prefix+B` — Setup wizard
