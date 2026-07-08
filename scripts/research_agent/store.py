#!/usr/bin/env python3
"""JSONL store helpers for research papers and repos."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from .config import META_JSON, PAPERS_JSONL, REPOS_JSONL, RUNS_DIR, STORE_DIR


def utc_now() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def ensure_store() -> None:
    STORE_DIR.mkdir(parents=True, exist_ok=True)
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    for path in (PAPERS_JSONL, REPOS_JSONL):
        if not path.exists():
            path.write_text("", encoding="utf-8")
    if not META_JSON.exists():
        write_meta({"created_at": utc_now(), "last_collect_at": None, "stats": {}})


def write_meta(meta: Dict[str, Any]) -> None:
    META_JSON.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def read_meta() -> Dict[str, Any]:
    ensure_store()
    if not META_JSON.exists():
        return {}
    return json.loads(META_JSON.read_text(encoding="utf-8"))


def _read_jsonl(path: Path) -> List[Dict[str, Any]]:
    ensure_store()
    if not path.exists() or path.stat().st_size == 0:
        return []
    items: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                items.append(obj)
    return items


def _write_jsonl(path: Path, items: Iterable[Dict[str, Any]]) -> None:
    ensure_store()
    with path.open("w", encoding="utf-8") as f:
        for item in items:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")


def load_papers() -> List[Dict[str, Any]]:
    return _read_jsonl(PAPERS_JSONL)


def load_repos() -> List[Dict[str, Any]]:
    return _read_jsonl(REPOS_JSONL)


def upsert_by_id(existing: List[Dict[str, Any]], incoming: List[Dict[str, Any]], id_key: str) -> Dict[str, int]:
    """Merge incoming into existing by id_key. Returns counts."""
    index = {str(item.get(id_key, "")): item for item in existing if item.get(id_key)}
    added = 0
    updated = 0
    for item in incoming:
        key = str(item.get(id_key, "")).strip()
        if not key:
            continue
        if key in index:
            old = index[key]
            merged = dict(old)
            merged.update(item)
            # Preserve first_seen_at if present.
            if "first_seen_at" in old:
                merged["first_seen_at"] = old["first_seen_at"]
            index[key] = merged
            updated += 1
        else:
            item = dict(item)
            item.setdefault("first_seen_at", item.get("collected_at", utc_now()))
            index[key] = item
            added += 1
    # Stable-ish order: newest collected/published first when available.
    def sort_key(x: Dict[str, Any]):
        return (
            str(x.get("published") or x.get("pushed_at") or x.get("collected_at") or ""),
            str(x.get(id_key) or ""),
        )

    merged_list = sorted(index.values(), key=sort_key, reverse=True)
    return {"items": merged_list, "added": added, "updated": updated, "total": len(merged_list)}  # type: ignore[return-value]


def save_papers(items: List[Dict[str, Any]]) -> None:
    _write_jsonl(PAPERS_JSONL, items)


def save_repos(items: List[Dict[str, Any]]) -> None:
    _write_jsonl(REPOS_JSONL, items)


def save_run_report(report: Dict[str, Any]) -> Path:
    ensure_store()
    stamp = datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = RUNS_DIR / f"run_{stamp}.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def keyword_match(text: str, query: str) -> bool:
    q = query.strip().lower()
    if not q:
        return True
    hay = text.lower()
    # AND of whitespace-separated tokens; quoted phrases supported simply.
    tokens: List[str] = []
    buf = ""
    in_quote = False
    for ch in q:
        if ch == '"':
            in_quote = not in_quote
            continue
        if ch.isspace() and not in_quote:
            if buf:
                tokens.append(buf)
                buf = ""
            continue
        buf += ch
    if buf:
        tokens.append(buf)
    return all(tok in hay for tok in tokens)


def filter_items(
    items: List[Dict[str, Any]],
    *,
    query: str = "",
    limit: int = 20,
    since: Optional[str] = None,
    fields: Optional[List[str]] = None,
) -> List[Dict[str, Any]]:
    fields = fields or ["title", "summary", "description", "full_name", "query_name", "topics"]
    out: List[Dict[str, Any]] = []
    for item in items:
        if since:
            stamp = str(item.get("published") or item.get("pushed_at") or item.get("collected_at") or "")
            if stamp and stamp[:10] < since[:10]:
                continue
        blob = " ".join(str(item.get(f, "")) for f in fields)
        if not keyword_match(blob, query):
            continue
        out.append(item)
        if len(out) >= limit:
            break
    return out
