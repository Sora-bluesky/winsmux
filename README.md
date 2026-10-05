[English](README.md) | [日本語](README.ja.md)

# winsmux

winsmux is a Windows-native, model-independent harness for working with multiple AI agents through their official CLIs. It keeps projects, terminal panes, runs and artifacts in one local workspace so you can direct work and inspect the result.

This README describes v0.38.0. Use the documentation shipped with the version you install; older releases have a different operator/worker interface and startup commands.

## Work with projects and panes

- Select a local project folder and check its working-directory identity.
- Create, select, split, resize and close terminal panes.
- Use the AI launch controls for Codex or Claude Code, with optional model and reasoning settings.
- Inspect process state separately from work state, with evidence and observation time.
- Interrupt the selected run and check that termination was observed.
- Register artifacts and inspect text or Git diffs without treating terminal output as approval to execute instructions.
- Restore saved pane layout without automatically restarting previous shells or agents.

GUI, CLI and MCP operate on the same workspace contract. External connections require explicit project and scope permission; metadata, output reading and control are separate scopes.

## Start with the desktop app

1. Choose the release for the version you intend to use from [Releases](https://github.com/Sora-bluesky/winsmux/releases).
2. Select the Windows installer for your architecture and verify it using that release's verification information.
3. Install and open winsmux, then use **プロジェクトを開く** (Open project) to select a folder.
4. Check the selected project, create a pane and choose the official CLI you want to run.

See [Quickstart](docs/quickstart.md) for the complete GUI flow and [Installation](docs/installation.md) for installation methods, version matching, updates and uninstall.

You need Windows, the pane's PowerShell runtime, and the official agent CLIs you want to use. Desktop rendering uses Microsoft Edge WebView2. See the matching release's requirements for supported Windows builds and architectures. Rust and the Windows C++ build tools are for source builds, not prerequisites for using a packaged executable.

## CLI and MCP

The native workspace CLI uses the `winsmux workspace` namespace. It differs from the older `winsmux init` / `winsmux launch` Windows Terminal workflow.

The desktop app can provide its current public connection information. Pass this information explicitly to a CLI/MCP client, request the required project scopes, and authorize the connection in the GUI. A new host requires fresh connection information and authorization.

The npm package is an installer entry point, while the native runtime handles workspace requests. Do not assume an npm package command is a native workspace command. See [Installation](docs/installation.md#cli-package-install).

To use this installation route, select a published package version matching your desired release and replace the placeholder:

```powershell
npm install -g winsmux@<published-version>
winsmux install --profile core
```

The script installer also accepts `winsmux install --profile full` to include all support components. The [customization guide for the older workflow](docs/customization.md) describes those optional components; use the v0.38.0 quickstart for the desktop workspace.

The legacy binary aliases `psmux`, `pmux`, and `tmux` are no longer shipped. Use `winsmux`; [runtime compatibility](core/docs/compatibility.md) describes the remaining tmux-compatible configuration support.

## Authentication and data

Authentication remains with each official agent CLI. winsmux does not extract another CLI's tokens or sign in on its behalf. A detected CLI version does not establish authentication or support for a requested model setting; inspect the CLI's actual result.

Projects and terminal contents can contain private data. Use the GUI's shareable diagnostics for a bug report and inspect screenshots before sharing them. Do not attach raw input, output, environment variables, private connection information or saved layouts.

Workspace authorization is not an OS sandbox against arbitrary code running as the same Windows user. Review changes, artifacts and verification results before adopting agent output.

## Guides

- [Quickstart](docs/quickstart.md)
- [Installation](docs/installation.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## License

Apache License 2.0.

Some runtime compatibility code keeps an upstream MIT notice under `core/LICENSE`.
See [Third-party notices](THIRD_PARTY_NOTICES.md) for the split.
