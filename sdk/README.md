# winsmux control-plane bindings

This directory provides Python and TypeScript bindings for the desktop named-pipe control plane. The checked-in contract defines the supported methods and their parameter and result schemas.

## Control-plane method names

`python/control_plane_contract.py` and `typescript/control-plane-contract.ts` are generated from `docs/control-plane-contract.v2.json`. They bind named-pipe method names, the contract version, and typed params/result declarations, not MCP tools. v2 adds per-method parameter/result schemas in the artifact. Regenerate with `npm run generate:control-plane-bindings` from `winsmux-app`. CI fails if they drift from the artifact.

```typescript
import { CONTROL_PIPE_METHODS, type ControlPlaneSchemas } from "./typescript/control-plane-contract";
```

```python
from python.control_plane_contract import CONTROL_PIPE_METHODS
```

A worked named-pipe sequence on those bindings is `examples/adapter-walkthrough.py`. The walkthrough section lives in `docs/external-control-plane.md`.
