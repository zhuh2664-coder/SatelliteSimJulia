#!/usr/bin/env python3
"""ZCode token usage audit report.

Reads the local ZCode SQLite database in read-only mode and summarizes model_usage
without printing message contents or credentials.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sqlite3
import sys
from pathlib import Path

DEFAULT_DB = Path.home() / ".zcode" / "cli" / "db" / "db.sqlite"


def local_date_expr(column: str = "started_at") -> str:
    return f"date({column}/1000,'unixepoch','localtime')"


def connect_readonly(path: Path) -> sqlite3.Connection:
    if not path.exists():
        raise FileNotFoundError(f"ZCode usage database not found: {path}")
    uri = f"file:{path}?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    con.row_factory = sqlite3.Row
    return con


def resolve_date(value: str | None) -> str | None:
    if value is None:
        return None
    if value == "today":
        return dt.datetime.now().strftime("%Y-%m-%d")
    # Validate ISO date.
    dt.date.fromisoformat(value)
    return value


def where_clause(date_value: str | None) -> tuple[str, list[str]]:
    if date_value:
        return f"WHERE {local_date_expr()} = ?", [date_value]
    return "", []


def query(con: sqlite3.Connection, sql: str, params: list[str] | tuple = ()) -> list[sqlite3.Row]:
    return list(con.execute(sql, params))


def fmt_int(value) -> str:
    if value is None:
        return "0"
    return f"{int(value):,}"


def md_table(headers: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def text_table(title: str, headers: list[str], rows: list[list[str]]) -> str:
    lines = [title]
    if not rows:
        return title + "\n  (no rows)"
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    fmt = "  " + "  ".join("{:<" + str(w) + "}" for w in widths)
    lines.append(fmt.format(*headers))
    lines.append(fmt.format(*["-" * w for w in widths]))
    lines += [fmt.format(*row) for row in rows]
    return "\n".join(lines)


def build_report(con: sqlite3.Connection, date_value: str | None, top: int, markdown: bool) -> str:
    where, params = where_clause(date_value)
    title_scope = f"date={date_value}" if date_value else "all recorded data"

    summary_sql = f"""
    SELECT
      COUNT(*) AS requests,
      SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) AS completed,
      SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) AS errors,
      SUM(input_tokens) AS input_tokens,
      SUM(output_tokens) AS output_tokens,
      SUM(reasoning_tokens) AS reasoning_tokens,
      SUM(cache_creation_input_tokens) AS cache_creation,
      SUM(cache_read_input_tokens) AS cache_read,
      SUM(input_tokens - cache_read_input_tokens) AS non_cached_input,
      SUM(computed_total_tokens) AS computed_total
    FROM model_usage
    {where}
    """
    summary = query(con, summary_sql, params)[0]

    by_date = query(con, f"""
    SELECT
      {local_date_expr()} AS day,
      COUNT(*) AS requests,
      SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) AS completed,
      SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) AS errors,
      SUM(input_tokens) AS input_tokens,
      SUM(output_tokens) AS output_tokens,
      SUM(cache_read_input_tokens) AS cache_read,
      SUM(input_tokens - cache_read_input_tokens) AS non_cached_input,
      SUM(computed_total_tokens) AS computed_total
    FROM model_usage
    GROUP BY day
    ORDER BY day
    """)

    by_model = query(con, f"""
    SELECT
      substr(provider_id,1,36) AS provider,
      model_id AS model,
      COUNT(*) AS requests,
      SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) AS completed,
      SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) AS errors,
      SUM(input_tokens) AS input_tokens,
      SUM(output_tokens) AS output_tokens,
      SUM(cache_read_input_tokens) AS cache_read,
      SUM(input_tokens - cache_read_input_tokens) AS non_cached_input,
      SUM(computed_total_tokens) AS computed_total
    FROM model_usage
    {where}
    GROUP BY provider_id, model_id
    ORDER BY computed_total DESC
    LIMIT ?
    """, params + [top])

    by_session = query(con, f"""
    SELECT
      substr(COALESCE(s.title, mu.session_id),1,70) AS session_title,
      COUNT(mu.id) AS requests,
      SUM(mu.input_tokens) AS input_tokens,
      SUM(mu.output_tokens) AS output_tokens,
      SUM(mu.cache_read_input_tokens) AS cache_read,
      SUM(mu.input_tokens - mu.cache_read_input_tokens) AS non_cached_input,
      SUM(mu.computed_total_tokens) AS computed_total
    FROM model_usage mu
    LEFT JOIN session s ON s.id = mu.session_id
    {where.replace('started_at', 'mu.started_at')}
    GROUP BY mu.session_id
    ORDER BY computed_total DESC
    LIMIT ?
    """, params + [top])

    errors = query(con, f"""
    SELECT
      COALESCE(error_type,'') AS error_type,
      COALESCE(error_code,'') AS error_code,
      substr(COALESCE(error_message,''),1,120) AS message,
      COUNT(*) AS count
    FROM model_usage
    {where + (' AND ' if where else 'WHERE ') + "status='error'"}
    GROUP BY error_type, error_code, message
    ORDER BY count DESC
    LIMIT ?
    """, params + [top])

    def row_summary() -> list[list[str]]:
        return [[
            fmt_int(summary["requests"]),
            fmt_int(summary["completed"]),
            fmt_int(summary["errors"]),
            fmt_int(summary["input_tokens"]),
            fmt_int(summary["output_tokens"]),
            fmt_int(summary["reasoning_tokens"]),
            fmt_int(summary["cache_read"]),
            fmt_int(summary["non_cached_input"]),
            fmt_int(summary["computed_total"]),
        ]]

    headers_summary = ["requests", "completed", "errors", "input", "output", "reasoning", "cache_read", "non_cached_input", "computed_total"]

    if markdown:
        parts = [
            f"# ZCode Token Usage Report\n\nScope: `{title_scope}`\n\nDatabase: `{DEFAULT_DB}`",
            "## Summary\n\n" + md_table(headers_summary, row_summary()),
            "## By Date\n\n" + md_table(["date","requests","completed","errors","input","output","cache_read","non_cached_input","computed_total"], [[r["day"], fmt_int(r["requests"]), fmt_int(r["completed"]), fmt_int(r["errors"]), fmt_int(r["input_tokens"]), fmt_int(r["output_tokens"]), fmt_int(r["cache_read"]), fmt_int(r["non_cached_input"]), fmt_int(r["computed_total"])] for r in by_date]),
            "## By Model / Provider\n\n" + md_table(["provider","model","requests","completed","errors","input","output","cache_read","non_cached_input","computed_total"], [[r["provider"], r["model"], fmt_int(r["requests"]), fmt_int(r["completed"]), fmt_int(r["errors"]), fmt_int(r["input_tokens"]), fmt_int(r["output_tokens"]), fmt_int(r["cache_read"]), fmt_int(r["non_cached_input"]), fmt_int(r["computed_total"])] for r in by_model]),
            "## Top Sessions\n\n" + md_table(["session","requests","input","output","cache_read","non_cached_input","computed_total"], [[r["session_title"], fmt_int(r["requests"]), fmt_int(r["input_tokens"]), fmt_int(r["output_tokens"]), fmt_int(r["cache_read"]), fmt_int(r["non_cached_input"]), fmt_int(r["computed_total"])] for r in by_session]),
            "## Errors\n\n" + md_table(["error_type","error_code","message","count"], [[r["error_type"], r["error_code"], r["message"].replace('|','/'), fmt_int(r["count"])] for r in errors]),
            "## Token Accounting Notes\n\n- `computed_total_tokens` includes cached context reads and reflects total context processed locally.\n- `cache_read_input_tokens` is cached input reused by the provider/runtime.\n- `non_cached_input = input_tokens - cache_read_input_tokens` is a rough estimate of new input tokens.\n- A practical cost proxy is `non_cached_input + output_tokens + reasoning_tokens`, but billing may differ by provider.",
        ]
        return "\n\n".join(parts) + "\n"

    parts = [
        f"ZCode Token Usage Report ({title_scope})",
        text_table("Summary", headers_summary, row_summary()),
        text_table("By Date", ["date","requests","completed","errors","input","output","cache_read","non_cached_input","computed_total"], [[r["day"], fmt_int(r["requests"]), fmt_int(r["completed"]), fmt_int(r["errors"]), fmt_int(r["input_tokens"]), fmt_int(r["output_tokens"]), fmt_int(r["cache_read"]), fmt_int(r["non_cached_input"]), fmt_int(r["computed_total"])] for r in by_date]),
        text_table("By Model / Provider", ["provider","model","requests","completed","errors","input","output","cache_read","non_cached_input","computed_total"], [[r["provider"], r["model"], fmt_int(r["requests"]), fmt_int(r["completed"]), fmt_int(r["errors"]), fmt_int(r["input_tokens"]), fmt_int(r["output_tokens"]), fmt_int(r["cache_read"]), fmt_int(r["non_cached_input"]), fmt_int(r["computed_total"])] for r in by_model]),
        text_table("Top Sessions", ["session","requests","input","output","cache_read","non_cached_input","computed_total"], [[r["session_title"], fmt_int(r["requests"]), fmt_int(r["input_tokens"]), fmt_int(r["output_tokens"]), fmt_int(r["cache_read"]), fmt_int(r["non_cached_input"]), fmt_int(r["computed_total"])] for r in by_session]),
        text_table("Errors", ["error_type","error_code","message","count"], [[r["error_type"], r["error_code"], r["message"], fmt_int(r["count"])] for r in errors]),
    ]
    return "\n\n".join(parts) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit local ZCode model token usage.")
    parser.add_argument("--db", default=str(DEFAULT_DB), help="Path to ZCode db.sqlite")
    parser.add_argument("--date", help="Local date YYYY-MM-DD or 'today'. Omit for all data.")
    parser.add_argument("--all", action="store_true", help="Report all recorded data (default when --date omitted).")
    parser.add_argument("--top", type=int, default=10, help="Top N rows for model/session/error tables")
    parser.add_argument("--format", choices=("text", "markdown"), default="text")
    parser.add_argument("--output", help="Optional output file path")
    args = parser.parse_args()

    if args.all and args.date:
        parser.error("--all and --date are mutually exclusive")
    date_value = None if args.all else resolve_date(args.date)

    try:
        con = connect_readonly(Path(args.db).expanduser())
        report = build_report(con, date_value, args.top, args.format == "markdown")
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    finally:
        try:
            con.close()  # type: ignore[name-defined]
        except Exception:
            pass

    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(report, encoding="utf-8")
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
