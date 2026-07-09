"""每周 PR 的保护性封装。"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from .config import PaperAgentConfig
from .util import iso_week_label


def create_weekly_pr(config: PaperAgentConfig, report_path: Path, dry_run: bool = True) -> dict[str, Any]:
    """创建每周 PR；dry-run 时只返回将执行的命令。"""
    branch = f"paper-agent/{iso_week_label()}"
    files = [config.main_markdown_path, report_path]
    commands = [
        ["git", "status", "--short"],
        ["git", "checkout", "-b", branch],
        ["git", "add", "-f", *[str(path.relative_to(config.project_root)) for path in files if path.exists()]],
        ["git", "commit", "-m", f"paper-agent: weekly literature update {iso_week_label()}"],
        ["git", "push", "-u", "origin", branch],
        ["gh", "pr", "create", "--title", f"chore(literature): weekly paper knowledge update {iso_week_label()}", "--body-file", str(report_path)],
    ]
    if dry_run:
        return {"dry_run": True, "branch": branch, "commands": commands}

    status = _run(config.project_root, ["git", "status", "--short"])
    if status.strip():
        raise RuntimeError("工作区存在未提交改动；为避免混入无关内容，拒绝自动创建 PR。请先手动处理 git status。")
    for command in commands[1:-1]:
        _run(config.project_root, command)
    pr_url = _run(config.project_root, commands[-1]).strip()
    return {"dry_run": False, "branch": branch, "pr_url": pr_url}


def _run(cwd: Path, command: list[str]) -> str:
    result = subprocess.run(command, cwd=str(cwd), text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"命令失败: {' '.join(command)}\n{result.stderr or result.stdout}")
    return result.stdout
