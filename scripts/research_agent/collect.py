#!/usr/bin/env python3
"""Collectors: arXiv papers + GitHub repositories."""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

from .config import (
    ARXIV_API,
    ARXIV_QUERIES,
    CROSSREF_API,
    DEFAULT_PAPER_DAYS,
    DEFAULT_PAPER_MAX_PER_QUERY,
    DEFAULT_REPO_PER_PAGE,
    GITHUB_API,
    GITHUB_QUERIES,
    OPENALEX_API,
    PAPER_KEYWORD_QUERIES,
    S2_API,
    USER_AGENT,
)
from . import store


def _http_get(
    url: str,
    headers: Optional[Dict[str, str]] = None,
    timeout: int = 90,
    *,
    retries: int = 4,
) -> bytes:
    hdrs = {"User-Agent": USER_AGENT}
    if headers:
        hdrs.update(headers)
    last_err: Optional[BaseException] = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            last_err = e
            # Retry rate limits / transient gateway errors.
            if e.code in (429, 500, 502, 503, 504) and attempt < retries:
                retry_after = e.headers.get("Retry-After") if e.headers else None
                try:
                    wait_s = float(retry_after) if retry_after else (3.0 * (2**attempt))
                except ValueError:
                    wait_s = 3.0 * (2**attempt)
                time.sleep(min(max(wait_s, 1.0), 60.0))
                continue
            raise
        except (TimeoutError, urllib.error.URLError) as e:
            last_err = e
            if attempt < retries:
                time.sleep(3.0 * (2**attempt))
                continue
            raise
    raise RuntimeError(f"HTTP GET failed after retries: {last_err}")


def fetch_arxiv_query(
    query_def: Dict[str, Any],
    *,
    max_results: int = DEFAULT_PAPER_MAX_PER_QUERY,
    days: int = DEFAULT_PAPER_DAYS,
) -> List[Dict[str, Any]]:
    cats = query_def.get("categories", ["cs.NI"])
    cat_clause = " OR ".join(f"cat:{c}" for c in cats)
    full_query = f"({query_def['query']}) AND ({cat_clause})"
    params = {
        "search_query": full_query,
        "start": 0,
        "max_results": max_results,
        "sortBy": "submittedDate",
        "sortOrder": "descending",
    }
    url = ARXIV_API + "?" + urllib.parse.urlencode(params)
    try:
        xml_data = _http_get(url, timeout=90, retries=4).decode("utf-8")
    except Exception as e:
        return [{"_error": str(e), "query_id": query_def["id"]}]

    ns = {
        "atom": "http://www.w3.org/2005/Atom",
        "arxiv": "http://arxiv.org/schemas/atom",
    }
    try:
        root = ET.fromstring(xml_data)
    except ET.ParseError as e:
        return [{"_error": f"xml parse: {e}", "query_id": query_def["id"]}]

    cutoff = (datetime.now(tz=timezone.utc) - timedelta(days=days)).date().isoformat()
    collected_at = store.utc_now()
    papers: List[Dict[str, Any]] = []

    for entry in root.findall("atom:entry", ns):
        title_el = entry.find("atom:title", ns)
        title = (title_el.text or "").strip().replace("\n", " ") if title_el is not None else ""

        summary_el = entry.find("atom:summary", ns)
        summary = (summary_el.text or "").strip().replace("\n", " ") if summary_el is not None else ""

        published_el = entry.find("atom:published", ns)
        published = (published_el.text or "").strip() if published_el is not None else ""
        published_day = published[:10]

        if published_day and published_day < cutoff:
            continue

        arxiv_id = ""
        id_el = entry.find("atom:id", ns)
        if id_el is not None and id_el.text:
            m = re.search(r"arxiv.org/abs/([^\s]+)", id_el.text)
            if m:
                arxiv_id = m.group(1)

        cats_found = [c.get("term", "") for c in entry.findall("arxiv:primary_category", ns)]
        category = cats_found[0] if cats_found else ""

        authors = []
        for a in entry.findall("atom:author", ns):
            name_el = a.find("atom:name", ns)
            if name_el is not None and name_el.text:
                authors.append(name_el.text.strip())
        authors_str = "; ".join(authors[:5])
        if len(authors) > 5:
            authors_str += "; et al."

        papers.append(
            {
                "id": arxiv_id,
                "arxiv_id": arxiv_id,
                "kind": "paper",
                "source": "arxiv",
                "title": title,
                "authors": authors_str,
                "published": published_day,
                "category": category,
                "summary": summary[:500],
                "url": f"https://arxiv.org/abs/{arxiv_id}" if arxiv_id else "",
                "pdf_url": f"https://arxiv.org/pdf/{arxiv_id}.pdf" if arxiv_id else "",
                "query_id": query_def["id"],
                "query_name": query_def["name"],
                "collected_at": collected_at,
            }
        )
    return papers


