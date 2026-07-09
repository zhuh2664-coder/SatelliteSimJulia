#!/usr/bin/env python3
"""Validate derived real-node traffic demand CSVs."""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DERIVED = ROOT / "data" / "real_sources" / "derived"
ENDPOINTS = DERIVED / "ground_endpoints.csv"
DEMANDS = DERIVED / "traffic_demands.csv"
MANIFEST = DERIVED / "traffic_manifest.json"
CALIBRATED = DERIVED / "traffic_demands_calibrated.csv"
CALIBRATION_MANIFEST = DERIVED / "traffic_calibration_manifest.json"


def read_csv(path: Path) -> list[dict]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def main() -> int:
    for path in (ENDPOINTS, DEMANDS, MANIFEST, CALIBRATED, CALIBRATION_MANIFEST):
        if not path.is_file() or path.stat().st_size <= 0:
            print(f"missing or empty file: {path}", file=sys.stderr)
            return 1

    manifest = json.loads(MANIFEST.read_text())
    endpoints = read_csv(ENDPOINTS)
    demands = read_csv(DEMANDS)
    calibrated = read_csv(CALIBRATED)
    if len(endpoints) < 20:
        print(f"too few endpoints: {len(endpoints)}", file=sys.stderr)
        return 1
    if len(demands) < 20:
        print(f"too few demands: {len(demands)}", file=sys.stderr)
        return 1
    if manifest.get("endpoint_count") != len(endpoints):
        print("endpoint manifest count mismatch", file=sys.stderr)
        return 1
    if manifest.get("demand_count") != len(demands):
        print("demand manifest count mismatch", file=sys.stderr)
        return 1
    calibration_manifest = json.loads(CALIBRATION_MANIFEST.read_text())
    if calibration_manifest.get("demand_count") != len(calibrated):
        print("calibration manifest count mismatch", file=sys.stderr)
        return 1
    if len(calibrated) != len(demands):
        print("calibrated demand count mismatch", file=sys.stderr)
        return 1

    endpoint_ids = set()
    sources = set()
    for row in endpoints:
        eid = int(row["id"])
        if eid <= 0 or eid in endpoint_ids:
            print(f"bad endpoint id: {eid}", file=sys.stderr)
            return 1
        endpoint_ids.add(eid)
        lat = float(row["lat"])
        lon = float(row["lon"])
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            print(f"bad endpoint coordinates: {row}", file=sys.stderr)
            return 1
        sources.add(row["source"])

    if not {"satnogs", "ripe_anchor", "ripe_probe"}.intersection(sources):
        print(f"unexpected endpoint sources: {sources}", file=sys.stderr)
        return 1

    demand_ids = set()
    for row in demands:
        did = int(row["id"])
        src = int(row["source_ground_id"])
        dst = int(row["destination_ground_id"])
        start = int(row["start_elapsed_s"])
        end = int(row["end_elapsed_s"])
        rate = float(row["rate_mbps"])
        if did <= 0 or did in demand_ids:
            print(f"bad demand id: {did}", file=sys.stderr)
            return 1
        demand_ids.add(did)
        if src == dst or src not in endpoint_ids or dst not in endpoint_ids:
            print(f"bad demand endpoints: {row}", file=sys.stderr)
            return 1
        if start < 0 or end <= start:
            print(f"bad demand time window: {row}", file=sys.stderr)
            return 1
        if rate <= 0:
            print(f"bad demand rate: {row}", file=sys.stderr)
            return 1

    for row in calibrated:
        rate = float(row["rate_mbps"])
        source_rate = float(row["source_rate_mbps"])
        if not (0 < rate <= source_rate):
            print(f"bad calibrated rate: {row}", file=sys.stderr)
            return 1
        if not row.get("calibration_source"):
            print(f"missing calibration source: {row}", file=sys.stderr)
            return 1
        if float(row.get("calibration_reliability", 0)) <= 0:
            print(f"bad calibration reliability: {row}", file=sys.stderr)
            return 1

    print("REAL TRAFFIC DEMANDS: ALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
