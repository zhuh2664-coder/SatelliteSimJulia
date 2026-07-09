"""待确认动作逻辑。"""

from __future__ import annotations

from collections import defaultdict
from typing import Any

from .db import PaperStore


def propose_duplicate_actions(store: PaperStore, run_id: str) -> list[dict[str, Any]]:
    """提出重复标题候选；只 proposed，不执行。"""
    papers = store.list_papers(limit=1000)
    by_title: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for paper in papers:
        by_title[paper.get("title_norm") or paper.get("title") or ""].append(paper)
    proposed: list[dict[str, Any]] = []
    existing = store.list_actions(status="proposed")
    existing_keys = {(a.get("action_type"), a.get("paper_id"), a.get("target_id")) for a in existing}
    for _, group in by_title.items():
        if len(group) <= 1:
            continue
        keeper = sorted(group, key=lambda p: (p.get("citation_count") or 0, p.get("actionability_score") or 0), reverse=True)[0]
        for duplicate in group:
            if duplicate["id"] == keeper["id"]:
                continue
            key = ("mark_duplicate", duplicate["id"], keeper["id"])
            if key in existing_keys:
                continue
            action = {
                "action_type": "mark_duplicate",
                "target_type": "paper",
                "target_id": keeper["id"],
                "paper_id": duplicate["id"],
                "reason": f"标题与 {keeper['id']} 重复，建议人工确认后合并/归档。",
                "risk_level": "medium",
                "run_id": run_id,
            }
            action["id"] = store.add_action(action)
            proposed.append(action)
    return proposed


def format_actions(actions: list[dict[str, Any]]) -> str:
    """渲染待确认动作表。"""
    if not actions:
        return "暂无待确认动作。\n"
    lines = ["| Action ID | 类型 | 目标 | 原因 | 确认命令 |", "|---|---|---|---|---|"]
    for action in actions:
        action_id = action["id"]
        lines.append(
            f"| `{action_id}` | {action.get('action_type')} | {action.get('paper_id') or action.get('target_path') or ''} | "
            f"{action.get('reason', '').replace('|', '/')} | `python3 scripts/run_paper_agent.py confirm-action --action-id {action_id}` |"
        )
    return "\n".join(lines) + "\n"
