#!/usr/bin/env python3
"""Fetch lightweight public real-world datasets for SatelliteSimJulia.

The script intentionally downloads only public, relatively small sources that are
safe for default use. Large or credential-gated sources are documented in the
manifest but not fetched automatically.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "data" / "real_sources"

CELESTRAK_GROUPS = {
    "starlink": "https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=tle",
    "oneweb": "https://celestrak.org/NORAD/elements/gp.php?GROUP=oneweb&FORMAT=tle",
    "iridium_next": "https://celestrak.org/NORAD/elements/gp.php?GROUP=iridium-NEXT&FORMAT=tle",
    "active": "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle",
}

SMALL_SOURCES = {
    "celestrak_satcat": {
        "url": "https://celestrak.org/pub/satcat.csv",
        "path": "celestrak/satcat.csv",
        "kind": "satellite_catalog",
    },
    "satnogs_stations": {
        "url": "https://network.satnogs.org/api/stations/",
        "path": "satnogs/stations.json",
        "kind": "ground_stations",
    },
    "ripe_atlas_probes_sample": {
        "url": "https://atlas.ripe.net/api/v2/probes/?status=1&page_size=500",
        "path": "ripe_atlas/probes_connected_sample.json",
        "kind": "latency_measurement_nodes",
    },
    "ripe_atlas_anchors_sample": {
        "url": "https://atlas.ripe.net/api/v2/anchors/?page_size=500",
        "path": "ripe_atlas/anchors_sample.json",
        "kind": "latency_measurement_anchors",
    },
    "ookla_open_data_readme": {
        "url": "https://raw.githubusercontent.com/teamookla/ookla-open-data/master/README.md",
        "path": "ookla/README.md",
        "kind": "traffic_geography_manifest",
    },
}

LARGE_OR_GATED_SOURCES = {
    "space_track": {
        "url": "https://www.space-track.org/",
        "kind": "tle_catalog",
        "reason": "Requires account/login; use for authoritative historical TLE snapshots.",
    },
    "ookla_open_data": {
        "url": "https://github.com/teamookla/ookla-open-data",
        "kind": "traffic_geography",
        "reason": "Quarterly Parquet tiles can be large; fetch per experiment window.",
    },
    "ripe_atlas": {
        "url": "https://atlas.ripe.net/docs/apis/rest-api-reference/",
        "kind": "latency_measurements",
        "reason": "Public API available, but network access may be slow/unstable from local environment.",
    },
    "caida": {
        "url": "https://www.caida.org/catalog/datasets/",
        "kind": "internet_topology_traffic",
        "reason": "Some datasets are public; others require request/terms approval.",
    },
}


def request_url(url: str, timeout: int) -> bytes:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "SatelliteSimJulia-real-data-fetch/0.1 (+research reproducibility)",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def write_bytes(path: Path, content: bytes, force: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not force:
        return
    path.write_bytes(content)


def count_tle_records(path: Path) -> int:
    lines = [line.strip() for line in path.read_text(errors="replace").splitlines() if line.strip()]
    count = 0
    i = 0
    while i + 2 < len(lines):
        if lines[i + 1].startswith("1 ") and lines[i + 2].startswith("2 "):
            count += 1
            i += 3
        elif lines[i].startswith("1 ") and lines[i + 1].startswith("2 "):
            count += 1
            i += 2
        else:
            i += 1
    return count


def count_csv_rows(path: Path) -> int:
    with path.open(newline="", errors="replace") as f:
        reader = csv.reader(f)
        rows = list(reader)
    return max(0, len(rows) - 1)


def count_json_items(path: Path) -> int:
    data = json.loads(path.read_text())
    if isinstance(data, list):
        return len(data)
    if isinstance(data, dict) and "results" in data and isinstance(data["results"], list):
        return len(data["results"])
    return 1


def parse_tle_names(path: Path) -> list[dict]:
    lines = [line.rstrip() for line in path.read_text(errors="replace").splitlines() if line.strip()]
    rows = []
    i = 0
    while i + 2 < len(lines):
        if lines[i + 1].startswith("1 ") and lines[i + 2].startswith("2 "):
            name = lines[i].strip()
            line1 = lines[i + 1].strip()
            norad = line1[2:7].strip()
            rows.append({"name": name, "norad_cat_id": norad})
            i += 3
        elif lines[i].startswith("1 ") and lines[i + 1].startswith("2 "):
            line1 = lines[i].strip()
            norad = line1[2:7].strip()
            rows.append({"name": f"SAT-{norad}", "norad_cat_id": norad})
            i += 2
        else:
            i += 1
    return rows


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({col: row.get(col, "") for col in columns})


def build_derived_indexes(out_dir: Path, fetched: list[dict]) -> list[dict]:
    derived = []

    tle_rows = []
    for item in fetched:
        if not item["name"].endswith("_tle"):
            continue
        path = ROOT / item["path"]
        if not path.is_file() or item.get("item_count", 0) <= 0:
            continue
        constellation = item["name"].removeprefix("celestrak_").removesuffix("_tle")
        for row in parse_tle_names(path):
            row["constellation"] = constellation
            row["source_path"] = item["path"]
            tle_rows.append(row)
    if tle_rows:
        inventory = out_dir / "celestrak" / "tle_inventory.csv"
        write_csv(inventory, tle_rows, ["constellation", "name", "norad_cat_id", "source_path"])
        derived.append({
            "name": "tle_inventory",
            "path": str(inventory.relative_to(ROOT)),
            "item_count": len(tle_rows),
        })

    stations_path = out_dir / "satnogs" / "stations.json"
    if stations_path.is_file():
        stations = json.loads(stations_path.read_text())
        if isinstance(stations, list):
            rows = []
            for station in stations:
                rows.append({
                    "id": station.get("id", ""),
                    "name": station.get("name", ""),
                    "lat": station.get("lat", ""),
                    "lon": station.get("lng", ""),
                    "altitude_m": station.get("altitude", ""),
                    "status": station.get("status", ""),
                    "success_rate": station.get("success_rate", ""),
                    "observations": station.get("observations", ""),
                    "last_seen": station.get("last_seen", ""),
                })
            csv_path = out_dir / "satnogs" / "stations.csv"
            write_csv(
                csv_path,
                rows,
                ["id", "name", "lat", "lon", "altitude_m", "status", "success_rate", "observations", "last_seen"],
            )
            derived.append({
                "name": "satnogs_stations_csv",
                "path": str(csv_path.relative_to(ROOT)),
                "item_count": len(rows),
            })

    return derived


def fetch_one(name: str, url: str, relpath: str, out_dir: Path, timeout: int, force: bool) -> dict:
    path = out_dir / relpath
    started = time.time()
    if path.exists() and not force:
        status = "cached"
    else:
        content = request_url(url, timeout)
        write_bytes(path, content, force=True)
        status = "downloaded"

    size = path.stat().st_size
    item_count = None
    if path.suffix == ".tle":
        item_count = count_tle_records(path)
    elif path.suffix == ".csv":
        item_count = count_csv_rows(path)
    elif path.suffix == ".json":
        item_count = count_json_items(path)
    elif path.suffix == ".md":
        item_count = len(path.read_text(errors="replace").splitlines())

    return {
        "name": name,
        "url": url,
        "path": str(path.relative_to(ROOT)),
        "status": status,
        "bytes": size,
        "item_count": item_count,
        "elapsed_s": round(time.time() - started, 3),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="output directory")
    parser.add_argument("--force", action="store_true", help="overwrite existing files")
    parser.add_argument("--allow-partial", action="store_true", help="exit 0 even if some sources fail")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--skip-active", action="store_true", help="skip large active.tle group")
    args = parser.parse_args(argv)

    out_dir = Path(args.out).resolve()
    results = []
    errors = []

    groups = dict(CELESTRAK_GROUPS)
    if args.skip_active:
        groups.pop("active", None)

    for group, url in groups.items():
        try:
            results.append(fetch_one(
                f"celestrak_{group}_tle",
                url,
                f"celestrak/{group}.tle",
                out_dir,
                args.timeout,
                args.force,
            ))
        except Exception as exc:  # keep fetching other sources
            errors.append({"name": f"celestrak_{group}_tle", "url": url, "error": repr(exc)})

    for name, spec in SMALL_SOURCES.items():
        try:
            results.append(fetch_one(
                name,
                spec["url"],
                spec["path"],
                out_dir,
                args.timeout,
                args.force,
            ))
        except Exception as exc:
            errors.append({"name": name, "url": spec["url"], "error": repr(exc)})

    derived = build_derived_indexes(out_dir, results)

    manifest = {
        "generated_at_epoch_s": int(time.time()),
        "proxy_env": {
            key: os.environ.get(key, "")
            for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "ATOMCODE_PROXY_MODE")
        },
        "fetched": results,
        "derived": derived,
        "errors": errors,
        "large_or_gated_sources": LARGE_OR_GATED_SOURCES,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

    print(json.dumps(manifest, indent=2, ensure_ascii=False))
    return 0 if not errors or args.allow_partial else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
