"""分类和评分,复用现有文献脚本。"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from .config import PaperAgentConfig


def _load_existing(project_root: Path):
    scripts_dir = project_root / "scripts"
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    import build_actionable_papers  # type: ignore
    import build_literature_index  # type: ignore

    return build_literature_index, build_actionable_papers


def score_candidate(candidate: dict[str, Any], config: PaperAgentConfig) -> dict[str, Any]:
    """给候选论文补充板块、tier、模块和可落地分。"""
    literature, actionable = _load_existing(config.project_root)
    adapted = _adapt_for_literature(candidate)
    matches = literature.classify_paper(adapted, set())
    if matches:
        section_id, tier = matches[0]
        section = next((s for s in literature.SECTIONS if s["id"] == section_id), {})
        section_name = section.get("name", section_id)
    else:
        section_id, tier, section_name = "99", "tier3", "跨板块/综述/工具"

    scoring_record = _adapt_for_actionable(candidate)
    actionability_score = actionable.score_paper(scoring_record)
    module = actionable.get_module(scoring_record)
    code_status = actionable.get_code_status(scoring_record)
    relevance_score = _relevance_score(tier, actionability_score, section_id)

    enriched = dict(candidate)
    enriched.update({
        "section_id": section_id,
        "section_name": section_name,
        "tier": tier,
        "module": module,
        "relevance_score": relevance_score,
        "actionability_score": actionability_score,
        "code_status": code_status,
    })
    return enriched


def _adapt_for_literature(candidate: dict[str, Any]) -> dict[str, Any]:
    return {
        "title": candidate.get("title") or "",
        "ni_sub_tags": "",
        "ni_cluster_label": "",
        "pf_category": "",
        "lg_cluster_label": "",
        "ni_sbert_label": "",
    }


def _adapt_for_actionable(candidate: dict[str, Any]) -> dict[str, Any]:
    year = candidate.get("year")
    if not year and candidate.get("published_at"):
        try:
            year = int(str(candidate["published_at"])[:4])
        except ValueError:
            year = ""
    venue = candidate.get("venue") or ""
    return {
        "title": candidate.get("title") or "",
        "year": year or "",
        "source": candidate.get("source") or candidate.get("source_primary") or "arXiv",
        "ref": venue,
    }


def _relevance_score(tier: str, actionability_score: float, section_id: str) -> float:
    base = {"tier1": 80.0, "tier2": 60.0, "tier3": 40.0}.get(tier, 25.0)
    if section_id == "99":
        base = 25.0
    return min(100.0, base + min(actionability_score, 100) * 0.2)
