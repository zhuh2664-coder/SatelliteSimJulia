"""论文 Agent 配置。"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[3]


@dataclass
class PaperAgentConfig:
    """运行配置,所有 secret 只从环境变量读取。"""

    project_root: Path = PROJECT_ROOT
    days: int = 1
    max_per_query: int = 50
    max_candidates: int = 100
    max_metadata_ingest: int = 50
    max_llm_papers: int = 5
    semantic_scholar_max: int = 20
    min_filter_score: float = 35.0
    enable_semantic_scholar: bool = True
    no_llm: bool = False
    no_fetch: bool = False
    dry_run: bool = False
    create_pr: bool = False
    source_sleep_seconds: float = 1.0
    http_timeout_seconds: int = 30
    max_pdf_mb: int = 25
    max_pdf_pages: int = 8
    max_text_chars: int = 24000
    user_agent: str = "SatelliteSimJulia-PaperAgent/0.1"

    @property
    def literature_dir(self) -> Path:
        return self.project_root / "docs" / "literature"

    @property
    def agent_dir(self) -> Path:
        return self.literature_dir / "_paper_agent"

    @property
    def sqlite_path(self) -> Path:
        return self.agent_dir / "papers.sqlite"

    @property
    def pdf_cache_dir(self) -> Path:
        return self.agent_dir / "pdf_cache"

    @property
    def notes_dir(self) -> Path:
        return self.agent_dir / "notes"

    @property
    def reports_dir(self) -> Path:
        return self.agent_dir / "reports"

    @property
    def runs_dir(self) -> Path:
        return self.agent_dir / "runs"

    @property
    def main_markdown_path(self) -> Path:
        return self.literature_dir / "15_自动论文知识库.md"

    @property
    def openai_base_url(self) -> str | None:
        return os.getenv("OPENAI_BASE_URL")

    @property
    def openai_api_key(self) -> str | None:
        return os.getenv("OPENAI_API_KEY")

    @property
    def openai_model_name(self) -> str:
        return os.getenv("OPENAI_MODEL_NAME", "gpt-5.5")

    @property
    def semantic_scholar_api_key(self) -> str | None:
        return os.getenv("SEMANTIC_SCHOLAR_API_KEY")

    @classmethod
    def from_env(cls) -> "PaperAgentConfig":
        """从环境变量读取默认配置。"""
        def env_int(name: str, default: int) -> int:
            value = os.getenv(name)
            if not value:
                return default
            try:
                return int(value)
            except ValueError:
                return default

        def env_bool(name: str, default: bool = False) -> bool:
            value = os.getenv(name)
            if value is None:
                return default
            return value.strip().lower() in {"1", "true", "yes", "on"}

        def env_float(name: str, default: float) -> float:
            value = os.getenv(name)
            if not value:
                return default
            try:
                return float(value)
            except ValueError:
                return default

        return cls(
            max_per_query=env_int("PAPER_AGENT_MAX_PER_QUERY", 50),
            max_candidates=env_int("PAPER_AGENT_MAX_CANDIDATES", 100),
            max_metadata_ingest=env_int("PAPER_AGENT_MAX_METADATA_INGEST", 50),
            max_llm_papers=env_int("PAPER_AGENT_MAX_LLM_PAPERS_PER_DAY", 5),
            semantic_scholar_max=env_int("PAPER_AGENT_SEMANTIC_SCHOLAR_MAX", 20),
            min_filter_score=env_float("PAPER_AGENT_MIN_FILTER_SCORE", 35.0),
            enable_semantic_scholar=not env_bool("PAPER_AGENT_NO_SEMANTIC_SCHOLAR", False),
            no_llm=env_bool("PAPER_AGENT_NO_LLM", False),
            no_fetch=env_bool("PAPER_AGENT_NO_FETCH", False),
            http_timeout_seconds=env_int("PAPER_AGENT_HTTP_TIMEOUT_S", 30),
            max_pdf_mb=env_int("PAPER_AGENT_MAX_PDF_MB", 25),
            max_pdf_pages=env_int("PAPER_AGENT_MAX_PDF_PAGES", 8),
            max_text_chars=env_int("PAPER_AGENT_MAX_TEXT_CHARS", 24000),
            user_agent=os.getenv("PAPER_AGENT_USER_AGENT", "SatelliteSimJulia-PaperAgent/0.1"),
        )

    def ensure_dirs(self) -> None:
        """创建运行所需目录。"""
        for path in [self.literature_dir, self.agent_dir, self.pdf_cache_dir,
                     self.notes_dir, self.reports_dir, self.runs_dir]:
            path.mkdir(parents=True, exist_ok=True)

    def public_dict(self) -> dict[str, Any]:
        """返回不含 secret 的配置摘要。"""
        return {
            "project_root": str(self.project_root),
            "days": self.days,
            "max_per_query": self.max_per_query,
            "max_candidates": self.max_candidates,
            "max_metadata_ingest": self.max_metadata_ingest,
            "max_llm_papers": self.max_llm_papers,
            "semantic_scholar_max": self.semantic_scholar_max,
            "min_filter_score": self.min_filter_score,
            "enable_semantic_scholar": self.enable_semantic_scholar,
            "no_llm": self.no_llm,
            "no_fetch": self.no_fetch,
            "dry_run": self.dry_run,
            "create_pr": self.create_pr,
            "sqlite_path": str(self.sqlite_path),
            "main_markdown_path": str(self.main_markdown_path),
            "openai_base_url_set": bool(self.openai_base_url),
            "openai_api_key_set": bool(self.openai_api_key),
            "openai_model_name": self.openai_model_name,
            "semantic_scholar_api_key_set": bool(self.semantic_scholar_api_key),
        }
