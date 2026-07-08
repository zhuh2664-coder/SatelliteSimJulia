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
    DEFAULT_PAPER_DAYS,
    DEFAULT_PAPER_MAX_PER_QUERY,
    DEFAULT_REPO_PER_PAGE,
    GITHUB_API,
    GITHUB_QUERIES,
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


def collect_papers(*, days: int = DEFAULT_PAPER_DAYS, max_per_query: int = DEFAULT_PAPER_MAX_PER_QUERY, query_id: Optional[str] = None) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    queries = ARXIV_QUERIES
    if query_id:
        queries = [q for q in ARXIV_QUERIES if q["id"] == query_id]
    all_papers: List[Dict[str, Any]] = []
    stats: Dict[str, Any] = {}
    errors: List[str] = []
    for q in queries:
        batch = fetch_arxiv_query(q, max_results=max_per_query, days=days)
        time.sleep(3.0)  # arXiv courtesy; HTTPS + retries still need spacing
        if batch and "_error" in batch[0]:
            errors.append(f"{q['id']}: {batch[0]['_error']}")
            stats[q["id"]] = 0
            continue
        stats[q["id"]] = len(batch)
        all_papers.extend(batch)
    # Dedup by arxiv id within this run.
    seen = {}
    for p in all_papers:
        aid = p.get("arxiv_id") or p.get("id")
        if not aid:
            continue
        seen[aid] = p
    papers = sorted(seen.values(), key=lambda x: x.get("published", ""), reverse=True)
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
        merged = store.upsert_by_id(existing, new_papers, "arxiv_id")
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
