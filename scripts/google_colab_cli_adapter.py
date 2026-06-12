#!/usr/bin/env python3
"""google-colab-cli compatible adapter for winsmux Colab MCP runs.

This is a thin bridge. winsmux keeps the worker contract and evidence handling;
the optional sibling apps/colab project owns the Colab MCP connection.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any


STATE_SCHEMA = "winsmux.google_colab_cli_adapter.v1"
DEFAULT_MODE = "execute_with_evidence"
DEFAULT_EXECUTE_TIMEOUT_SEC = 1800.0
DEFAULT_PROXY_TIMEOUT_SEC = 120.0
PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----", re.IGNORECASE | re.DOTALL)
AUTH_BEARER_RE = re.compile(r"(?<![A-Za-z0-9_])([\"']?authorization[\"']?\s*[:=]\s*[\"']?\s*bearer\s+)[^\s\"',;}]+", re.IGNORECASE)
SECRET_FIELD_RE = re.compile(
    r"(?<![A-Za-z0-9_])([\"']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|oauth[_-]?token|token|password|passwd|secret|credential|credentials)[\"']?\s*[:=]\s*[\"']?)[^\s\"',;}]+",
    re.IGNORECASE,
)
EMAIL_RE = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.IGNORECASE)
COLAB_TOKEN_URL_RE = re.compile(r"https://colab\.(?:research\.)?google\.com/[^\s\"']*mcpProxyToken=[^\s\"']+", re.IGNORECASE)
COLAB_DRIVE_URL_RE = re.compile(r"https://colab\.(?:research\.)?google\.com/drive/[A-Za-z0-9_-]+[^\s\"']*", re.IGNORECASE)
MCP_TOKEN_RE = re.compile(r"mcpProxyToken=[^&\s\"']+", re.IGNORECASE)
WINDOWS_PATH_RE = re.compile(r"(?<![A-Za-z0-9_])(?:[A-Za-z]:\\Users\\[^\\\r\n]+(?:\\[^\r\n\"']+)*)", re.IGNORECASE)
DRIVE_PATH_RE = re.compile(r"(?:/content/drive/MyDrive|[A-Za-z]:\\マイドライブ|[A-Za-z]:\\My Drive)[^\r\n\"']*", re.IGNORECASE)


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="replace")


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


def redact_sensitive_text(text: str) -> str:
    redacted = PRIVATE_KEY_RE.sub("[PRIVATE_KEY_REDACTED]", text or "")
    redacted = AUTH_BEARER_RE.sub(r"\1[REDACTED]", redacted)
    redacted = SECRET_FIELD_RE.sub(r"\1[REDACTED]", redacted)
    redacted = EMAIL_RE.sub("[EMAIL_REDACTED]", redacted)
    redacted = COLAB_TOKEN_URL_RE.sub("[COLAB_MCP_URL_REDACTED]", redacted)
    redacted = COLAB_DRIVE_URL_RE.sub("[COLAB_NOTEBOOK_URL_REDACTED]", redacted)
    redacted = MCP_TOKEN_RE.sub("mcpProxyToken=[REDACTED]", redacted)
    redacted = DRIVE_PATH_RE.sub("[DRIVE_PATH_REDACTED]", redacted)
    redacted = WINDOWS_PATH_RE.sub("[LOCAL_PATH_REDACTED]", redacted)
    return redacted


def read_positive_float_env(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except (OverflowError, ValueError):
        return default
    if value <= 0 or not math.isfinite(value):
        return default
    return value


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
        "import inspect, json, math, os, sys\n"
        "from pathlib import Path\n"
        "print('WINSMUX_COLAB_ADAPTER_STAGE import_execute_begin', file=sys.stderr, flush=True)\n"
        "import colab_llm_mcp.execute as execute_mod\n"
        "try:\n"
        "    import colab_llm_mcp.colab_mcp_pool as pool_mod\n"
        "except ModuleNotFoundError:\n"
        "    pool_mod = None\n"
        "from colab_llm_mcp.execute import execute_llm_plan\n"
        "print('WINSMUX_COLAB_ADAPTER_STAGE import_execute_done', file=sys.stderr, flush=True)\n"
        "def _stage(name):\n"
        "    print(f'WINSMUX_COLAB_ADAPTER_STAGE {name}', file=sys.stderr, flush=True)\n"
        "def _static_attr(owner, attr):\n"
        "    try:\n"
        "        return inspect.getattr_static(owner, attr)\n"
        "    except AttributeError:\n"
        "        return getattr(owner, '__dict__', {}).get(attr)\n"
        "def _descriptor_target(owner, attr):\n"
        "    raw = _static_attr(owner, attr)\n"
        "    if isinstance(raw, (classmethod, staticmethod)):\n"
        "        return raw, raw.__func__\n"
        "    return raw, getattr(owner, attr, None)\n"
        "def _set_wrapped(owner, attr, raw, wrapped):\n"
        "    if isinstance(raw, classmethod):\n"
        "        setattr(owner, attr, classmethod(wrapped))\n"
        "    elif isinstance(raw, staticmethod):\n"
        "        setattr(owner, attr, staticmethod(wrapped))\n"
        "    else:\n"
        "        setattr(owner, attr, wrapped)\n"
        "def _wrap_sync(owner, attr, begin, done):\n"
        "    raw, original = _descriptor_target(owner, attr)\n"
        "    if original is None or getattr(original, '_winsmux_wrapped', False):\n"
        "        return\n"
        "    def wrapped(*args, **kwargs):\n"
        "        _stage(begin)\n"
        "        try:\n"
        "            result = original(*args, **kwargs)\n"
        "            _stage(done)\n"
        "            return result\n"
        "        except Exception as exc:\n"
        "            _stage(f'{begin}_error:{type(exc).__name__}')\n"
        "            raise\n"
        "    wrapped._winsmux_wrapped = True\n"
        "    try:\n"
        "        wrapped.__signature__ = inspect.signature(original)\n"
        "    except (TypeError, ValueError):\n"
        "        pass\n"
        "    _set_wrapped(owner, attr, raw, wrapped)\n"
        "def _wrap_async(owner, attr, begin, done):\n"
        "    raw, original = _descriptor_target(owner, attr)\n"
        "    if original is None or getattr(original, '_winsmux_wrapped', False):\n"
        "        return\n"
        "    if not inspect.iscoroutinefunction(original):\n"
        "        _wrap_sync(owner, attr, begin, done)\n"
        "        return\n"
        "    async def wrapped(*args, **kwargs):\n"
        "        _stage(begin)\n"
        "        try:\n"
        "            result = await original(*args, **kwargs)\n"
        "            _stage(done)\n"
        "            return result\n"
        "        except Exception as exc:\n"
        "            _stage(f'{begin}_error:{type(exc).__name__}')\n"
        "            raise\n"
        "    wrapped._winsmux_wrapped = True\n"
        "    try:\n"
        "        wrapped.__signature__ = inspect.signature(original)\n"
        "    except (TypeError, ValueError):\n"
        "        pass\n"
        "    _set_wrapped(owner, attr, raw, wrapped)\n"
        "def _float_env(name, default):\n"
        "    raw = os.environ.get(name, '').strip()\n"
        "    if not raw:\n"
        "        return default\n"
        "    try:\n"
        "        value = float(raw)\n"
        "    except (OverflowError, ValueError):\n"
        "        _stage(f'{name}_invalid')\n"
        "        return default\n"
        "    if value <= 0 or not math.isfinite(value):\n"
        "        _stage(f'{name}_invalid')\n"
        "        return default\n"
        "    return value\n"
        "def _execute_llm_plan_compat(plan_text, selected_mode, proxy_timeout, verify_kernel_bind):\n"
        "    kwargs = {}\n"
        "    try:\n"
        "        signature = inspect.signature(execute_llm_plan)\n"
        "        params = signature.parameters\n"
        "        accepts_kwargs = any(param.kind == inspect.Parameter.VAR_KEYWORD for param in params.values())\n"
        "    except (TypeError, ValueError):\n"
        "        params = {}\n"
        "        accepts_kwargs = False\n"
        "    if accepts_kwargs or 'proxy_timeout_sec' in params:\n"
        "        kwargs['proxy_timeout_sec'] = proxy_timeout\n"
        "    if accepts_kwargs or 'verify_kernel_bind' in params:\n"
        "        kwargs['verify_kernel_bind'] = verify_kernel_bind\n"
        "    if params and not accepts_kwargs and 'mode' not in params:\n"
        "        return execute_llm_plan(plan_text, selected_mode)\n"
        "    try:\n"
        "        return execute_llm_plan(plan_text, mode=selected_mode, **kwargs)\n"
        "    except TypeError:\n"
        "        if kwargs:\n"
        "            try:\n"
        "                return execute_llm_plan(plan_text, mode=selected_mode)\n"
        "            except TypeError:\n"
        "                return execute_llm_plan(plan_text, selected_mode)\n"
        "        return execute_llm_plan(plan_text, selected_mode)\n"
        "def _callable_accepts_positional(owner, attr, minimum):\n"
        "    fn = getattr(owner, attr, None)\n"
        "    if not callable(fn):\n"
        "        return False\n"
        "    try:\n"
        "        params = inspect.signature(fn).parameters.values()\n"
        "    except (TypeError, ValueError):\n"
        "        return False\n"
        "    positional = [p for p in params if p.kind in (inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD)]\n"
        "    return any(p.kind == inspect.Parameter.VAR_POSITIONAL for p in params) or len(positional) >= minimum\n"
        "def _callable_accepts_keywords(owner, attr, names):\n"
        "    fn = getattr(owner, attr, None)\n"
        "    if not callable(fn):\n"
        "        return False\n"
        "    try:\n"
        "        params = inspect.signature(fn).parameters\n"
        "    except (TypeError, ValueError):\n"
        "        return False\n"
        "    accepts_kwargs = any(param.kind == inspect.Parameter.VAR_KEYWORD for param in params.values())\n"
        "    return accepts_kwargs or all(name in params for name in names)\n"
        "def _callable_is_coroutine(owner, attr):\n"
        "    raw, fn = _descriptor_target(owner, attr)\n"
        "    return callable(fn) and inspect.iscoroutinefunction(fn)\n"
        "def _callable_is_class_accessible(owner, attr):\n"
        "    if not inspect.isclass(owner):\n"
        "        return True\n"
        "    raw, _ = _descriptor_target(owner, attr)\n"
        "    return isinstance(raw, (classmethod, staticmethod))\n"
        "if os.environ.get('WINSMUX_COLAB_CLI_ADAPTER_STAGE_TRACE', '1').strip().lower() not in ('0', 'false', 'no', 'off'):\n"
        "    pool = getattr(execute_mod, 'ColabMcpPool', None)\n"
        "    if pool is not None:\n"
        "        _wrap_sync(pool, '_ensure_loop_thread', 'ensure_loop_thread_begin', 'ensure_loop_thread_done')\n"
        "        _wrap_sync(pool, 'run', 'pool_run_begin', 'pool_run_done')\n"
        "        _wrap_sync(pool, 'get_session', 'get_session_begin', 'get_session_done')\n"
        "    if pool_mod is not None:\n"
        "        _wrap_sync(pool_mod, 'colab_mcp_stdio_params', 'stdio_params_begin', 'stdio_params_done')\n"
        "        _wrap_async(pool_mod, 'call_tool', 'pool_call_tool_begin', 'pool_call_tool_done')\n"
        "        _wrap_async(pool_mod, 'ensure_proxy_tools', 'pool_ensure_proxy_begin', 'pool_ensure_proxy_done')\n"
        "    _wrap_async(execute_mod, '_maybe_verify_kernel_bind', 'kernel_bind_begin', 'kernel_bind_done')\n"
        "    _wrap_async(execute_mod, 'add_code_cell', 'add_code_cell_begin', 'add_code_cell_done')\n"
        "    _wrap_async(execute_mod, 'run_code_cell', 'run_code_cell_begin', 'run_code_cell_done')\n"
        "    _wrap_async(execute_mod, 'read_cell_output', 'read_cell_output_begin', 'read_cell_output_done')\n"
        "async def _winsmux_execute_plan_async(plan_text, selected_mode, proxy_timeout, verify_kernel_bind):\n"
        "    if selected_mode == 'plan_only':\n"
        "        return {'ok': True, **execute_mod.plan_only_result(plan_text)}\n"
        "    code = execute_mod.extract_plan_code(plan_text)\n"
        "    notebook_url = execute_mod.resolve_colab_notebook_url()\n"
        "    raw_open_browser = os.environ.get('COLAB_MCP_OPEN_BROWSER', '').strip().lower()\n"
        "    no_auto_browser = raw_open_browser not in ('1', 'true', 'yes', 'on')\n"
        "    pool = execute_mod.ColabMcpPool\n"
        "    _stage('connect_session_begin')\n"
        "    try:\n"
        "        session = await pool._connect_session(proxy_timeout_sec=proxy_timeout, no_auto_browser=no_auto_browser)\n"
        "        _stage('connect_session_done')\n"
        "    except Exception as exc:\n"
        "        _stage(f'connect_session_error:{type(exc).__name__}')\n"
        "        raise\n"
        "    kernel_bind_ok = True\n"
        "    bind_detail = 'bind check skipped'\n"
        "    if verify_kernel_bind:\n"
        "        kernel_bind_ok, bind_detail = await execute_mod._maybe_verify_kernel_bind(session, notebook_url)\n"
        "        if not kernel_bind_ok:\n"
        "            return {'mode': selected_mode, 'ok': False, 'error': f'kernel bind failed: {bind_detail}', 'notebook_url': notebook_url}\n"
        "    cell_id = await execute_mod.add_code_cell(session, code)\n"
        "    await execute_mod.run_code_cell(session, cell_id)\n"
        "    stdout = await execute_mod.read_cell_output(session, cell_id)\n"
        "    stripped_stdout = stdout.strip()\n"
        "    if not stripped_stdout:\n"
        "        return {'mode': selected_mode, 'ok': False, 'error': 'empty cell output after execution', 'cell_id': cell_id, 'notebook_url': notebook_url}\n"
        "    if stripped_stdout.startswith('ERROR:') or '\\nERROR:' in stripped_stdout:\n"
        "        return {'mode': selected_mode, 'ok': False, 'error': stripped_stdout, 'cell_id': cell_id, 'notebook_url': notebook_url}\n"
        "    result = {'mode': selected_mode, 'ok': True, 'stdout': stdout, 'cell_id': cell_id, 'notebook_url': notebook_url, 'kernel_bind_ok': kernel_bind_ok, 'kernel_bind_detail': bind_detail}\n"
        "    if selected_mode == 'execute_with_evidence':\n"
        "        result['evidence'] = execute_mod.build_execution_evidence(stdout=stdout, cell_id=cell_id, notebook_url=notebook_url, kernel_bind_ok=kernel_bind_ok, gpu=execute_mod.parse_gpu_from_text(stdout))\n"
        "    return result\n"
        "def _can_use_safe_executor(selected_mode, verify_kernel_bind):\n"
        "    pool = getattr(execute_mod, 'ColabMcpPool', None)\n"
        "    required = ['extract_plan_code', 'resolve_colab_notebook_url', 'add_code_cell', 'run_code_cell', 'read_cell_output']\n"
        "    async_required = ['add_code_cell', 'run_code_cell', 'read_cell_output']\n"
        "    if verify_kernel_bind:\n"
        "        required.append('_maybe_verify_kernel_bind')\n"
        "        async_required.append('_maybe_verify_kernel_bind')\n"
        "    if selected_mode == 'execute_with_evidence':\n"
        "        required.extend(['parse_gpu_from_text', 'build_execution_evidence'])\n"
        "    return selected_mode != 'plan_only' and pool is not None and _callable_is_class_accessible(pool, 'run') and _callable_is_class_accessible(pool, '_connect_session') and _callable_accepts_positional(pool, 'run', 1) and _callable_accepts_keywords(pool, '_connect_session', ('proxy_timeout_sec', 'no_auto_browser')) and _callable_is_coroutine(pool, '_connect_session') and all(callable(getattr(execute_mod, name, None)) for name in required) and all(_callable_is_coroutine(execute_mod, name) for name in async_required)\n"
        "plan = Path(sys.argv[1]).read_text(encoding='utf-8')\n"
        f"proxy_timeout = _float_env('WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC', {DEFAULT_PROXY_TIMEOUT_SEC!r})\n"
        "verify_kernel_bind = os.environ.get('WINSMUX_COLAB_CLI_ADAPTER_VERIFY_KERNEL_BIND', '1').strip().lower() not in ('0', 'false', 'no', 'off')\n"
        "normalized_mode = sys.argv[2].strip().lower()\n"
        "if normalized_mode not in ('plan_only', 'execute', 'execute_with_evidence'):\n"
        "    raise ValueError(f'mode must be plan_only, execute, or execute_with_evidence; got {sys.argv[2]!r}')\n"
        "print('WINSMUX_COLAB_ADAPTER_STAGE execute_plan_begin', file=sys.stderr, flush=True)\n"
        "if _can_use_safe_executor(normalized_mode, verify_kernel_bind):\n"
        "    _stage('safe_executor_begin')\n"
        "    payload = execute_mod.ColabMcpPool.run(_winsmux_execute_plan_async(plan, normalized_mode, proxy_timeout, verify_kernel_bind))\n"
        "    _stage('safe_executor_done')\n"
        "    if inspect.isawaitable(payload):\n"
        "        close = getattr(payload, 'close', None)\n"
        "        if callable(close):\n"
        "            close()\n"
        "        _stage('safe_executor_awaitable_result_fallback')\n"
        "        print(_execute_llm_plan_compat(plan, normalized_mode, proxy_timeout, verify_kernel_bind))\n"
        "    elif not isinstance(payload, dict):\n"
        "        print(json.dumps({'ok': False, 'error': 'invalid safe executor result type', 'result_type': type(payload).__name__}, ensure_ascii=False, indent=2))\n"
        "        sys.exit(1)\n"
        "    else:\n"
        "        print(json.dumps(payload, ensure_ascii=False, indent=2))\n"
        "        if not payload.get('ok', True):\n"
        "            sys.exit(1)\n"
        "else:\n"
        "    print(_execute_llm_plan_compat(plan, normalized_mode, proxy_timeout, verify_kernel_bind))\n"
        "print('WINSMUX_COLAB_ADAPTER_STAGE execute_plan_done', file=sys.stderr, flush=True)\n"
    )
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUNBUFFERED"] = "1"
    colab_src = str(colab_repo / "src")
    existing_pythonpath = env.get("PYTHONPATH", "").strip()
    env["PYTHONPATH"] = colab_src if not existing_pythonpath else os.pathsep.join([colab_src, existing_pythonpath])
    command = [*colab_python(colab_repo), "-u", "-c", code, str(plan_path), mode]
    timeout_sec = read_positive_float_env("WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC", DEFAULT_EXECUTE_TIMEOUT_SEC)
    try:
        proc = subprocess.run(
            command,
            cwd=str(colab_repo),
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_sec,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        message = f"Colab execution timed out after {timeout_sec:.0f}s"
        stderr = f"{stderr.rstrip()}\n{message}".strip()
        return 124, str(stdout).strip(), stderr
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

    exit_code, stdout, stderr = execute_plan(colab_repo, plan_path.resolve(), mode)
    visible_stdout = redact_sensitive_text(parse_colab_stdout(stdout))
    stderr = redact_sensitive_text(stderr)
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
    configure_stdio()
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
