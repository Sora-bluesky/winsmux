```
╔═══════════════════════════════════════════════════════════╗
║   ██████╗ ███████╗███╗   ███╗██╗   ██╗██╗  ██╗            ║
║   ██╔══██╗██╔════╝████╗ ████║██║   ██║╚██╗██╔╝            ║
║   ██████╔╝███████╗██╔████╔██║██║   ██║ ╚███╔╝             ║
║   ██╔═══╝ ╚════██║██║╚██╔╝██║██║   ██║ ██╔██╗             ║
║   ██║     ███████║██║ ╚═╝ ██║╚██████╔╝██╔╝ ██╗            ║
║   ╚═╝     ╚══════╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝            ║
║     Born in PowerShell. Made in Rust. 🦀                 ║
║          Terminal Multiplexer for Windows                 ║
╚═══════════════════════════════════════════════════════════╝
```

<p align="center">
  <strong>The native Windows tmux. Born in PowerShell, made in Rust.</strong><br/>
  Full mouse support · tmux themes · tmux config · 76 commands · blazing fast
</p>

<p align="center">
  <a href="#installation">Install</a> ·
  <a href="#usage">Usage</a> ·
  <a href="docs/claude-code.md">Claude Code</a> ·
  <a href="docs/features.md">Features</a> ·
  <a href="docs/compatibility.md">Compatibility</a> ·
  <a href="docs/performance.md">Performance</a> ·
  <a href="docs/plugins.md">Plugins</a> ·
  <a href="docs/keybindings.md">Keys</a> ·
  <a href="docs/scripting.md">Scripting</a> ·
  <a href="docs/configuration.md">Config</a> ·
  <a href="docs/mouse-ssh.md">Mouse/SSH</a> ·
  <a href="docs/faq.md">FAQ</a> ·
  <a href="#related-projects">Related Projects</a>
</p>

---

# winsmux

**The real tmux for Windows.** Not a port, not a wrapper, not a workaround.

winsmux is a **native Windows terminal multiplexer** built from the ground up in Rust. It uses Windows ConPTY directly, speaks the tmux command language, reads your `.tmux.conf`, and supports tmux themes. All without WSL, Cygwin, or MSYS2.

> 💡 **Tip:** winsmux ships with `tmux` and `pmux` aliases. Just type `tmux` and it works!

👀 On Windows 👇

![winsmux in action](demo.gif)

## Installation

### Using WinGet

```powershell
winget install winsmux
```

### Using Cargo

```powershell
cargo install winsmux
```

This installs `winsmux`, `pmux`, and `tmux` binaries to your Cargo bin directory.

### Using Scoop

```powershell
scoop bucket add winsmux https://github.com/winsmux/scoop-winsmux
scoop install winsmux
```

### Using Chocolatey

```powershell
choco install winsmux
```

### From GitHub Releases

