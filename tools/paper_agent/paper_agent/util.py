"""通用工具函数。"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    """返回 ISO-8601 UTC 时间。"""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def today_utc() -> str:
    """返回 UTC 日期。"""
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def iso_week_label() -> str:
    """返回 ISO 周标签,例如 2026-W28。"""
    year, week, _ = datetime.now(timezone.utc).isocalendar()
    return f"{year}-W{week:02d}"


def json_dumps(value: Any) -> str:
    """稳定写出 JSON。"""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def json_loads(value: str | None, default: Any = None) -> Any:
    """安全解析 JSON。"""
    if not value:
        return default
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return default


def normalize_title(title: str) -> str:
    """归一化标题,用于去重。"""
    text = title.lower().strip()
    text = re.sub(r"^\s*\d+\.\s*", "", text)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"[^\w\s]", "", text)
    return text.strip()


def sha256_text(text: str) -> str:
    """计算文本 SHA256。"""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_file(path: Path) -> str:
    """计算文件 SHA256。"""
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def arxiv_base_id(arxiv_id: str | None) -> str | None:
    """去掉 arXiv 版本号。"""
    if not arxiv_id:
        return None
    return re.sub(r"v\d+$", "", arxiv_id.strip())


def canonical_id_for(paper: dict[str, Any]) -> str:
    """按 DOI/arXiv/Semantic Scholar/title 生成稳定 ID。"""
    doi = (paper.get("doi") or "").strip().lower()
    if doi:
        return f"doi:{doi}"
    arxiv_id = arxiv_base_id(paper.get("arxiv_id"))
    if arxiv_id:
        return f"arxiv:{arxiv_id}"
    s2_id = (paper.get("semantic_scholar_id") or paper.get("paperId") or "").strip()
    if s2_id:
        return f"s2:{s2_id}"
    title_norm = normalize_title(paper.get("title") or "")
    return f"title:{sha256_text(title_norm)[:24]}"


def safe_filename(value: str) -> str:
    """把任意 ID 转成安全文件名。"""
    text = value.replace(":", "_").replace("/", "_").replace("\\", "_")
    text = re.sub(r"[^A-Za-z0-9_.-]", "_", text)
    return text[:180]


def content_hash(text: str) -> str:
    """计算内容短 hash。"""
    return sha256_text(text)[:16]
