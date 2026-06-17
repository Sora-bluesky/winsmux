#!/usr/bin/env python3
"""Colab GPU LLM worker for winsmux colab_llm slots."""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import importlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import site
import subprocess
import sys
import time
from typing import Any
import urllib.request


SCHEMA_VERSION = "winsmux.colab_llm.result.v1"
WORKER_SOURCE_REVISION = "colab-llm-vllm-reexec-20260615"
DEFAULT_DRIVE_ROOT = "/content/drive/MyDrive/winsmux-colab-llm"
DEFAULT_RUNTIME_CACHE = "/content/winsmux-runtime-cache"
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
AUTH_BEARER_RE = re.compile(r"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s\"',;}]+")
SECRET_ASSIGNMENT_RE = re.compile(
    r"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|oauth[_-]?token|token|password|secret)\s*[:=]\s*)[^\s\"',;}]+"
)
DRIVE_PATH_RE = re.compile(r"/content/drive/(?:MyDrive|Shareddrives)/[^\s\"']+")
COLAB_TOKEN_RE = re.compile(r"mcpProxyToken=[^&\s\"']+", re.IGNORECASE)


class InputError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def emit_stage(stage: str, **detail: Any) -> None:
    payload: dict[str, Any] = {
        "at": utc_now(),
        "stage": stage,
    }
    if detail:
        payload["detail"] = detail
    print(
        "WINSMUX_COLAB_LLM_STAGE " + json.dumps(payload, ensure_ascii=False, sort_keys=True),
        flush=True,
    )


def read_json(path: str, inline: str = "") -> dict[str, Any]:
    if inline:
        raw = inline
    elif path:
        try:
            raw = Path(path).read_text(encoding="utf-8")
        except OSError as exc:
            raise InputError("task_json_read_failed", str(exc)) from exc
    else:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise InputError("invalid_task_json", exc.msg) from exc
    if not isinstance(data, dict):
        raise InputError("invalid_task_json", "task JSON must be an object")
    return data


def text_at(data: dict[str, Any], *names: str, default: str = "") -> str:
    for name in names:
        value = data.get(name)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return default


def safe_id(value: str, fallback: str) -> str:
    text = (value or fallback).strip()
    if not SAFE_ID_RE.match(text):
        raise InputError("invalid_id", "ids must start with an ASCII letter or digit and contain only letters, digits, '.', '_' or '-'")
    return text


def ensure_colab_path(path: str, label: str) -> str:
    text = (path or "").strip().rstrip("/")
    if not text.startswith("/content/drive/MyDrive/") and not text.startswith("/content/drive/Shareddrives/"):
        raise InputError(f"{label}_not_drive", f"{label} must be under /content/drive/MyDrive or /content/drive/Shareddrives")
    return text


def ensure_runtime_cache(path: str) -> str:
    text = (path or DEFAULT_RUNTIME_CACHE).strip().rstrip("/")
    if not text.startswith(DEFAULT_RUNTIME_CACHE):
        raise InputError("runtime_cache_not_scoped", "runtime cache must stay under /content/winsmux-runtime-cache")
    return text


def configure_cache(task: dict[str, Any]) -> dict[str, str]:
    storage = task.get("storage") if isinstance(task.get("storage"), dict) else {}
    drive_root = ensure_colab_path(str(storage.get("drive_root") or DEFAULT_DRIVE_ROOT), "drive_root")
    model_root = ensure_colab_path(str(storage.get("model_root") or f"{drive_root}/models"), "model_root")
    hf_cache = ensure_colab_path(str(storage.get("hf_cache_root") or f"{drive_root}/hf-cache"), "hf_cache_root")
    artifact_root = ensure_colab_path(str(storage.get("artifact_root") or f"{drive_root}/artifacts"), "artifact_root")
    runtime_cache = ensure_runtime_cache(str(storage.get("runtime_cache_root") or DEFAULT_RUNTIME_CACHE))

    env = {
        "HF_HOME": hf_cache,
        "HF_HUB_CACHE": hf_cache,
        "TRANSFORMERS_CACHE": hf_cache,
        "XDG_CACHE_HOME": hf_cache,
        "WINSMUX_COLAB_LLM_MODEL_ROOT": model_root,
        "WINSMUX_COLAB_LLM_ARTIFACT_ROOT": artifact_root,
        "WINSMUX_COLAB_LLM_RUNTIME_CACHE": runtime_cache,
    }
    os.environ.update(env)
    for folder in (model_root, hf_cache, artifact_root, runtime_cache):
        Path(folder).mkdir(parents=True, exist_ok=True)
    return {
        "drive_root": drive_root,
        "model_root": model_root,
        "hf_cache_root": hf_cache,
        "artifact_root": artifact_root,
        "runtime_cache_root": runtime_cache,
    }