Download the latest `.zip` from [GitHub Releases](https://github.com/winsmux/winsmux/releases) and add to your PATH.

### From Source

```powershell
git clone https://github.com/winsmux/winsmux.git
cd winsmux
cargo build --release
```

Built binaries:

```text
target\release\winsmux.exe
target\release\pmux.exe
target\release\tmux.exe
```

### Docker (build environment)

A ready-made Windows container with Rust + MSVC + SSH for building winsmux:

```powershell
cd docker
docker build -t winsmux-dev .
docker run -d --name winsmux-dev -p 127.0.0.1:2222:22 -e ADMIN_PASSWORD=YourPass123! winsmux-dev
ssh ContainerAdministrator@localhost -p 2222
```

See [docker/README.md](docker/README.md) for full details.

### Requirements

- Windows 10 or Windows 11
- **PowerShell 7+** (recommended) or cmd.exe
  - Download PowerShell: `winget install --id Microsoft.PowerShell`
  - Or visit: https://aka.ms/powershell

## Why winsmux?

If you've used tmux on Linux/macOS and wished you had something like it on Windows, **this is it**. Split panes, multiple windows, session persistence, full mouse support, tmux themes, 76 commands, 126+ format variables, 53 vim copy-mode keys. Your existing `.tmux.conf` works. Full details: **[docs/features.md](docs/features.md)** · **[docs/compatibility.md](docs/compatibility.md)**

## Usage

Use `winsmux`, `pmux`, or `tmux` — they're identical:

```powershell
winsmux                        # Start a new session
winsmux new-session -s work    # Named session
winsmux ls                     # List sessions
winsmux attach -t work         # Attach to a session
winsmux --help                 # Show help
```

## Claude Code Agent Teams

winsmux has first-class support for Claude Code agent teams. When Claude Code runs inside a winsmux session, teammate agents automatically spawn in separate tmux panes instead of running in-process.

```powershell
winsmux new-session -s work    # Start a winsmux session
claude                       # Run Claude Code — agent teams just work
```

No extra configuration needed. Full guide: **[docs/claude-code.md](docs/claude-code.md)**

## Documentation

| Topic | Description |
|-------|-------------|
| **[Features](docs/features.md)** | Full feature list — mouse, copy mode, layouts, format engine |
| **[Compatibility](docs/compatibility.md)** | tmux command/config compatibility matrix |
| **[Performance](docs/performance.md)** | Benchmarks and optimization details |
| **[Key Bindings](docs/keybindings.md)** | Default keys and customization |
| **[Scripting](docs/scripting.md)** | 76 commands, hooks, targets, pipe-pane |
| **[Configuration](docs/configuration.md)** | Config files, options, environment variables |
| **[Plugins & Themes](docs/plugins.md)** | Plugin ecosystem — Catppuccin, Dracula, Nord, and more |
| **[Mouse Over SSH](docs/mouse-ssh.md)** | SSH mouse support and Windows version requirements |
| **[Claude Code](docs/claude-code.md)** | Agent teams integration guide |
| **[FAQ](docs/faq.md)** | Common questions and answers |

## Related Projects

<table>
  <tr>
    <td align="center" width="50%">
      <a href="https://github.com/winsmux/pstop">
        <img src="https://raw.githubusercontent.com/winsmux/pstop/master/pstop-demo.gif" width="400" alt="pstop demo" /><br/>
        <b>pstop</b>
      </a><br/>
      <sub>htop for Windows — real-time system monitor with per-core CPU bars, tree view, 7 color schemes</sub><br/>
      <code>cargo install pstop</code>
    </td>
    <td align="center" width="50%">
      <a href="https://github.com/winsmux/psnet">
        <img src="https://raw.githubusercontent.com/winsmux/psnet/master/image.png" width="400" alt="psnet screenshot" /><br/>
        <b>psnet</b>
      </a><br/>
      <sub>Real-time TUI network monitor — live speed graphs, connections, traffic log, packet sniffer</sub><br/>
      <code>cargo install psnet</code>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <a href="https://github.com/winsmux/Tmux-Plugin-Panel">
        <img src="https://raw.githubusercontent.com/winsmux/Tmux-Plugin-Panel/master/screenshot.png" width="400" alt="Tmux Plugin Panel screenshot" /><br/>
        <b>Tmux Plugin Panel</b>
      </a><br/>
      <sub>TUI plugin & theme manager for tmux and winsmux — browse, install, update from your terminal</sub><br/>
      <code>cargo install tmuxpanel</code>
    </td>
    <td align="center" width="50%">
      <a href="https://github.com/winsmux/omp-manager">
        <img src="https://raw.githubusercontent.com/winsmux/omp-manager/master/screenshot.png" width="400" alt="OMP Manager screenshot" /><br/>
        <b>OMP Manager</b>
      </a><br/>
      <sub>Oh My Posh setup wizard — browse 100+ themes, install fonts, configure shells automatically</sub><br/>
      <code>cargo install omp-manager</code>
    </td>
  </tr>
</table>

## License

MIT

## Contributing

Contributions welcome — bug reports, PRs, docs, and test scripts via [GitHub Issues](https://github.com/winsmux/winsmux/issues).

If winsmux helps your Windows workflow, consider giving it a ⭐ on GitHub!

## Star History

[![Star History Chart](https://api.star-history.com/image?repos=winsmux/winsmux&type=date&legend=top-left)](https://www.star-history.com/?repos=winsmux%2Fwinsmux&type=date&legend=top-left)

---

<p align="center">
  Made with ❤️ for PowerShell using Rust 🦀
</p>
