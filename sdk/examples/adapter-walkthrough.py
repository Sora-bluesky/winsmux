"""Worked named-pipe client on generated control-plane bindings. Import is side-effect-free."""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

_SDK_PYTHON = Path(__file__).resolve().parents[1] / "python"
if str(_SDK_PYTHON) not in sys.path:
    sys.path.insert(0, str(_SDK_PYTHON))

from control_plane_contract import (
    CONTROL_PIPE_METHODS,
    DesktopProviderCapabilitiesParams,
    DesktopRunExplainParams,
    DesktopSummarySnapshotParams,
    PtyCaptureParams,
    PtyCloseParams,
    PtySpawnParams,
)

PIPE_NAME = r"\\.\pipe\winsmux-control"
PANE_ID = "adapter-walkthrough"
NO_RUNS = "no runs to explain -- capabilities and pty legs completed"


def _method(name: str) -> str:
    if name not in CONTROL_PIPE_METHODS:
        raise SystemExit("generated bindings do not advertise that method")
    return name


def _token() -> str:
    env = os.environ.get("WINSMUX_CONTROL_PIPE_TOKEN", "").strip()
    if env:
        return env
    local = os.environ.get("LOCALAPPDATA", "").strip()
    if not local:
        raise SystemExit("no usable control-pipe token")
    path = Path(local) / "winsmux" / "control-pipe" / "token"
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        value = ""
    if not value:
        raise SystemExit("no usable control-pipe token")
    return value


def _rpc(
    method: str, params: dict[str, Any] | None, token: str | None, req_id: str
) -> Any:
    payload: dict[str, Any] = {"jsonrpc": "2.0", "id": req_id, "method": method}
    if params is not None:
        payload["params"] = params
    if token is not None:
        payload["auth"] = {"token": token}
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    with open(PIPE_NAME, "r+b", buffering=0) as pipe:
        if pipe.write(raw) != len(raw):
            raise SystemExit("named-pipe short write")
        response = pipe.read(1024 * 1024)
    body = json.loads(response.decode("utf-8"))
    if body.get("error"):
        err = body["error"]
        raise SystemExit(f"rpc error {err.get('code')}: {err.get('message')}")
    return body.get("result")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", dest="run_id", default=None)
    args = parser.parse_args()
    token = _token()
    cap_params: DesktopProviderCapabilitiesParams = {}
    caps = _rpc(
        _method("desktop.provider.capabilities"),
        dict(cap_params),
        token,
        "capabilities",
    )
    providers = caps.get("providers") if isinstance(caps, dict) else {}
    print(
        "capabilities version", caps.get("version") if isinstance(caps, dict) else None
    )
    print(
        "capabilities providers",
        sorted(providers) if isinstance(providers, dict) else [],
    )
    spawn_params: PtySpawnParams = {
        "paneId": PANE_ID,
        "cols": 80,
        "rows": 24,
        "startupInput": "echo adapter-walkthrough\r",
    }
    spawned = False
    try:
        spawn_result = _rpc(_method("pty.spawn"), dict(spawn_params), token, "spawn")
        pane_id = (
            spawn_result.get("paneId") if isinstance(spawn_result, dict) else PANE_ID
        )
        spawned = True
        capture_params: PtyCaptureParams = {"paneId": str(pane_id), "lines": 40}
        captured = _rpc(_method("pty.capture"), dict(capture_params), token, "capture")
        output = captured.get("output") if isinstance(captured, dict) else ""
        preview = str(output).replace("\r", " ").replace("\n", " ").strip()[:120]
        print("pty.capture paneId", pane_id)
        print("pty.capture preview", preview)
        run_id = args.run_id
        if not run_id:
            snapshot_params: DesktopSummarySnapshotParams = {}
            snapshot = _rpc(
                _method("desktop.summary.snapshot"),
                dict(snapshot_params),
                token,
                "snapshot",
            )
            projections = (
                snapshot.get("run_projections") if isinstance(snapshot, dict) else None
            )
            first = (
                projections[0] if isinstance(projections, list) and projections else {}
            )
            candidate = first.get("run_id") if isinstance(first, dict) else None
            run_id = (
                candidate if isinstance(candidate, str) and candidate.strip() else None
            )
        if not run_id:
            print(NO_RUNS)
        else:
            explain_params: DesktopRunExplainParams = {"runId": run_id}
            explained = _rpc(
                _method("desktop.run.explain"), dict(explain_params), token, "explain"
            )
            explanation = (
                explained.get("explanation") if isinstance(explained, dict) else {}
            )
            summary = (
                explanation.get("summary") if isinstance(explanation, dict) else ""
            )
            print("desktop.run.explain runId", run_id)
            if summary:
                print("desktop.run.explain summary", str(summary)[:200])
    finally:
        if spawned:
            close_params: PtyCloseParams = {"paneId": PANE_ID}
            _rpc(_method("pty.close"), dict(close_params), token, "close")
    print("honest limit: worker start/status/stop stay off this walkthrough")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
