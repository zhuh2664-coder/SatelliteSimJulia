#!/usr/bin/env python3
"""SatelliteSimJulia 的本地 AgentOS 包装器。

该 AgentOS 面默认只读、只绑定 loopback。它只暴露由 Julia JSON runner
提供的安全目录查询工具；不会运行仿真、测试、frame/payload 生成、传播、
导出或任何写文件工具。
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict

from praisonai import AgentOS
from praisonaiagents import Agent, AgentOSConfig


PROJECT_ROOT = Path(__file__).resolve().parent
RUNNER = PROJECT_ROOT / "scripts" / "mcp_tool_runner.jl"
DEFAULT_TIMEOUT_SECONDS = 120
LOOPBACK_HOST = "127.0.0.1"
SAFE_TOOL_NAMES = frozenset({"list_constellations", "describe_constellation"})


class SatelliteToolError(RuntimeError):
    """SatelliteSimJulia JSON runner 失败时抛出。"""


def _parse_runner_json(stdout: str) -> Dict[str, Any]:
    """解析 Julia runner 输出中的最后一个 JSON 对象。"""
    for line in reversed(stdout.splitlines()):
        stripped = line.strip()
        if stripped.startswith("{") and stripped.endswith("}"):
            parsed = json.loads(stripped)
            if isinstance(parsed, dict):
                return parsed
    raise SatelliteToolError(f"Julia runner did not emit JSON. stdout={stdout[-500:]!r}")


def _run_satellite_tool(
    tool_name: str,
    args: Dict[str, Any],
    *,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
) -> Dict[str, Any]:
    """运行一个安全的 SatelliteSimJulia JSON 工具并返回结果。"""
    if tool_name not in SAFE_TOOL_NAMES:
        raise SatelliteToolError(f"tool is not exposed by this safe AgentOS surface: {tool_name}")
    if not RUNNER.exists():
        raise SatelliteToolError(f"Runner not found: {RUNNER}")

    cmd = [
        "julia",
        f"--project={PROJECT_ROOT}",
        str(RUNNER),
        tool_name,
        json.dumps(args, ensure_ascii=False),
    ]
    completed = subprocess.run(
        cmd,
        cwd=str(PROJECT_ROOT),
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )

    parsed = _parse_runner_json(completed.stdout)
    if completed.returncode != 0 or not parsed.get("ok", False):
        message = parsed.get("message") or completed.stderr[-500:] or "unknown error"
        raise SatelliteToolError(f"{tool_name} failed: {message}")

    result = parsed.get("result")
    if not isinstance(result, dict):
        raise SatelliteToolError(f"{tool_name} returned non-object result: {result!r}")
    return result


def _json_text(data: Dict[str, Any]) -> str:
    """返回便于阅读的 JSON 文本。"""
    return json.dumps(data, ensure_ascii=False, indent=2)


def list_satellite_constellations() -> str:
    """列出 SatelliteSimJulia 可用的目录星座名称。"""
    try:
        result = _run_satellite_tool("list_constellations", {})
    except Exception as exc:  # 工具输出应面向用户，而不是暴露堆栈。
        return f"SatelliteSimJulia tool error: {exc}"

    names = result.get("names", [])
    return "可用星座：" + ", ".join(str(name) for name in names)


def describe_satellite_constellation(name: str) -> str:
    """按名称描述一个 Walker 星座，例如 iridium 或 oneweb。"""
    try:
        result = _run_satellite_tool("describe_constellation", {"name": name})
    except Exception as exc:
        return f"SatelliteSimJulia tool error: {exc}"

    return _json_text(result)


def _build_agent() -> Agent:
    model = os.environ.get("OPENAI_MODEL_NAME") or os.environ.get("MODEL_NAME") or "gpt-5.5"
    return Agent(
        name="satellite_sim_julia",
        role="SatelliteSimJulia 只读目录助手",
        instructions=(
            "你是 SatelliteSimJulia 项目的本地 AgentOS 只读助手。"
            "硬边界：当前 AgentOS/MCP 面默认只暴露 safe tools：列出星座目录、描述单个星座参数。"
            "不得运行仿真、传播、测试、frame payload、PNG/CZML/JLD2/export、写文件或任何公网部署。"
            "如果用户要求这些能力，明确说明当前安全配置没有暴露该工具；不要说‘确认后可以执行’，也不要承诺稍后代跑。"
            "可以建议用户离开 AgentOS/MCP 安全面后，在本地 CLI 中手动运行相关命令。"
            "回答尽量简洁，必要时给出可复制的只读 Julia 查询命令。"
        ),
        llm=model,
        tools=[
            list_satellite_constellations,
            describe_satellite_constellation,
        ],
    )


def main() -> None:
    # 本仓库中的 PraisonAI/OpenAI 兼容客户端可能检查两种环境变量拼写。
    if os.environ.get("OPENAI_BASE_URL") and not os.environ.get("OPENAI_API_BASE"):
        os.environ["OPENAI_API_BASE"] = os.environ["OPENAI_BASE_URL"]

    # 安全边界：AgentOS 只绑定 loopback。本地安全 demo 会故意忽略
    # SATELLITESIM_AGENTOS_HOST 与 SATELLITESIM_AGENTOS_API_KEY。
    host = LOOPBACK_HOST
    port = int(os.environ.get("SATELLITESIM_AGENTOS_PORT", "8920"))

    config = AgentOSConfig(
        name="SatelliteSimJulia AgentOS",
        host=host,
        port=port,
        api_key=None,
    )
    app = AgentOS(
        name="SatelliteSimJulia AgentOS",
        agents=[_build_agent()],
        config=config,
    )
    app.serve()


if __name__ == "__main__":
    main()
