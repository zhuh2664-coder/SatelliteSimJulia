"""LangGraph 状态定义。"""

from __future__ import annotations

from typing import Any, TypedDict


class PaperAgentState(TypedDict, total=False):
    run_id: str
    mode: str
    today: str
    config: dict[str, Any]
    candidates: list[dict[str, Any]]
    new_or_updated_paper_ids: list[str]
    read_queue: list[str]
    fetch_results: list[dict[str, Any]]
    read_results: list[dict[str, Any]]
    proposed_actions: list[dict[str, Any]]
    render_outputs: dict[str, Any]
    errors: list[dict[str, Any]]
    stats: dict[str, Any]
    weekly_report_path: str
    pr_url: str