def _norm_doi(doi: str) -> str:
    doi = (doi or "").strip().lower()
    for prefix in ("https://doi.org/", "http://doi.org/", "doi:"):
        if doi.startswith(prefix):
            doi = doi[len(prefix):]
    return doi


def _norm_title(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (title or "").lower()).strip()


_RELEVANT_PAT = re.compile(
    r"satellit|constellation|\bleo\b|inter-satellite|\bisl\b|starlink|oneweb|"
    r"mega-constellation|\bntn\b|non-terrestrial|space network|orbital",
    re.IGNORECASE,
)


def _relevant(title: str) -> bool:
    return bool(_RELEVANT_PAT.search(title or ""))


def _plausible_date(published: str) -> bool:
    if not published:
        return True
    year = published[:4]
    return year.isdigit() and 1990 <= int(year) <= datetime.now(tz=timezone.utc).year + 1


def _openalex_abstract(inv_index: Optional[Dict[str, List[int]]]) -> str:
    if not inv_index:
        return ""
    positions: List[Tuple[int, str]] = []
    for word, idxs in inv_index.items():
        for i in idxs:
            positions.append((i, word))
    positions.sort()
    return " ".join(w for _, w in positions)[:500]


def fetch_openalex(query_def: Dict[str, Any], *, max_results: int, days: int) -> List[Dict[str, Any]]:
    since = (datetime.now(tz=timezone.utc) - timedelta(days=days)).date().isoformat()
    params = {
        "search": query_def["q"],
        "filter": f"from_publication_date:{since}",
        "per-page": min(max_results, 100),
        "sort": "publication_date:desc",
        "mailto": "research-agent@satellitesimjulia.local",
    }
    url = OPENALEX_API + "?" + urllib.parse.urlencode(params)
    try:
        data = json.loads(_http_get(url).decode("utf-8"))
    except Exception as e:
        return [{"_error": str(e), "query_id": query_def["id"]}]

    collected_at = store.utc_now()
    papers: List[Dict[str, Any]] = []
    for w in data.get("results", []):
        if not _relevant(w.get("title") or ""):
            continue
        if not _plausible_date((w.get("publication_date") or "")[:10]):
            continue
        doi = _norm_doi(w.get("doi") or "")
        oa_id = (w.get("id") or "").rsplit("/", 1)[-1]
        authors = [
            (a.get("author") or {}).get("display_name") or ""
            for a in (w.get("authorships") or [])[:5]
        ]
        venue = ((w.get("primary_location") or {}).get("source") or {}).get("display_name") or ""
        papers.append(
            {
                "id": doi or f"openalex:{oa_id}",
                "kind": "paper",
                "source": "openalex",
                "doi": doi,
                "title": w.get("title") or "",
                "authors": "; ".join(a for a in authors if a),
                "published": (w.get("publication_date") or "")[:10],
                "category": venue,
                "summary": _openalex_abstract(w.get("abstract_inverted_index")),
                "url": w.get("doi") or (w.get("id") or ""),
                "query_id": query_def["id"],
                "query_name": query_def["name"],
                "collected_at": collected_at,
            }
        )
    return papers


