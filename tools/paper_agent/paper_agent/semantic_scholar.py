"""Semantic Scholar Graph API 客户端。"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from difflib import SequenceMatcher
from typing import Any

from .config import PaperAgentConfig
from .util import arxiv_base_id, normalize_title

S2_BASE = "https://api.semanticscholar.org/graph/v1"
FIELDS = ",".join([
    "paperId", "corpusId", "title", "abstract", "authors", "year", "venue",
    "publicationDate", "url", "externalIds", "citationCount",
    "influentialCitationCount", "openAccessPdf", "fieldsOfStudy", "s2FieldsOfStudy",
])


class SemanticScholarClient:
    """很小的 Semantic Scholar 客户端。"""

    def __init__(self, config: PaperAgentConfig):
        self.config = config

    def enhance_many(self, candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not self.config.enable_semantic_scholar:
            return candidates
        out: list[dict[str, Any]] = []
        for idx, candidate in enumerate(candidates):
            if idx >= self.config.semantic_scholar_max:
                out.append(candidate)
                continue
            try:
                out.append(self.enhance(candidate))
            except Exception as exc:  # 外部 API 失败不阻断日跑
                enriched = dict(candidate)
                enriched.setdefault("source_errors", []).append({"source": "Semantic Scholar", "error": str(exc)})
                out.append(enriched)
            time.sleep(0.2 if self.config.semantic_scholar_api_key else 1.2)
        return out

    def enhance(self, candidate: dict[str, Any]) -> dict[str, Any]:
        paper = None
        arxiv_id = arxiv_base_id(candidate.get("arxiv_id"))
        doi = candidate.get("doi")
        if doi:
            paper = self._get_paper(f"DOI:{doi}")
        if paper is None and arxiv_id:
            paper = self._get_paper(f"ARXIV:{arxiv_id}")
        if paper is None and candidate.get("title"):
            paper = self._search_title(candidate["title"])
        if paper is None:
            return candidate
        return self._merge(candidate, paper)

    def _get_paper(self, paper_id: str) -> dict[str, Any] | None:
        quoted = urllib.parse.quote(paper_id, safe=":")
        url = f"{S2_BASE}/paper/{quoted}?fields={urllib.parse.quote(FIELDS)}"
        return self._request_json(url)

    def _search_title(self, title: str) -> dict[str, Any] | None:
        params = urllib.parse.urlencode({"query": title, "limit": 5, "fields": FIELDS})
        payload = self._request_json(f"{S2_BASE}/paper/search?{params}")
        rows = payload.get("data") if payload else None
        if not rows:
            return None
        title_norm = normalize_title(title)
        best = None
        best_score = 0.0
        for row in rows:
            score = SequenceMatcher(None, title_norm, normalize_title(row.get("title") or "")).ratio()
            if score > best_score:
                best = row
                best_score = score
        return best if best_score >= 0.82 else None

    def _request_json(self, url: str) -> dict[str, Any] | None:
        headers = {"User-Agent": self.config.user_agent}
        if self.config.semantic_scholar_api_key:
            headers["x-api-key"] = self.config.semantic_scholar_api_key
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.config.http_timeout_seconds) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if exc.code == 429:
                retry_after = exc.headers.get("retry-after")
                if retry_after and retry_after.isdigit():
                    time.sleep(min(int(retry_after), 10))
            raise

    def _merge(self, candidate: dict[str, Any], paper: dict[str, Any]) -> dict[str, Any]:
        external = paper.get("externalIds") or {}
        pdf = paper.get("openAccessPdf") or {}
        fields = paper.get("fieldsOfStudy") or []
        s2_fields = [f.get("category") for f in paper.get("s2FieldsOfStudy") or [] if f.get("category")]
        authors = [a.get("name") for a in paper.get("authors") or [] if a.get("name")]
        enriched = dict(candidate)
        enriched.update({
            "semantic_scholar_id": paper.get("paperId") or candidate.get("semantic_scholar_id"),
            "corpus_id": paper.get("corpusId") or candidate.get("corpus_id"),
            "doi": external.get("DOI") or candidate.get("doi"),
            "url": paper.get("url") or candidate.get("url"),
            "pdf_url": pdf.get("url") or candidate.get("pdf_url"),
            "venue": paper.get("venue") or candidate.get("venue"),
            "year": paper.get("year") or candidate.get("year"),
            "published_at": paper.get("publicationDate") or candidate.get("published_at"),
            "citation_count": paper.get("citationCount"),
            "influential_citation_count": paper.get("influentialCitationCount"),
            "fields": fields + s2_fields,
            "semantic_scholar_payload": paper,
        })
        if not enriched.get("abstract") and paper.get("abstract"):
            enriched["abstract"] = paper["abstract"]
        if authors:
            enriched["authors"] = authors
        return enriched