def detect_gpu_from_nvidia_smi() -> dict[str, Any]:
    nvidia_smi = shutil.which("nvidia-smi") or "nvidia-smi"
    try:
        completed = subprocess.run(
            [nvidia_smi, "--query-gpu=name", "--format=csv,noheader"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"available": False, "name": "", "count": 0, "source": "nvidia-smi"}
    if completed.returncode != 0:
        return {"available": False, "name": "", "count": 0, "source": "nvidia-smi"}
    names = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if not names:
        return {"available": False, "name": "", "count": 0, "source": "nvidia-smi"}
    return {"available": True, "name": names[0], "count": len(names), "source": "nvidia-smi"}


def detect_gpu() -> dict[str, Any]:
    smi = detect_gpu_from_nvidia_smi()
    if smi.get("available"):
        return smi
    try:
        import torch  # type: ignore

        if not torch.cuda.is_available():
            return {"available": False, "name": "", "count": 0, "source": "torch"}
        return {
            "available": True,
            "name": torch.cuda.get_device_name(0),
            "count": int(torch.cuda.device_count()),
            "source": "torch",
        }
    except Exception as exc:  # pragma: no cover - depends on Colab runtime
        return {"available": False, "name": "", "count": 0, "source": "torch", "error": str(exc)}


def bool_env(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


def positive_float_env(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def text_tail(value: str, max_chars: int = 1200) -> str:
    text = value or ""
    return text[-max_chars:]


def redact_sensitive_text(value: str) -> str:
    text = str(value or "")
    text = EMAIL_RE.sub("[EMAIL_REDACTED]", text)
    text = COLAB_TOKEN_RE.sub("mcpProxyToken=[REDACTED]", text)
    text = AUTH_BEARER_RE.sub(r"\1[REDACTED]", text)
    text = SECRET_ASSIGNMENT_RE.sub(r"\1[REDACTED]", text)
    text = DRIVE_PATH_RE.sub("[DRIVE_PATH_REDACTED]", text)
    return text


def classify_worker_exception(exc: BaseException) -> str:
    text = str(exc).lower()
    if "gated repo" in text or ("401 client error" in text and "restricted" in text):
        return "model_access_denied"
    if "not enough memory" in text or "out of memory" in text or "cuda out of memory" in text:
        return "gpu_memory_exhausted"
    if "huggingface" in text or "hugging face" in text:
        return "model_download_failed"
    return "worker_exception"


def python_package_roots() -> list[Path]:
    roots: list[Path] = []
    candidates = list(sys.path)
    try:
        candidates.extend(site.getsitepackages())
    except Exception:
        pass
    try:
        candidates.append(site.getusersitepackages())
    except Exception:
        pass
    seen: set[str] = set()
    for raw in candidates:
        if not raw:
            continue
        path = Path(raw)
        try:
            resolved = str(path.resolve())
        except OSError:
            resolved = str(path)
        if resolved in seen or not path.exists():
            continue
        seen.add(resolved)
        roots.append(path)
    return roots


def preload_nvidia_runtime_libraries() -> int:
    if not bool_env("WINSMUX_COLAB_LLM_PRELOAD_NVIDIA_LIBS", True):
        return 0
    patterns = (
        "nvidia/cuda_runtime/lib/libcudart.so*",
        "nvidia/cuda_nvrtc/lib/libnvrtc.so*",
    )
    loaded = 0
    seen: set[str] = set()
    for root in python_package_roots():
        for pattern in patterns:
            for lib_path in sorted(root.glob(pattern), reverse=True):
                key = str(lib_path)
                if key in seen or not lib_path.is_file():
                    continue
                seen.add(key)
                try:
                    ctypes.CDLL(key, mode=ctypes.RTLD_GLOBAL)
                    loaded += 1
                except OSError:
                    continue
    return loaded


def prepare_torch_cuda_runtime() -> bool:
    try:
        import torch  # type: ignore

        try:
            if torch.cuda.is_available():
                _ = torch.cuda.current_device()
        except Exception:
            pass
        return True
    except Exception:
        return False


def resolve_uv_torch_backend() -> str:
    override = os.environ.get("WINSMUX_COLAB_LLM_UV_TORCH_BACKEND", "").strip().lower()
    if override:
        return override
    try:
        import torch  # type: ignore

        cuda_version = str(getattr(torch.version, "cuda", "") or "").strip()
    except Exception:
        cuda_version = ""
    match = re.match(r"^(\d+)\.(\d+)", cuda_version)
    if not match:
        return "auto"
    major, minor = match.groups()
    return f"cu{major}{minor}"


def resolve_vllm_cuda_version() -> str:
    override = os.environ.get("WINSMUX_COLAB_LLM_VLLM_CUDA_VERSION", "").strip().lower()
    if override:
        return override.removeprefix("cu")
    return os.environ.get("WINSMUX_COLAB_LLM_DEFAULT_VLLM_CUDA_VERSION", "129").strip().lower().removeprefix("cu") or "129"


def resolve_vllm_version() -> str:
    override = os.environ.get("WINSMUX_COLAB_LLM_VLLM_VERSION", "").strip()
    if override:
        return override.removeprefix("v")
    url = os.environ.get(
        "WINSMUX_COLAB_LLM_VLLM_RELEASE_API",
        "https://api.github.com/repos/vllm-project/vllm/releases/latest",
    )
    with urllib.request.urlopen(url, timeout=20) as response:  # nosec B310 - fixed public GitHub API by default
        payload = json.loads(response.read().decode("utf-8"))
    tag = str(payload.get("tag_name") or "").strip()
    if not tag:
        raise InputError("vllm_version_unresolved", "failed to resolve latest vLLM release tag")
    return tag.removeprefix("v")


def resolve_vllm_arch() -> str:
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return "x86_64"
    if machine in ("aarch64", "arm64"):
        return "aarch64"
    raise InputError("vllm_arch_unsupported", f"unsupported vLLM wheel architecture: {machine}")


def resolve_vllm_wheel_url(version: str, cuda_version: str, arch: str) -> str:
    template = os.environ.get("WINSMUX_COLAB_LLM_VLLM_WHEEL_URL_TEMPLATE", "").strip()
    if template:
        return template.format(version=version, cuda=cuda_version, arch=arch)
    api_template = os.environ.get(
        "WINSMUX_COLAB_LLM_VLLM_RELEASE_TAG_API_TEMPLATE",
        "https://api.github.com/repos/vllm-project/vllm/releases/tags/v{version}",
    )
    url = api_template.format(version=version)
    with urllib.request.urlopen(url, timeout=20) as response:  # nosec B310 - fixed public GitHub API by default
        payload = json.loads(response.read().decode("utf-8"))
    expected = f"vllm-{version}+cu{cuda_version}-cp38-abi3-"
    for asset in payload.get("assets", []):
        if not isinstance(asset, dict):
            continue
        name = str(asset.get("name") or "")
        download_url = str(asset.get("browser_download_url") or "")
        if name.startswith(expected) and name.endswith(f"_{arch}.whl") and download_url:
            return download_url
    raise InputError("vllm_wheel_not_found", f"vLLM wheel for cu{cuda_version}/{arch} was not found in release v{version}")


def import_vllm_with_preload() -> tuple[Any, Any, int]:
    prepare_torch_cuda_runtime()
    try:
        from vllm import LLM, SamplingParams  # type: ignore

        return LLM, SamplingParams, 0
    except Exception as first_exc:
        loaded = preload_nvidia_runtime_libraries()
        if loaded <= 0:
            raise
        importlib.invalidate_caches()
        prepare_torch_cuda_runtime()
        try:
            from vllm import LLM, SamplingParams  # type: ignore

            return LLM, SamplingParams, loaded
        except Exception as second_exc:
            raise RuntimeError(f"{second_exc} (nvidia_runtime_libs_preloaded={loaded})") from first_exc


def clear_imported_modules(prefixes: tuple[str, ...]) -> None:
    for name in list(sys.modules.keys()):
        if any(name == prefix or name.startswith(f"{prefix}.") for prefix in prefixes):
            sys.modules.pop(name, None)


def reexec_after_vllm_install_if_needed(install_mode: str, completed_steps: int) -> None:
    if not bool_env("WINSMUX_COLAB_LLM_REEXEC_AFTER_INSTALL", True):
        return
    if os.environ.get("WINSMUX_COLAB_LLM_REEXECED", "").strip() == "1":
        return
    emit_stage("reexec_after_vllm_install", install_mode=install_mode, completed_steps=completed_steps)
    os.environ["WINSMUX_COLAB_LLM_REEXECED"] = "1"
    os.environ["WINSMUX_COLAB_LLM_REEXEC_INSTALL_MODE"] = install_mode
    os.environ["WINSMUX_COLAB_LLM_REEXEC_INSTALL_STEPS"] = str(completed_steps)
    os.execv(sys.executable, [sys.executable, *sys.argv])


def build_vllm_install_commands() -> tuple[list[list[str]], str]:
    raw_mode = os.environ.get("WINSMUX_COLAB_LLM_VLLM_INSTALL_MODE", "uv-wheel")
    mode = raw_mode.strip().lower()
    force_reinstall = bool_env("WINSMUX_COLAB_LLM_VLLM_FORCE_REINSTALL_ON_IMPORT_FAILURE", True)

    if mode in ("uv-auto", "uv-wheel"):
        uv_runner = [shutil.which("uv") or sys.executable]
        if uv_runner == [sys.executable]:
            uv_runner.extend(["-m", "uv"])
        if mode == "uv-wheel":
            cuda_version = resolve_vllm_cuda_version()
            version = resolve_vllm_version()
            wheel_url = resolve_vllm_wheel_url(version, cuda_version, resolve_vllm_arch())
            command = uv_runner + [
                "pip",
                "install",
                "--system",
                "-U",
                wheel_url,
                "--extra-index-url",
                f"https://download.pytorch.org/whl/cu{cuda_version}",
                "--index-strategy",
                os.environ.get("WINSMUX_COLAB_LLM_UV_INDEX_STRATEGY", "unsafe-best-match").strip()
                or "unsafe-best-match",
            ]
        else:
            torch_backend = resolve_uv_torch_backend()
            command = uv_runner + ["pip", "install", "--system", "-U", "vllm", f"--torch-backend={torch_backend}"]
        if force_reinstall:
            command.append("--reinstall-package=vllm")
        commands = [[sys.executable, "-m", "pip", "install", "-q", "uv"], command]
        if bool_env("WINSMUX_COLAB_LLM_UPGRADE_PILLOW", True):
            commands.append([sys.executable, "-m", "pip", "install", "-q", "-U", "Pillow"])
        if bool_env("WINSMUX_COLAB_LLM_INSTALL_CUDA13_RUNTIME", False):
            commands.append(
                [
                    sys.executable,
                    "-m",
                    "pip",
                    "install",
                    "-q",
                    "nvidia-cuda-runtime-cu13",
                    "nvidia-cuda-nvrtc-cu13",
                ]
            )
    elif mode == "pip-cu129":
        extra_index = os.environ.get(
            "WINSMUX_COLAB_LLM_VLLM_PIP_EXTRA_INDEX_URL",
            "https://download.pytorch.org/whl/cu129",
        ).strip()
        command = [sys.executable, "-m", "pip", "install", "-q", "vllm", "--extra-index-url", extra_index]
        if force_reinstall:
            command.extend(["--upgrade", "--force-reinstall"])
        commands = [command]
    elif mode == "pip":
        command = [sys.executable, "-m", "pip", "install", "-q", "vllm"]
        if force_reinstall:
            command.extend(["--upgrade", "--force-reinstall"])
        commands = [command]
    else:
        raise InputError(
            "vllm_install_mode_invalid",
            f"Unsupported WINSMUX_COLAB_LLM_VLLM_INSTALL_MODE: {raw_mode}",
        )
    return commands, mode


def ensure_vllm(worker_id: str = "", model_id: str = "") -> tuple[Any, Any, dict[str, Any]]:
    emit_stage("vllm_import_begin", worker_id=worker_id, model_id=model_id)
    try:
        LLM, SamplingParams, preloaded = import_vllm_with_preload()
        emit_stage(
            "vllm_import_ready",
            worker_id=worker_id,
            model_id=model_id,
            installed=False,
            nvidia_runtime_libs_preloaded=preloaded,
        )

        return LLM, SamplingParams, {
            "vllm_install_seconds": 0.0,
            "vllm_installed": False,
            "nvidia_runtime_libs_preloaded": preloaded,
        }
    except Exception as first_exc:  # pragma: no cover - depends on Colab runtime
        if not bool_env("WINSMUX_COLAB_LLM_AUTO_INSTALL_VLLM", True):
            raise InputError("vllm_unavailable", f"vLLM is not importable in this Colab runtime: {first_exc}") from first_exc

    runtime_cache = ensure_runtime_cache(os.environ.get("WINSMUX_COLAB_LLM_RUNTIME_CACHE", DEFAULT_RUNTIME_CACHE))
    pip_cache = Path(runtime_cache) / "pip-cache"
    pip_cache.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["PIP_CACHE_DIR"] = str(pip_cache)
    timeout_sec = positive_float_env("WINSMUX_COLAB_LLM_VLLM_INSTALL_TIMEOUT_SEC", 1200.0)
    started = time.monotonic()
    commands, install_mode = build_vllm_install_commands()
    emit_stage("vllm_install_begin", worker_id=worker_id, model_id=model_id, install_mode=install_mode, steps=len(commands))
    completed_steps = 0
    for command in commands:
        remaining_timeout = max(1.0, timeout_sec - (time.monotonic() - started))
        try:
            completed = subprocess.run(
                command,
                check=False,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=remaining_timeout,
            )
        except subprocess.TimeoutExpired as exc:  # pragma: no cover - depends on network/runtime
            tail = text_tail((exc.stdout or "") + "\n" + (exc.stderr or ""))
            raise InputError(
                "vllm_install_timeout",
                f"vLLM install mode {install_mode} timed out after {timeout_sec:.0f}s. {tail}".strip(),
            ) from exc
        if completed.returncode != 0:
            tail = text_tail((completed.stdout or "") + "\n" + (completed.stderr or ""))
            raise InputError(
                "vllm_install_failed",
                f"vLLM install mode {install_mode} failed with exit code {completed.returncode}. {tail}".strip(),
            )
        completed_steps += 1
        emit_stage(
            "vllm_install_step_done",
            worker_id=worker_id,
            model_id=model_id,
            install_mode=install_mode,
            completed_steps=completed_steps,
        )
    install_seconds = time.monotonic() - started

    importlib.invalidate_caches()
    clear_imported_modules(("PIL", "vllm", "numpy"))
    reexec_after_vllm_install_if_needed(install_mode, completed_steps)
    try:
        LLM, SamplingParams, preloaded = import_vllm_with_preload()
    except Exception as exc:  # pragma: no cover - depends on Colab runtime
        raise InputError(
            "vllm_unavailable_after_install",
            f"vLLM install mode {install_mode} completed {completed_steps} step(s), but vLLM is still not importable: {exc}",
        ) from exc
    emit_stage(
        "vllm_import_ready",
        worker_id=worker_id,
        model_id=model_id,
        installed=True,
        install_mode=install_mode,
        seconds=round(install_seconds, 3),
    )
    return LLM, SamplingParams, {
        "vllm_install_seconds": install_seconds,
        "vllm_installed": True,
        "vllm_install_mode": install_mode,
        "nvidia_runtime_libs_preloaded": preloaded,
    }


def build_effective_prompt(prompt: str, model_id: str, worker_id: str, runtime_engine: str, gpu_name: str) -> str:
    if not bool_env("WINSMUX_COLAB_LLM_INCLUDE_RUNTIME_METADATA", True):
        return prompt
    metadata = "\n".join(
        [
            "winsmux runtime metadata:",
            f"- worker_id: {worker_id}",
            "- backend: colab_llm",
            "- runtime: colab",
            f"- runtime_engine: {runtime_engine}",
            f"- model_id: {model_id}",
            f"- gpu: {gpu_name or 'unknown'}",
            "",
            "Use the metadata above as authoritative. Do not infer or invent a different model id, backend, runtime engine, or GPU.",
        ]
    )
    return f"{metadata}\n\nUser task:\n{prompt.strip()}"


def format_chat_prompt(model_id: str, prompt: str) -> str:
    if not bool_env("WINSMUX_COLAB_LLM_USE_QWEN_CHAT_TEMPLATE", True):
        return prompt
    if "qwen" not in model_id.lower():
        return prompt
    return (
        "<|im_start|>system\n"
        "You are a concise winsmux worker. Follow the user task exactly, and keep identifiers copied from metadata verbatim.\n"
        "<|im_end|>\n"
        "<|im_start|>user\n"
        f"{prompt}\n"
        "<|im_end|>\n"
        "<|im_start|>assistant\n"
    )


def run_vllm(model_id: str, prompt: str, precision: str, quantization: str, worker_id: str) -> tuple[str, dict[str, Any]]:
    LLM, SamplingParams, metrics = ensure_vllm(worker_id=worker_id, model_id=model_id)

    kwargs: dict[str, Any] = {
        "model": model_id,
        "download_dir": os.environ["WINSMUX_COLAB_LLM_MODEL_ROOT"],
    }
    if precision:
        kwargs["dtype"] = precision
    if quantization and quantization.strip().lower() not in ("none", "null", "false"):
        kwargs["quantization"] = quantization

    started = time.monotonic()
    emit_stage(
        "model_load_begin",
        worker_id=worker_id,
        model_id=model_id,
        precision=precision or "auto",
        quantization=quantization or "none",
    )
    llm = LLM(**kwargs)
    load_seconds = time.monotonic() - started
    emit_stage("model_load_done", worker_id=worker_id, model_id=model_id, seconds=round(load_seconds, 3))
    sampling = SamplingParams(temperature=0.1, max_tokens=220, stop=["<|im_end|>"])
    gen_started = time.monotonic()
    emit_stage("generation_begin", worker_id=worker_id, model_id=model_id)
    outputs = llm.generate([format_chat_prompt(model_id, prompt)], sampling)
    generation_seconds = time.monotonic() - gen_started
    emit_stage("generation_done", worker_id=worker_id, model_id=model_id, seconds=round(generation_seconds, 3))
    text = outputs[0].outputs[0].text if outputs and outputs[0].outputs else ""
    metrics.update({"load_seconds": load_seconds, "generation_seconds": generation_seconds})
    return text, metrics


def write_result(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8", newline="\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="winsmux Colab GPU LLM worker")
    parser.add_argument("--task-json", default="", help="winsmux colab_llm task JSON path")
    parser.add_argument("--task-json-inline", default="", help="winsmux colab_llm inline task JSON")
    parser.add_argument("--worker-id", default="worker-1")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--task-id", default="")
    parser.add_argument("--artifact-root", default="")
    parser.add_argument("--model-id", default="")
    parser.add_argument("--runtime-engine", default="vllm")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    started = time.monotonic()
    try:
        emit_stage("worker_start", worker_id=args.worker_id or "worker-1")
        task = read_json(args.task_json, args.task_json_inline)
        worker_id = safe_id(args.worker_id or text_at(task, "slot_id", default="worker-1"), "worker-1")
        run_id = safe_id(args.run_id or text_at(task, "run_id", default=dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")), "run")
        model_id = args.model_id or text_at(task, "model_id")
        if not model_id:
            raise InputError("missing_model_id", "model_id is required")
        engine = (args.runtime_engine or text_at(task, "runtime_engine", default="vllm")).strip().lower()
        if engine != "vllm":
            raise InputError("unsupported_runtime_engine", f"unsupported runtime engine: {engine}")
        license_state = text_at(task, "license_state")
        if license_state not in ("accepted", "not_required"):
            raise InputError("license_not_accepted", "license_state must be accepted or not_required")

        emit_stage("configure_storage_begin", worker_id=worker_id, model_id=model_id)
        storage = configure_cache(task)
        if args.artifact_root:
            storage["artifact_root"] = ensure_colab_path(args.artifact_root, "artifact_root")
        artifact_dir = Path(storage["artifact_root"]) / worker_id / run_id
        prompt = text_at(task, "prompt", default="Say hello from winsmux colab_llm.")
        emit_stage("configure_storage_done", worker_id=worker_id)
        emit_stage("gpu_detect_begin", worker_id=worker_id)
        gpu = detect_gpu()
        if not gpu.get("available"):
            raise InputError("gpu_unavailable", "CUDA GPU is not available in this Colab runtime")
        gpu_name = str(gpu.get("name") or "")
        if "H100" not in gpu_name and "A100" not in gpu_name:
            raise InputError("gpu_degraded", f"expected H100 or A100, got {gpu_name}")
        emit_stage("gpu_detect_done", worker_id=worker_id, gpu=gpu_name)
        prompt = build_effective_prompt(
            prompt=prompt,
            model_id=model_id,
            worker_id=worker_id,
            runtime_engine=engine,
            gpu_name=gpu_name,
        )

        metrics: dict[str, Any] = {}
        output_text = ""
        if args.dry_run:
            output_text = "dry-run: Colab GPU LLM worker preflight completed"
        else:
            output_text, metrics = run_vllm(
                model_id=model_id,
                prompt=prompt,
                precision=text_at(task, "precision"),
                quantization=text_at(task, "quantization"),
                worker_id=worker_id,
            )

        result = {
                "schema_version": SCHEMA_VERSION,
                "worker_source_revision": WORKER_SOURCE_REVISION,
                "generated_at": utc_now(),
            "status": "succeeded",
            "backend": "colab_llm",
            "worker_id": worker_id,
            "run_id": run_id,
            "task_id": args.task_id or text_at(task, "task_id"),
            "runtime": "colab",
            "runtime_engine": "vllm",
            "model_id": model_id,
            "gpu": gpu,
            "storage": storage,
            "metrics": metrics,
            "elapsed_seconds": time.monotonic() - started,
            "output": output_text,
            "errors": [],
        }
        write_result(artifact_dir / "result.json", result)
        emit_stage("worker_result_written", worker_id=worker_id, model_id=model_id, status="succeeded")
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
        return 0
    except InputError as exc:
        emit_stage("worker_failed", worker_id=args.worker_id, model_id=args.model_id, error_code=exc.code)
        result = {
              "schema_version": SCHEMA_VERSION,
              "worker_source_revision": WORKER_SOURCE_REVISION,
              "generated_at": utc_now(),
            "status": "failed",
            "backend": "colab_llm",
            "worker_id": args.worker_id,
            "run_id": args.run_id,
            "runtime": "colab",
            "runtime_engine": args.runtime_engine,
            "model_id": args.model_id,
            "elapsed_seconds": time.monotonic() - started,
            "output": "",
            "errors": [{"code": exc.code, "message": exc.message}],
        }
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
        return 1
    except Exception as exc:  # pragma: no cover - depends on live model/runtime failures
        emit_stage("worker_failed", worker_id=args.worker_id, model_id=args.model_id, error_code=classify_worker_exception(exc))
        result = {
              "schema_version": SCHEMA_VERSION,
              "worker_source_revision": WORKER_SOURCE_REVISION,
              "generated_at": utc_now(),
            "status": "failed",
            "backend": "colab_llm",
            "worker_id": args.worker_id,
            "run_id": args.run_id,
            "runtime": "colab",
            "runtime_engine": args.runtime_engine,
            "model_id": args.model_id,
            "elapsed_seconds": time.monotonic() - started,
            "output": "",
            "errors": [
                {
                    "code": classify_worker_exception(exc),
                    "message": redact_sensitive_text(str(exc)),
                    "type": type(exc).__name__,
                }
            ],
        }
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
