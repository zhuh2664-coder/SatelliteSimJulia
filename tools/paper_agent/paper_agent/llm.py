"""CPA/OpenAI-compatible LLM 摘要。"""

from __future__ import annotations

import json
from typing import Any

from .config import PaperAgentConfig
from .util import content_hash

PROMPT_VERSION = "paper-agent-v1"


SYSTEM_PROMPT = """你是 SatelliteSimJulia 项目的论文阅读助手。
项目方向：LEO 卫星互联网仿真、轨道传播、ISL/GSL 链路、拓扑/路由、流量/容量/时延、可微优化、PINN、LLM 仿真编排、切换/TCP/安全。
请只基于输入论文内容输出 JSON，不要编造论文没有的信息。"""


def should_use_llm(config: PaperAgentConfig) -> bool:
    """判断是否可以调用 LLM。"""
    return (not config.no_llm) and bool(config.openai_api_key)


def summarize_paper(candidate: dict[str, Any], reading_input: dict[str, Any], config: PaperAgentConfig) -> dict[str, Any] | None:
    """调用 OpenAI-compatible 模型生成结构化摘要。"""
    if not should_use_llm(config):
        return None
    try:
        from openai import OpenAI  # type: ignore
    except Exception as exc:
        return {
            "input_kind": reading_input.get("input_kind") or "metadata",
            "input_sha256": reading_input.get("input_sha256"),
            "model": config.openai_model_name,
            "prompt_version": PROMPT_VERSION,
            "summary_md": f"LLM 依赖不可用，跳过摘要：{exc}",
            "structured": {"error": str(exc), "skipped": True},
        }

    client = OpenAI(api_key=config.openai_api_key, base_url=config.openai_base_url)
    prompt = _build_prompt(candidate, reading_input.get("text") or "")
    response = client.chat.completions.create(
        model=config.openai_model_name,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        temperature=0.2,
        max_tokens=1800,
    )
    content = response.choices[0].message.content or "{}"
    structured = _parse_json(content)
    summary_md = _summary_markdown(candidate, structured)
    usage = getattr(response, "usage", None)
    return {
        "input_kind": reading_input.get("input_kind") or "metadata",
        "input_sha256": reading_input.get("input_sha256") or content_hash(reading_input.get("text") or ""),
        "model": config.openai_model_name,
        "prompt_version": PROMPT_VERSION,
        "summary_md": summary_md,
        "structured": structured,
        "key_contributions": structured.get("key_contributions") or [],
        "methods": structured.get("methods") or [],
        "limitations": structured.get("limitations") or [],
        "project_relevance": structured.get("project_relevance") or {},
        "implementation_tasks": structured.get("implementation_tasks") or [],
        "input_tokens": getattr(usage, "prompt_tokens", None) if usage else None,
        "output_tokens": getattr(usage, "completion_tokens", None) if usage else None,
    }


def _build_prompt(candidate: dict[str, Any], text: str) -> str:
    return f"""
请阅读下面论文材料，输出严格 JSON。字段：
{{
  "one_sentence": "一句话总结",
  "problem": "解决的问题",
  "key_contributions": ["贡献1", "贡献2"],
  "methods": ["方法1", "方法2"],
  "experiments": ["实验/指标"],
  "limitations": ["局限性"],
  "project_relevance": {{
    "score": 0-10,
    "modules": ["src/orbit", "src/net"],
    "why": "为什么对 SatelliteSimJulia 有用"
  }},
  "implementation_tasks": [
    {{"priority": "P0/P1/P2", "task": "可落地任务", "module": "对应模块"}}
  ],
  "confidence": 0-1
}}

论文元数据：
标题：{candidate.get('title') or ''}
作者：{'; '.join(candidate.get('authors') or [])}
年份：{candidate.get('year') or ''}
板块：{candidate.get('section_name') or ''}
模块：{candidate.get('module') or ''}
链接：{candidate.get('url') or ''}

论文材料：
{text[:24000]}
""".strip()


def _parse_json(content: str) -> dict[str, Any]:
    text = content.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.startswith("json"):
            text = text[4:].strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"one_sentence": content[:500], "parse_error": True, "raw": content}


def _summary_markdown(candidate: dict[str, Any], structured: dict[str, Any]) -> str:
    lines = [
        f"# {candidate.get('title') or 'Untitled'}",
        "",
        "## 一句话结论",
        structured.get("one_sentence") or "未生成。",
        "",
        "## 解决的问题",
        structured.get("problem") or "未生成。",
        "",
        "## 核心贡献",
    ]
    for item in structured.get("key_contributions") or []:
        lines.append(f"- {item}")
    lines.extend(["", "## 方法细节"])
    for item in structured.get("methods") or []:
        lines.append(f"- {item}")
    lines.extend(["", "## 实验与指标"])
    for item in structured.get("experiments") or []:
        lines.append(f"- {item}")
    lines.extend(["", "## 局限性"])
    for item in structured.get("limitations") or []:
        lines.append(f"- {item}")
    relevance = structured.get("project_relevance") or {}
    lines.extend([
        "",
        "## 对 SatelliteSimJulia 的价值",
        f"- 相关性分数：{relevance.get('score', '未知')}",
        f"- 相关模块：{', '.join(relevance.get('modules') or [])}",
        f"- 原因：{relevance.get('why', '未生成')}",
        "",
        "## 可落地实现建议",
    ])
    for task in structured.get("implementation_tasks") or []:
        if isinstance(task, dict):
            lines.append(f"- [{task.get('priority', 'P?')}] {task.get('task', '')}（{task.get('module', '未指定')}）")
        else:
            lines.append(f"- {task}")
    return "\n".join(lines).strip() + "\n"
