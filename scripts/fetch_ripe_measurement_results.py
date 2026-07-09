#!/usr/bin/env python3
"""Fetch a small RIPE Atlas measurement-result sample for traffic calibration.

This intentionally pulls only a tiny public latest-results sample and filters it
to RIPE endpoints already selected by build_real_traffic_demands.py.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REAL = ROOT / "data" / "real_sources"
DERIVED = REAL / "derived"
DEFAULT_OUT = REAL / "ripe_atlas" / "measurement_results_sample.csv"
ANCHOR_MEASUREMENTS_URL = "https://atlas.ripe.net/api/v2/anchor-measurements/?page_size=50"


def request_json(url: str, timeout: int):
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "SatelliteSimJulia-ripe-results-fetch/0.1 (+research reproducibility)"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read())


def read_csv(path: Path) -> list[dict]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({col: row.get(col, "") for col in columns})


def endpoint_probe_ids() -> set[int]:
    path = DERIVED / "ground_endpoints.csv"
    probe_ids = set()
    for row in read_csv(path):
        if row.get("source") != "ripe_anchor":
            continue
        for part in row.get("evidence", "").split(";"):
            if part.startswith("probe_id="):
                try:
                    probe_ids.add(int(float(part.split("=", 1)[1])))
                except ValueError:
                    pass
    return probe_ids


def discover_ping_measurement_id(timeout: int) -> int:
    data = request_json(ANCHOR_MEASUREMENTS_URL, timeout)
    for item in data.get("results", []):
        if item.get("type") != "ping" or not item.get("is_active", False):
            continue
        match = re.search(r"/measurements/(\d+)/", item.get("measurement", ""))
        if match:
            return int(match.group(1))
    raise RuntimeError("No active RIPE Atlas anchor ping measurement found")


def fetch_latest_results(measurement_id: int, timeout: int) -> list[dict]:
    url = f"https://atlas.ripe.net/api/v2/measurements/{measurement_id}/latest/"
    data = request_json(url, timeout)
    return data if isinstance(data, list) else []


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--measurement-id", type=int, default=0)
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    parser.add_argument("--limit", type=int, default=80)
    parser.add_argument("--timeout", type=int, default=45)
    args = parser.parse_args(argv)

    probes = endpoint_probe_ids()
    if not probes:
        print("no RIPE anchor probe ids found; rebuild traffic demands first", file=sys.stderr)
        return 1

    measurement_id = args.measurement_id or discover_ping_measurement_id(args.timeout)
    latest = fetch_latest_results(measurement_id, args.timeout)
    rows = []
    for item in latest:
        prb_id = item.get("prb_id")
        if prb_id not in probes:
            continue
        avg = item.get("avg")
        if avg is None or float(avg) < 0:
            continue
        rows.append({
            "prb_id": prb_id,
            "avg": avg,
            "min": item.get("min", ""),
            "max": item.get("max", ""),
            "sent": item.get("sent", ""),
            "rcvd": item.get("rcvd", ""),
            "timestamp": item.get("timestamp", ""),
            "msm_id": item.get("msm_id", measurement_id),
            "msm_name": item.get("msm_name", ""),
            "type": item.get("type", ""),
        })
        if len(rows) >= args.limit:
            break

    if not rows:
        print(f"no latest RIPE results matched selected endpoint probes for measurement {measurement_id}", file=sys.stderr)
        return 1

    out = Path(args.out)
    columns = ["prb_id", "avg", "min", "max", "sent", "rcvd", "timestamp", "msm_id", "msm_name", "type"]
    write_csv(out, rows, columns)
    out_json = out.with_suffix(".json")
    out_json.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n")

    manifest = {
        "measurement_id": measurement_id,
        "result_count": len(rows),
        "source": f"https://atlas.ripe.net/api/v2/measurements/{measurement_id}/latest/",
        "csv": str(out.relative_to(ROOT)),
        "json": str(out_json.relative_to(ROOT)),
        "limitations": [
            "RIPE Atlas ping latest results provide latency, not customer traffic throughput.",
            "Rows are filtered to currently selected RIPE anchor endpoints.",
        ],
    }
    manifest_path = out.with_name(out.stem + "_manifest.json")
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(manifest, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
