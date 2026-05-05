# winsmux desktop app

This directory contains the Tauri desktop control plane for `winsmux`.

The desktop app is not a replacement for the CLI. It presents the same local-first operator contract through a denser UI:

- workspace sidebar for sessions, files, and source-control summary
- conversation shell for the operator-facing run stream
- context side sheet for run, slot, branch, evidence, and review state
- decision cockpit for verification, review, security, architecture, and operator-decision gates
- terminal drawer for raw PTY output and diagnostics

The app must not proxy AI service sign-in. Each pane agent keeps using its own official authentication setup.

## Development

Install dependencies from this directory:

```powershell
npm ci
```

Run a development build:

```powershell
npm run build
```

Start the local dev server when needed, then open it in a Playwright browser
whose viewport follows the window size:

```powershell
npm run dev:browser
```

Run a headless viewport probe:

```powershell
npm run dev:browser -- --headless --probe --width=2048 --height=1244
```

Run the viewport harness when changing desktop UI layout:

```powershell
npm run test:viewport-harness
```

Tauri commands live under `src-tauri`. Frontend code lives under `src`.
