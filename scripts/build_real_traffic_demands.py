#!/usr/bin/env python3
"""Derive reproducible TrafficDemand candidates from cached real-world nodes.

This is not an official Starlink traffic matrix. It creates an auditable OD
matrix from real ground/measurement node locations so simulations can move
beyond hand-written toy endpoints while keeping the limitation explicit.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REAL = ROOT / "data" / "real_sources"
DEFAULT_OUT = REAL / "derived"


def safe_float(value, default=0.0) -> float:
    try:
        if value in ("", None):
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def safe_int(value, default=0) -> int:
    try:
        if value in ("", None):
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def haversine_km(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> float:
    radius = 6371.0088
    lat1 = math.radians(a_lat)
    lat2 = math.radians(b_lat)
    dlat = math.radians(b_lat - a_lat)
    dlon = math.radians(b_lon - a_lon)
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * radius * math.asin(min(1.0, math.sqrt(h)))


def read_satnogs(limit: int) -> list[dict]:
    path = REAL / "satnogs" / "stations.csv"
    rows = []
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            lat = safe_float(row.get("lat"))
            lon = safe_float(row.get("lon"))
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                continue
            success = safe_float(row.get("success_rate"))
            observations = safe_int(row.get("observations"))
            online = 1 if str(row.get("status", "")).lower() == "online" else 0
            weight = (1 + math.log1p(max(observations, 0))) * (0.25 + success / 100.0) * (1.0 + online)
            rows.append({
                "source": "satnogs",
                "external_id": row.get("id", ""),
                "name": row.get("name", ""),
                "lat": lat,
                "lon": lon,
                "alt_km": safe_float(row.get("altitude_m")) / 1000.0,
                "country": "",
                "weight": weight,
                "evidence": f"status={row.get('status','')};success_rate={row.get('success_rate','')};observations={row.get('observations','')}",
            })
    rows.sort(key=lambda item: (-item["weight"], item["external_id"]))
    return rows[:limit]


def _ripe_point(item: dict) -> tuple[float, float] | None:
    geometry = item.get("geometry") or {}
    coords = geometry.get("coordinates")
    if not isinstance(coords, list) or len(coords) < 2:
        return None
    lon = safe_float(coords[0], None)
    lat = safe_float(coords[1], None)
    if lat is None or lon is None:
        return None
    if -90 <= lat <= 90 and -180 <= lon <= 180:
        return lat, lon
    return None


def read_ripe(limit: int) -> list[dict]:
    endpoints = []
    for rel, source, base_weight in [
        ("ripe_atlas/anchors_sample.json", "ripe_anchor", 4.0),
        ("ripe_atlas/probes_connected_sample.json", "ripe_probe", 2.0),
    ]:
        path = REAL / rel
        data = json.loads(path.read_text())
        for item in data.get("results", []):
            if source == "ripe_anchor" and (item.get("is_disabled") or item.get("date_decommissioned")):
                continue
            point = _ripe_point(item)
            if point is None:
                continue
            lat, lon = point
            country = item.get("country") or item.get("country_code") or ""
            asn = item.get("as_v4") or item.get("asn_v4") or ""
            probe_id = item.get("probe", "")
            endpoints.append({
                "source": source,
                "external_id": item.get("id", ""),
                "name": item.get("hostname") or item.get("description") or f"{source}_{item.get('id','')}",
                "lat": lat,
                "lon": lon,
                "alt_km": 0.0,
                "country": country,
                "weight": base_weight,
                "evidence": f"asn={asn};country={country};probe_id={probe_id}",
            })
    endpoints.sort(key=lambda item: (item["source"], item["external_id"]))
    return endpoints[:limit]


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({col: row.get(col, "") for col in columns})


def build_demands(
    endpoints: list[dict],
    max_demands: int,
    duration_s: int,
    base_rate_mbps: float,
    min_ripe_demands: int,
) -> list[dict]:
    candidates = []
    for i, src in enumerate(endpoints):
        for j, dst in enumerate(endpoints):
            if i >= j:
                continue
            distance = haversine_km(src["lat"], src["lon"], dst["lat"], dst["lon"])
            if distance < 500:
                continue
            score = math.sqrt(max(src["weight"], 0.1) * max(dst["weight"], 0.1)) * math.log1p(distance)
            candidates.append((score, distance, src, dst))

    candidates.sort(key=lambda item: (-item[0], -item[1], item[2]["id"], item[3]["id"]))

    selected = []
    seen = set()
    for candidate in candidates:
        _, _, src, dst = candidate
        if len(selected) >= min(max_demands, min_ripe_demands):
            break
        if not (src["source"].startswith("ripe_") or dst["source"].startswith("ripe_")):
            continue
        key = (src["id"], dst["id"])
        selected.append(candidate)
        seen.add(key)

    for candidate in candidates:
        if len(selected) >= max_demands:
            break
        _, _, src, dst = candidate
        key = (src["id"], dst["id"])
        if key in seen:
            continue
        selected.append(candidate)
        seen.add(key)

    demands = []
    for idx, (score, distance, src, dst) in enumerate(selected, start=1):
        rate = base_rate_mbps * max(0.25, min(10.0, score / 25.0))
        demands.append({
            "id": idx,
            "source_ground_id": src["id"],
            "destination_ground_id": dst["id"],
            "start_elapsed_s": 0,
            "end_elapsed_s": duration_s,
            "rate_mbps": round(rate, 3),
            "source_label": src["label"],
            "destination_label": dst["label"],
            "distance_km": round(distance, 3),
            "derivation": "gravity_model_from_real_node_weights",
        })
    return demands


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    parser.add_argument("--satnogs-limit", type=int, default=40)
    parser.add_argument("--ripe-limit", type=int, default=40)
    parser.add_argument("--max-demands", type=int, default=80)
    parser.add_argument("--min-ripe-demands", type=int, default=10)
    parser.add_argument("--duration-s", type=int, default=3600)
    parser.add_argument("--base-rate-mbps", type=float, default=25.0)
    args = parser.parse_args(argv)

    endpoints = read_satnogs(args.satnogs_limit) + read_ripe(args.ripe_limit)
    for idx, endpoint in enumerate(endpoints, start=1):
        endpoint["id"] = idx
        endpoint["label"] = f"{endpoint['source']}:{endpoint['external_id']}"

    demands = build_demands(endpoints, args.max_demands, args.duration_s, args.base_rate_mbps, args.min_ripe_demands)
    out = Path(args.out)
    write_csv(
        out / "ground_endpoints.csv",
        endpoints,
        ["id", "label", "source", "external_id", "name", "lat", "lon", "alt_km", "country", "weight", "evidence"],
    )
    write_csv(
        out / "traffic_demands.csv",
        demands,
        [
            "id",
            "source_ground_id",
            "destination_ground_id",
            "start_elapsed_s",
            "end_elapsed_s",
            "rate_mbps",
            "source_label",
            "destination_label",
            "distance_km",
            "derivation",
        ],
    )
    (out / "ground_endpoints.json").write_text(json.dumps(endpoints, indent=2, ensure_ascii=False) + "\n")
    (out / "traffic_demands.json").write_text(json.dumps(demands, indent=2, ensure_ascii=False) + "\n")

    manifest = {
        "ground_endpoints": str((out / "ground_endpoints.csv").relative_to(ROOT)),
        "ground_endpoints_json": str((out / "ground_endpoints.json").relative_to(ROOT)),
        "traffic_demands": str((out / "traffic_demands.csv").relative_to(ROOT)),
        "traffic_demands_json": str((out / "traffic_demands.json").relative_to(ROOT)),
        "endpoint_count": len(endpoints),
        "demand_count": len(demands),
        "duration_s": args.duration_s,
        "base_rate_mbps": args.base_rate_mbps,
        "min_ripe_demands": args.min_ripe_demands,
        "limitations": [
            "Derived from real node geography and public measurement metadata.",
            "Not an official Starlink customer OD traffic matrix.",
            "Raw rates are gravity-model proxies; run calibrate_real_traffic_demands.py for calibrated rate_mbps.",
        ],
    }
    (out / "traffic_manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(manifest, indent=2, ensure_ascii=False))
    return 0 if demands else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
