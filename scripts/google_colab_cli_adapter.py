#!/usr/bin/env python3
"""google-colab-cli compatible adapter for winsmux Colab MCP runs.

This is a thin bridge. winsmux keeps the worker contract and evidence handling;
the optional sibling apps/colab project owns the Colab MCP connection.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any


STATE_SCHEMA = "winsmux.google_colab_cli_adapter.v1"
DEFAULT_MODE = "execute_with_evidence"


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def default_state_root() -> Path:
    return Path(os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_STATE_ROOT", repo_root() / ".winsmux" / "colab-cli-adapter"))


def safe_segment(value: str, fallback: str) -> str:
    text = (value or fallback).strip()
    allowed = []
    for char in text:
        if char.isalnum() or char in ("-", "_", "."):
            allowed.append(char)
        else:
            allowed.append("_")
    safe = "".join(allowed).strip("._")
    return safe or fallback


def state_dir(session: str, run_id: str) -> Path:
    return default_state_root() / safe_segment(session, "session") / safe_segment(run_id, "run")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def write_json(path: Path, payload: dict[str, Any]) -> None:
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def remove_existing_path(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def find_colab_repo() -> Path | None:
    explicit = os.environ.get("WINSMUX_COLAB_MCP_REPO", "").strip()
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    candidates.append(repo_root().parent / "colab")
    for candidate in candidates:
        if (candidate / "pyproject.toml").is_file() and (candidate / "src" / "colab_llm_mcp").is_dir():
            return candidate
    return None


def colab_python(colab_repo: Path) -> list[str]:
    explicit = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_PYTHON", "").strip()
    if explicit:
        return [explicit]
    venv_python = colab_repo / ".venv" / "Scripts" / "python.exe"
    if venv_python.is_file():
        return [str(venv_python)]
    venv_unix = colab_repo / ".venv" / "bin" / "python"
    if venv_unix.is_file():
        return [str(venv_unix)]
    uv = shutil.which("uv")
    if uv:
        return [uv, "run", "--no-sync", "--directory", str(colab_repo), "python"]
    return [sys.executable]


def build_cell_code(script_path: Path, session: str, run_id: str, script_args: list[str]) -> str:
    source = script_path.read_text(encoding="utf-8")
    remote_script = f"/content/winsmux-runtime-cache/adapter/{safe_segment(session, 'session')}/{safe_segment(run_id, 'run')}/{script_path.name}"
    argv = [remote_script, *script_args]
    return "\n".join(
        [
            "from pathlib import Path",
            "import runpy",
            "import sys",
            f"_winsmux_script_source = {json.dumps(source, ensure_ascii=False)}",
            f"_winsmux_script_path = Path({json.dumps(remote_script)})",
            "_winsmux_script_path.parent.mkdir(parents=True, exist_ok=True)",
            "_winsmux_script_path.write_text(_winsmux_script_source, encoding='utf-8')",
            f"sys.argv = {json.dumps(argv, ensure_ascii=False)}",
            "runpy.run_path(str(_winsmux_script_path), run_name='__main__')",
        ]
    )


def execute_plan(colab_repo: Path, plan_path: Path, mode: str) -> tuple[int, str, str]:
    code = (
        "import json, sys\n"
        "from pathlib import Path\n"
        "from colab_llm_mcp.execute import execute_llm_plan\n"
        "plan = Path(sys.argv[1]).read_text(encoding='utf-8')\n"
        "print(execute_llm_plan(plan, mode=sys.argv[2]))\n"
    )
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    command = [*colab_python(colab_repo), "-c", code, str(plan_path), mode]
    proc = subprocess.run(
        command,
        cwd=str(colab_repo),
        env=env,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def parse_colab_stdout(raw: str) -> str:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return raw
    if isinstance(payload, dict):
        stdout = payload.get("stdout")
        if isinstance(stdout, str) and stdout.strip():
            return stdout.strip()
        evidence = payload.get("evidence")
        if isinstance(evidence, dict):
            evidence_stdout = evidence.get("stdout")
            if isinstance(evidence_stdout, str) and evidence_stdout.strip():
                return evidence_stdout.strip()
    return raw


def command_run(args: argparse.Namespace, script_args: list[str]) -> int:
    script_path = Path(args.script)
    if not script_path.is_file():
        print(f"script not found: {script_path.name}", file=sys.stderr)
        return 2
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    run_state = state_dir(args.session, args.run_id)
    run_state.mkdir(parents=True, exist_ok=True)

    cell_code = build_cell_code(script_path, args.session, args.run_id, script_args)
    plan_path = output_dir / "colab-adapter-plan.py"
    write_text(plan_path, cell_code)
    write_text(run_state / "colab-adapter-plan.py", cell_code)

    mode = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_MODE", DEFAULT_MODE).strip() or DEFAULT_MODE
    if mode == "plan_only":
        payload = {
            "schema_version": STATE_SCHEMA,
            "status": "planned",
            "mode": mode,
            "session": args.session,
            "run_id": args.run_id,
            "script": script_path.name,
            "plan": str(plan_path),
        }
        text = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        write_text(output_dir / "stdout.log", text)
        write_text(run_state / "stdout.log", text)
        write_json(output_dir / "adapter-result.json", payload)
        write_json(run_state / "adapter-result.json", payload)
        print(text)
        return 0

    colab_repo = find_colab_repo()
    if colab_repo is None:
        message = "Colab MCP repo not found. Set WINSMUX_COLAB_MCP_REPO to the local apps/colab checkout."
        write_text(output_dir / "stdout.log", message)
        write_text(run_state / "stdout.log", message)
        print(message, file=sys.stderr)
        return 1

    exit_code, stdout, stderr = execute_plan(colab_repo, plan_path, mode)
    visible_stdout = parse_colab_stdout(stdout)
    write_text(output_dir / "stdout.log", visible_stdout)
    write_text(run_state / "stdout.log", visible_stdout)
    if stderr:
        write_text(output_dir / "stderr.log", stderr)
        write_text(run_state / "stderr.log", stderr)
    result = {
        "schema_version": STATE_SCHEMA,
        "status": "succeeded" if exit_code == 0 else "failed",
        "mode": mode,
        "session": args.session,
        "run_id": args.run_id,
        "script": script_path.name,
        "exit_code": exit_code,
        "stdout": visible_stdout,
        "stderr": stderr,
    }
    write_json(output_dir / "adapter-result.json", result)
    write_json(run_state / "adapter-result.json", result)
    if visible_stdout:
        print(visible_stdout)
    if stderr:
        print(stderr, file=sys.stderr)
    return exit_code


def command_logs(args: argparse.Namespace) -> int:
    run_state = state_dir(args.session, args.run_id or "run")
    log_path = run_state / "stdout.log"
    if not log_path.is_file():
        print("adapter log not found", file=sys.stderr)
        return 1
    print(log_path.read_text(encoding="utf-8"))
    return 0


def command_upload(args: argparse.Namespace) -> int:
    source = Path(args.source)
    if not source.exists():
        print("upload source not found", file=sys.stderr)
        return 2
    run_state = state_dir(args.session, args.run_id or "upload")
    dest = run_state / "uploads"
    dest.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        target = dest / source.name
        remove_existing_path(target)
        shutil.copytree(source, target)
    else:
        target = dest / source.name
        remove_existing_path(target)
        shutil.copy2(source, target)
    payload = {
        "schema_version": STATE_SCHEMA,
        "status": "uploaded",
        "session": args.session,
        "run_id": args.run_id,
        "dest": args.dest,
        "staged": str(target),
    }
    if args.manifest:
        write_json(Path(args.manifest), payload)
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return 0


def command_download(args: argparse.Namespace) -> int:
    run_state = state_dir(args.session, args.run_id or "download")
    staged = run_state / "uploads" / Path(args.source).name
    dest = Path(args.dest)
    if not staged.exists():
        print("download source not found in adapter state", file=sys.stderr)
        return 1
    if staged.is_dir():
        target = dest / staged.name if dest.exists() and dest.is_dir() else dest
        remove_existing_path(target)
        shutil.copytree(staged, target)
    else:
        target = dest / staged.name if dest.exists() and dest.is_dir() else dest
        target.parent.mkdir(parents=True, exist_ok=True)
        remove_existing_path(target)
        shutil.copy2(staged, target)
    payload = {
        "schema_version": STATE_SCHEMA,
        "status": "downloaded",
        "session": args.session,
        "run_id": args.run_id,
        "source": args.source,
        "output": str(target),
    }
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="google-colab-cli-adapter")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run")
    run.add_argument("--session", required=True)
    run.add_argument("--script", required=True)
    run.add_argument("--run-id", required=True)
    run.add_argument("--output-dir", required=True)

    logs = sub.add_parser("logs")
    logs.add_argument("--session", required=True)
    logs.add_argument("--run-id", default="")

    upload = sub.add_parser("upload")
    upload.add_argument("--session", required=True)
    upload.add_argument("--source", required=True)
    upload.add_argument("--dest", required=True)
    upload.add_argument("--manifest", default="")
    upload.add_argument("--run-id", default="")

    download = sub.add_parser("download")
    download.add_argument("--session", required=True)
    download.add_argument("--source", required=True)
    download.add_argument("--dest", required=True)
    download.add_argument("--run-id", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args, rest = parser.parse_known_args(argv)
    if args.command == "run":
        return command_run(args, rest)
    if args.command == "logs":
        return command_logs(args)
    if args.command == "upload":
        return command_upload(args)
    if args.command == "download":
        return command_download(args)
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
