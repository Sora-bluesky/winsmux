"""
winsmux SDK -- Python client for the winsmux MCP Server.

Communicates with mcp-server.js via subprocess.Popen + stdio JSON-RPC 2.0.
No external dependencies (stdlib only).
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from pathlib import Path
from typing import Any, Optional


class WinsmuxError(Exception):
    """Raised when a tool call returns an error."""


class WinsmuxClient:
    """Client for the winsmux MCP server.

    Spawns ``node mcp-server.js`` as a child process and communicates
    via newline-delimited JSON-RPC 2.0 over stdin/stdout.
    """

    def __init__(self, server_path: Optional[str] = None) -> None:
        self._server_path = server_path or self._resolve_default_server_path()
        self._process: Optional[subprocess.Popen[bytes]] = None
        self._next_id = 1
        self._lock = threading.Lock()
        self._initialized = False

    # --- Public API ---

    def list(self) -> str:
        """List labeled panes in the current winsmux session."""
        return self._call_tool("winsmux_list", {})

    def read(self, target: str, lines: int = 50) -> str:
        """Read recent output from a pane."""
        args: dict[str, Any] = {"target": target}
        if lines != 50:
            args["lines"] = lines
        return self._call_tool("winsmux_read", args)

    def send(self, target: str, text: str) -> str:
        """Send text to a pane via winsmux-bridge send."""
        return self._call_tool("winsmux_send", {"target": target, "text": text})

    def dispatch(self, text: str) -> str:
        """Route text to the appropriate pane by keyword."""
        return self._call_tool("winsmux_dispatch", {"text": text})

    def health(self) -> str:
        """Health check all panes."""
        return self._call_tool("winsmux_health", {})

    def pipeline(self, task: str) -> str:
        """Run plan-exec-verify-fix pipeline for a task."""
        return self._call_tool("winsmux_pipeline", {"task": task})

    def close(self) -> None:
        """Close the child process and clean up."""
        if self._process is not None:
            try:
                self._process.stdin.close()  # type: ignore[union-attr]
            except OSError:
                pass
            try:
                self._process.terminate()
                self._process.wait(timeout=5)
            except Exception:
                self._process.kill()
            self._process = None
        self._initialized = False

    # --- Context manager ---

    def __enter__(self) -> WinsmuxClient:
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    # --- Internals ---

    @staticmethod
    def _resolve_default_server_path() -> str:
        # Relative to this file: ../../winsmux-core/mcp-server.js
        here = Path(__file__).resolve().parent
        return str(here / ".." / ".." / "winsmux" / "mcp-server.js")

    def _ensure_process(self) -> subprocess.Popen[bytes]:
        if self._process is None or self._process.poll() is not None:
            self._process = subprocess.Popen(
                ["node", self._server_path],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                creationflags=(
                    subprocess.CREATE_NO_WINDOW
                    if os.name == "nt"
                    else 0
                ),
            )
            self._initialized = False
        return self._process

    def _send_request(
        self, method: str, params: Optional[dict[str, Any]] = None
    ) -> dict[str, Any]:
        proc = self._ensure_process()

        with self._lock:
            req_id = self._next_id
            self._next_id += 1

        msg: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
        }
        if params is not None:
            msg["params"] = params

        line = json.dumps(msg, separators=(",", ":")) + "\n"
        proc.stdin.write(line.encode("utf-8"))  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]

        # Read lines until we get a response with our id
        while True:
            raw = proc.stdout.readline()  # type: ignore[union-attr]
            if not raw:
                raise WinsmuxError("Server process closed unexpectedly")
            raw_str = raw.decode("utf-8").strip()
            if not raw_str:
                continue
            try:
                resp = json.loads(raw_str)
            except json.JSONDecodeError:
                continue
            if resp.get("id") == req_id:
                return resp

    def _send_notification(self, method: str) -> None:
        proc = self._ensure_process()
        msg = {"jsonrpc": "2.0", "method": method}
        line = json.dumps(msg, separators=(",", ":")) + "\n"
        proc.stdin.write(line.encode("utf-8"))  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]

    def _ensure_initialized(self) -> None:
        if self._initialized:
            return

        self._ensure_process()

        # Step 1: initialize
        resp = self._send_request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "winsmux-sdk-py", "version": "1.0.0"},
        })

        if "error" in resp:
            raise WinsmuxError(
                f"Initialize failed: {resp['error']['message']}"
            )

        # Step 2: notifications/initialized
        self._send_notification("notifications/initialized")

        self._initialized = True

    def _call_tool(self, name: str, arguments: dict[str, Any]) -> str:
        self._ensure_initialized()

        resp = self._send_request("tools/call", {
            "name": name,
            "arguments": arguments,
        })

        if "error" in resp:
            raise WinsmuxError(
                f"Tool call failed: {resp['error']['message']}"
            )

        result = resp.get("result", {})
        content = result.get("content", [])
        if content:
            text = content[0].get("text", "")
            if result.get("isError"):
                raise WinsmuxError(text)
            return text

        return ""
