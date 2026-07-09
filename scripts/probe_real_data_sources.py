#!/usr/bin/env python3
"""Validate cached real-world data sources used by SatelliteSimJulia."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "data" / "real_sources" / "manifest.json"


MIN_COUNTS = {
    "celestrak_starlink_tle": 1000,
    "celestrak_oneweb_tle": 100,
    "celestrak_iridium_next_tle": 60,
    "celestrak_satcat": 10000,
    "satnogs_stations": 1000,
    "ripe_atlas_probes_sample": 100,
    "ripe_atlas_anchors_sample": 100,
    "ookla_open_data_readme": 50,
}


def main() -> int:
    if not MANIFEST.is_file():
        print(f"missing manifest: {MANIFEST}", file=sys.stderr)
        return 1

    manifest = json.loads(MANIFEST.read_text())
    if manifest.get("errors"):
        print(f"manifest has errors: {manifest['errors']}", file=sys.stderr)
        return 1

    fetched = {item["name"]: item for item in manifest.get("fetched", [])}
    missing = sorted(set(MIN_COUNTS) - set(fetched))
    if missing:
        print(f"manifest missing sources: {missing}", file=sys.stderr)
        return 1

    for name, min_count in MIN_COUNTS.items():
        item = fetched[name]
        path = ROOT / item["path"]
        if not path.is_file():
            print(f"{name} missing file: {path}", file=sys.stderr)
            return 1
        if path.stat().st_size <= 0:
            print(f"{name} empty file: {path}", file=sys.stderr)
            return 1
        item_count = item.get("item_count")
        if item_count is None or item_count < min_count:
            print(f"{name} item_count {item_count} < {min_count}", file=sys.stderr)
            return 1

    derived = {item["name"]: item for item in manifest.get("derived", [])}
    for name, min_count in {
        "tle_inventory": 10000,
        "satnogs_stations_csv": 1000,
    }.items():
        item = derived.get(name)
        if item is None:
            print(f"manifest missing derived source: {name}", file=sys.stderr)
            return 1
        path = ROOT / item["path"]
        if not path.is_file() or path.stat().st_size <= 0:
            print(f"{name} missing or empty file: {path}", file=sys.stderr)
            return 1
        if item.get("item_count", 0) < min_count:
            print(f"{name} item_count {item.get('item_count')} < {min_count}", file=sys.stderr)
            return 1

    print("REAL DATA SOURCES: ALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
