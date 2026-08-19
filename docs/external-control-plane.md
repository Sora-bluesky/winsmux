# External Control Plane API

winsmux exposes a local Windows named-pipe JSON-RPC endpoint for external
automation clients that run on the same machine as the desktop app.

A new external agent can follow this page from a fresh install (start the
desktop normally, with no `WINSMUX_CONTROL_PIPE_TOKEN` set before launch) or
from an already-running desktop to a successful `desktop.operator.snapshot`
without reading source.

## Transport

- Pipe: `\\.\pipe\winsmux-control`
- Protocol: JSON-RPC 2.0
- Network transport: none. There is no localhost HTTP or WebSocket endpoint.
- Remote clients must connect through a user-approved local bridge; the desktop
  app does not expose this pipe to the network.

## Launch modes

Normal desktop start does not require `WINSMUX_CONTROL_PIPE_TOKEN` in the
process environment. On start, the desktop app creates
`%LOCALAPPDATA%\winsmux\control-pipe\token` with a user-only DACL (Windows
equivalent of `0600`), writes a new current token, and keeps any previous token
in process memory only. The previous value is accepted until the first
successful auth with the new token, or until 60 seconds of process time, then
the old bytes are dropped. Logs may contain the marker
`control-pipe token: rotated`. They must not contain the token value or the
expanded filesystem path.

Some launchers still set `WINSMUX_CONTROL_PIPE_TOKEN` on the desktop process
(for example bakeoff helpers). That explicit env remains supported and wins
over the token file for both the desktop pipe and the CLI.

## Token provisioning

The protected asset is the control-pipe token bytes. The trust boundary is the
local user profile, not the git repo and not project `.winsmux`.

Discovery is this exact path only:

`%LOCALAPPDATA%\winsmux\control-pipe\token`

A planted file under the repo, project `.winsmux`, `TEMP`, or any other name
must not win.

Token source precedence for the desktop pipe and for `winsmux control-rpc`:

1. Non-empty process env `WINSMUX_CONTROL_PIPE_TOKEN` (keeps existing tests and
   explicit launchers)
2. Else the exact token file above
3. Else fail closed

Do not print the token. Secret slots in examples use `<token-file>`.

## Authorization

`desktop.control_plane.contract` is discoverable without a token. Every other
method requires `auth.token`. Prefer `winsmux control-rpc`, which injects
`auth.token` from the env override or, when the env is unset, from the exact
token file.

Clients can discover the external contract by calling:

```json
{"jsonrpc":"2.0","id":"contract","method":"desktop.control_plane.contract"}
```

When that request is sent through the named pipe, `methods` contains only the
methods that the pipe allowlist accepts. The contract advertises
`auth.token_env` as `WINSMUX_CONTROL_PIPE_TOKEN` and `auth.token_file` as
`%LOCALAPPDATA%\winsmux\control-pipe\token`.

For any method other than `desktop.control_plane.contract`, clients must include
the local control token outside `params`:

```json
{"jsonrpc":"2.0","id":"capture","method":"pty.capture","params":{"paneId":"pane-1"},"auth":{"token":"<token-file>"}}
```

Do not write the token directly in shell history.

## Connect from zero to operator-snapshot

A leftover token file is not liveness. Pair once with `winsmux automation-pair`
before calling authenticated methods. Do not print the token.

### Fresh install

1. Install winsmux, then start the desktop app normally. Do not set
   `WINSMUX_CONTROL_PIPE_TOKEN` before launch.
2. Discover:

```powershell
winsmux automation-discover
```

Expect `desktop_running` true, `auth_source` `"file"`, and `connect_ready` true.

3. Pair once:

```powershell
winsmux automation-pair
```

Expect `paired` true.

4. Capture operator output. The CLI reads the exact token file:

```powershell
winsmux operator-snapshot --lines 80
```

### Already-running desktop

If a desktop may already be running, start with `winsmux automation-discover`.
`desktop_running` is true only while the named pipe answers.

1. Discover (same command as above).
2. Pair once (`winsmux automation-pair`).
3. Capture operator output (`winsmux operator-snapshot --lines 80`).

Some launchers still set `WINSMUX_CONTROL_PIPE_TOKEN`. That env remains
supported and wins over the token file.

Equivalent raw JSON-RPC:

```json
{"jsonrpc":"2.0","id":"operator-snapshot","method":"desktop.operator.snapshot","params":{"lines":80},"auth":{"token":"<token-file>"}}
```

## Error semantics

Non-contract calls fail closed when no usable token exists (env unset and the
exact file missing or empty), when `auth.token` is omitted, or when the token
does not match. The pipe keeps the existing JSON-RPC fail-closed behavior:
error code `-32600` (Invalid Request) with a message that names
`WINSMUX_CONTROL_PIPE_TOKEN`. The CLI helper fails with
`control-rpc requires WINSMUX_CONTROL_PIPE_TOKEN for non-contract methods`.
This page does not introduce a new public error code.

## Exposed Methods

The named pipe currently exposes these desktop methods:

