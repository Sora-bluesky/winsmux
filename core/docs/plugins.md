# Plugins & Themes

winsmux has a full plugin ecosystem — ports of the most popular tmux plugins, reimplemented in PowerShell for Windows.

## Plugin Repository

**Browse available plugins and themes:** [**winsmux-plugins**](https://github.com/winsmux/winsmux-plugins)

**Install & manage plugins with a TUI:** [**Tmux Plugin Panel**](https://github.com/winsmux/Tmux-Plugin-Panel) — a terminal UI for browsing, installing, updating, and removing plugins and themes.

## Available Plugins

| Plugin | Description |
|--------|-------------|
| [winsmux-sensible](https://github.com/winsmux/winsmux-plugins/tree/main/winsmux-sensible) | Sensible defaults for winsmux |
| [winsmux-yank](https://github.com/winsmux/winsmux-plugins/tree/main/winsmux-yank) | Windows clipboard integration |
| [winsmux-resurrect](https://github.com/winsmux/winsmux-plugins/tree/main/winsmux-resurrect) | Save/restore sessions |
| [winsmux-pain-control](https://github.com/winsmux/winsmux-plugins/tree/main/winsmux-pain-control) | Better pane navigation |
| [winsmux-prefix-highlight](https://github.com/winsmux/winsmux-plugins/tree/main/winsmux-prefix-highlight) | Prefix key indicator |
| [ppm](https://github.com/winsmux/winsmux-plugins/tree/main/ppm) | Plugin manager (like tpm) |

## Themes

Catppuccin · Dracula · Nord · Tokyo Night · Gruvbox

## Quick Start

```powershell
# Install the plugin manager
git clone https://github.com/winsmux/winsmux-plugins.git "$env:TEMP\winsmux-plugins"
Copy-Item "$env:TEMP\winsmux-plugins\ppm" "$env:USERPROFILE\.winsmux\plugins\ppm" -Recurse
Remove-Item "$env:TEMP\winsmux-plugins" -Recurse -Force
```

Then add to your `~/.winsmux.conf`:

```tmux
set -g @plugin 'winsmux-plugins/ppm'
set -g @plugin 'winsmux-plugins/winsmux-sensible'
run '~/.winsmux/plugins/ppm/ppm.ps1'
```

Press `Prefix + I` inside winsmux to install the declared plugins.
