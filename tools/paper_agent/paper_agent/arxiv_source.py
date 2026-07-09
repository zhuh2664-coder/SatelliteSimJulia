"""arXiv 数据源,复用仓库已有 collector。"""

from __future__ import annotations

import sys
import time
from pathlib import Path
from typing import Any

from .config import PaperAgentConfig
from .util import arxiv_base_id


def _load_collector(project_root: Path):
    scripts_dir = project_root / "scripts"
    if str(scripts_dir) not in sys.path:
        sys.path.insert(0, str(scripts_dir))
    import arxiv_collector  # type: ignore

    return arxiv_collector


def discover_arxiv(config: PaperAgentConfig) -> list[dict[str, Any]]:
    """按现有 QUERIES 抓取 arXiv 候选。"""
    collector = _load_collector(config.project_root)
    papers: list[dict[str, Any]] = []
    for query in collector.QUERIES:
        batch = collector.fetch_arxiv(query, max_results=config.max_per_query, days=config.days)
        for item in batch:
            papers.append(_normalize_arxiv_item(item))
        time.sleep(config.source_sleep_seconds)
        if len(papers) >= config.max_candidates:
            break
    deduped = collector.deduplicate(papers)
    return deduped[: config.max_candidates]


def _normalize_arxiv_item(item: dict[str, Any]) -> dict[str, Any]:
    arxiv_id = item.get("arxiv_id")
    base_id = arxiv_base_id(arxiv_id)
    authors = item.get("authors") or ""
    author_list = [a.strip() for a in authors.split(";") if a.strip()]
    year = None
    published = item.get("published")
    if published:
        try:
            year = int(str(published)[:4])
        except ValueError:
            year = None
    url = f"https://arxiv.org/abs/{base_id}" if base_id else None
    pdf_url = f"https://arxiv.org/pdf/{base_id}" if base_id else None
    return {
        "source_primary": "arXiv",
        "source": "arXiv",
        "external_id": arxiv_id,
        "arxiv_id": arxiv_id,
        "title": item.get("title") or "",
        "authors": author_list,
        "abstract": item.get("summary") or "",
        "summary": item.get("summary") or "",
        "published": published,
        "updated": item.get("updated"),
        "category": item.get("category"),
        "published_at": published,
        "updated_at": item.get("updated"),
        "year": year,
        "categories": [item.get("category")] if item.get("category") else [],
        "url": url,
        "pdf_url": pdf_url,
        "query_id": item.get("query_id"),
        "query_name": item.get("query_name"),
    }