def fetch_crossref(query_def: Dict[str, Any], *, max_results: int, days: int) -> List[Dict[str, Any]]:
    since = (datetime.now(tz=timezone.utc) - timedelta(days=days)).date().isoformat()
    params = {
        "query": query_def["q"],
        "filter": f"from-pub-date:{since},type:journal-article",
        "rows": min(max_results, 50),
        "sort": "score",
        "order": "desc",
        "mailto": "research-agent@satellitesimjulia.local",
    }
    url = CROSSREF_API + "?" + urllib.parse.urlencode(params)
    try:
        data = json.loads(_http_get(url).decode("utf-8"))
    except Exception as e:
        return [{"_error": str(e), "query_id": query_def["id"]}]

    collected_at = store.utc_now()
    papers: List[Dict[str, Any]] = []
    for item in (data.get("message") or {}).get("items", []):
        doi = _norm_doi(item.get("DOI") or "")
        titles = item.get("title") or []
        title = titles[0] if titles else ""
        if not _relevant(title):
            continue
        authors = [
            f"{a.get('given', '')} {a.get('family', '')}".strip()
            for a in (item.get("author") or [])[:5]
        ]
        date_parts = (
            (item.get("published-online") or item.get("published-print") or item.get("published") or {})
            .get("date-parts", [[]])
        )
        published = "-".join(f"{p:02d}" if i else str(p) for i, p in enumerate(date_parts[0])) if date_parts and date_parts[0] else ""
        venue_list = item.get("container-title") or []
        venue = venue_list[0] if venue_list else ""
        if not _plausible_date(published[:10]):
            continue
        abstract = re.sub(r"<[^>]+>", " ", item.get("abstract") or "").strip()[:500]
        papers.append(
            {
                "id": doi or f"crossref:{title[:60]}",
                "kind": "paper",
                "source": "crossref",
                "doi": doi,
                "title": title,
                "authors": "; ".join(a for a in authors if a),
                "published": published[:10],
                "category": venue,
                "summary": abstract,
                "url": f"https://doi.org/{doi}" if doi else "",
                "query_id": query_def["id"],
                "query_name": query_def["name"],
                "collected_at": collected_at,
            }
        )
    return papers


def fetch_s2(query_def: Dict[str, Any], *, max_results: int, days: int) -> List[Dict[str, Any]]:
    year = (datetime.now(tz=timezone.utc) - timedelta(days=days)).year
    params = {
        "query": query_def["q"],
        "fields": "title,abstract,externalIds,publicationDate,year,authors,venue",
        "limit": min(max_results, 50),
        "year": f"{year}-",
    }
    url = S2_API + "?" + urllib.parse.urlencode(params)
    try:
        data = json.loads(_http_get(url).decode("utf-8"))
    except Exception as e:
        return [{"_error": str(e), "query_id": query_def["id"]}]

    collected_at = store.utc_now()
    papers: List[Dict[str, Any]] = []
    for item in data.get("data", []):
        if not _relevant(item.get("title") or ""):
            continue
        ext = item.get("externalIds") or {}
        doi = _norm_doi(ext.get("DOI") or "")
        arxiv_id = ext.get("ArXiv") or ""
        pid = doi or (f"arxiv:{arxiv_id}" if arxiv_id else f"s2:{item.get('paperId', '')}")
        if arxiv_id:
            pid = arxiv_id  # align with arXiv source ids
        authors = [a.get("name") or "" for a in (item.get("authors") or [])[:5]]
        papers.append(
            {
                "id": pid,
                "kind": "paper",
                "source": "semanticscholar",
                "doi": doi,
                "arxiv_id": arxiv_id,
                "title": item.get("title") or "",
                "authors": "; ".join(a for a in authors if a),
                "published": (item.get("publicationDate") or f"{item.get('year', '')}")[:10],
                "category": item.get("venue") or "",
                "summary": (item.get("abstract") or "")[:500],
                "url": f"https://doi.org/{doi}" if doi else (f"https://arxiv.org/abs/{arxiv_id}" if arxiv_id else ""),
                "query_id": query_def["id"],
                "query_name": query_def["name"],
                "collected_at": collected_at,
            }
        )
    return papers


PAPER_SOURCES = ("arxiv", "openalex", "crossref", "semanticscholar")


