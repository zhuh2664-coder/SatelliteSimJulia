"""PDF/网页获取与文本抽取。"""

from __future__ import annotations

import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from .config import PaperAgentConfig
from .util import content_hash, safe_filename, sha256_file


def fetch_for_reading(candidate: dict[str, Any], config: PaperAgentConfig) -> dict[str, Any]:
    """下载 PDF 并尽量抽取文本。失败时返回 metadata-only 结果。"""
    result: dict[str, Any] = {
        "paper_id": candidate.get("canonical_id"),
        "input_kind": "metadata",
        "text": _metadata_text(candidate),
        "input_sha256": content_hash(_metadata_text(candidate)),
    }
    if config.no_fetch:
        return result
    pdf_url = candidate.get("pdf_url")
    if not pdf_url:
        return result
    try:
        pdf_path = download_pdf(candidate, config)
        result["pdf_path"] = str(pdf_path)
        result["pdf_sha256"] = sha256_file(pdf_path)
        extracted = extract_pdf_text(pdf_path, config)
        if extracted:
            result["input_kind"] = "pdf"
            result["text"] = extracted[: config.max_text_chars]
            result["input_sha256"] = content_hash(result["text"])
    except Exception as exc:
        result.setdefault("errors", []).append({"stage": "fetch_pdf", "error": str(exc)})
    return result


def download_pdf(candidate: dict[str, Any], config: PaperAgentConfig) -> Path:
    """下载 PDF 到 cache。"""
    config.pdf_cache_dir.mkdir(parents=True, exist_ok=True)
    paper_id = candidate.get("canonical_id") or candidate.get("arxiv_id") or candidate.get("title") or "paper"
    target = config.pdf_cache_dir / f"{safe_filename(str(paper_id))}.pdf"
    if target.exists() and target.stat().st_size > 0:
        return target
    req = urllib.request.Request(candidate["pdf_url"], headers={"User-Agent": config.user_agent})
    max_bytes = config.max_pdf_mb * 1024 * 1024
    with urllib.request.urlopen(req, timeout=config.http_timeout_seconds) as resp:
        data = resp.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise ValueError(f"PDF 超过限制: {config.max_pdf_mb} MB")
    target.write_bytes(data)
    return target


def extract_pdf_text(path: Path, config: PaperAgentConfig) -> str | None:
    """用 pypdf 抽取前几页文本；没有依赖时返回 None。"""
    try:
        from pypdf import PdfReader  # type: ignore
    except Exception:
        return None
    reader = PdfReader(str(path))
    texts: list[str] = []
    for page in reader.pages[: config.max_pdf_pages]:
        try:
            texts.append(page.extract_text() or "")
        except Exception:
            continue
    text = "\n\n".join(t.strip() for t in texts if t.strip())
    return text or None


def _metadata_text(candidate: dict[str, Any]) -> str:
    authors = "; ".join(candidate.get("authors") or [])
    return "\n".join([
        f"标题: {candidate.get('title') or ''}",
        f"作者: {authors}",
        f"年份: {candidate.get('year') or ''}",
        f"来源: {candidate.get('source_primary') or candidate.get('source') or ''}",
        f"板块: {candidate.get('section_name') or ''}",
        f"模块: {candidate.get('module') or ''}",
        "摘要:",
        candidate.get("abstract") or candidate.get("summary") or "",
    ])
