# winsmux SDK

Client libraries for the winsmux MCP Server. Both libraries spawn `node mcp-server.js` as a child process and communicate via newline-delimited JSON-RPC 2.0 over stdio.

No external dependencies required -- TypeScript uses Node.js built-ins, Python uses stdlib only.

## Available Methods

| Method | Description |
|--------|-------------|
| `list()` | List labeled panes in the current winsmux session |
| `read(target, lines?)` | Read recent output from a pane |
| `send(target, text)` | Send text to a pane |
| `dispatch(text)` | Route text to the appropriate pane by keyword |
| `health()` | Health check all panes |
| `pipeline(task)` | Run plan-exec-verify-fix pipeline for a task |

## TypeScript

```typescript
import { WinsmuxClient } from "./typescript/winsmux";

const client = new WinsmuxClient();

try {
  // List all panes
  const panes = await client.list();
  console.log(panes);

  // Read output from a pane
  const output = await client.read("builder-1", 100);
  console.log(output);

  // Send a command to a pane
  await client.send("builder-1", "npm test");

  // Dispatch to auto-routed pane
  await client.dispatch("run the linter");

  // Health check
  const status = await client.health();
  console.log(status);

  // Run a full pipeline
  const result = await client.pipeline("fix the failing tests");
  console.log(result);
} finally {
  client.close();
}
```

### Custom server path

```typescript
const client = new WinsmuxClient("/path/to/mcp-server.js");
```

## Python

```python
from python.winsmux import WinsmuxClient

# Using context manager (recommended)
with WinsmuxClient() as client:
    # List all panes
    panes = client.list()
    print(panes)

    # Read output from a pane
    output = client.read("builder-1", lines=100)
    print(output)

    # Send a command to a pane
    client.send("builder-1", "npm test")

    # Dispatch to auto-routed pane
    client.dispatch("run the linter")

    # Health check
    status = client.health()
    print(status)

    # Run a full pipeline
    result = client.pipeline("fix the failing tests")
    print(result)
```

### Manual lifecycle

```python
client = WinsmuxClient()
try:
    panes = client.list()
    print(panes)
finally:
    client.close()
```

### Custom server path

```python
client = WinsmuxClient(server_path="/path/to/mcp-server.js")
```

## Error Handling

Both clients raise exceptions when the server returns an error:

**TypeScript** -- throws `Error` with the server's error message.

**Python** -- raises `WinsmuxError` (a subclass of `Exception`).

```typescript
// TypeScript
try {
  await client.read("nonexistent-pane");
} catch (err) {
  console.error("Tool failed:", err.message);
}
```

```python
# Python
from python.winsmux import WinsmuxClient, WinsmuxError

try:
    client.read("nonexistent-pane")
except WinsmuxError as e:
    print(f"Tool failed: {e}")
```