def collect_papers(
    *,
    days: int = DEFAULT_PAPER_DAYS,
    max_per_query: int = DEFAULT_PAPER_MAX_PER_QUERY,
    query_id: Optional[str] = None,
    sources: Tuple[str, ...] = PAPER_SOURCES,
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    all_papers: List[Dict[str, Any]] = []
    stats: Dict[str, Any] = {}
    errors: List[str] = []

    def run_batch(label: str, batch: List[Dict[str, Any]]) -> None:
        if batch and "_error" in batch[0]:
            errors.append(f"{label}: {batch[0]['_error']}")
            stats[label] = 0
            return
        stats[label] = len(batch)
        all_papers.extend(batch)

    if "arxiv" in sources:
        queries = ARXIV_QUERIES
        if query_id:
            queries = [q for q in ARXIV_QUERIES if q["id"] == query_id]
        for q in queries:
            run_batch(f"arxiv/{q['id']}", fetch_arxiv_query(q, max_results=max_per_query, days=days))
            time.sleep(3.0)  # arXiv courtesy; HTTPS + retries still need spacing

    kw_queries = PAPER_KEYWORD_QUERIES
    if query_id:
        kw_queries = [q for q in PAPER_KEYWORD_QUERIES if q["id"] == query_id] or PAPER_KEYWORD_QUERIES

    if "openalex" in sources:
        for q in kw_queries:
            run_batch(f"openalex/{q['id']}", fetch_openalex(q, max_results=max_per_query, days=days))
            time.sleep(0.4)

    if "crossref" in sources:
        for q in kw_queries:
            run_batch(f"crossref/{q['id']}", fetch_crossref(q, max_results=max_per_query, days=days))
            time.sleep(0.5)

    if "semanticscholar" in sources:
        for q in kw_queries:
            run_batch(f"s2/{q['id']}", fetch_s2(q, max_results=max_per_query, days=days))
            time.sleep(1.5)  # S2 shared pool is aggressive with 429s

    # Cross-source dedup: prefer arxiv > openalex > crossref > semanticscholar.
    priority = {"arxiv": 0, "openalex": 1, "crossref": 2, "semanticscholar": 3}
    best: Dict[str, Dict[str, Any]] = {}
    for p in all_papers:
        key = _norm_doi(p.get("doi") or "") or str(p.get("arxiv_id") or "") or _norm_title(p.get("title") or "")
        if not key:
            continue
        cur = best.get(key)
        if cur is None or priority.get(p.get("source", ""), 9) < priority.get(cur.get("source", ""), 9):
            best[key] = p
    # Second pass: collapse residual duplicates by normalized title.
    by_title: Dict[str, Dict[str, Any]] = {}
    for p in best.values():
        tkey = _norm_title(p.get("title") or "") or str(p.get("id"))
        cur = by_title.get(tkey)
        if cur is None or priority.get(p.get("source", ""), 9) < priority.get(cur.get("source", ""), 9):
            by_title[tkey] = p
    papers = sorted(by_title.values(), key=lambda x: str(x.get("published", "")), reverse=True)
    return papers, {"query_stats": stats, "errors": errors, "unique": len(papers)}


def _github_headers() -> Dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": USER_AGENT,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_github_search(query_def: Dict[str, Any], *, per_page: int = DEFAULT_REPO_PER_PAGE) -> List[Dict[str, Any]]:
    params = {
        "q": query_def["q"],
        "sort": "updated",
        "order": "desc",
        "per_page": per_page,
    }
    url = GITHUB_API + "/search/repositories?" + urllib.parse.urlencode(params)
    try:
        raw = _http_get(url, headers=_github_headers())
        data = json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:300]
        return [{"_error": f"HTTP {e.code}: {body}", "query_id": query_def["id"]}]
    except Exception as e:
        return [{"_error": str(e), "query_id": query_def["id"]}]

    collected_at = store.utc_now()
    repos: List[Dict[str, Any]] = []
    for item in data.get("items", []):
        full_name = item.get("full_name") or ""
        repos.append(
            {
                "id": full_name,
                "kind": "repo",
                "source": "github",
                "full_name": full_name,
                "name": item.get("name") or "",
                "description": item.get("description") or "",
                "url": item.get("html_url") or "",
                "stars": item.get("stargazers_count") or 0,
                "forks": item.get("forks_count") or 0,
                "language": item.get("language") or "",
                "topics": item.get("topics") or [],
                "pushed_at": (item.get("pushed_at") or "")[:10],
                "updated_at": (item.get("updated_at") or "")[:10],
                "query_id": query_def["id"],
                "query_name": query_def["name"],
                "collected_at": collected_at,
            }
        )
    return repos


