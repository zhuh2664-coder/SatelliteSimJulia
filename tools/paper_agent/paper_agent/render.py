"""Markdown 渲染。"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from .actions import format_actions
from .config import PaperAgentConfig
from .db import PaperStore
from .util import content_hash, iso_week_label, safe_filename, today_utc, utc_now

SECTION_ORDER = ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "99"]


def render_main_markdown(config: PaperAgentConfig, store: PaperStore, run_id: str | None = None) -> Path:
    """渲染主知识库 Markdown。"""
    config.ensure_dirs()
    papers = store.list_papers(limit=300)
    candidate_pool = store.list_papers(limit=100, status="ignored_candidate")
    recent = store.list_recent_papers(since_iso=_days_ago(1), limit=100)
    weekly = store.list_recent_papers(since_iso=_days_ago(7), limit=100)
    actions = store.list_actions(status="proposed")
    latest_runs = _latest_runs(store, limit=5)
    lines: list[str] = [
        "# 板块 15: 自动论文知识库维护 Agent",
        "",
        "> 自动维护 SatelliteSimJulia 论文知识库：每日发现、阅读、摘要、入库；每周汇总并可创建 PR。",
        "",
        f"> 最近渲染：{utc_now()}",
        "",
        "## 1. 当前状态",
        "",
        f"- SQLite：`{config.sqlite_path.relative_to(config.project_root)}`",
        f"- PDF cache：`{config.pdf_cache_dir.relative_to(config.project_root)}`",
        f"- 已入库 active 论文：{len(papers)} 篇",
        f"- 候选池/低相关论文：{len(candidate_pool)} 篇",
        f"- 今日/近 24 小时新增或更新：{len(recent)} 篇",
        f"- 本周新增或更新：{len(weekly)} 篇",
        f"- 待确认动作：{len(actions)} 个",
        "",
        "### 最近运行",
        "",
    ]
    if latest_runs:
        lines.extend(["| Run | 模式 | 状态 | 开始 | 结束 |", "|---|---|---|---|---|"])
        for run in latest_runs:
            lines.append(f"| `{run['id']}` | {run['mode']} | {run['status']} | {run['started_at']} | {run.get('finished_at') or ''} |")
    else:
        lines.append("暂无运行记录。")
    lines.extend(["", "## 2. 今日新增论文", ""])
    lines.extend(_paper_table(recent[:20]))
    lines.extend(["", "## 3. 本周重点论文", ""])
    top_weekly = sorted(weekly, key=lambda p: (p.get("actionability_score") or 0, p.get("relevance_score") or 0), reverse=True)[:20]
    lines.extend(_paper_table(top_weekly))
    lines.extend(["", "## 4. 分板块知识库", ""])
    by_section: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for paper in papers:
        by_section[paper.get("section_id") or "99"].append(paper)
    for section_id in SECTION_ORDER:
        section_papers = by_section.get(section_id, [])
        if not section_papers:
            continue
        section_name = section_papers[0].get("section_name") or section_id
        lines.extend([f"### {section_id} {section_name}", ""])
        lines.extend(_paper_table(section_papers[:15]))
        lines.append("")
    lines.extend(["## 5. 单篇论文摘要索引", ""])
    lines.extend(_notes_table(config, papers[:80]))
    lines.extend(["", "## 6. 可落地任务队列", ""])
    lines.extend(_task_table(store, papers[:50]))
    lines.extend(["", "## 7. 候选池/低相关论文", ""])
    lines.extend(_candidate_pool_table(candidate_pool[:30]))
    lines.extend(["", "## 8. 待用户确认动作", "", format_actions(actions), ""])
    lines.extend(["## 9. 运行方式", "", "```bash"])
    lines.extend([
        "cd /Users/zhuhai/Research/SatelliteSimJulia",
        "python3 scripts/run_paper_agent.py init-db",
        "python3 scripts/run_paper_agent.py daily --days 1 --max-per-query 5 --no-llm",
        "python3 scripts/run_paper_agent.py daily --days 1",
        "python3 scripts/run_paper_agent.py weekly --dry-run",
        "python3 scripts/run_paper_agent.py list-actions",
        "python3 scripts/run_paper_agent.py confirm-action --action-id <id>",
    ])
    lines.extend(["```", "", "环境变量示例（不要提交真实 key）：", "", "```bash"])
    lines.extend([
        "export OPENAI_BASE_URL=http://127.0.0.1:8317/v1",
        "export OPENAI_API_KEY=...",
        "export OPENAI_MODEL_NAME=gpt-5.5",
        "export HTTP_PROXY=http://127.0.0.1:7890",
        "export HTTPS_PROXY=http://127.0.0.1:7890",
        "export NO_PROXY=127.0.0.1,localhost",
    ])
    lines.extend(["```", "", "## 10. 周报索引", ""])
    reports = sorted(config.reports_dir.glob("*.md"), reverse=True) if config.reports_dir.exists() else []
    if reports:
        for report in reports[:20]:
            rel = report.relative_to(config.literature_dir)
            lines.append(f"- [{report.stem}]({rel})")
    else:
        lines.append("暂无周报。")
    content = "\n".join(lines).rstrip() + "\n"
    config.main_markdown_path.write_text(content, encoding="utf-8")
    store.record_markdown("main", config.main_markdown_path, content_hash(content), run_id=run_id)
    return config.main_markdown_path


def render_notes(config: PaperAgentConfig, store: PaperStore, run_id: str | None = None, limit: int = 50) -> list[Path]:
    """为有摘要或高分论文渲染单篇 note。"""
    config.ensure_dirs()
    paths: list[Path] = []
    papers = store.list_papers(limit=limit)
    for paper in papers:
        read = store.latest_read(paper["id"])
        content = _note_content(paper, read)
        path = config.notes_dir / f"{safe_filename(paper['id'])}.md"
        path.write_text(content, encoding="utf-8")
        store.record_markdown("note", path, content_hash(content), run_id=run_id, paper_id=paper["id"])
        paths.append(path)
    return paths


def render_weekly_report(config: PaperAgentConfig, store: PaperStore, run_id: str | None = None) -> Path:
    """渲染每周周报。"""
    config.ensure_dirs()
    week = iso_week_label()
    papers = store.list_recent_papers(since_iso=_days_ago(7), limit=200)
    top = sorted(papers, key=lambda p: (p.get("actionability_score") or 0, p.get("relevance_score") or 0), reverse=True)[:10]
    actions = store.list_actions(status="proposed")
    lines: list[str] = [
        f"# 自动论文知识库周报 {week}",
        "",
        f"> 生成时间：{utc_now()}",
        "",
        "## 本周摘要",
        "",
        f"- 本周新增或更新论文：{len(papers)} 篇",
        f"- 待用户确认动作：{len(actions)} 个",
        "",
        "## 新增与阅读统计",
        "",
        *_paper_table(papers[:30]),
        "",
        "## 最值得读的 10 篇",
        "",
        *_paper_table(top),
        "",
        "## 最值得实现的 5 个方向",
        "",
    ]
    tasks_added = 0
    for paper in top:
        read = store.latest_read(paper["id"])
        structured = read.get("structured") if read else None
        for task in (structured or {}).get("implementation_tasks") or []:
            if isinstance(task, dict):
                lines.append(f"- [{task.get('priority', 'P?')}] {task.get('task', '')}（{task.get('module', paper.get('module') or '未指定')}）")
            else:
                lines.append(f"- {task}")
            tasks_added += 1
            if tasks_added >= 5:
                break
        if tasks_added >= 5:
            break
    if tasks_added == 0:
        lines.append("- 暂无 LLM 生成的实现任务；可先运行带 LLM 的 daily。")
    lines.extend([
        "",
        "## 与现有 00-14 文献体系的关系",
        "",
        "本周论文按既有 10 个板块分类，并优先服务 Hypatia 对标、可微优化闭环、PINN 路由、LLM 编排等路线图方向。",
        "",
        "## 待用户确认动作",
        "",
        format_actions(actions),
        "",
        "## 下周计划",
        "",
        "- 继续跟踪 arXiv 与 Semantic Scholar 新增论文。",
        "- 优先深读可落地分最高的论文。",
        "- 对重复/低相关条目只提出建议，不自动删除。",
        "",
        "## PR 内容说明",
        "",
        "PR 应只包含 Markdown 周报/总览，不包含 SQLite、PDF cache 或任何 secret。",
    ])
    content = "\n".join(lines).rstrip() + "\n"
    path = config.reports_dir / f"{week}.md"
    path.write_text(content, encoding="utf-8")
    store.record_markdown("weekly", path, content_hash(content), run_id=run_id)
    return path


def _paper_table(papers: list[dict[str, Any]]) -> list[str]:
    if not papers:
        return ["暂无。"]
    lines = ["| 分数 | 板块 | 年份 | 来源 | 标题 | 模块 | 链接 |", "|---:|---|---:|---|---|---|---|"]
    for paper in papers:
        score = paper.get("actionability_score") or paper.get("relevance_score") or 0
        title = (paper.get("title") or "").replace("|", "/")
        if len(title) > 90:
            title = title[:87] + "..."
        url = paper.get("url") or paper.get("pdf_url") or ""
        link = f"[link]({url})" if url else ""
        lines.append(
            f"| {score:.0f} | {paper.get('section_id') or '99'} {paper.get('section_name') or ''} | "
            f"{paper.get('year') or ''} | {paper.get('source_primary') or ''} | {title} | {paper.get('module') or ''} | {link} |"
        )
    return lines


def _candidate_pool_table(papers: list[dict[str, Any]]) -> list[str]:
    if not papers:
        return ["暂无低相关候选。"]
    lines = ["| 过滤分 | 标题 | 原因 | 链接 |", "|---:|---|---|---|"]
    for paper in papers:
        title = (paper.get("title") or "").replace("|", "/")
        if len(title) > 80:
            title = title[:77] + "..."
        reason = (paper.get("filter_reason") or "").replace("|", "/")
        url = paper.get("url") or paper.get("pdf_url") or ""
        link = f"[link]({url})" if url else ""
        lines.append(f"| {paper.get('filter_score') or 0:.1f} | {title} | {reason} | {link} |")
    return lines


def _notes_table(config: PaperAgentConfig, papers: list[dict[str, Any]]) -> list[str]:
    if not papers:
        return ["暂无。"]
    lines = ["| 论文 | 笔记 | PDF | arXiv/S2 |", "|---|---|---|---|"]
    for paper in papers:
        title = (paper.get("title") or "").replace("|", "/")
        if len(title) > 80:
            title = title[:77] + "..."
        note_rel = (Path("_paper_agent") / "notes" / f"{safe_filename(paper['id'])}.md").as_posix()
        pdf = "有" if paper.get("pdf_path") else ""
        ext = paper.get("arxiv_id") or paper.get("semantic_scholar_id") or ""
        lines.append(f"| {title} | [{paper['id']}]({note_rel}) | {pdf} | {ext} |")
    return lines


def _task_table(store: PaperStore, papers: list[dict[str, Any]]) -> list[str]:
    lines = ["| 优先级 | 论文 | 模块 | 任务 |", "|---|---|---|---|"]
    count = 0
    for paper in papers:
        read = store.latest_read(paper["id"])
        structured = read.get("structured") if read else None
        for task in (structured or {}).get("implementation_tasks") or []:
            if not isinstance(task, dict):
                continue
            lines.append(
                f"| {task.get('priority', 'P?')} | {(paper.get('title') or '').replace('|', '/')[:70]} | "
                f"{task.get('module') or paper.get('module') or ''} | {str(task.get('task') or '').replace('|', '/')} |"
            )
            count += 1
            if count >= 20:
                return lines
    if count == 0:
        return ["暂无 LLM 生成任务；可运行带 LLM 的 daily。"]
    return lines


def _note_content(paper: dict[str, Any], read: dict[str, Any] | None) -> str:
    authors = "; ".join(paper.get("authors") or [])
    lines = [
        f"# {paper.get('title') or 'Untitled'}",
        "",
        "## 元数据",
        "",
        "| 字段 | 值 |",
        "|---|---|",
        f"| canonical_id | `{paper['id']}` |",
        f"| 年份 | {paper.get('year') or ''} |",
        f"| 作者 | {authors} |",
        f"| 来源 | {paper.get('source_primary') or ''} |",
        f"| 板块 | {paper.get('section_id') or ''} {paper.get('section_name') or ''} |",
        f"| 模块 | {paper.get('module') or ''} |",
        f"| arXiv | {paper.get('arxiv_id') or ''} |",
        f"| Semantic Scholar | {paper.get('semantic_scholar_id') or ''} |",
        f"| DOI | {paper.get('doi') or ''} |",
        f"| URL | {paper.get('url') or ''} |",
        f"| PDF | {paper.get('pdf_url') or ''} |",
        "",
    ]
    if read and read.get("summary_md"):
        lines.append(read["summary_md"].strip())
    else:
        lines.extend([
            "## 一句话结论",
            "尚未进行 LLM 深读。",
            "",
            "## 摘要",
            paper.get("abstract") or "暂无摘要。",
        ])
    return "\n".join(lines).rstrip() + "\n"


def _latest_runs(store: PaperStore, limit: int = 5) -> list[dict[str, Any]]:
    with store.connect() as conn:
        rows = conn.execute("SELECT * FROM runs ORDER BY started_at DESC LIMIT ?", (limit,)).fetchall()
    return [dict(row) for row in rows]


def _days_ago(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
