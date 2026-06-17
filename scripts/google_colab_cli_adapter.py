#!/usr/bin/env python3
"""google-colab-cli compatible adapter for winsmux Colab MCP runs.

This is a thin bridge. winsmux keeps the worker contract and evidence handling;
the optional sibling apps/colab project owns the Colab MCP connection.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Any
from urllib.parse import unquote, unquote_plus


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
WINDOWS_PATH_RE = re.compile(r"(?<![A-Za-z0-9_])(?:[A-Za-z]:[\\/]+Users[\\/]+[^\\/\r\n\"']+(?:[\\/]+[^\\/\r\n\"']+)*)", re.IGNORECASE)
DRIVE_PATH_RE = re.compile(r"(?:/content/drive/MyDrive|[A-Za-z]:[\\/]+マイドライブ|[A-Za-z]:[\\/]+My Drive)[^\r\n\"']*", re.IGNORECASE)
PERCENT_ENCODED_TOKEN_RE = re.compile(r"[^\s\"']*%[0-9A-Fa-f]{2}[^\s\"']*")
SENSITIVE_KEY_RE = re.compile(
    r"^(?:authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|oauth[_-]?token|token|password|passwd|secret|credential|credentials)$",
    re.IGNORECASE,
)


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


def utc_now_text() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def append_progress(stage: str, detail: str = "") -> None:
    progress_path = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_PROGRESS_PATH", "").strip()
    if not progress_path:
        return
    payload = {
        "at": utc_now_text(),
        "stage": safe_segment(stage, "stage"),
    }
    if detail:
        payload["detail"] = redact_sensitive_text(detail)
    path = Path(progress_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")


def redact_sensitive_text(text: str) -> str:
    redacted = PRIVATE_KEY_RE.sub("[PRIVATE_KEY_REDACTED]", text or "")
    redacted = redact_percent_encoded_sensitive_text(redacted)
    redacted = AUTH_BEARER_RE.sub(r"\1[REDACTED]", redacted)
    redacted = SECRET_FIELD_RE.sub(r"\1[REDACTED]", redacted)
    redacted = EMAIL_RE.sub("[EMAIL_REDACTED]", redacted)
    redacted = COLAB_TOKEN_URL_RE.sub("[COLAB_MCP_URL_REDACTED]", redacted)
    redacted = COLAB_DRIVE_URL_RE.sub("[COLAB_NOTEBOOK_URL_REDACTED]", redacted)
    redacted = MCP_TOKEN_RE.sub("mcpProxyToken=[REDACTED]", redacted)
    redacted = DRIVE_PATH_RE.sub("[DRIVE_PATH_REDACTED]", redacted)
    redacted = WINDOWS_PATH_RE.sub("[LOCAL_PATH_REDACTED]", redacted)
    return redacted


def contains_sensitive_text(text: str) -> bool:
    value = text or ""
    return any(
        pattern.search(value)
        for pattern in (
            PRIVATE_KEY_RE,
            AUTH_BEARER_RE,
            SECRET_FIELD_RE,
            EMAIL_RE,
            COLAB_TOKEN_URL_RE,
            COLAB_DRIVE_URL_RE,
            MCP_TOKEN_RE,
            DRIVE_PATH_RE,
            WINDOWS_PATH_RE,
        )
    )


def redact_percent_encoded_sensitive_text(text: str) -> str:
    def replace(match: re.Match[str]) -> str:
        value = match.group(0)
        try:
            decoded_values = {unquote(value), unquote_plus(value)}
        except Exception:
            return value
        if any(decoded != value and contains_sensitive_text(decoded) for decoded in decoded_values):
            return "[URL_ENCODED_SENSITIVE_REDACTED]"
        return value

    return PERCENT_ENCODED_TOKEN_RE.sub(replace, text or "")


def redact_secret_value(value: Any) -> Any:
    if isinstance(value, str):
        if value.strip().lower().startswith("bearer "):
            return "Bearer [REDACTED]"
        return "[REDACTED]"
    if value is None:
        return None
    return "[REDACTED]"


def redact_sensitive_value(value: Any) -> Any:
    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            if SENSITIVE_KEY_RE.search(key_text):
                redacted[key_text] = redact_secret_value(item)
            else:
                redacted[key_text] = redact_sensitive_value(item)
        return redacted
    if isinstance(value, list):
        return [redact_sensitive_value(item) for item in value]
    if isinstance(value, str):
        return redact_sensitive_text(value)
    return value


def redact_json_arg(value: str) -> str:
    try:
        payload = json.loads(value)
    except json.JSONDecodeError:
        return redact_sensitive_text(value)
    return json.dumps(redact_sensitive_value(payload), ensure_ascii=False, separators=(",", ":"))


def redact_script_args(script_args: list[str]) -> list[str]:
    redacted: list[str] = []
    index = 0
    while index < len(script_args):
        arg = script_args[index]
        if arg.startswith("--task-json-inline="):
            flag, value = arg.split("=", 1)
            redacted.append(f"{flag}={redact_json_arg(value)}")
            index += 1
            continue
        if arg.startswith("--task-json="):
            flag, value = arg.split("=", 1)
            redacted.append(f"{flag}={redact_sensitive_text(value)}")
            index += 1
            continue
        redacted.append(redact_sensitive_text(arg))
        if arg == "--task-json-inline" and index + 1 < len(script_args):
            index += 1
            redacted.append(redact_json_arg(script_args[index]))
        elif arg == "--task-json" and index + 1 < len(script_args):
            index += 1
            redacted.append(redact_sensitive_text(script_args[index]))
        index += 1
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
    argv = [remote_script]
    if run_id and "--run-id" not in script_args:
        argv.extend(["--run-id", run_id])
    argv.extend(script_args)
    return "\n".join(
        [
            "from pathlib import Path",
            "import os",
            "import subprocess",
            "import sys",
            f"_winsmux_script_source = {json.dumps(source, ensure_ascii=False)}",
            f"_winsmux_script_path = Path({json.dumps(remote_script)})",
            "_winsmux_script_path.parent.mkdir(parents=True, exist_ok=True)",
            "_winsmux_script_path.write_text(_winsmux_script_source, encoding='utf-8')",
            f"_winsmux_argv = [sys.executable, *{json.dumps(argv, ensure_ascii=False)}]",
            "_winsmux_env = dict(os.environ)",
            "_winsmux_env['PYTHONUNBUFFERED'] = '1'",
            "_winsmux_proc = subprocess.Popen(_winsmux_argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=_winsmux_env)",
            "assert _winsmux_proc.stdout is not None",
            "for _winsmux_line in _winsmux_proc.stdout:",
            "    print(_winsmux_line, end='', flush=True)",
            "_winsmux_returncode = _winsmux_proc.wait()",
            "if _winsmux_returncode:",
            "    raise SystemExit(_winsmux_returncode)",
        ]
    )


def acquire_direct_browser_lock(lock_path: Path, timeout_sec: float) -> int:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + timeout_sec
    while True:
        try:
            handle = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_RDWR)
            os.write(handle, str(os.getpid()).encode("utf-8", errors="replace"))
            return handle
        except FileExistsError:
            if not direct_browser_lock_owner_alive(lock_path):
                try:
                    lock_path.unlink()
                    continue
                except FileNotFoundError:
                    continue
                except OSError:
                    pass
            if time.monotonic() >= deadline:
                raise TimeoutError(f"direct browser lock timed out: {lock_path.name}")
            time.sleep(1.0)


def direct_browser_lock_owner_alive(lock_path: Path) -> bool:
    try:
        raw = lock_path.read_text(encoding="utf-8", errors="replace").strip()
        owner_pid = int(raw)
    except (OSError, ValueError):
        return False
    if owner_pid <= 0:
        return False
    try:
        os.kill(owner_pid, 0)
        return True
    except OSError:
        return False


def release_direct_browser_lock(lock_path: Path, handle: int | None) -> None:
    if handle is not None:
        try:
            os.close(handle)
        except OSError:
            pass
    try:
        lock_path.unlink()
    except FileNotFoundError:
        pass


def extract_json_object_containing(text: str, marker: str, run_id: str = "") -> dict[str, Any] | None:
    decoder = json.JSONDecoder()
    matches: list[dict[str, Any]] = []
    for match in re.finditer(r"\{", text or ""):
        try:
            payload, _ = decoder.raw_decode(text[match.start() :])
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        if payload.get("schema_version") != marker and marker not in json.dumps(payload, ensure_ascii=False):
            continue
        matches.append(payload)
    if not matches:
        return None
    if run_id:
        for payload in reversed(matches):
            if str(payload.get("run_id") or "") == run_id:
                return payload
        return None
    return matches[-1]


def read_direct_browser_text(page: Any) -> str:
    texts: list[str] = []
    for frame in [page.main_frame, *[candidate for candidate in page.frames if candidate != page.main_frame]]:
        try:
            text = frame.locator("body").inner_text(timeout=5000)
        except Exception:
            continue
        if text and text not in texts:
            texts.append(text)
    return "\n".join(texts)


def parse_utc_timestamp(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw.strip():
        return None
    value = raw.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def extract_worker_stage_lines(text: str, not_before_utc: datetime | None = None) -> list[str]:
    lines: list[str] = []
    prefix = "WINSMUX_COLAB_LLM_STAGE "
    for raw_line in (text or "").splitlines():
        line = raw_line.strip()
        if not line.startswith(prefix):
            continue
        payload_text = line[len(prefix) :].strip()
        if not payload_text.startswith("{"):
            continue
        try:
            payload = json.loads(payload_text)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        if not_before_utc is not None:
            stage_at = parse_utc_timestamp(payload.get("at"))
            if stage_at is None or stage_at < not_before_utc:
                continue
        normalized = prefix + json.dumps(payload, ensure_ascii=False, sort_keys=True)
        if normalized not in lines:
            lines.append(normalized)
    return lines


def direct_browser_scopes(page: Any) -> list[Any]:
    scopes = [page]
    try:
        scopes.extend(page.frames)
    except Exception:
        pass
    return scopes


def click_direct_locator(locator: Any, timeout_ms: int = 5000) -> bool:
    try:
        count = locator.count()
    except Exception:
        return False
    for index in range(min(count, 8) - 1, -1, -1):
        candidate = locator.nth(index)
        try:
            candidate.scroll_into_view_if_needed(timeout=2000)
        except Exception:
            pass
        try:
            candidate.click(timeout=timeout_ms)
            return True
        except Exception:
            continue
    return False


def click_direct_browser_editor(page: Any) -> bool:
    for scope in direct_browser_scopes(page):
        candidates = [
            scope.locator("[role='textbox']"),
            scope.locator("textarea"),
            scope.locator(".cm-content"),
            scope.locator(".CodeMirror textarea"),
            scope.locator("[contenteditable='true']"),
        ]
        for locator in candidates:
            if click_direct_locator(locator):
                return True
    for scope in direct_browser_scopes(page):
        try:
            locator = scope.get_by_text(re.compile(r"コーディングを開始するか|Start coding", re.I))
        except Exception:
            continue
        if click_direct_locator(locator):
            return True
    return False


def paste_direct_browser_code(page: Any, code: str) -> bool:
    try:
        page.evaluate("value => navigator.clipboard.writeText(value)", code)
        page.keyboard.press("Control+V")
        return True
    except Exception:
        return False


def set_direct_browser_monaco_code(page: Any, code: str, run_id: str) -> bool:
    script = """
    ({ code, run_id }) => {
      const api = window.monaco && window.monaco.editor;
      if (!api) return { ok: false, reason: 'monaco_missing' };
      const editors = typeof api.getEditors === 'function' ? api.getEditors() : [];
      let editor = editors.find((candidate) => {
        try { return candidate && candidate.hasTextFocus && candidate.hasTextFocus(); }
        catch (_) { return false; }
      });
      if (!editor && editors.length > 0) editor = editors[editors.length - 1];
      if (editor && editor.getModel) {
        const model = editor.getModel();
        if (model && model.setValue && model.getValue) {
          model.setValue(code);
          if (editor.focus) editor.focus();
          return { ok: !run_id || model.getValue().includes(run_id), reason: 'editor_model' };
        }
      }
      const models = typeof api.getModels === 'function' ? api.getModels() : [];
      const target = [...models].reverse().find((model) => {
        try { return !(model.getValue() || '').trim(); }
        catch (_) { return false; }
      }) || models[models.length - 1];
      if (!target || !target.setValue || !target.getValue) {
        return { ok: false, reason: 'model_missing' };
      }
      target.setValue(code);
      return { ok: !run_id || target.getValue().includes(run_id), reason: 'standalone_model' };
    }
    """
    for scope in direct_browser_scopes(page):
        try:
            result = scope.evaluate(script, {"code": code, "run_id": run_id})
        except Exception:
            continue
        if isinstance(result, dict) and result.get("ok"):
            return True
    return False


def build_terminal_python_command(code: str, run_id: str) -> str:
    suffix = safe_segment(run_id or "run", "run").replace("-", "_")
    marker = f"WINSMUX_PY_{suffix}_EOF"
    while marker in code:
        marker += "_X"
    return f"python - <<'{marker}'\n{code}\n{marker}\n"


def open_direct_browser_terminal(page: Any) -> bool:
    candidates = [
        page.get_by_text(re.compile(r"^ターミナル$|^Terminal$", re.I)).last,
        page.get_by_role("button", name=re.compile(r"ターミナル|Terminal", re.I)).last,
    ]
    for locator in candidates:
        try:
            if locator.count() < 1:
                continue
            locator.click(timeout=5000)
            page.wait_for_timeout(1500)
            if direct_browser_terminal_visible(page):
                return True
        except Exception:
            continue
    try:
        viewport = page.viewport_size or {"width": 1280, "height": 720}
        page.mouse.click(145, max(40, viewport["height"] - 20))
        page.wait_for_timeout(1500)
        if direct_browser_terminal_visible(page):
            return True
    except Exception:
        pass
    return False


def direct_browser_terminal_visible(page: Any) -> bool:
    for selector in (".xterm", ".xterm-screen", ".xterm-helper-textarea", "[class*='terminal']"):
        try:
            if page.locator(selector).count() > 0:
                return True
        except Exception:
            continue
    return False


def click_direct_browser_terminal(page: Any) -> bool:
    candidates = [
        page.locator(".xterm-helper-textarea").last,
        page.locator(".xterm-screen").last,
        page.locator("textarea").last,
    ]
    for locator in candidates:
        try:
            if locator.count() < 1:
                continue
            locator.click(timeout=5000)
            return True
        except Exception:
            continue
    return False


def try_direct_browser_terminal(page: Any, code: str, run_id: str, timeout_sec: float, started: float) -> dict[str, Any] | None:
    if os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_TERMINAL", "1").strip().lower() not in (
        "1",
        "true",
        "yes",
        "on",
    ):
        return None
    if not open_direct_browser_terminal(page):
        return None
    if not click_direct_browser_terminal(page):
        return None
    command = build_terminal_python_command(code, run_id)
    if not paste_direct_browser_code(page, command):
        page.keyboard.insert_text(command)
    page.wait_for_timeout(500)
    page.keyboard.press("Enter")
    marker = "winsmux.colab_llm.result.v1"
    echo_deadline = time.monotonic() + 20
    while time.monotonic() < echo_deadline:
        page.wait_for_timeout(1000)
        body_text = read_direct_browser_text(page)
        if run_id in body_text or "WINSMUX_PY_" in body_text or "python -" in body_text:
            break
    else:
        return None
    while time.monotonic() - started < timeout_sec:
        page.wait_for_timeout(5000)
        body_text = read_direct_browser_text(page)
        result_json = extract_json_object_containing(body_text, marker, run_id=run_id)
        if result_json is not None:
            return result_json
    return None


def add_direct_browser_code_cell(page: Any) -> None:
    try:
        page.get_by_role("button", name=re.compile(r"(\+ Code|\+ コード|Code|コード)", re.I)).last.click(timeout=5000)
        page.wait_for_timeout(700)
        return
    except Exception:
        pass
    try:
        page.keyboard.press("Escape")
        page.keyboard.press("Control+M")
        page.keyboard.press("B")
        page.wait_for_timeout(700)
    except Exception:
        pass


def insert_direct_browser_code(page: Any, code: str, run_id: str) -> None:
    for attempt in range(3):
        if attempt > 0:
            add_direct_browser_code_cell(page)
        if set_direct_browser_monaco_code(page, code, run_id):
            return
        if not click_direct_browser_editor(page):
            page.mouse.click(180, 145 + (attempt * 50))
        page.wait_for_timeout(300)
        try:
            page.keyboard.press("Control+A")
            page.wait_for_timeout(150)
            page.keyboard.press("Backspace")
            page.wait_for_timeout(150)
        except Exception:
            pass
        if not paste_direct_browser_code(page, code):
            page.keyboard.insert_text(code)
        page.wait_for_timeout(1500)
        if not run_id or run_id in read_direct_browser_text(page):
            return
    raise RuntimeError("direct browser code editor did not accept the run payload")


def direct_browser_dry_payload(stdout: str, selected_mode: str, verify_kernel_bind: bool) -> dict[str, Any]:
    result = extract_json_object_containing(stdout, "winsmux.colab_llm.result.v1")
    ok = result is not None and str(result.get("status", "succeeded")) == "succeeded"
    payload: dict[str, Any] = {
        "mode": selected_mode,
        "ok": ok,
        "stdout": stdout,
        "cell_id": "direct-browser-dry-run",
        "notebook_url": "about:blank",
        "kernel_bind_ok": not verify_kernel_bind or ok,
        "kernel_bind_detail": "direct browser dry run",
    }
    if selected_mode == "execute_with_evidence":
        payload["evidence"] = {
            "stdout": stdout,
            "cell_id": "direct-browser-dry-run",
            "notebook_url": "about:blank",
            "kernel_bind_ok": payload["kernel_bind_ok"],
            "gpu": None,
        }
    if not ok:
        error_message = (
            "direct browser dry run did not contain result marker"
            if result is None
            else str(result.get("error") or stdout.strip() or "direct browser dry run failed")
        )
        payload["error"] = error_message
        payload["stdout"] = f"{error_message}\n{stdout}".strip()
    return payload


def direct_browser_execute(plan_text: str, selected_mode: str, verify_kernel_bind: bool) -> dict[str, Any]:
    append_progress("direct_browser_enter")
    dry_stdout = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_DRY_STDOUT", "")
    if dry_stdout:
        append_progress("direct_browser_dry_run")
        return direct_browser_dry_payload(dry_stdout, selected_mode, verify_kernel_bind)

    append_progress("direct_browser_import_colab_modules")
    import colab_llm_mcp.colab_playwright as colab_playwright
    import colab_llm_mcp.execute as execute_mod

    if selected_mode == "plan_only":
        append_progress("direct_browser_plan_only")
        return {"ok": True, **execute_mod.plan_only_result(plan_text)}

    append_progress("direct_browser_extract_plan")
    code = execute_mod.extract_plan_code(plan_text)
    notebook_url = execute_mod.resolve_colab_notebook_url()
    run_id_match = re.search(r'"--run-id"\s*,\s*"([^"]+)"', code)
    run_id = run_id_match.group(1) if run_id_match else ""
    profile = colab_playwright.resolve_playwright_profile_dir(None)
    profile.mkdir(parents=True, exist_ok=True)
    state_root = colab_playwright.repo_root() / ".colab"
    state_root.mkdir(parents=True, exist_ok=True)
    screenshot_path = state_root / "direct-browser-last.png"
    lock_path = state_root / "winsmux-direct-browser.lock"
    timeout_sec = read_positive_float_env("WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_TIMEOUT_SEC", DEFAULT_EXECUTE_TIMEOUT_SEC)
    lock_timeout_sec = read_positive_float_env("WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_LOCK_TIMEOUT_SEC", 1200.0)
    headless = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_HEADLESS", "0").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )
    channel = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_CHANNEL", "").strip()
    gpu_label = colab_playwright.resolve_gpu_label(
        os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU", "").strip()
        or os.environ.get("COLAB_PLAYWRIGHT_GPU", "").strip()
        or "A100"
    )
    set_gpu = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER_SET_GPU", "0").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )
    handle: int | None = None
    playwright = None
    context = None
    started = time.monotonic()
    try:
        append_progress("direct_browser_acquire_lock")
        handle = acquire_direct_browser_lock(lock_path, lock_timeout_sec)
        append_progress("direct_browser_start_playwright")
        playwright = colab_playwright._require_playwright()().start()
        launch_kwargs: dict[str, Any] = {
            "user_data_dir": str(profile),
            "headless": headless,
            "args": [
                "--disable-blink-features=AutomationControlled",
                "--disable-session-crashed-bubble",
                "--disable-infobars",
                "--no-first-run",
            ],
        }
        if channel:
            launch_kwargs["channel"] = channel
        append_progress("direct_browser_launch_browser", f"headless={headless} channel={channel or 'default'}")
        context = playwright.chromium.launch_persistent_context(**launch_kwargs)
        try:
            context.grant_permissions(["clipboard-read", "clipboard-write"], origin="https://colab.research.google.com")
        except Exception:
            pass
        page = context.pages[0] if context.pages else context.new_page()
        append_progress("direct_browser_open_notebook")
        page.goto(notebook_url, wait_until="domcontentloaded", timeout=120000)
        append_progress("direct_browser_wait_colab_ready")
        colab_playwright._wait_until_colab_ready(page, login_wait_sec=300)
        append_progress("direct_browser_colab_ready")
        colab_playwright._dismiss_overlays(page)
        if set_gpu:
            append_progress("direct_browser_set_gpu", gpu_label)
            colab_playwright._set_gpu_runtime(page, gpu_label)
        try:
            append_progress("direct_browser_connect_runtime")
            colab_playwright._connect_runtime_if_needed(page)
            append_progress("direct_browser_runtime_connect_attempted")
        except Exception:
            append_progress("direct_browser_runtime_connect_ignored_error")
            pass
        marker = "winsmux.colab_llm.result.v1"
        append_progress("direct_browser_try_terminal")
        terminal_result = try_direct_browser_terminal(page, code, run_id, timeout_sec, started)
        if terminal_result is not None:
            append_progress("direct_browser_terminal_result")
            stdout = json.dumps(terminal_result, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            ok = str(terminal_result.get("status", "succeeded")) == "succeeded"
            payload: dict[str, Any] = {
                "mode": selected_mode,
                "ok": ok,
                "stdout": stdout,
                "cell_id": "direct-browser-terminal",
                "notebook_url": notebook_url,
                "kernel_bind_ok": ok or not verify_kernel_bind,
                "kernel_bind_detail": "direct browser terminal output marker observed",
            }
            if selected_mode == "execute_with_evidence":
                payload["evidence"] = execute_mod.build_execution_evidence(
                    stdout=stdout,
                    cell_id="direct-browser-terminal",
                    notebook_url=notebook_url,
                    kernel_bind_ok=payload["kernel_bind_ok"],
                    gpu=execute_mod.parse_gpu_from_text(stdout),
                )
            if not ok:
                payload["error"] = stdout
            return payload
        try:
            append_progress("direct_browser_open_code_cell")
            colab_playwright._click_first_visible(
                page,
                [
                    page.get_by_text(re.compile(r"コーディングを開始|Start coding", re.I)),
                    page.get_by_role("button", name=re.compile(r"(\+ Code|\+ コード|Code|コード)", re.I)),
                ],
                timeout_ms=15000,
            )
        except Exception:
            append_progress("direct_browser_open_code_cell_ignored_error")
            pass
        page.wait_for_timeout(1000)
        append_progress("direct_browser_insert_code")
        insert_direct_browser_code(page, code, run_id)
        append_progress("direct_browser_run_code")
        worker_stage_not_before = datetime.now(timezone.utc)
        page.keyboard.press("Control+Enter")
        body_text = ""
        last_wait_progress = 0.0
        seen_worker_stage_lines: set[str] = set()
        while time.monotonic() - started < timeout_sec:
            page.wait_for_timeout(5000)
            body_text = read_direct_browser_text(page)
            for worker_stage in extract_worker_stage_lines(body_text, not_before_utc=worker_stage_not_before):
                if worker_stage in seen_worker_stage_lines:
                    continue
                seen_worker_stage_lines.add(worker_stage)
                append_progress("direct_browser_worker_stage", worker_stage)
            elapsed = time.monotonic() - started
            if elapsed - last_wait_progress >= 30:
                last_wait_progress = elapsed
                append_progress("direct_browser_wait_output", f"elapsed_seconds={elapsed:.0f}")
            result_json = extract_json_object_containing(body_text, marker, run_id=run_id)
            if result_json is not None:
                append_progress("direct_browser_output_marker_found")
                stdout = json.dumps(result_json, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
                ok = str(result_json.get("status", "succeeded")) == "succeeded"
                payload: dict[str, Any] = {
                    "mode": selected_mode,
                    "ok": ok,
                    "stdout": stdout,
                    "cell_id": "direct-browser",
                    "notebook_url": notebook_url,
                    "kernel_bind_ok": ok or not verify_kernel_bind,
                    "kernel_bind_detail": "direct browser code cell output marker observed",
                }
                if selected_mode == "execute_with_evidence":
                    payload["evidence"] = execute_mod.build_execution_evidence(
                        stdout=stdout,
                        cell_id="direct-browser",
                        notebook_url=notebook_url,
                        kernel_bind_ok=payload["kernel_bind_ok"],
                        gpu=execute_mod.parse_gpu_from_text(stdout),
                    )
                if not ok:
                    payload["error"] = stdout
                return payload
        append_progress("direct_browser_output_marker_missing")
        page.screenshot(path=str(screenshot_path), full_page=True)
        return {
            "mode": selected_mode,
            "ok": False,
            "error": "direct browser output marker not found",
            "stdout_tail": body_text[-4000:],
            "cell_id": "direct-browser",
            "notebook_url": notebook_url,
            "screenshot": str(screenshot_path),
            "kernel_bind_ok": False,
            "kernel_bind_detail": "direct browser output marker not found",
        }
    finally:
        try:
            if context is not None:
                append_progress("direct_browser_close_context")
                context.close()
        finally:
            try:
                if playwright is not None:
                    append_progress("direct_browser_stop_playwright")
                    playwright.stop()
            finally:
                append_progress("direct_browser_release_lock")
                release_direct_browser_lock(lock_path, handle)


def execute_plan(colab_repo: Path, plan_text: str, mode: str) -> tuple[int, str, str]:
    code = (
        "import atexit, inspect, json, math, os, re, sys, threading, time\n"
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
        "def _bool_env(name, default=False):\n"
        "    raw = os.environ.get(name, '').strip().lower()\n"
        "    if not raw:\n"
        "        return default\n"
        "    return raw in ('1', 'true', 'yes', 'on')\n"
        "_winsmux_playwright_keepalive = []\n"
        "def _cleanup_playwright_keepalive():\n"
        "    while _winsmux_playwright_keepalive:\n"
        "        context, playwright = _winsmux_playwright_keepalive.pop()\n"
        "        try:\n"
        "            context.close()\n"
        "        except Exception:\n"
        "            pass\n"
        "        try:\n"
        "            playwright.stop()\n"
        "        except Exception:\n"
        "            pass\n"
        "atexit.register(_cleanup_playwright_keepalive)\n"
        "def _winsmux_playwright_result(ok, message, screenshot=''):\n"
        "    class Result:\n"
        "        pass\n"
        "    result = Result()\n"
        "    result.ok = ok\n"
        "    result.message = message\n"
        "    result.screenshot = screenshot\n"
        "    return result\n"
        "def _winsmux_run_playwright_setup_keepalive(colab_playwright, gpu, headless, login_wait, setup_timeout):\n"
        "    required = ('read_mcp_connect_url', 'resolve_gpu_label', 'resolve_playwright_profile_dir', 'repo_root', '_require_playwright', '_wait_until_colab_ready', '_dismiss_overlays', '_close_stray_colab_tabs', '_click_mcp_connect', '_set_gpu_runtime', '_connect_runtime_if_needed')\n"
        "    if any(not hasattr(colab_playwright, name) for name in required):\n"
        "        return colab_playwright.run_colab_playwright_setup(gpu=gpu, headless=headless, login_wait_sec=login_wait, setup_timeout_sec=setup_timeout)\n"
        "    url = (colab_playwright.read_mcp_connect_url() or '').strip()\n"
        "    if not url or 'mcpProxyToken=' not in url:\n"
        "        return _winsmux_playwright_result(False, 'Missing MCP connect URL')\n"
        "    gpu_label = colab_playwright.resolve_gpu_label(gpu)\n"
        "    profile = colab_playwright.resolve_playwright_profile_dir(None)\n"
        "    profile.mkdir(parents=True, exist_ok=True)\n"
        "    channel = os.environ.get('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_CHANNEL', '').strip()\n"
        "    screenshot_dir = colab_playwright.repo_root() / '.colab'\n"
        "    screenshot_dir.mkdir(parents=True, exist_ok=True)\n"
        "    screenshot_path = screenshot_dir / 'playwright-setup-last.png'\n"
        "    playwright = None\n"
        "    context = None\n"
        "    started = time.monotonic()\n"
        "    try:\n"
        "        playwright = colab_playwright._require_playwright()().start()\n"
        "        launch_kwargs = {'user_data_dir': str(profile), 'headless': headless, 'args': ['--disable-blink-features=AutomationControlled']}\n"
        "        if channel:\n"
        "            launch_kwargs['channel'] = channel\n"
        "        context = playwright.chromium.launch_persistent_context(**launch_kwargs)\n"
        "        page = context.pages[0] if context.pages else context.new_page()\n"
        "        print('[pw] Navigating to pinned notebook + MCP token…', flush=True)\n"
        "        page.goto(url, wait_until='domcontentloaded', timeout=120000)\n"
        "        colab_playwright._wait_until_colab_ready(page, login_wait_sec=login_wait)\n"
        "        colab_playwright._dismiss_overlays(page)\n"
        "        colab_playwright._close_stray_colab_tabs(context, page)\n"
        "        print('[pw] Clicking MCP Connect…', flush=True)\n"
        "        if not colab_playwright._click_mcp_connect(page):\n"
        "            page.screenshot(path=str(screenshot_path), full_page=True)\n"
        "            return _winsmux_playwright_result(False, 'MCP Connect dialog/button not found', str(screenshot_path))\n"
        "        page.wait_for_timeout(2000)\n"
        "        print(f'[pw] Runtime → Change runtime type → {gpu_label} GPU → Save…', flush=True)\n"
        "        colab_playwright._set_gpu_runtime(page, gpu_label)\n"
        "        print('[pw] Connecting runtime if disconnected…', flush=True)\n"
        "        colab_playwright._connect_runtime_if_needed(page)\n"
        "        page.wait_for_timeout(4000)\n"
        "        print('[pw] Re-opening MCP Connect after runtime changes…', flush=True)\n"
        "        page.goto(url.split('#', 1)[0], wait_until='domcontentloaded', timeout=120000)\n"
        "        page.wait_for_timeout(1000)\n"
        "        page.goto(url, wait_until='domcontentloaded', timeout=120000)\n"
        "        colab_playwright._wait_until_colab_ready(page, login_wait_sec=login_wait)\n"
        "        colab_playwright._dismiss_overlays(page)\n"
        "        if not colab_playwright._click_mcp_connect(page):\n"
        "            _stage('mcp_connect_reopen_missing')\n"
        "        else:\n"
        "            _stage('mcp_connect_reopen_clicked')\n"
        "        page.wait_for_timeout(4000)\n"
        "        remaining = setup_timeout - (time.monotonic() - started)\n"
        "        wait_ms = max(5000, int(min(60000, remaining) * 1000))\n"
        "        page.wait_for_timeout(min(wait_ms, 30000))\n"
        "        page.screenshot(path=str(screenshot_path), full_page=True)\n"
        "        if time.monotonic() - started > setup_timeout:\n"
        "            return _winsmux_playwright_result(False, 'Playwright setup timed out', str(screenshot_path))\n"
        "        _winsmux_playwright_keepalive.append((context, playwright))\n"
        "        return _winsmux_playwright_result(True, f'Playwright setup done ({gpu_label} GPU, MCP Connect attempted; browser kept alive)', str(screenshot_path))\n"
        "    except BaseException as exc:\n"
        "        try:\n"
        "            if context is not None:\n"
        "                context.close()\n"
        "        except Exception:\n"
        "            pass\n"
        "        try:\n"
        "            if playwright is not None:\n"
        "                playwright.stop()\n"
        "        except Exception:\n"
        "            pass\n"
        "        return _winsmux_playwright_result(False, str(exc), str(screenshot_path))\n"
        "def _maybe_run_playwright_setup():\n"
        "    if not _bool_env('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP', False):\n"
        "        return\n"
        "    _stage('playwright_setup_begin')\n"
        "    holder = {}\n"
        "    def _target():\n"
        "        try:\n"
        "            import colab_llm_mcp.colab_playwright as colab_playwright\n"
        "            gpu = os.environ.get('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_GPU', '').strip() or os.environ.get('COLAB_PLAYWRIGHT_GPU', '').strip() or 'A100'\n"
        "            headless = _bool_env('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_HEADLESS', False)\n"
        "            login_wait = _float_env('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_LOGIN_WAIT_SEC', 300.0)\n"
        "            setup_timeout = _float_env('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_TIMEOUT_SEC', 300.0)\n"
        "            def _winsmux_click_mcp_connect(page):\n"
        "                mcp_pat = re.compile(r'(Connect to a local Colab MCP|local Colab MCP|ローカル Colab MCP)', re.I)\n"
        "                connect_pat = re.compile(r'^(Connect|接続)$', re.I)\n"
        "                try:\n"
        "                    page.get_by_text(mcp_pat).first.wait_for(state='visible', timeout=45000)\n"
        "                except Exception:\n"
        "                    _stage('mcp_connect_dialog_missing')\n"
        "                    return False\n"
        "                selectors = ('div[role=\"dialog\"]', 'colab-dialog', 'paper-dialog', 'mwc-dialog', 'dialog')\n"
        "                for selector in selectors:\n"
        "                    try:\n"
        "                        dialog = page.locator(selector).filter(has_text=mcp_pat).first\n"
        "                        if dialog.is_visible(timeout=3000):\n"
        "                            clicked = colab_playwright._click_first_visible(page, [dialog.get_by_role('button', name=connect_pat), dialog.locator('button').filter(has_text=connect_pat), dialog.locator('[role=\"button\"]').filter(has_text=connect_pat)], timeout_ms=15000)\n"
        "                            if clicked:\n"
        "                                _stage('mcp_connect_dialog_clicked')\n"
        "                                return True\n"
        "                    except Exception:\n"
        "                        pass\n"
        "                try:\n"
        "                    clicked_dom = page.evaluate(\"\"\"\n"
        "() => {\n"
        "  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();\n"
        "  const textRe = /(Connect to a local Colab MCP|local Colab MCP|ローカル Colab MCP)/i;\n"
        "  const buttonRe = /^(Connect|接続)$/i;\n"
        "  const collect = (root, out = []) => {\n"
        "    if (!root) return out;\n"
        "    const nodes = root.querySelectorAll ? Array.from(root.querySelectorAll('*')) : [];\n"
        "    for (const node of nodes) {\n"
        "      out.push(node);\n"
        "      if (node.shadowRoot) collect(node.shadowRoot, out);\n"
        "    }\n"
        "    return out;\n"
        "  };\n"
        "  const visible = (el) => {\n"
        "    const rect = el.getBoundingClientRect();\n"
        "    const style = window.getComputedStyle(el);\n"
        "    return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';\n"
        "  };\n"
        "  const all = collect(document).filter(visible);\n"
        "  const mcpItems = all\n"
        "    .map((el) => ({ el, rect: el.getBoundingClientRect(), text: normalize(el.innerText || el.textContent) }))\n"
        "    .filter((item) => textRe.test(item.text));\n"
        "  if (mcpItems.length < 1) return false;\n"
        "  const mcpBox = mcpItems.sort((a, b) => (a.rect.width * a.rect.height) - (b.rect.width * b.rect.height))[0].rect;\n"
        "  const buttons = all\n"
        "    .map((el) => ({ el, rect: el.getBoundingClientRect(), text: normalize(el.innerText || el.textContent), tag: String(el.tagName || '').toLowerCase(), role: el.getAttribute('role') || '' }))\n"
        "    .filter((item) => buttonRe.test(item.text))\n"
        "    .filter((item) => item.tag.includes('button') || item.role === 'button' || item.el.tabIndex >= 0)\n"
        "    .filter((item) => Math.abs((item.rect.left + item.rect.right) / 2 - (mcpBox.left + mcpBox.right) / 2) < 420)\n"
        "    .filter((item) => item.rect.top >= mcpBox.top - 40 && item.rect.top <= mcpBox.bottom + 260)\n"
        "    .sort((a, b) => Math.abs(a.rect.top - mcpBox.bottom) - Math.abs(b.rect.top - mcpBox.bottom));\n"
        "  if (buttons.length < 1) return false;\n"
        "  buttons[0].el.click();\n"
        "  return true;\n"
        "}\n"
        "\"\"\")\n"
        "                    if clicked_dom:\n"
        "                        _stage('mcp_connect_shadow_dom_clicked')\n"
        "                        return True\n"
        "                except Exception:\n"
        "                    pass\n"
        "                _stage('mcp_connect_button_missing')\n"
        "                return False\n"
        "            colab_playwright._click_mcp_connect = _winsmux_click_mcp_connect\n"
        "            def _winsmux_connect_runtime_if_needed(page):\n"
        "                connect_pat = re.compile(r'^(Connect|接続)$', re.I)\n"
        "                clicked_direct = colab_playwright._click_first_visible(page, [page.get_by_role('button', name=connect_pat), page.locator('div[role=\"button\"]').filter(has_text=connect_pat), page.locator('span').filter(has_text=connect_pat)], timeout_ms=12000)\n"
        "                if clicked_direct:\n"
        "                    page.wait_for_timeout(15000)\n"
        "                    return\n"
        "                try:\n"
        "                    viewport = page.viewport_size or {}\n"
        "                    width = int(viewport.get('width') or page.evaluate('window.innerWidth'))\n"
        "                    page.mouse.click(max(0, width - 120), 84)\n"
        "                    page.wait_for_timeout(20000)\n"
        "                    return\n"
        "                except Exception:\n"
        "                    pass\n"
        "                runtime_pat = re.compile(r'^(Runtime|ランタイム)$', re.I)\n"
        "                runtime_items = [page.get_by_role('menuitem', name=runtime_pat), page.get_by_text(runtime_pat)]\n"
        "                if colab_playwright._click_first_visible(page, runtime_items, timeout_ms=4000):\n"
        "                    colab_playwright._click_first_visible(page, [page.get_by_role('menuitem', name=connect_pat), page.get_by_text(connect_pat)], timeout_ms=6000)\n"
        "            colab_playwright._connect_runtime_if_needed = _winsmux_connect_runtime_if_needed\n"
        "            result = _winsmux_run_playwright_setup_keepalive(colab_playwright, gpu, headless, login_wait, setup_timeout)\n"
        "            holder['ok'] = bool(getattr(result, 'ok', False))\n"
        "            holder['message'] = str(getattr(result, 'message', ''))\n"
        "            holder['screenshot'] = str(getattr(result, 'screenshot', '') or '')\n"
        "        except BaseException as exc:\n"
        "            holder['error'] = exc\n"
        "    timeout_budget = _float_env('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_THREAD_TIMEOUT_SEC', _float_env('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_TIMEOUT_SEC', 300.0) + 60.0)\n"
        "    thread = threading.Thread(target=_target, name='winsmux-colab-playwright-setup', daemon=True)\n"
        "    thread.start()\n"
        "    thread.join(timeout_budget)\n"
        "    if thread.is_alive():\n"
        "        _stage('playwright_setup_error:TimeoutError')\n"
        "        raise TimeoutError(f'Colab Playwright setup did not finish within {timeout_budget:.0f}s')\n"
        "    if 'error' in holder:\n"
        "        _stage(f\"playwright_setup_error:{type(holder['error']).__name__}\")\n"
        "        raise holder['error']\n"
        "    if not holder.get('ok', False):\n"
        "        _stage('playwright_setup_error:ResultNotOk')\n"
        "        raise RuntimeError('Colab Playwright setup failed: ' + holder.get('message', ''))\n"
        "    _stage('playwright_setup_done')\n"
        "def _install_playwright_proxy_setup():\n"
        "    if pool_mod is None or not _bool_env('WINSMUX_COLAB_CLI_ADAPTER_PLAYWRIGHT_SETUP', False):\n"
        "        return\n"
        "    raw, original = _descriptor_target(pool_mod, 'ensure_proxy_tools')\n"
        "    if original is None or getattr(original, '_winsmux_playwright_wrapped', False):\n"
        "        return\n"
        "    async def wrapped(*args, **kwargs):\n"
        "        _maybe_run_playwright_setup()\n"
        "        if inspect.iscoroutinefunction(original):\n"
        "            return await original(*args, **kwargs)\n"
        "        return original(*args, **kwargs)\n"
        "    wrapped._winsmux_playwright_wrapped = True\n"
        "    try:\n"
        "        wrapped.__signature__ = inspect.signature(original)\n"
        "    except (TypeError, ValueError):\n"
        "        pass\n"
        "    _set_wrapped(pool_mod, 'ensure_proxy_tools', raw, wrapped)\n"
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
        "def _payload_error(message, source, **extra):\n"
        "    payload = {'ok': False, 'error': message, 'source': source}\n"
        "    payload.update(extra)\n"
        "    return payload\n"
        "def _normalize_payload(payload, source):\n"
        "    if isinstance(payload, dict):\n"
        "        return payload\n"
        "    if isinstance(payload, str):\n"
        "        text = payload.strip()\n"
        "        if not text:\n"
        "            _stage(f'{source}_payload_normalize_error:empty_string')\n"
        "            return _payload_error('invalid safe executor result type: empty string', source, result_type='str')\n"
        "        try:\n"
        "            parsed = json.loads(text)\n"
        "        except json.JSONDecodeError:\n"
        "            _stage(f'{source}_payload_normalize_error:json_decode')\n"
        "            return _payload_error('invalid safe executor result type: string is not JSON', source, result_type='str')\n"
        "        if isinstance(parsed, dict):\n"
        "            return parsed\n"
        "        _stage(f'{source}_payload_normalize_error:json_not_object')\n"
        "        return _payload_error('invalid safe executor result type: JSON payload is not an object', source, result_type=type(parsed).__name__)\n"
        "    _stage(f'{source}_payload_normalize_error:{type(payload).__name__}')\n"
        "    return _payload_error('invalid safe executor result type', source, result_type=type(payload).__name__)\n"
        "def _print_payload_and_exit_if_failed(payload):\n"
        "    print(json.dumps(payload, ensure_ascii=False, indent=2))\n"
        "    if not payload.get('ok', True):\n"
        "        sys.exit(1)\n"
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
        "_install_playwright_proxy_setup()\n"
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
        "plan = sys.stdin.read()\n"
        f"proxy_timeout = _float_env('WINSMUX_COLAB_CLI_ADAPTER_PROXY_TIMEOUT_SEC', {DEFAULT_PROXY_TIMEOUT_SEC!r})\n"
        "verify_kernel_bind = os.environ.get('WINSMUX_COLAB_CLI_ADAPTER_VERIFY_KERNEL_BIND', '1').strip().lower() not in ('0', 'false', 'no', 'off')\n"
        "normalized_mode = sys.argv[1].strip().lower()\n"
        "if normalized_mode not in ('plan_only', 'execute', 'execute_with_evidence'):\n"
        "    raise ValueError(f'mode must be plan_only, execute, or execute_with_evidence; got {sys.argv[1]!r}')\n"
        "print('WINSMUX_COLAB_ADAPTER_STAGE execute_plan_begin', file=sys.stderr, flush=True)\n"
        "if _bool_env('WINSMUX_COLAB_CLI_ADAPTER_DIRECT_BROWSER', False):\n"
        "    _stage('direct_browser_begin')\n"
        "    from scripts.google_colab_cli_adapter import direct_browser_execute\n"
        "    payload = direct_browser_execute(plan, normalized_mode, verify_kernel_bind)\n"
        "    _stage('direct_browser_done')\n"
        "    _print_payload_and_exit_if_failed(_normalize_payload(payload, 'direct_browser'))\n"
        "elif _can_use_safe_executor(normalized_mode, verify_kernel_bind):\n"
        "    _stage('safe_executor_begin')\n"
        "    payload = execute_mod.ColabMcpPool.run(_winsmux_execute_plan_async(plan, normalized_mode, proxy_timeout, verify_kernel_bind))\n"
        "    _stage('safe_executor_done')\n"
        "    if inspect.isawaitable(payload):\n"
        "        close = getattr(payload, 'close', None)\n"
        "        if callable(close):\n"
        "            close()\n"
        "        _stage('safe_executor_awaitable_result_fallback')\n"
        "        _print_payload_and_exit_if_failed(_normalize_payload(_execute_llm_plan_compat(plan, normalized_mode, proxy_timeout, verify_kernel_bind), 'safe_executor_fallback'))\n"
        "    else:\n"
        "        _print_payload_and_exit_if_failed(_normalize_payload(payload, 'safe_executor'))\n"
        "else:\n"
        "    _print_payload_and_exit_if_failed(_normalize_payload(_execute_llm_plan_compat(plan, normalized_mode, proxy_timeout, verify_kernel_bind), 'compat_executor'))\n"
        "print('WINSMUX_COLAB_ADAPTER_STAGE execute_plan_done', file=sys.stderr, flush=True)\n"
    )
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUNBUFFERED"] = "1"
    colab_src = str(colab_repo / "src")
    adapter_src = str(repo_root())
    existing_pythonpath = env.get("PYTHONPATH", "").strip()
    pythonpath_parts = [colab_src, adapter_src]
    if existing_pythonpath:
        pythonpath_parts.append(existing_pythonpath)
    env["PYTHONPATH"] = os.pathsep.join(pythonpath_parts)
    command = [*colab_python(colab_repo), "-u", "-c", code, mode]
    timeout_sec = read_positive_float_env("WINSMUX_COLAB_CLI_ADAPTER_TIMEOUT_SEC", DEFAULT_EXECUTE_TIMEOUT_SEC)
    try:
        proc = subprocess.run(
            command,
            cwd=str(colab_repo),
            env=env,
            text=True,
            encoding="utf-8",
            errors="replace",
            input=plan_text,
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
    redacted_cell_code = build_cell_code(script_path, args.session, args.run_id, redact_script_args(script_args))
    plan_path = output_dir / "colab-adapter-plan.py"
    write_text(plan_path, redacted_cell_code)
    write_text(run_state / "colab-adapter-plan.py", redacted_cell_code)
    progress_path = output_dir / "progress.jsonl"
    write_text(progress_path, "")
    write_text(run_state / "progress.jsonl", "")

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

    previous_progress_path = os.environ.get("WINSMUX_COLAB_CLI_ADAPTER_PROGRESS_PATH")
    os.environ["WINSMUX_COLAB_CLI_ADAPTER_PROGRESS_PATH"] = str(progress_path)
    append_progress("command_run_execute_plan_begin", f"mode={mode}")
    try:
        exit_code, stdout, stderr = execute_plan(colab_repo, cell_code, mode)
        append_progress("command_run_execute_plan_done", f"exit_code={exit_code}")
    finally:
        if previous_progress_path is None:
            os.environ.pop("WINSMUX_COLAB_CLI_ADAPTER_PROGRESS_PATH", None)
        else:
            os.environ["WINSMUX_COLAB_CLI_ADAPTER_PROGRESS_PATH"] = previous_progress_path
    visible_stdout = redact_sensitive_text(parse_colab_stdout(stdout))
    stderr = redact_sensitive_text(stderr)
    write_text(output_dir / "stdout.log", visible_stdout)
    write_text(run_state / "stdout.log", visible_stdout)
    write_text(run_state / "progress.jsonl", progress_path.read_text(encoding="utf-8"))
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