def collect_repos(*, per_page: int = DEFAULT_REPO_PER_PAGE, query_id: Optional[str] = None) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    queries = GITHUB_QUERIES
    if query_id:
        queries = [q for q in GITHUB_QUERIES if q["id"] == query_id]
    all_repos: List[Dict[str, Any]] = []
    stats: Dict[str, Any] = {}
    errors: List[str] = []
    for q in queries:
        batch = fetch_github_search(q, per_page=per_page)
        time.sleep(0.8)
        if batch and "_error" in batch[0]:
            errors.append(f"{q['id']}: {batch[0]['_error']}")
            stats[q["id"]] = 0
            continue
        stats[q["id"]] = len(batch)
        all_repos.extend(batch)
    seen = {}
    for r in all_repos:
        key = r.get("full_name") or r.get("id")
        if not key:
            continue
        seen[key] = r
    repos = sorted(seen.values(), key=lambda x: x.get("pushed_at", ""), reverse=True)
    return repos, {"query_stats": stats, "errors": errors, "unique": len(repos)}


def run_collect(
    *,
    days: int = DEFAULT_PAPER_DAYS,
    max_per_query: int = DEFAULT_PAPER_MAX_PER_QUERY,
    per_page: int = DEFAULT_REPO_PER_PAGE,
    papers: bool = True,
    repos: bool = True,
) -> Dict[str, Any]:
    store.ensure_store()
    report: Dict[str, Any] = {
        "started_at": store.utc_now(),
        "papers": {},
        "repos": {},
        "ok": True,
    }

    if papers:
        new_papers, pstats = collect_papers(days=days, max_per_query=max_per_query)
        existing = store.load_papers()
        merged = store.upsert_by_id(existing, new_papers, "id")
        store.save_papers(merged["items"])  # type: ignore[arg-type]
        report["papers"] = {
            "fetched_unique": pstats.get("unique", 0),
            "added": merged["added"],
            "updated": merged["updated"],
            "total": merged["total"],
            "query_stats": pstats.get("query_stats", {}),
            "errors": pstats.get("errors", []),
        }
        if pstats.get("errors"):
            report["ok"] = False

    if repos:
        new_repos, rstats = collect_repos(per_page=per_page)
        existing = store.load_repos()
        merged = store.upsert_by_id(existing, new_repos, "full_name")
        store.save_repos(merged["items"])  # type: ignore[arg-type]
        report["repos"] = {
            "fetched_unique": rstats.get("unique", 0),
            "added": merged["added"],
            "updated": merged["updated"],
            "total": merged["total"],
            "query_stats": rstats.get("query_stats", {}),
            "errors": rstats.get("errors", []),
        }
        if rstats.get("errors"):
            report["ok"] = False

    meta = store.read_meta()
    meta["last_collect_at"] = store.utc_now()
    prev_stats = meta.get("stats") or {}
    papers_total = report.get("papers", {}).get("total")
    repos_total = report.get("repos", {}).get("total")
    if papers_total is None:
        papers_total = prev_stats.get("papers_total", len(store.load_papers()))
    if repos_total is None:
        repos_total = prev_stats.get("repos_total", len(store.load_repos()))
    meta["stats"] = {
        "papers_total": papers_total,
        "repos_total": repos_total,
    }
    store.write_meta(meta)
    report["finished_at"] = store.utc_now()
    path = store.save_run_report(report)
    report["run_report_path"] = str(path)
    return report
