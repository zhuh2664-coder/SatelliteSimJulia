#!/usr/bin/env python3
"""MCP stdio server for SatelliteSimJulia research agent.

Exposes research_* tools so other agents can call this collector via MCP.
Supports Content-Length framed JSON-RPC and newline-delimited JSON (smoke tests).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from research_agent.api import TOOL_SCHEMAS, TOOLS  # noqa: E402


def read_message(io) -> Optional[str]:
    if io.closed:
        return None
    line = io.readline()
    if not line:
        return None
    if line.lower().startswith("content-length:"):
        n = int(line.split(":", 1)[1].strip())
        # consume headers until blank line
        while True:
            h = io.readline()
            if not h or h in ("\n", "\r\n"):
                break
        return io.read(n)
    return line.strip() or None


def send_message(obj: Dict[str, Any]) -> None:
    payload = json.dumps(obj, ensure_ascii=False)
    data = payload.encode("utf-8")
    sys.stdout.write(f"Content-Length: {len(data)}\r\n\r\n")
    sys.stdout.write(payload)
    sys.stdout.flush()


def rpc_result(id_, result):
    return {"jsonrpc": "2.0", "id": id_, "result": result}


def rpc_error(id_, code: int, message: str):
    return {"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": message}}


def handle_request(req: Dict[str, Any]):
    method = req.get("method", "")
    id_ = req.get("id")

    if method == "initialize":
        return rpc_result(
            id_,
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "satellitesimjulia-research", "version": "0.1.0"},
            },
        )
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        tools = [TOOL_SCHEMAS[name] for name in sorted(TOOL_SCHEMAS)]
        return rpc_result(id_, {"tools": tools})
    if method == "tools/call":
        params = req.get("params") or {}
        name = str(params.get("name") or "")
        args = params.get("arguments") or {}
        if name not in TOOL_SCHEMAS or name not in TOOLS:
            return rpc_error(id_, -32602, f"unknown tool: {name}")
        try:
            result = TOOLS[name](args if isinstance(args, dict) else {})
            text = json.dumps({"ok": True, "tool": name, "result": result}, ensure_ascii=False)
            return rpc_result(id_, {"content": [{"type": "text", "text": text}], "isError": False})
        except Exception as e:
            text = json.dumps(
                {
                    "ok": False,
                    "tool": name,
                    "error_type": type(e).__name__,
                    "message": str(e),
                },
                ensure_ascii=False,
            )
            return rpc_result(id_, {"content": [{"type": "text", "text": text}], "isError": True})
    if method == "shutdown":
        return rpc_result(id_, None)
    return rpc_error(id_, -32601, f"method not found: {method}")


def serve_stdio() -> None:
    while True:
        raw = read_message(sys.stdin)
        if raw is None:
            break
        try:
            req = json.loads(raw)
        except json.JSONDecodeError as e:
            send_message(rpc_error(None, -32700, f"parse error: {e}"))
            continue
        resp = handle_request(req)
        if resp is not None:
            send_message(resp)


if __name__ == "__main__":
    serve_stdio()