- `desktop.control_plane.contract`
- `desktop.pairing.confirm`
- `desktop.summary.snapshot`
- `desktop.run.explain`
- `desktop.run.compare`
- `desktop.run.promote`
- `desktop.run.pick_winner`
- `desktop.operator.snapshot`
- `desktop.operator.submit`
- `desktop.voice.capture_status`

The operator methods are the only external methods intended for agent-to-operator
conversation:

- `desktop.operator.snapshot` captures recent output from the operator pane.
- `desktop.operator.submit` writes one message to the operator composer and
  submits it. The API always targets the operator pane and rejects `paneId` /
  `pane_id` overrides so external agents cannot bypass the operator and write
  directly to worker panes.

Prefer the dedicated CLI helpers for external agents:

```powershell
winsmux operator-snapshot --lines 80
winsmux operator-submit --text "Restore the six-pane orchestra and report can_dispatch."
```

Those helpers follow the same token precedence (env override, else the exact
token file), call only `desktop.operator.snapshot` /
`desktop.operator.submit`, and never accept a worker pane target. Raw JSON-RPC
remains available for clients that implement their own named-pipe transport:

```json
{"jsonrpc":"2.0","id":"operator-snapshot","method":"desktop.operator.snapshot","params":{"lines":80},"auth":{"token":"<token-file>"}}
```

```json
{"jsonrpc":"2.0","id":"operator-submit","method":"desktop.operator.submit","params":{"message":"Restore the six-pane orchestra and report can_dispatch."},"auth":{"token":"<token-file>"}}
```

The same pipe also exposes these PTY methods for local pane control:

- `pty.spawn`
- `pty.write`
- `pty.resize`
- `pty.capture`
- `pty.respawn`
- `pty.close`

## Internal-Only Methods

The Tauri app uses a wider internal `desktop_json_rpc` surface. That internal
surface is available to the desktop WebView through Tauri `invoke`, but it is
not automatically part of the external pipe contract.

These methods are intentionally not exposed through the named pipe today:

- `desktop.workers.status`
- `desktop.workers.start`
- `desktop.runtime.roles.apply`
- `desktop.dogfood.event`
- `desktop.explorer.list`
- `desktop.editor.read`
- Agent Vault, session search, resume metadata, and drag-restore methods
- Feed, notification, and View menu state methods

For example, `desktop.editor.read` and `desktop.explorer.list` can read local
project files. They remain internal to the Tauri desktop context until a
separate external authorization model exists.

The Agent Vault, session search/filtering, resume metadata, drag restore, Feed,
notification linkage, and worker status strip visibility controls added in
`v0.36.8` are desktop-internal UI surfaces today. They are not exposed as named
pipe JSON-RPC methods until an explicit external authorization model exists.

## Enterprise Worker Policy

External clients do not grant network, write, or provider access by sending
instructions in a prompt. For prepared `isolated-enterprise` runs, the operator
defines that access with `winsmux workers policy baseline` after the broker
baseline and a valid broker token exist. The policy artifact records mandatory
checks and role-specific evidence outside the prompt and projects the latest
state through `winsmux workers status --json` as `policy`.

The policy command fails closed before execution when the run is not
`isolated-enterprise`, the broker baseline is missing, the broker token is
missing or expired, a policy value is invalid, or the run boundary contains a
reparse point. External bridges should surface those stop reasons instead of
retrying with broader prompt instructions.

## MCP Adapter Boundary

The bundled MCP server is a thin local adapter over the upstream MCP JSON-RPC
shape and stdio transport. winsmux-specific code should stay limited to
argument-array command invocation, input validation, and local safety policy.
If an upstream protocol client or official transport behavior can handle a
case, winsmux should prefer that path before adding local compatibility code.

MCP clients reach that same named-pipe contract through the
`winsmux_automation_contract` tool, which runs native
`winsmux automation-contract` and returns the JSON. It does not go through
PowerShell.

## Client Compatibility

Local automation clients can connect if they run on the same Windows host and
implement JSON-RPC over the named pipe. They should call
`desktop.control_plane.contract` first and generate client capabilities from
the returned `methods` list.

Non-contract calls fail closed when neither a non-empty
`WINSMUX_CONTROL_PIPE_TOKEN` nor the exact token file can authenticate the
request, or when the request omits `auth.token`. See [Error semantics](#error-semantics).

Agent CLIs can also drive the pipe from a local shell or tool call when the user
has granted permission to run a local command. They do not get a special
privileged API surface. They see the same external contract as any other local
client.

The desktop app remains the required control surface for worker launch approval
and local file-reading UI actions. External clients should not assume that an
internal Tauri method is available through the pipe unless the pipe contract
advertises it.

## Shutdown behavior

On desktop app shutdown, winsmux requests the summary stream to stop, stops
native voice capture when it is running, drains the active PTY pane registry,
kills worker-pane children, and waits briefly for those children to exit.

External clients can still call `pty.close` for explicit per-pane cleanup
before disconnecting. Closing the desktop app is now the final cleanup path for
PTY-backed panes created by that desktop session.
