#!/usr/bin/env python3
"""CrewAI 外部编排 SatelliteSimJulia 的最小安全入口。

这个脚本是 SatelliteSimJulia 外部的薄适配层：
- 不修改 Julia 核心仿真代码；
- 不把 CPA key 放到命令行；
- 不向 LLM 暴露任意 shell；
- 只通过白名单调用现有 `bin/satnet.jl` CLI。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Literal, Type


sys.dont_write_bytecode = True

DEFAULT_PROJECT_ROOT = Path("/Users/zhuhai/Research/SatelliteSimJulia")
DEFAULT_CREWAI_ROOT = Path("/Users/zhuhai/Research/github上很牛逼的项目/crewAI")
DEFAULT_CPA_CONFIG = DEFAULT_CREWAI_ROOT / "CPA配置信息.md"

ACTION_ARGV: dict[str, list[str]] = {
    "list_goals": ["list", "goals"],
    "list_studies": ["list", "studies"],
    "list_constellations": ["list", "constellations"],
    "list_topologies": ["list", "topologies"],
    "list_propagators": ["list", "propagators"],
    "describe_coverage": ["describe", "coverage"],
    "run_coverage_study": ["run", "study", "coverage"],
}
RUN_ACTIONS = {"run_coverage_study"}
REDACTED = "[REDACTED]"


@dataclass(frozen=True)
class CPAConfig:
    api_key: str
    base_url: str
    model: str
    timeout_s: int

    def public_dict(self) -> dict[str, Any]:
        return {
            "api_key_set": bool(self.api_key),
            "base_url": self.base_url,
            "model": self.model,
            "timeout_s": self.timeout_s,
        }


@dataclass(frozen=True)
class ToolRuntime:
    project_root: Path
    tool_timeout_s: int
    max_output_chars: int
    allow_run_study: bool
    api_key_for_redaction: str = ""


def _strip_quotes(value: str) -> str:
    value = value.strip().strip("`").strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def _extract_env_value(text: str, name: str) -> str:
    pattern = rf"(?m)^\s*(?:export\s+)?{re.escape(name)}\s*=\s*([^\n#]+)"
    match = re.search(pattern, text)
    return _strip_quotes(match.group(1)) if match else ""


def _extract_label_value(text: str, labels: list[str]) -> str:
    for label in labels:
        pattern = rf"(?m)^\s*{re.escape(label)}\s*[:：]\s*([^\n#]+)"
        match = re.search(pattern, text)
        if match:
            return _strip_quotes(match.group(1))
    return ""


def load_cpa_config(path: Path, *, model_override: str | None, timeout_s: int) -> CPAConfig:
    """读取 CPA 配置；优先环境变量，缺失时读本地 markdown 配置文件。"""
    api_key = os.getenv("OPENAI_API_KEY", "")
    base_url = os.getenv("OPENAI_BASE_URL", "")
    model = os.getenv("OPENAI_MODEL_NAME", "")

    text = ""
    if path.exists() and (not api_key or not base_url or not model):
        text = path.read_text(encoding="utf-8")

    if not api_key and text:
        api_key = _extract_env_value(text, "OPENAI_API_KEY") or _extract_label_value(
            text, ["OPENAI_API_KEY", "api_key", "Key", "key"]
        )
    if not base_url and text:
        base_url = _extract_env_value(text, "OPENAI_BASE_URL") or _extract_label_value(
            text, ["OPENAI_BASE_URL", "base_url", "url", "地址"]
        )
    if not model and text:
        model = _extract_env_value(text, "OPENAI_MODEL_NAME") or _extract_label_value(
            text, ["OPENAI_MODEL_NAME", "model", "模型"]
        )

    model = model_override or model or "gpt-5.5"
    base_url = base_url.rstrip("/")

    missing = []
    if not api_key:
        missing.append("OPENAI_API_KEY")
    if not base_url:
        missing.append("OPENAI_BASE_URL")
    if missing:
        raise RuntimeError(
            "CPA 配置缺少 " + ", ".join(missing) + "；请设置环境变量或提供 --cpa-config。"
        )

    return CPAConfig(api_key=api_key, base_url=base_url, model=model, timeout_s=timeout_s)


def _as_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def redact_secret(text: str | bytes | None, *, api_key: str = "") -> str:
    """脱敏工具输出，避免 key 出现在终端或 CrewAI 上下文中。"""
    redacted = _as_text(text)
    if not redacted:
        return redacted
    if api_key:
        redacted = redacted.replace(api_key, REDACTED)
    redacted = re.sub(r"Bearer\s+[A-Za-z0-9._:/+=\-]+", f"Bearer {REDACTED}", redacted)
    redacted = re.sub(r"sk-[A-Za-z0-9._\-]{6,}", REDACTED, redacted)
    return redacted


def clip_text(text: str, max_chars: int) -> tuple[str, bool]:
    if len(text) <= max_chars:
        return text, False
    return text[:max_chars] + "\n...（输出已截断）", True


def run_satnet_action(action: str, runtime: ToolRuntime) -> dict[str, Any]:
    """按白名单执行 satnet CLI action。"""
    started = time.monotonic()
    if action not in ACTION_ARGV:
        return {
            "ok": False,
            "action": action,
            "exit_code": None,
            "error": "不允许的 action。允许值：" + ", ".join(sorted(ACTION_ARGV)),
        }

    if action in RUN_ACTIONS and not runtime.allow_run_study:
        return {
            "ok": False,
            "action": action,
            "exit_code": None,
            "error": "该 action 会运行 study；请显式传 --allow-run-study。",
        }

    project_root = runtime.project_root
    satnet = project_root / "bin" / "satnet.jl"
    if not satnet.exists():
        return {
            "ok": False,
            "action": action,
            "exit_code": None,
            "error": f"satnet.jl 不存在：{satnet}",
        }

    cmd = ["julia", f"--project={project_root}", str(satnet), *ACTION_ARGV[action]]
    try:
        proc = subprocess.run(
            cmd,
            cwd=project_root,
            shell=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=runtime.tool_timeout_s,
            check=False,
        )
        stdout = redact_secret(proc.stdout, api_key=runtime.api_key_for_redaction)
        stderr = redact_secret(proc.stderr, api_key=runtime.api_key_for_redaction)
        stdout, stdout_truncated = clip_text(stdout.strip(), runtime.max_output_chars)
        stderr, stderr_truncated = clip_text(stderr.strip(), runtime.max_output_chars)
        return {
            "ok": proc.returncode == 0,
            "action": action,
            "exit_code": proc.returncode,
            "duration_s": round(time.monotonic() - started, 3),
            "stdout": stdout,
            "stderr": stderr,
            "truncated": stdout_truncated or stderr_truncated,
        }
    except subprocess.TimeoutExpired as exc:
        partial_out = redact_secret(exc.stdout, api_key=runtime.api_key_for_redaction)
        partial_err = redact_secret(exc.stderr, api_key=runtime.api_key_for_redaction)
        partial_out, stdout_truncated = clip_text(partial_out.strip(), runtime.max_output_chars)
        partial_err, stderr_truncated = clip_text(partial_err.strip(), runtime.max_output_chars)
        return {
            "ok": False,
            "action": action,
            "exit_code": None,
            "duration_s": round(time.monotonic() - started, 3),
            "error": f"命令超时：{runtime.tool_timeout_s}s",
            "stdout": partial_out,
            "stderr": partial_err,
            "truncated": stdout_truncated or stderr_truncated,
        }


def add_local_crewai_to_path(crewai_root: Path) -> None:
    """把本地 crewAI workspace 的源码路径加入 sys.path。"""
    source_paths = [
        crewai_root / "lib" / "crewai" / "src",
        crewai_root / "lib" / "crewai-tools" / "src",
        crewai_root / "lib" / "crewai-core" / "src",
    ]
    for source_path in reversed(source_paths):
        if source_path.exists():
            sys.path.insert(0, str(source_path))


def require_crewai(crewai_root: Path) -> tuple[Any, Any, Any, Any, Any, Any, Any, Any]:
    """延迟导入 CrewAI；dry-run 和 tool-smoke 不依赖 Python 包环境。"""
    add_local_crewai_to_path(crewai_root)
    try:
        from crewai import Agent, Crew, LLM, Process, Task
        from crewai.tools import BaseTool
        from pydantic import BaseModel, Field
    except Exception as exc:  # noqa: BLE001 - 这里需要把导入失败转成清晰提示
        raise RuntimeError(
            "无法导入本地 CrewAI。建议使用：\n"
            f"  uv run --project {crewai_root} --package crewai python -B {Path(__file__).resolve()} ...\n"
            f"原始错误：{exc}"
        ) from exc
    return Agent, Crew, LLM, Process, Task, BaseTool, BaseModel, Field


def build_crewai_tool_classes(BaseTool: Any, BaseModel: Any, Field: Any, runtime: ToolRuntime) -> Any:
    """构造绑定当前 runtime 的 CrewAI BaseTool 子类。"""

    class SatnetCLIArgs(BaseModel):
        """satnet_cli 的入参 schema。"""

        action: Literal[
            "list_goals",
            "list_studies",
            "list_constellations",
            "list_topologies",
            "list_propagators",
            "describe_coverage",
            "run_coverage_study",
        ] = Field(description="允许调用的 SatelliteSimJulia CLI action。")

    class SatnetCLITool(BaseTool):
        name: str = "satnet_cli"
        description: str = (
            "安全调用 SatelliteSimJulia 现有 satnet CLI。"
            "只允许固定白名单 action，不接受任意 shell 命令。"
        )
        args_schema: Type[BaseModel] = SatnetCLIArgs

        def _run(self, action: str) -> str:
            result = run_satnet_action(action, runtime)
            return json.dumps(result, ensure_ascii=False, indent=2)

    return SatnetCLITool


def run_crewai_task(args: argparse.Namespace, config: CPAConfig) -> str:
    """运行 CrewAI + CPA + satnet CLI 的端到端编排。"""
    os.environ.setdefault("CREWAI_DISABLE_TELEMETRY", "true")
    os.environ.setdefault("OTEL_SDK_DISABLED", "true")
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")

    Agent, Crew, LLM, Process, Task, BaseTool, BaseModel, Field = require_crewai(args.crewai_root)
    runtime = ToolRuntime(
        project_root=args.project_root,
        tool_timeout_s=args.tool_timeout_s,
        max_output_chars=args.max_output_chars,
        allow_run_study=args.allow_run_study,
        api_key_for_redaction=config.api_key,
    )
    SatnetCLITool = build_crewai_tool_classes(BaseTool, BaseModel, Field, runtime)
    readonly_tool = SatnetCLITool()
    runner_tool = SatnetCLITool()

    llm = LLM(
        model=config.model,
        api_key=config.api_key,
        base_url=config.base_url,
        timeout=config.timeout_s,
        temperature=0.1,
    )

    planner = Agent(
        role="SatelliteSimJulia 实验规划员",
        goal="理解用户自然语言目标，使用 satnet_cli 查询现有能力并形成最小执行计划。",
        backstory="你只通过白名单工具观察项目能力，不修改源码，不执行高成本实验。",
        llm=llm,
        tools=[readonly_tool],
        verbose=True,
        allow_delegation=False,
        max_iter=4,
    )
    runner = Agent(
        role="SatelliteSimJulia 实验执行员",
        goal="按规划调用允许的 satnet_cli action，并保留真实 stdout/stderr/exit code。",
        backstory="你是谨慎的执行员，只运行被工具白名单和命令行开关允许的动作。",
        llm=llm,
        tools=[runner_tool],
        verbose=True,
        allow_delegation=False,
        max_iter=4,
    )
    reviewer = Agent(
        role="SatelliteSimJulia 结果审查员",
        goal="基于真实工具输出给出中文结论，指出限制和下一步。",
        backstory="你不重复执行工具，只审查前序结果是否足以支持结论。",
        llm=llm,
        tools=[],
        verbose=True,
        allow_delegation=False,
        max_iter=2,
    )

    plan_task = Task(
        description=(
            "用户任务：\n"
            f"{args.task}\n\n"
            "请调用 satnet_cli 查询项目现有能力。至少调用 list_goals、list_constellations、describe_coverage。"
            "输出一个简短计划，说明是否需要运行 coverage study。"
        ),
        expected_output="包含真实 CLI 查询结果摘要的执行计划。",
        agent=planner,
    )
    run_task = Task(
        description=(
            "根据规划执行最小验证。若需要运行 coverage study，请调用 satnet_cli(action='run_coverage_study')；"
            "如果工具拒绝运行，原样报告拒绝原因。输出必须包含工具 JSON 结果中的 exit_code/stdout/stderr 摘要。"
        ),
        expected_output="包含真实工具执行结果的运行摘要。",
        agent=runner,
        context=[plan_task],
    )
    review_task = Task(
        description=(
            "审查前序计划和运行结果，用中文输出最终报告。必须包含：调用链、关键输出、"
            "coverage_ratio/avg_latency_ms/connectivity/fitness、是否跑通、限制和下一步。"
            "如果 coverage_ratio 是 NaN，请标注为底层 study 当前真实输出，不要说成 CrewAI 失败。"
        ),
        expected_output="中文端到端验证报告。",
        agent=reviewer,
        context=[plan_task, run_task],
    )

    crew = Crew(
        agents=[planner, runner, reviewer],
        tasks=[plan_task, run_task, review_task],
        process=Process.sequential,
        verbose=True,
        memory=False,
    )
    result = crew.kickoff()
    return str(result)


def path_arg(value: str) -> Path:
    return Path(value).expanduser().resolve()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="CrewAI 外部编排 SatelliteSimJulia 的最小安全入口。"
    )
    parser.add_argument("--task", help="要交给 CrewAI 编排的自然语言任务。")
    parser.add_argument("--project-root", type=path_arg, default=DEFAULT_PROJECT_ROOT)
    parser.add_argument("--crewai-root", type=path_arg, default=DEFAULT_CREWAI_ROOT)
    parser.add_argument("--cpa-config", type=path_arg, default=DEFAULT_CPA_CONFIG)
    parser.add_argument("--model", help="覆盖 CPA 文件或环境变量中的模型名。")
    parser.add_argument("--timeout-s", type=int, default=180, help="LLM 请求超时。")
    parser.add_argument("--tool-timeout-s", type=int, default=420, help="satnet CLI 调用超时；冷启动预编译可能较慢。")
    parser.add_argument("--max-output-chars", type=int, default=12000, help="工具输出最大字符数。")
    parser.add_argument("--dry-run", action="store_true", help="只检查配置和白名单，不调用 LLM/JULIA。")
    parser.add_argument("--check-cpa", action="store_true", help="检查 CPA 配置可读且不泄漏 key。")
    parser.add_argument("--list-actions", action="store_true", help="列出 satnet_cli 白名单 action。")
    parser.add_argument("--tool-smoke", choices=sorted(ACTION_ARGV), help="不调用 LLM，直接执行一个白名单 action。")
    parser.add_argument("--allow-run-study", action="store_true", help="允许运行 run_coverage_study。")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])

    if args.timeout_s <= 0 or args.tool_timeout_s <= 0 or args.max_output_chars <= 0:
        raise SystemExit("timeout 和 max-output-chars 必须为正数。")

    config: CPAConfig | None = None
    if args.dry_run or args.check_cpa or args.task:
        config = load_cpa_config(args.cpa_config, model_override=args.model, timeout_s=args.timeout_s)

    if args.dry_run:
        payload = {
            "mode": "dry-run",
            "project_root": str(args.project_root),
            "crewai_root": str(args.crewai_root),
            "cpa_config": str(args.cpa_config),
            "cpa": config.public_dict() if config else None,
            "allow_run_study": args.allow_run_study,
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))

    if args.check_cpa and not args.dry_run:
        print(json.dumps({"mode": "check-cpa", "cpa": config.public_dict()}, ensure_ascii=False, indent=2))

    if args.list_actions:
        print(json.dumps({"actions": sorted(ACTION_ARGV)}, ensure_ascii=False, indent=2))

    if args.tool_smoke:
        smoke_config = config or CPAConfig("", "", args.model or "gpt-5.5", args.timeout_s)
        runtime = ToolRuntime(
            project_root=args.project_root,
            tool_timeout_s=args.tool_timeout_s,
            max_output_chars=args.max_output_chars,
            allow_run_study=args.allow_run_study,
            api_key_for_redaction=smoke_config.api_key,
        )
        result = run_satnet_action(args.tool_smoke, runtime)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result.get("ok") else 1

    if args.task:
        assert config is not None
        result = run_crewai_task(args, config)
        print("\n=== CREWAI_SATNET_RESULT ===")
        print(redact_secret(result, api_key=config.api_key))
        return 0

    if not (args.dry_run or args.check_cpa or args.list_actions):
        print("未指定操作。请使用 --dry-run、--list-actions、--tool-smoke 或 --task。", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
