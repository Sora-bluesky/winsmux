#!/usr/bin/env python3
"""Colab GPU LLM worker for winsmux colab_llm slots."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any


SCHEMA_VERSION = "winsmux.colab_llm.result.v1"
DEFAULT_DRIVE_ROOT = "/content/drive/MyDrive/winsmux-colab-llm"
DEFAULT_RUNTIME_CACHE = "/content/winsmux-runtime-cache"
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")


class InputError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


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


def detect_gpu() -> dict[str, Any]:
    try:
        import torch  # type: ignore

        if not torch.cuda.is_available():
            return {"available": False, "name": "", "count": 0}
        return {
            "available": True,
            "name": torch.cuda.get_device_name(0),
            "count": int(torch.cuda.device_count()),
        }
    except Exception as exc:  # pragma: no cover - depends on Colab runtime
        return {"available": False, "name": "", "count": 0, "error": str(exc)}


def run_vllm(model_id: str, prompt: str, precision: str, quantization: str) -> tuple[str, dict[str, Any]]:
    try:
        from vllm import LLM, SamplingParams  # type: ignore
    except Exception as exc:  # pragma: no cover - depends on Colab runtime
        raise InputError("vllm_unavailable", f"vLLM is not importable in this Colab runtime: {exc}") from exc

    kwargs: dict[str, Any] = {
        "model": model_id,
        "download_dir": os.environ["WINSMUX_COLAB_LLM_MODEL_ROOT"],
    }
    if precision:
        kwargs["dtype"] = precision
    if quantization:
        kwargs["quantization"] = quantization

    started = time.monotonic()
    llm = LLM(**kwargs)
    load_seconds = time.monotonic() - started
    sampling = SamplingParams(temperature=0.2, max_tokens=256)
    gen_started = time.monotonic()
    outputs = llm.generate([prompt], sampling)
    generation_seconds = time.monotonic() - gen_started
    text = outputs[0].outputs[0].text if outputs and outputs[0].outputs else ""
    return text, {"load_seconds": load_seconds, "generation_seconds": generation_seconds}


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

        storage = configure_cache(task)
        if args.artifact_root:
            storage["artifact_root"] = ensure_colab_path(args.artifact_root, "artifact_root")
        artifact_dir = Path(storage["artifact_root"]) / worker_id / run_id
        prompt = text_at(task, "prompt", default="Say hello from winsmux colab_llm.")
        gpu = detect_gpu()
        if not gpu.get("available"):
            raise InputError("gpu_unavailable", "CUDA GPU is not available in this Colab runtime")
        gpu_name = str(gpu.get("name") or "")
        if "H100" not in gpu_name and "A100" not in gpu_name:
            raise InputError("gpu_degraded", f"expected H100 or A100, got {gpu_name}")

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
            )

        result = {
            "schema_version": SCHEMA_VERSION,
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
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
        return 0
    except InputError as exc:
        result = {
            "schema_version": SCHEMA_VERSION,
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


if __name__ == "__main__":
    raise SystemExit(main())
