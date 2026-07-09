#!/usr/bin/env python3
"""Validate Ookla/RIPE sample calibration paths for real traffic demands."""

from __future__ import annotations

import csv
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DERIVED = ROOT / "data" / "real_sources" / "derived"
ENDPOINTS = DERIVED / "ground_endpoints.csv"
DEMANDS = DERIVED / "traffic_demands.csv"
OUT_STEM = "traffic_demands_calibrated_probe"


def read_csv(path: Path) -> list[dict]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({col: row.get(col, "") for col in columns})


def cleanup_probe_outputs() -> None:
    for suffix in (".csv", ".json", "_manifest.json"):
        (DERIVED / f"{OUT_STEM}{suffix}").unlink(missing_ok=True)


def ripe_probe_id(endpoint: dict) -> int:
    for part in endpoint.get("evidence", "").split(";"):
        if part.startswith("probe_id="):
            return int(float(part.split("=", 1)[1]))
    return int(float(endpoint["external_id"]))


def main() -> int:
    if not ENDPOINTS.is_file() or not DEMANDS.is_file():
        print("missing derived real traffic inputs", file=sys.stderr)
        return 1

    endpoints = {int(row["id"]): row for row in read_csv(ENDPOINTS)}
    demands = read_csv(DEMANDS)
    ripe_demand = None
    for demand in demands:
        src = endpoints[int(demand["source_ground_id"])]
        dst = endpoints[int(demand["destination_ground_id"])]
        if src["source"].startswith("ripe_") or dst["source"].startswith("ripe_"):
            ripe_demand = (demand, src, dst)
            break

    if ripe_demand is None:
        print("no RIPE-backed demand available for measurement calibration", file=sys.stderr)
        return 1

    demand, src, dst = ripe_demand
    ripe_endpoint = src if src["source"].startswith("ripe_") else dst
    probe_id = ripe_probe_id(ripe_endpoint)
    cleanup_probe_outputs()

    with tempfile.TemporaryDirectory(prefix="satsim-calibration-") as tmp:
        tmpdir = Path(tmp)
        ookla_path = tmpdir / "ookla_tiles_sample.csv"
        ripe_path = tmpdir / "ripe_results_sample.csv"
        write_csv(
            ookla_path,
            [
                {
                    "lat": src["lat"],
                    "lon": src["lon"],
                    "avg_d_kbps": "120000",
                    "avg_u_kbps": "30000",
                    "tests": "30",
                },
                {
                    "lat": dst["lat"],
                    "lon": dst["lon"],
                    "avg_d_kbps": "80000",
                    "avg_u_kbps": "20000",
                    "tests": "20",
                },
            ],
            ["lat", "lon", "avg_d_kbps", "avg_u_kbps", "tests"],
        )
        write_csv(
            ripe_path,
            [
                {
                    "prb_id": str(probe_id),
                    "avg": "45",
                    "download_mbps": "55",
                }
            ],
            ["prb_id", "avg", "download_mbps"],
        )

        cmd = [
            sys.executable,
            str(ROOT / "scripts" / "calibrate_real_traffic_demands.py"),
            "--ookla-sample",
            str(ookla_path),
            "--ripe-results-sample",
            str(ripe_path),
            "--out-stem",
            OUT_STEM,
        ]
        result = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode != 0:
            print(result.stdout, file=sys.stderr)
            return 1

    out_csv = DERIVED / f"{OUT_STEM}.csv"
    manifest_path = DERIVED / f"{OUT_STEM}_manifest.json"
    if not out_csv.is_file() or not manifest_path.is_file():
        print("calibration probe outputs were not written", file=sys.stderr)
        return 1

    rows = read_csv(out_csv)
    out_row = next((row for row in rows if row["id"] == demand["id"]), None)
    if out_row is None:
        print("RIPE-backed demand missing from calibrated output", file=sys.stderr)
        return 1

    source = out_row.get("calibration_source", "")
    if "ripe_measurement_results" not in source:
        print(f"RIPE measurement source not reflected in calibration: {source}", file=sys.stderr)
        return 1
    if float(out_row.get("calibration_measurement_factor", "0")) <= 1.0:
        print(f"RIPE RTT factor did not improve the selected demand: {out_row}", file=sys.stderr)
        return 1
    if float(out_row.get("calibration_baseline_mbps", "0")) <= 0:
        print(f"missing measured baseline: {out_row}", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text())
    if manifest.get("ookla", {}).get("geolocated_tile_count", 0) < 2:
        print("Ookla geolocated tile sample was not consumed", file=sys.stderr)
        return 1
    if manifest.get("ripe_measurements", {}).get("matched_endpoint_count", 0) < 1:
        print("RIPE measurement sample was not matched to an endpoint", file=sys.stderr)
        return 1

    cleanup_probe_outputs()
    print("REAL TRAFFIC CALIBRATION SAMPLES: ALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
