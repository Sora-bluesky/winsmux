# External Control Plane API

winsmux exposes a local Windows named-pipe JSON-RPC endpoint for external
automation clients that run on the same machine as the desktop app.

## Transport

- Pipe: `\\.\pipe\winsmux-control`
- Protocol: JSON-RPC 2.0
- Network transport: none. There is no localhost HTTP or WebSocket endpoint.
- Remote clients must connect through a user-approved local bridge; the desktop
  app does not expose this pipe to the network.

Clients can discover the external contract by calling:

```json
{"jsonrpc":"2.0","id":"contract","method":"desktop.control_plane.contract"}
```

When that request is sent through the named pipe, `methods` contains only the
methods that the pipe allowlist accepts.

## Exposed Methods

The named pipe currently exposes these desktop methods:

- `desktop.control_plane.contract`
- `desktop.summary.snapshot`
- `desktop.run.explain`
- `desktop.run.compare`
- `desktop.run.promote`
- `desktop.run.pick_winner`
- `desktop.voice.capture_status`

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

For example, `desktop.editor.read` and `desktop.explorer.list` can read local
project files. They remain internal to the Tauri desktop context until a
separate external authorization model exists.

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

Agent CLIs can also drive the pipe from a local shell or tool call when the user
has granted permission to run a local command. They do not get a special
privileged API surface. They see the same external contract as any other local
client.

The desktop app remains the required control surface for worker launch approval
and local file-reading UI actions. External clients should not assume that an
internal Tauri method is available through the pipe unless the pipe contract
advertises it.
