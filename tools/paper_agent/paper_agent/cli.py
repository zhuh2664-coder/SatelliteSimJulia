"""命令行入口。"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .config import PaperAgentConfig
from .db import PaperStore
from .git_pr import create_weekly_pr
from .graph import run_agent
from .render import render_main_markdown, render_notes, render_weekly_report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="SatelliteSimJulia 论文知识库维护 Agent")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init-db", help="初始化 SQLite")

    daily = sub.add_parser("daily", help="每日发现、入库、摘要并渲染 Markdown")
    _add_common_args(daily)

    render = sub.add_parser("render", help="只从 SQLite 渲染 Markdown")
    render.add_argument("--notes-limit", type=int, default=50)

    weekly = sub.add_parser("weekly", help="生成周报；可选创建 PR")
    weekly.add_argument("--create-pr", action="store_true", help="创建分支并用 gh 创建 PR")
    weekly.add_argument("--dry-run", action="store_true", help="只展示 PR 命令，不执行 git/gh")

    sub.add_parser("list-actions", help="列出待确认动作")

    confirm = sub.add_parser("confirm-action", help="确认并应用一个动作")
    confirm.add_argument("--action-id", required=True)
    confirm.add_argument("--yes", action="store_true", help="非交互确认；仍会校验确认文本")

    args = parser.parse_args(argv)
    config = PaperAgentConfig.from_env()
    store = PaperStore(config)

    if args.command == "init-db":
        config.ensure_dirs()
        store.init_db()
        print(f"已初始化 SQLite: {config.sqlite_path}")
        return 0

    if args.command == "daily":
        _apply_common_args(config, args)
        state = run_agent(config, mode="daily")
        print(json.dumps({
            "run_id": state.get("run_id"),
            "stats": state.get("stats"),
            "errors": state.get("errors"),
            "render_outputs": state.get("render_outputs"),
        }, ensure_ascii=False, indent=2))
        return 0 if not state.get("errors") else 2

    if args.command == "render":
        config.ensure_dirs()
        store.init_db()
        main_path = render_main_markdown(config, store)
        notes = render_notes(config, store, limit=args.notes_limit)
        print(f"已渲染主文档: {main_path}")
        print(f"已渲染单篇笔记: {len(notes)} 个")
        return 0

    if args.command == "weekly":
        config.ensure_dirs()
        store.init_db()
        report_path = render_weekly_report(config, store)
        main_path = render_main_markdown(config, store)
        print(f"已渲染主文档: {main_path}")
        print(f"已渲染周报: {report_path}")
        if args.create_pr:
            result = create_weekly_pr(config, report_path, dry_run=args.dry_run)
            print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    if args.command == "list-actions":
        store.init_db()
        actions = store.list_actions(status="proposed")
        if not actions:
            print("暂无待确认动作。")
            return 0
        for action in actions:
            print(f"{action['id']} | {action['action_type']} | {action.get('paper_id') or action.get('target_path')} | {action['reason']}")
        return 0

    if args.command == "confirm-action":
        store.init_db()
        expected = f"APPLY {args.action_id}"
        if args.yes:
            confirmation = expected
        else:
            print(f"即将确认动作 {args.action_id}。如果确定，请输入：{expected}")
            confirmation = input("> ").strip()
        action = store.confirm_action(args.action_id, confirmation)
        print(json.dumps(action, ensure_ascii=False, indent=2))
        return 0

    parser.error("未知命令")
    return 1


def _add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--days", type=int, default=None, help="检索最近几天")
    parser.add_argument("--max-per-query", type=int, default=None, help="每个 arXiv 查询最多返回多少篇")
    parser.add_argument("--max-candidates", type=int, default=None, help="候选总上限")
    parser.add_argument("--max-llm-papers", type=int, default=None, help="每日 LLM 深读上限")
    parser.add_argument("--min-filter-score", type=float, default=None, help="进入主知识库的最低相关性过滤分")
    parser.add_argument("--no-llm", action="store_true", help="跳过 LLM 摘要")
    parser.add_argument("--no-fetch", action="store_true", help="跳过 PDF 下载")
    parser.add_argument("--no-semantic-scholar", action="store_true", help="跳过 Semantic Scholar 增强")


def _apply_common_args(config: PaperAgentConfig, args: argparse.Namespace) -> None:
    if args.days is not None:
        config.days = args.days
    if args.max_per_query is not None:
        config.max_per_query = args.max_per_query
    if args.max_candidates is not None:
        config.max_candidates = args.max_candidates
    if args.max_llm_papers is not None:
        config.max_llm_papers = args.max_llm_papers
    if args.min_filter_score is not None:
        config.min_filter_score = args.min_filter_score
    if args.no_llm:
        config.no_llm = True
    if args.no_fetch:
        config.no_fetch = True
    if args.no_semantic_scholar:
        config.enable_semantic_scholar = False


if __name__ == "__main__":
    raise SystemExit(main())
