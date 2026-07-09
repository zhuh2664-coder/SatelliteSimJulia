"""SQLite 存储层。"""

from __future__ import annotations

import sqlite3
import uuid
from pathlib import Path
from typing import Any

from .config import PaperAgentConfig
from .util import canonical_id_for, json_dumps, json_loads, normalize_title, utc_now


SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id TEXT PRIMARY KEY,
    mode TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL,
    config_json TEXT,
    stats_json TEXT,
    errors_json TEXT,
    git_branch TEXT,
    pr_url TEXT
);

CREATE TABLE IF NOT EXISTS papers (
    id TEXT PRIMARY KEY,
    canonical_id TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    title_norm TEXT NOT NULL,
    authors_json TEXT,
    abstract TEXT,
    year INTEGER,
    published_at TEXT,
    source_updated_at TEXT,
    source_primary TEXT,
    arxiv_id TEXT,
    semantic_scholar_id TEXT,
    doi TEXT,
    corpus_id TEXT,
    url TEXT,
    pdf_url TEXT,
    pdf_path TEXT,
    pdf_sha256 TEXT,
    venue TEXT,
    categories_json TEXT,
    fields_json TEXT,
    citation_count INTEGER,
    influential_citation_count INTEGER,
    section_id TEXT,
    section_name TEXT,
    tier TEXT,
    module TEXT,
    relevance_score REAL,
    actionability_score REAL,
    code_status TEXT,
    priority TEXT,
    filter_score REAL,
    filter_reason TEXT,
    matched_keywords_json TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    deleted_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_papers_title_norm ON papers(title_norm);
CREATE INDEX IF NOT EXISTS idx_papers_arxiv_id ON papers(arxiv_id);
CREATE INDEX IF NOT EXISTS idx_papers_s2_id ON papers(semantic_scholar_id);
CREATE INDEX IF NOT EXISTS idx_papers_section ON papers(section_id);
CREATE INDEX IF NOT EXISTS idx_papers_status ON papers(status);
CREATE INDEX IF NOT EXISTS idx_papers_last_seen ON papers(last_seen_at);

CREATE TABLE IF NOT EXISTS paper_sources (
    id TEXT PRIMARY KEY,
    paper_id TEXT NOT NULL,
    source_name TEXT NOT NULL,
    external_id TEXT,
    url TEXT,
    fetched_at TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    FOREIGN KEY (paper_id) REFERENCES papers(id)
);

CREATE INDEX IF NOT EXISTS idx_paper_sources_paper ON paper_sources(paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_sources_source ON paper_sources(source_name, external_id);

CREATE TABLE IF NOT EXISTS paper_reads (
    id TEXT PRIMARY KEY,
    paper_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    input_kind TEXT NOT NULL,
    input_sha256 TEXT,
    model TEXT,
    prompt_version TEXT,
    summary_md TEXT,
    structured_json TEXT,
    key_contributions_json TEXT,
    methods_json TEXT,
    limitations_json TEXT,
    project_relevance_json TEXT,
    implementation_tasks_json TEXT,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cost_estimate_usd REAL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (paper_id) REFERENCES papers(id),
    FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE INDEX IF NOT EXISTS idx_paper_reads_paper ON paper_reads(paper_id);
CREATE INDEX IF NOT EXISTS idx_paper_reads_run ON paper_reads(run_id);

CREATE TABLE IF NOT EXISTS markdown_outputs (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    path TEXT NOT NULL,
    paper_id TEXT,
    run_id TEXT,
    content_sha256 TEXT NOT NULL,
    rendered_at TEXT NOT NULL,
    FOREIGN KEY (paper_id) REFERENCES papers(id),
    FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE TABLE IF NOT EXISTS actions (
    id TEXT PRIMARY KEY,
    action_type TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT,
    target_path TEXT,
    paper_id TEXT,
    reason TEXT NOT NULL,
    risk_level TEXT NOT NULL DEFAULT 'medium',
    status TEXT NOT NULL DEFAULT 'proposed',
    proposed_at TEXT NOT NULL,
    confirmed_at TEXT,
    applied_at TEXT,
    rejected_at TEXT,
    confirmation_text TEXT,
    run_id TEXT,
    FOREIGN KEY (paper_id) REFERENCES papers(id),
    FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE INDEX IF NOT EXISTS idx_actions_status ON actions(status);
CREATE INDEX IF NOT EXISTS idx_actions_paper ON actions(paper_id);
"""


class PaperStore:
    """SQLite 访问封装。"""

    def __init__(self, config: PaperAgentConfig):
        self.config = config
        self.path = config.sqlite_path

    def connect(self) -> sqlite3.Connection:
        self.config.ensure_dirs()
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def init_db(self) -> None:
        with self.connect() as conn:
            conn.executescript(SCHEMA)
            self._migrate(conn)
            conn.commit()

    def _migrate(self, conn: sqlite3.Connection) -> None:
        """给既有本地 SQLite 添加新列。"""
        rows = conn.execute("PRAGMA table_info(papers)").fetchall()
        columns = {row[1] for row in rows}
        migrations = {
            "priority": "TEXT",
            "filter_score": "REAL",
            "filter_reason": "TEXT",
            "matched_keywords_json": "TEXT",
        }
        for name, kind in migrations.items():
            if name not in columns:
                conn.execute(f"ALTER TABLE papers ADD COLUMN {name} {kind}")

    def start_run(self, mode: str, config_json: dict[str, Any]) -> str:
        run_id = f"run_{uuid.uuid4().hex[:12]}"
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO runs (id, mode, started_at, status, config_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                (run_id, mode, utc_now(), "running", json_dumps(config_json)),
            )
            conn.commit()
        return run_id

    def finish_run(
        self,
        run_id: str,
        status: str,
        stats: dict[str, Any] | None = None,
        errors: list[dict[str, Any]] | None = None,
        pr_url: str | None = None,
    ) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                UPDATE runs
                SET finished_at = ?, status = ?, stats_json = ?, errors_json = ?, pr_url = COALESCE(?, pr_url)
                WHERE id = ?
                """,
                (utc_now(), status, json_dumps(stats or {}), json_dumps(errors or []), pr_url, run_id),
            )
            conn.commit()

    def get_run(self, run_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
        return dict(row) if row else None

    def upsert_paper(self, paper: dict[str, Any], run_id: str | None = None) -> tuple[str, bool]:
        canonical_id = paper.get("canonical_id") or canonical_id_for(paper)
        paper_id = canonical_id
        title = paper.get("title") or "Untitled"
        now = utc_now()
        existing = self.get_paper(paper_id)
        inserted = existing is None
        fields = {
            "id": paper_id,
            "canonical_id": canonical_id,
            "title": title,
            "title_norm": normalize_title(title),
            "authors_json": json_dumps(paper.get("authors") or []),
            "abstract": paper.get("abstract") or paper.get("summary"),
            "year": paper.get("year"),
            "published_at": paper.get("published_at") or paper.get("published"),
            "source_updated_at": paper.get("updated_at") or paper.get("updated"),
            "source_primary": paper.get("source_primary") or paper.get("source") or "unknown",
            "arxiv_id": paper.get("arxiv_id"),
            "semantic_scholar_id": paper.get("semantic_scholar_id") or paper.get("paperId"),
            "doi": paper.get("doi"),
            "corpus_id": str(paper.get("corpus_id")) if paper.get("corpus_id") is not None else None,
            "url": paper.get("url"),
            "pdf_url": paper.get("pdf_url"),
            "pdf_path": paper.get("pdf_path"),
            "pdf_sha256": paper.get("pdf_sha256"),
            "venue": paper.get("venue"),
            "categories_json": json_dumps(paper.get("categories") or []),
            "fields_json": json_dumps(paper.get("fields") or []),
            "citation_count": paper.get("citation_count"),
            "influential_citation_count": paper.get("influential_citation_count"),
            "section_id": paper.get("section_id"),
            "section_name": paper.get("section_name"),
            "tier": paper.get("tier"),
            "module": paper.get("module"),
            "relevance_score": paper.get("relevance_score"),
            "actionability_score": paper.get("actionability_score"),
            "code_status": paper.get("code_status"),
            "priority": paper.get("priority"),
            "filter_score": paper.get("filter_score"),
            "filter_reason": paper.get("filter_reason"),
            "matched_keywords_json": json_dumps(paper.get("matched_keywords") or {}),
            "status": paper.get("status") or "active",
            "first_seen_at": existing.get("first_seen_at") if existing else now,
            "last_seen_at": now,
            "deleted_at": paper.get("deleted_at"),
            "created_at": existing.get("created_at") if existing else now,
            "updated_at": now,
        }
        columns = list(fields)
        placeholders = ",".join("?" for _ in columns)
        update_columns = [c for c in columns if c not in {"id", "canonical_id", "first_seen_at", "created_at"}]
        update_sql = ", ".join(f"{c}=excluded.{c}" for c in update_columns)
        sql = f"""
            INSERT INTO papers ({','.join(columns)}) VALUES ({placeholders})
            ON CONFLICT(canonical_id) DO UPDATE SET {update_sql}
        """
        with self.connect() as conn:
            conn.execute(sql, tuple(fields[c] for c in columns))
            conn.commit()
        if run_id:
            self.record_source(
                paper_id,
                paper.get("source_primary") or paper.get("source") or "unknown",
                paper.get("external_id") or paper.get("arxiv_id") or paper.get("semantic_scholar_id"),
                paper.get("url"),
                paper,
            )
        return paper_id, inserted

    def record_source(
        self,
        paper_id: str,
        source_name: str,
        external_id: str | None,
        url: str | None,
        payload: dict[str, Any],
    ) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO paper_sources (id, paper_id, source_name, external_id, url, fetched_at, payload_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (f"src_{uuid.uuid4().hex[:12]}", paper_id, source_name, external_id, url, utc_now(), json_dumps(payload)),
            )
            conn.commit()

    def get_paper(self, paper_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM papers WHERE id = ?", (paper_id,)).fetchone()
        return self._row_to_paper(row) if row else None

    def list_papers(self, limit: int = 200, status: str = "active") -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM papers
                WHERE status = ?
                ORDER BY COALESCE(actionability_score, 0) DESC, COALESCE(relevance_score, 0) DESC, last_seen_at DESC
                LIMIT ?
                """,
                (status, limit),
            ).fetchall()
        return [self._row_to_paper(row) for row in rows]

    def count_papers(self, status: str | None = None) -> int:
        """统计论文数量。"""
        query = "SELECT COUNT(*) FROM papers"
        params: list[Any] = []
        if status:
            query += " WHERE status = ?"
            params.append(status)
        with self.connect() as conn:
            return int(conn.execute(query, params).fetchone()[0])

    def list_recent_papers(self, since_iso: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        where = "status = 'active'"
        params: list[Any] = []
        if since_iso:
            where += " AND last_seen_at >= ?"
            params.append(since_iso)
        params.append(limit)
        with self.connect() as conn:
            rows = conn.execute(
                f"""
                SELECT * FROM papers
                WHERE {where}
                ORDER BY last_seen_at DESC, COALESCE(actionability_score, 0) DESC
                LIMIT ?
                """,
                params,
            ).fetchall()
        return [self._row_to_paper(row) for row in rows]

    def insert_read(self, paper_id: str, run_id: str, read: dict[str, Any]) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO paper_reads (
                    id, paper_id, run_id, input_kind, input_sha256, model, prompt_version,
                    summary_md, structured_json, key_contributions_json, methods_json,
                    limitations_json, project_relevance_json, implementation_tasks_json,
                    input_tokens, output_tokens, cost_estimate_usd, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    f"read_{uuid.uuid4().hex[:12]}", paper_id, run_id,
                    read.get("input_kind") or "metadata", read.get("input_sha256"),
                    read.get("model"), read.get("prompt_version"), read.get("summary_md"),
                    json_dumps(read.get("structured") or {}),
                    json_dumps(read.get("key_contributions") or []),
                    json_dumps(read.get("methods") or []),
                    json_dumps(read.get("limitations") or []),
                    json_dumps(read.get("project_relevance") or {}),
                    json_dumps(read.get("implementation_tasks") or []),
                    read.get("input_tokens"), read.get("output_tokens"), read.get("cost_estimate_usd"), utc_now(),
                ),
            )
            conn.commit()

    def latest_read(self, paper_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM paper_reads
                WHERE paper_id = ?
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (paper_id,),
            ).fetchone()
        if not row:
            return None
        result = dict(row)
        result["structured"] = json_loads(result.get("structured_json"), {})
        return result

    def record_markdown(self, kind: str, path: Path, content_hash: str, run_id: str | None = None, paper_id: str | None = None) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO markdown_outputs (id, kind, path, paper_id, run_id, content_sha256, rendered_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (f"md_{uuid.uuid4().hex[:12]}", kind, str(path), paper_id, run_id, content_hash, utc_now()),
            )
            conn.commit()

    def add_action(self, action: dict[str, Any]) -> str:
        action_id = action.get("id") or f"act_{uuid.uuid4().hex[:12]}"
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO actions (
                    id, action_type, target_type, target_id, target_path, paper_id,
                    reason, risk_level, status, proposed_at, confirmation_text, run_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    action_id, action["action_type"], action["target_type"],
                    action.get("target_id"), action.get("target_path"), action.get("paper_id"),
                    action["reason"], action.get("risk_level") or "medium",
                    action.get("status") or "proposed", utc_now(), action.get("confirmation_text"), action.get("run_id"),
                ),
            )
            conn.commit()
        return action_id

    def list_actions(self, status: str | None = "proposed") -> list[dict[str, Any]]:
        query = "SELECT * FROM actions"
        params: list[Any] = []
        if status:
            query += " WHERE status = ?"
            params.append(status)
        query += " ORDER BY proposed_at DESC"
        with self.connect() as conn:
            rows = conn.execute(query, params).fetchall()
        return [dict(row) for row in rows]

    def get_action(self, action_id: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM actions WHERE id = ?", (action_id,)).fetchone()
        return dict(row) if row else None

    def confirm_action(self, action_id: str, confirmation_text: str) -> dict[str, Any]:
        action = self.get_action(action_id)
        if not action:
            raise ValueError(f"动作不存在: {action_id}")
        if action["status"] != "proposed":
            raise ValueError(f"动作状态不是 proposed: {action['status']}")
        expected = f"APPLY {action_id}"
        if confirmation_text != expected:
            raise ValueError(f"确认文本不匹配,需要输入: {expected}")
        with self.connect() as conn:
            conn.execute(
                "UPDATE actions SET status = 'confirmed', confirmed_at = ?, confirmation_text = ? WHERE id = ?",
                (utc_now(), confirmation_text, action_id),
            )
            if action["action_type"] == "mark_deleted" and action.get("paper_id"):
                conn.execute(
                    "UPDATE papers SET status = 'deleted', deleted_at = ?, updated_at = ? WHERE id = ?",
                    (utc_now(), utc_now(), action["paper_id"]),
                )
                conn.execute(
                    "UPDATE actions SET status = 'applied', applied_at = ? WHERE id = ?",
                    (utc_now(), action_id),
                )
            conn.commit()
        return self.get_action(action_id) or action

    def _row_to_paper(self, row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["authors"] = json_loads(result.get("authors_json"), [])
        result["categories"] = json_loads(result.get("categories_json"), [])
        result["fields"] = json_loads(result.get("fields_json"), [])
        result["matched_keywords"] = json_loads(result.get("matched_keywords_json"), {})
        return result
