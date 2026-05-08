# FAQ

**Q: Is winsmux cross-platform?**
A: No. winsmux is built exclusively for Windows using the Windows ConPTY API. For Linux/macOS, use tmux. winsmux is the Windows counterpart.

**Q: Does winsmux work with Windows Terminal?**
A: Yes! winsmux works great with Windows Terminal, PowerShell, cmd.exe, and other Windows terminal emulators.

**Q: Why use winsmux instead of Windows Terminal tabs?**
A: winsmux offers session persistence (detach/reattach), synchronized input to multiple panes, full tmux command scripting, hooks, format engine, and tmux-compatible keybindings. Windows Terminal tabs can't do any of that.

**Q: Can I use my existing `.tmux.conf`?**
A: Yes! winsmux reads `~/.tmux.conf` automatically. Most tmux config options, key bindings, and style settings work as-is.

**Q: Can I use tmux themes?**
A: Yes. winsmux supports 14 style options with 24-bit true color, 256 indexed colors, and text attributes (bold, italic, dim, etc.). Most tmux theme configs are compatible.

**Q: Can I use tmux commands with winsmux?**
A: Yes! winsmux includes a `tmux` alias. Commands like `tmux new-session`, `tmux attach`, `tmux ls`, `tmux split-window` all work. 76 commands in total.

**Q: How fast is winsmux?**
A: Session creation takes < 100ms. New windows/panes add < 80ms overhead. The bottleneck is your shell's startup time, not winsmux. Compiled with opt-level 3 and full LTO.

**Q: Does winsmux support mouse?**
A: Full mouse support: click to focus panes, drag to resize borders, scroll wheel, click status-bar tabs, drag-select text, right-click copy. Plus VT mouse forwarding for TUI apps like vim, htop, and mc.

**Q: What shells does winsmux support?**
A: PowerShell 7 (default), PowerShell 5, cmd.exe, Git Bash, WSL, nushell, and any Windows executable. Change with `set -g default-shell <shell>`.

**Q: Is it stable for daily use?**
A: Yes. winsmux is stress-tested with 15+ rapid windows, 18+ concurrent panes, 5 concurrent sessions, kill+recreate cycles, and sustained load, all with zero hangs or resource leaks.

**Q: PSReadLine predictions / intellisense / autocompletion (inline history suggestions) are disabled inside winsmux. How do I enable them?**
A: Add `set -g allow-predictions on` to your `~/.winsmux.conf`. This tells winsmux to preserve your `PredictionSource` setting after initialization. If your profile sets `PredictionSource` explicitly, winsmux respects that. If not, winsmux restores the system default (typically `HistoryAndPlugin`). See the [PSReadLine Predictions](configuration.md#psreadline-predictions-intellisense--autocompletion) section in the configuration docs for details.

**Q: How do I use a custom config file?**
A: Use the `-f` flag: `winsmux -f /path/to/config.conf`. This loads the specified file instead of the default search order.

**Q: How do I disable warm (pre-spawned) sessions?**
A: Add `set -g warm off` to your config, or set `$env:WINSMUX_NO_WARM = "1"`. See [warm-sessions.md](warm-sessions.md) for details.

**Q: Can I set environment variables for panes?**
A: Yes. Use `winsmux set-environment -g VARNAME value` to set env vars inherited by all new panes. Use `-gu` to unset. See [configuration.md](configuration.md) for details.

**Q: How do I mute the audible bell inside winsmux?**
A: Add `set -g bell-action none` to your `~/.winsmux.conf`. This silences both the audible beep and the status bar bell flag. To keep the visual flag but mute the sound, this is not currently split into separate controls. See the [Bell](configuration.md#bell) section in the configuration docs.
