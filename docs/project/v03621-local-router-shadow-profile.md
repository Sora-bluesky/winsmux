# v0.36.21 Local Router Resource And Privacy Profile

This profile records the local resource and privacy expectations for the
v0.36.21 Shadow Mode router. It is a release gate input, not a benchmark.

## Local Profile

| Metric | Value |
| --- | ---: |
| provider calls | 0 |
| GPU required | false |
| raw prompt stored | false |
| workspace writes | 0 bytes |
| provider metadata retained | false |
| local private paths retained | false |
| artifact update mode | manual release change only |

## Runtime Boundary

The local route-head path runs in PowerShell 7, loads only repository-pinned
JSON artifacts, and writes no workspace files unless an operator explicitly
calls the trace writer with a target path. The default evaluator and profile
functions return in-memory objects only.

## Privacy Boundary

The feature projection reads sanitized RouteContext metadata and counts. It does
not persist raw prompt text, API keys, bearer tokens, cookies, provider request
ids, local absolute paths, or browser profile paths. The release gate checks the
implementation and public documents for these boundaries.

## Interpretation

This profile proves that the Shadow proposal path is CPU-only, offline,
deterministic, and bounded for fixture evaluation. It does not prove real model
quality, worker quality, or Harness Bench performance. Those measurements belong
to the later six-pane benchmark release.
