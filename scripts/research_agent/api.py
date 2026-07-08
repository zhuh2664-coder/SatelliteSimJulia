#!/usr/bin/env python3
"""Read-only research API tools (MCP-facing)."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from . import collect, store
from .config import ARXIV_QUERIES, GITHUB_QUERIES, STORE_DIR


def tool_research_status(_args: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    store.ensure_store()
    meta = store.read_meta()
    papers = store.load_papers()
    repos = store.load_repos()
    return {
        "store_dir": str(STORE_DIR),
        "meta": meta,
        "papers_count": len(papers),
        "repos_count": len(repos),
        "arxiv_query_ids": [q["id"] for q in ARXIV_QUERIES],
        "github_query_ids": [q["id"] for q in GITHUB_QUERIES],
    }


def tool_research_collect(args: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    args = args or {}
    days = int(args.get("days", 14))
    max_per_query = int(args.get("max_per_query", 40))
    per_page = int(args.get("per_page", 30))
    do_papers = bool(args.get("papers", True))
    do_repos = bool(args.get("repos", True))
    report = collect.run_collect(
        days=days,
        max_per_query=max_per_query,
        per_page=per_page,
        papers=do_papers,
        repos=do_repos,
    )
    return report


def tool_research_search_papers(args: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    args = args or {}
    query = str(args.get("query", ""))
    limit = int(args.get("limit", 20))
    since = args.get("since")
    since_s = str(since) if since else None
    items = store.filter_items(
        store.load_papers(),
        query=query,
        limit=limit,
        since=since_s,
        fields=["title", "summary", "authors", "query_name", "category", "arxiv_id"],
    )
    return {"count": len(items), "items": items}


def tool_research_search_repos(args: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    args = args or {}
    query = str(args.get("query", ""))
    limit = int(args.get("limit", 20))
    since = args.get("since")
    since_s = str(since) if since else None
    items = store.filter_items(
        store.load_repos(),
        query=query,
        limit=limit,
        since=since_s,
        fields=["full_name", "description", "language", "query_name", "topics"],
    )
    return {"count": len(items), "items": items}


def tool_research_get_latest(args: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    args = args or {}
    kind = str(args.get("kind", "all")).lower()  # papers | repos | all
    limit = int(args.get("limit", 20))
    papers: List[Dict[str, Any]] = []
    repos: List[Dict[str, Any]] = []
    if kind in ("papers", "all", "paper"):
        papers = store.load_papers()[:limit]
    if kind in ("repos", "all", "repo"):
        repos = store.load_repos()[:limit]
    return {
        "kind": kind,
        "papers": papers,
        "repos": repos,
        "papers_count": len(papers),
        "repos_count": len(repos),
    }


def tool_research_get_item(args: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    args = args or {}
    item_id = str(args.get("id", "")).strip()
    if not item_id:
        raise ValueError("missing required argument: id")
    kind = str(args.get("kind", "auto")).lower()

    if kind in ("auto", "paper", "papers"):
        for p in store.load_papers():
            if p.get("arxiv_id") == item_id or p.get("id") == item_id:
                return {"found": True, "kind": "paper", "item": p}
        if kind != "auto":
            return {"found": False, "kind": "paper", "id": item_id}

    if kind in ("auto", "repo", "repos"):
        for r in store.load_repos():
            if r.get("full_name") == item_id or r.get("id") == item_id:
                return {"found": True, "kind": "repo", "item": r}
        return {"found": False, "kind": "repo", "id": item_id}

    return {"found": False, "kind": kind, "id": item_id}


TOOLS = {
    "research_status": tool_research_status,
    "research_collect": tool_research_collect,
    "research_search_papers": tool_research_search_papers,
    "research_search_repos": tool_research_search_repos,
    "research_get_latest": tool_research_get_latest,
    "research_get_item": tool_research_get_item,
}

TOOL_SCHEMAS = {
    "research_status": {
        "name": "research_status",
        "description": "Return research store status: counts, last collect time, query ids. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
    },
    "research_collect": {
        "name": "research_collect",
        "description": (
            "Run a collection cycle: fetch recent arXiv papers and GitHub repos related to "
            "LEO constellation / satellite network simulation, upsert into local research_store. "
            "Side effect: writes local JSONL store. Uses GH_TOKEN/GITHUB_TOKEN if set."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "days": {"type": "integer", "description": "arXiv lookback days (default 14)"},
                "max_per_query": {"type": "integer", "description": "max papers per arXiv query"},
                "per_page": {"type": "integer", "description": "GitHub search per_page"},
                "papers": {"type": "boolean", "description": "collect papers (default true)"},
                "repos": {"type": "boolean", "description": "collect repos (default true)"},
            },
            "additionalProperties": False,
        },
    },
    "research_search_papers": {
        "name": "research_search_papers",
        "description": "Search collected papers in local research_store by keyword. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "keyword tokens (AND)"},
                "limit": {"type": "integer", "description": "max results (default 20)"},
                "since": {"type": "string", "description": "YYYY-MM-DD lower bound on published"},
            },
            "additionalProperties": False,
        },
    },
    "research_search_repos": {
        "name": "research_search_repos",
        "description": "Search collected GitHub repos in local research_store by keyword. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "keyword tokens (AND)"},
                "limit": {"type": "integer", "description": "max results (default 20)"},
                "since": {"type": "string", "description": "YYYY-MM-DD lower bound on pushed_at"},
            },
            "additionalProperties": False,
        },
    },
    "research_get_latest": {
        "name": "research_get_latest",
        "description": "Return newest collected papers and/or repos from local store. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "kind": {"type": "string", "description": "papers | repos | all"},
                "limit": {"type": "integer", "description": "max items per kind (default 20)"},
            },
            "additionalProperties": False,
        },
    },
    "research_get_item": {
        "name": "research_get_item",
        "description": "Get one paper (arxiv id) or repo (owner/name) from local store. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "arxiv id or owner/repo"},
                "kind": {"type": "string", "description": "auto | paper | repo"},
            },
            "required": ["id"],
            "additionalProperties": False,
        },
    },
}
