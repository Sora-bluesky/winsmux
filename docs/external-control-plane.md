# External Control Plane API

winsmux exposes a local Windows named-pipe JSON-RPC endpoint for external
automation clients that run on the same machine as the desktop app.

## Transport

- Pipe: `\\.\pipe\winsmux-control`
- Protocol: JSON-RPC 2.0
- Network transport: none. There is no localhost HTTP or WebSocket endpoint.
- Remote clients must connect through a user-approved local bridge; the desktop
  app does not expose this pipe to the network.
- Authorization: `desktop.control_plane.contract` is discoverable without a
  token. Every other method requires `auth.token`, supplied from the local
  `WINSMUX_CONTROL_PIPE_TOKEN` environment variable by the winsmux CLI helper.

Clients can discover the external contract by calling:

```json
{"jsonrpc":"2.0","id":"contract","method":"desktop.control_plane.contract"}
```

When that request is sent through the named pipe, `methods` contains only the
methods that the pipe allowlist accepts.

For any method other than `desktop.control_plane.contract`, clients must include
the local control token outside `params`:

```json
{"jsonrpc":"2.0","id":"capture","method":"pty.capture","params":{"paneId":"pane-1"},"auth":{"token":"<WINSMUX_CONTROL_PIPE_TOKEN>"}}
```

Do not write the token directly in shell history. Prefer `winsmux control-rpc`,
which reads `WINSMUX_CONTROL_PIPE_TOKEN` from the current process environment
and injects `auth.token` into non-contract requests.

## Exposed Methods

The named pipe currently exposes these desktop methods:

- `desktop.control_plane.contract`
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

Those helpers read `WINSMUX_CONTROL_PIPE_TOKEN`, call only
`desktop.operator.snapshot` / `desktop.operator.submit`, and never accept a
worker pane target. Raw JSON-RPC remains available for clients that implement
their own named-pipe transport:

```json
{"jsonrpc":"2.0","id":"operator-snapshot","method":"desktop.operator.snapshot","params":{"lines":80},"auth":{"token":"<WINSMUX_CONTROL_PIPE_TOKEN>"}}
```

```json
{"jsonrpc":"2.0","id":"operator-submit","method":"desktop.operator.submit","params":{"message":"Restore the six-pane orchestra and report can_dispatch."},"auth":{"token":"<WINSMUX_CONTROL_PIPE_TOKEN>"}}
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

## Client Compatibility

Local automation clients can connect if they run on the same Windows host and
implement JSON-RPC over the named pipe. They should call
`desktop.control_plane.contract` first and generate client capabilities from
the returned `methods` list.

Non-contract calls fail closed when the desktop app was not launched with
`WINSMUX_CONTROL_PIPE_TOKEN`, or when the request omits `auth.token`.

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
