#!/usr/bin/env python3
"""CLI entry for research collection + local query."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow `python3 scripts/research_collect.py` without installing a package.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from research_agent import api  # noqa: E402


def emit(obj) -> None:
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="SatelliteSimJulia research collector / query CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_status = sub.add_parser("status", help="show store status")
    p_status.set_defaults(func=lambda a: api.tool_research_status({}))

    p_collect = sub.add_parser("collect", help="fetch arXiv + GitHub into research_store")
    p_collect.add_argument("--days", type=int, default=14)
    p_collect.add_argument("--max-per-query", type=int, default=40)
    p_collect.add_argument("--per-page", type=int, default=30)
    p_collect.add_argument("--papers-only", action="store_true")
    p_collect.add_argument("--repos-only", action="store_true")

    def do_collect(a):
        papers = not a.repos_only
        repos = not a.papers_only
        return api.tool_research_collect(
            {
                "days": a.days,
                "max_per_query": a.max_per_query,
                "per_page": a.per_page,
                "papers": papers,
                "repos": repos,
            }
        )

    p_collect.set_defaults(func=do_collect)

    p_sp = sub.add_parser("search-papers", help="search local papers")
    p_sp.add_argument("query", nargs="?", default="")
    p_sp.add_argument("--limit", type=int, default=20)
    p_sp.add_argument("--since", default=None)
    p_sp.set_defaults(
        func=lambda a: api.tool_research_search_papers(
            {"query": a.query, "limit": a.limit, "since": a.since}
        )
    )

    p_sr = sub.add_parser("search-repos", help="search local repos")
    p_sr.add_argument("query", nargs="?", default="")
    p_sr.add_argument("--limit", type=int, default=20)
    p_sr.add_argument("--since", default=None)
    p_sr.set_defaults(
        func=lambda a: api.tool_research_search_repos(
            {"query": a.query, "limit": a.limit, "since": a.since}
        )
    )

    p_latest = sub.add_parser("latest", help="show latest items")
    p_latest.add_argument("--kind", default="all", choices=["all", "papers", "repos"])
    p_latest.add_argument("--limit", type=int, default=10)
    p_latest.set_defaults(
        func=lambda a: api.tool_research_get_latest({"kind": a.kind, "limit": a.limit})
    )

    p_get = sub.add_parser("get", help="get one item by id")
    p_get.add_argument("id")
    p_get.add_argument("--kind", default="auto")
    p_get.set_defaults(func=lambda a: api.tool_research_get_item({"id": a.id, "kind": a.kind}))

    args = parser.parse_args(argv)
    try:
        result = args.func(args)
        emit({"ok": True, "cmd": args.cmd, "result": result})
        return 0
    except Exception as e:
        emit({"ok": False, "cmd": args.cmd, "error_type": type(e).__name__, "message": str(e)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
