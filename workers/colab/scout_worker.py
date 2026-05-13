#!/usr/bin/env python3
"""Self-contained repository scout worker template for winsmux Colab slots."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
from typing import Any


SCHEMA_VERSION = "winsmux.colab.worker.result.v1"
DEFAULT_ARTIFACT_ROOT = "/content/winsmux_artifacts"
WORKER_KIND = "scout"
ARTIFACT_FILE = "scout-plan.md"
ACTIONS = ["search for related files", "summarize relevant contracts", "stop before editing files"]
RISKS = ["template is read-only and does not validate the repository state by itself"]
WORKER_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


class InputError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    return [value]


def text_field(task: dict[str, Any], *names: str, default: str = "") -> str:
    for name in names:
        value = task.get(name)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return default


def task_title(task: dict[str, Any]) -> str:
    return text_field(task, "title", "summary", "task", default="Untitled winsmux task")


def task_id(task: dict[str, Any], fallback: str = "") -> str:
    return text_field(task, "task_id", "id", default=fallback)


def unique_text_items(task: dict[str, Any], keys: tuple[str, ...]) -> list[str]:
    items: list[str] = []
    for key in keys:
        for item in as_list(task.get(key)):
            text = str(item).strip()
            if text and text not in items:
                items.append(text)
    return items


def bullet_list(items: list[str], empty: str = "None provided.") -> str:
    if not items:
        return f"- {empty}"
    return "\n".join(f"- {item}" for item in items)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def emit_json(payload: dict[str, Any], pretty: bool) -> None:
    if pretty:
        print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True))


def read_task(args: argparse.Namespace) -> dict[str, Any]:
    if args.task_json:
        try:
            raw = Path(args.task_json).read_text(encoding="utf-8")
        except OSError as exc:
            raise InputError("task_json_read_failed", str(exc)) from exc
    elif args.task_json_inline:
        raw = args.task_json_inline
    elif os.environ.get("WINSMUX_TASK_JSON"):
        raw = os.environ["WINSMUX_TASK_JSON"]
    elif not sys.stdin.isatty():
        raw = sys.stdin.read()
    else:
        raw = ""

    if not raw.strip():
        return {}

    try:
        task = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise InputError("invalid_task_json", f"task JSON is invalid: {exc.msg}") from exc
    if not isinstance(task, dict):
        raise InputError("invalid_task_json", "task JSON must be an object")
    return task


def safe_worker_id(value: str) -> str:
    worker_id = (value or "worker").strip()
    if not WORKER_ID_RE.match(worker_id):
        raise InputError(
            "invalid_worker_id",
            "worker id must start with an ASCII letter or digit and contain only letters, digits, '.', '_' or '-'",
        )
    return worker_id


def safe_run_id(value: str) -> str:
    run_id = (value or dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")).strip()
    if not WORKER_ID_RE.match(run_id):
        raise InputError(
            "invalid_run_id",
            "run id must start with an ASCII letter or digit and contain only letters, digits, '.', '_' or '-'",
        )
    return run_id


def render_artifact(task: dict[str, Any]) -> str:
    files = unique_text_items(task, ("changed_files", "target_files", "files", "write_scope"))
    query = text_field(task, "query", "search", "summary", default=task_title(task))
    return f"""# Repository Scout Plan

## Search Goal

{query}

## Starting Files

{bullet_list(files, "Start from README, docs, tests, and nearby implementation files.")}

## Output Contract

- Report the files and symbols that matter.
- Explain why each file is relevant.
- Stop after gathering enough context for the operator or implementation worker.
"""


def success_payload(args: argparse.Namespace, worker_id: str, run_id: str, task: dict[str, Any], artifact_path: Path) -> dict[str, Any]:
    query = text_field(task, "query", "search", "summary", default=task_title(task))
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "status": "succeeded",
        "worker_kind": WORKER_KIND,
        "worker_id": worker_id,
        "run_id": run_id,
        "task": {"id": task_id(task, args.task_id), "title": task_title(task)},
        "summary": "prepared a repository scouting template",
        "actions": ACTIONS,
        "artifacts": [{"kind": "markdown", "path": artifact_path.as_posix(), "description": "Repository scouting plan."}],
        "observations": [{"query": query}],
        "risks": RISKS,
        "errors": [],
    }


def failure_payload(args: argparse.Namespace, code: str, message: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "status": "failed",
        "worker_kind": WORKER_KIND,
        "worker_id": args.worker_id,
        "run_id": args.run_id,
        "task": {"id": args.task_id, "title": ""},
        "summary": "worker execution failed",
        "actions": [],
        "artifacts": [],
        "observations": [],
        "risks": [],
        "errors": [{"code": code, "message": message}],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="winsmux Colab repository scout worker template")
    parser.add_argument("--task-json", default="", help="Path to a JSON task payload.")
    parser.add_argument("--task-json-inline", default="", help="Inline JSON task payload.")
    parser.add_argument("--task-id", default=os.environ.get("WINSMUX_TASK_ID", ""), help="Fallback task id.")
    parser.add_argument("--run-id", default=os.environ.get("WINSMUX_RUN_ID", ""), help="Run id for artifact isolation.")
    parser.add_argument("--worker-id", default=os.environ.get("WINSMUX_WORKER_ID", "worker"), help="Worker id.")
    parser.add_argument("--artifact-root", default=os.environ.get("WINSMUX_ARTIFACT_ROOT", DEFAULT_ARTIFACT_ROOT))
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output.")
    args = parser.parse_args(argv)

    try:
        worker_id = safe_worker_id(args.worker_id)
        task = read_task(args)
        run_id = safe_run_id(args.run_id or text_field(task, "run_id", default=""))
        artifact_dir = Path(args.artifact_root or DEFAULT_ARTIFACT_ROOT).expanduser() / worker_id / run_id
        artifact_dir.mkdir(parents=True, exist_ok=True)
        artifact_path = artifact_dir / ARTIFACT_FILE
        artifact_path.write_text(render_artifact(task), encoding="utf-8", newline="\n")
        emit_json(success_payload(args, worker_id, run_id, task, artifact_path), args.pretty)
        return 0
    except InputError as exc:
        emit_json(failure_payload(args, exc.code, exc.message), args.pretty)
        return 1
    except Exception as exc:  # pragma: no cover - defensive template boundary
        emit_json(failure_payload(args, "worker_exception", f"{type(exc).__name__}: {exc}"), args.pretty)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
