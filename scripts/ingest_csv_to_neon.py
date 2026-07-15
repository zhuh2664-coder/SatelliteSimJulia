#!/usr/bin/env python3
"""Ingest SatelliteSimJulia experiment CSVs into Neon Postgres.

Schema (already created):
  datasets(id, name UNIQUE, category, columns jsonb, n_rows, n_cols,
           file_bytes, sha256, imported_at)
  dataset_rows(id, dataset_id -> datasets, row_index, data jsonb)

Each CSV becomes one `datasets` row; every CSV data row becomes one
`dataset_rows` row with the record stored as JSONB (types inferred:
int -> float -> string, empty -> null).

Usage:
  export NEON_DATABASE_URL='postgres://...'
  python3 ingest_csv_to_neon.py --root /path/to/repo \
      [--include experiments paper benchmark_suite competitive outputs platform artifacts] \
      [--max-mb 5] [--all] [--dry-run]

--all           ingest every CSV under --root (ignores --include / --max-mb)
--include DIRS  only CSVs whose path contains one of these segments
--max-mb N      skip files larger than N MB (0 = no cap)
"""
import argparse, csv, hashlib, json, math, os, sys
from pathlib import Path

try:
    import psycopg2
    from psycopg2.extras import execute_values
except ImportError:
    sys.exit("psycopg2 missing: pip install psycopg2-binary")


def infer(v):
    if v is None:
        return None
    s = v.strip()
    if s == "":
        return None
    try:
        i = int(s)
        return i
    except ValueError:
        pass
    try:
        f = float(s)
        if not math.isfinite(f):  # NaN / inf are not valid JSON -> store null
            return None
        return f
    except ValueError:
        return s


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_csv(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            return [], []
        rows = []
        for rec in reader:
            if not rec:
                continue
            d = {}
            for i, col in enumerate(header):
                d[col] = infer(rec[i]) if i < len(rec) else None
            rows.append(d)
    return header, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--include", nargs="*", default=[
        "experiments", "paper", "benchmark_suite", "competitive",
        "outputs", "platform", "artifacts"])
    ap.add_argument("--max-mb", type=float, default=5.0)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    url = os.environ.get("NEON_DATABASE_URL")
    if not url and not args.dry_run:
        sys.exit("NEON_DATABASE_URL not set")

    max_bytes = int(args.max_mb * 1024 * 1024) if args.max_mb else 0
    files = []
    for p in sorted(root.rglob("*.csv")):
        rel = p.relative_to(root).as_posix()
        if "/test/" in "/" + rel or rel.startswith("test/"):
            continue
        if not args.all:
            if not any(seg in rel.split("/") for seg in args.include):
                continue
            if max_bytes and p.stat().st_size > max_bytes:
                print(f"SKIP (>{args.max_mb}MB): {rel}")
                continue
        files.append((p, rel))

    print(f"{len(files)} CSV files selected")
    if args.dry_run:
        for _, rel in files:
            print("  ", rel)
        return

    conn = psycopg2.connect(url)
    conn.autocommit = False
    cur = conn.cursor()
    total_rows = 0
    for p, rel in files:
        try:
            header, rows = load_csv(p)
        except Exception as e:
            print(f"ERROR reading {rel}: {e}")
            continue
        category = rel.split("/")[0]
        sha = sha256_of(p)
        try:
            cur.execute("select id, sha256 from datasets where name=%s", (rel,))
            existing = cur.fetchone()
            if existing and existing[1] == sha:
                print(f"UNCHANGED: {rel} ({len(rows)} rows)")
                continue
            if existing:
                ds_id = existing[0]
                cur.execute("delete from dataset_rows where dataset_id=%s", (ds_id,))
                cur.execute(
                    """update datasets set category=%s, columns=%s, n_rows=%s,
                       n_cols=%s, file_bytes=%s, sha256=%s, imported_at=now()
                       where id=%s""",
                    (category, json.dumps(header), len(rows), len(header),
                     p.stat().st_size, sha, ds_id))
            else:
                cur.execute(
                    """insert into datasets(name, category, columns, n_rows,
                       n_cols, file_bytes, sha256) values (%s,%s,%s,%s,%s,%s,%s)
                       returning id""",
                    (rel, category, json.dumps(header), len(rows), len(header),
                     p.stat().st_size, sha))
                ds_id = cur.fetchone()[0]
            if rows:
                execute_values(
                    cur,
                    "insert into dataset_rows(dataset_id, row_index, data) values %s",
                    [(ds_id, i, json.dumps(r)) for i, r in enumerate(rows)],
                    page_size=1000)
            conn.commit()
            total_rows += len(rows)
            print(f"OK: {rel} -> {len(rows)} rows")
        except Exception as e:
            conn.rollback()
            print(f"ERROR ingesting {rel}: {e}")
    cur.close()
    conn.close()
    print(f"DONE: {len(files)} datasets, {total_rows} rows")


if __name__ == "__main__":
    main()
