# Dogfooding Measurement

This document describes the tracked code contract for the v0.25 dogfooding measurement surface. It contains no measured results, task content, or command text.

## Storage

Runtime dogfooding data is stored outside the repository by default:

- database: `%APPDATA%\winsmux\dogfood\events.db`
- exports: `%APPDATA%\winsmux\dogfood\exports\`
- override database: `WINSMUX_DOGFOOD_DB`
- override root: `WINSMUX_DOGFOOD_ROOT`

Repository-local databases, reports, and exports must not be committed. The `.gitignore` dogfood patterns are a secondary guard for accidental local files.

## Schema

`dogfood_events` stores structured operator events without raw command text.

```sql
CREATE TABLE dogfood_events (
  event_id TEXT PRIMARY KEY,
  timestamp INTEGER NOT NULL,
  run_id TEXT NOT NULL DEFAULT '',
  session_id TEXT NOT NULL,
  pane_id TEXT NOT NULL,
  input_source TEXT NOT NULL,
  action_type TEXT NOT NULL,
  task_ref TEXT NOT NULL DEFAULT '',
  duration_ms INTEGER,
  payload_hash TEXT NOT NULL DEFAULT '',
  created_at_utc TEXT NOT NULL
);
```

`event_id` is generated in UUID shape when the caller does not provide one. `input_source` is limited to `voice`, `keyboard`, `shortcut`, or `paste`. `action_type` is limited to `command`, `approval`, `cancel`, `retry`, `completion`, or `input`.

`dogfood_runs` stores comparable run metadata for later Codex-direct versus desktop-mediated comparisons.
Run rows are created only through `winsmux dogfood run-start`; plain event recording does not create or update a run.

## Integration Points

The desktop composer records command events when the operator submits a message. It also records keyed input transition events when voice input is corrected with the keyboard. It stores the SHA-256 hash of the message and attachment summary, not the raw message.

The desktop detail action buttons record operator actions. Winner selection and tactic promotion are recorded as `approval`, comparison is recorded as `retry`, and focus actions are recorded as `command`.

## Aggregation

`winsmux dogfood stats --since <date> --json` returns JSON and writes the same payload to the default exports directory. The payload includes:

- counts and share by `input_source`
- counts and share by `action_type`
- daily command counts
- task reference counts
- voice-to-keyboard fallback rate
- comparable run pairs
- quality counters from finished runs

The stats payload keeps `raw_payload_stored` as `false` and `payload_hash_only` as `true`.
Voice-to-keyboard fallback is calculated only from keyed command or input events that share a `run_id` or `task_ref`; unkeyed session history is ignored.
