#!/usr/bin/env python3
"""Calibrate derived TrafficDemand rates with external measurement samples.

Default mode uses cached RIPE Atlas node reliability and SatNOGS observation
metadata to avoid hand-written constant rates. If an Ookla tile sample is later
provided as CSV/JSON, the same script can use throughput fields from that file.
If RIPE Atlas measurement results are provided, RTT/throughput observations are
folded into the per-demand rate calibration.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REAL = ROOT / "data" / "real_sources"
DERIVED = REAL / "derived"
DEFAULT_RIPE_RESULTS = REAL / "ripe_atlas" / "measurement_results_sample.csv"


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


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    vals = sorted(values)
    pos = (len(vals) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return vals[lo]
    frac = pos - lo
    return vals[lo] * (1 - frac) + vals[hi] * frac


def haversine_km(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> float:
    radius = 6371.0088
    lat1 = math.radians(a_lat)
    lat2 = math.radians(b_lat)
    dlat = math.radians(b_lat - a_lat)
    dlon = math.radians(b_lon - a_lon)
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * radius * math.asin(min(1.0, math.sqrt(h)))


def load_rows(path: Path | None) -> list[dict]:
    if path is None or not path.is_file():
        return []
    suffix = path.suffix.lower()
    if suffix == ".json":
        data = json.loads(path.read_text())
        if isinstance(data, list):
            return [row for row in data if isinstance(row, dict)]
        for key in ("rows", "results", "features"):
            value = data.get(key) if isinstance(data, dict) else None
            if isinstance(value, list):
                return [row for row in value if isinstance(row, dict)]
        return []
    if suffix == ".csv":
        return read_csv(path)
    return []


def first_float(row: dict, fields: tuple[str, ...], default=0.0) -> float:
    for field in fields:
        if field in row:
            value = safe_float(row.get(field), default)
            if value != default:
                return value
    return default


def endpoint_reliability(row: dict) -> float:
    evidence = row.get("evidence", "")
    source = row.get("source", "")
    weight = safe_float(row.get("weight"), 1.0)
    if source == "satnogs":
        success = 50.0
        observations = 0
        for part in evidence.split(";"):
            if part.startswith("success_rate="):
                success = safe_float(part.split("=", 1)[1], 50.0)
            elif part.startswith("observations="):
                observations = safe_int(part.split("=", 1)[1], 0)
        return max(0.05, min(1.0, (success / 100.0) * (math.log1p(observations) / 13.0)))
    if source == "ripe_anchor":
        return 0.85
    if source == "ripe_probe":
        return max(0.25, min(0.75, math.log1p(weight) / 3.0))
    return max(0.1, min(0.7, math.log1p(weight) / 4.0))


def load_ookla_sample(path: Path | None) -> dict:
    if path is None or not path.is_file():
        return {"available": False}

    rows = load_rows(path)
    down_fields = ("avg_d_kbps", "avg_download_kbps", "download_kbps", "download")
    up_fields = ("avg_u_kbps", "avg_upload_kbps", "upload_kbps", "upload")
    test_fields = ("tests", "devices", "samples")
    lat_fields = ("lat", "latitude", "tile_lat", "tile_y")
    lon_fields = ("lon", "lng", "longitude", "tile_lon", "tile_x")
    samples = []
    tiles = []
    for row in rows:
        down = first_float(row, down_fields, 0.0)
        up = first_float(row, up_fields, 0.0)
        tests = first_float(row, test_fields, 1.0)
        if down > 0:
            down_mbps = down / 1000.0
            up_mbps = max(up, 0.0) / 1000.0
            weight = max(tests, 1.0)
            samples.append((down_mbps, up_mbps, weight))
            lat = first_float(row, lat_fields, None)
            lon = first_float(row, lon_fields, None)
            if lat is not None and lon is not None and -90 <= lat <= 90 and -180 <= lon <= 180:
                tiles.append({
                    "lat": lat,
                    "lon": lon,
                    "baseline_mbps": 0.65 * down_mbps + 0.35 * up_mbps,
                    "weight": weight,
                })

    if not samples:
        return {"available": False, "path": str(path)}

    weighted_down = sum(down * tests for down, _, tests in samples) / sum(tests for _, _, tests in samples)
    weighted_up = sum(up * tests for _, up, tests in samples) / sum(tests for _, _, tests in samples)
    return {
        "available": True,
        "path": display_path(path),
        "weighted_down_mbps": weighted_down,
        "weighted_up_mbps": weighted_up,
        "sample_count": len(samples),
        "geolocated_tile_count": len(tiles),
        "tiles": tiles,
    }


def ookla_endpoint_baseline(ookla: dict, endpoint: dict, fallback: float, radius_km: float) -> float:
    if not ookla.get("available"):
        return fallback

    global_baseline = 0.65 * safe_float(ookla.get("weighted_down_mbps"), fallback) + 0.35 * safe_float(
        ookla.get("weighted_up_mbps"),
        fallback * 0.25,
    )
    lat = safe_float(endpoint.get("lat"), None)
    lon = safe_float(endpoint.get("lon"), None)
    if lat is None or lon is None or not ookla.get("tiles"):
        return global_baseline

    weighted_sum = 0.0
    weight_sum = 0.0
    nearest = None
    for tile in ookla["tiles"]:
        distance = haversine_km(lat, lon, tile["lat"], tile["lon"])
        if nearest is None or distance < nearest[0]:
            nearest = (distance, tile)
        if distance <= radius_km:
            weight = tile["weight"] / max(distance, 1.0)
            weighted_sum += tile["baseline_mbps"] * weight
            weight_sum += weight

    if weight_sum > 0:
        return weighted_sum / weight_sum
    if nearest is not None:
        # Small samples may only include a few tiles. Use the nearest tile rather
        # than discarding the measurement entirely, while recording the tile count
        # in the manifest so this remains auditable.
        return nearest[1]["baseline_mbps"]
    return global_baseline


def _probe_id_from_endpoint(endpoint: dict) -> int | None:
    if endpoint.get("source") not in ("ripe_probe", "ripe_anchor"):
        return None
    for part in endpoint.get("evidence", "").split(";"):
        if part.startswith("probe_id="):
            probe_id = safe_int(part.split("=", 1)[1], 0)
            return probe_id if probe_id > 0 else None
    probe_id = safe_int(endpoint.get("external_id"), 0)
    return probe_id if probe_id > 0 else None


def _ripe_rtt_ms(row: dict) -> float:
    rtt = first_float(row, ("rtt_ms", "avg_rtt_ms", "avg", "median", "min"), 0.0)
    if rtt > 0:
        return rtt
    result = row.get("result")
    if isinstance(result, list):
        values = [safe_float(item.get("rtt"), 0.0) for item in result if isinstance(item, dict)]
        values = [value for value in values if value > 0]
        if values:
            return statistics.median(values)
    return 0.0


def load_ripe_results_sample(path: Path | None, endpoints: list[dict], target_rtt_ms: float) -> dict:
    if path is None or not path.is_file():
        return {"available": False}

    rows = load_rows(path)
    endpoint_ids_by_probe = {}
    for endpoint in endpoints:
        probe_id = _probe_id_from_endpoint(endpoint)
        if probe_id is not None:
            endpoint_ids_by_probe[probe_id] = int(endpoint["id"])

    observations = {}
    throughput_fields = (
        "throughput_mbps",
        "download_mbps",
        "rate_mbps",
        "mbps",
        "bitrate_mbps",
    )
    bps_fields = ("bits_per_second", "bps", "bitrate_bps")

    for row in rows:
        probe_id = safe_int(row.get("prb_id") or row.get("probe_id") or row.get("source_probe_id"), 0)
        endpoint_id = endpoint_ids_by_probe.get(probe_id)
        if endpoint_id is None:
            continue

        rtt = _ripe_rtt_ms(row)
        throughput = first_float(row, throughput_fields, 0.0)
        if throughput <= 0:
            bps = first_float(row, bps_fields, 0.0)
            throughput = bps / 1_000_000.0 if bps > 0 else 0.0

        obs = observations.setdefault(endpoint_id, {"rtts": [], "throughputs": []})
        if rtt > 0:
            obs["rtts"].append(rtt)
        if throughput > 0:
            obs["throughputs"].append(throughput)

    endpoint_factors = {}
    for endpoint_id, obs in observations.items():
        rtt_median = statistics.median(obs["rtts"]) if obs["rtts"] else 0.0
        throughput_median = statistics.median(obs["throughputs"]) if obs["throughputs"] else 0.0
        latency_factor = 1.0
        if rtt_median > 0:
            latency_factor = max(0.25, min(1.15, target_rtt_ms / max(rtt_median, 1.0)))
        endpoint_factors[endpoint_id] = {
            "latency_factor": latency_factor,
            "rtt_median_ms": rtt_median,
            "throughput_mbps": throughput_median,
            "observation_count": len(obs["rtts"]) + len(obs["throughputs"]),
        }

    return {
        "available": bool(endpoint_factors),
        "path": display_path(path),
        "sample_count": len(rows),
        "matched_endpoint_count": len(endpoint_factors),
        "target_rtt_ms": target_rtt_ms,
        "endpoint_factors": endpoint_factors,
    }


def calibrate(args: argparse.Namespace) -> dict:
    endpoints = read_csv(DERIVED / "ground_endpoints.csv")
    demands = read_csv(DERIVED / "traffic_demands.csv")
    endpoint_by_id = {int(row["id"]): row for row in endpoints}
    reliabilities = {eid: endpoint_reliability(row) for eid, row in endpoint_by_id.items()}
    source_rates = [safe_float(row["rate_mbps"]) for row in demands]
    p50_source = percentile(source_rates, 0.5)
    p95_source = percentile(source_rates, 0.95)
    ookla = load_ookla_sample(Path(args.ookla_sample) if args.ookla_sample else None)
    ripe_path = Path(args.ripe_results_sample) if args.ripe_results_sample else DEFAULT_RIPE_RESULTS
    ripe = load_ripe_results_sample(ripe_path, endpoints, args.ripe_target_rtt_ms)

    calibrated = []
    for row in demands:
        src = int(row["source_ground_id"])
        dst = int(row["destination_ground_id"])
        distance = safe_float(row.get("distance_km"))
        source_rate = safe_float(row["rate_mbps"])
        rel = math.sqrt(reliabilities.get(src, 0.35) * reliabilities.get(dst, 0.35))
        distance_factor = max(0.35, min(1.25, math.log1p(distance) / math.log1p(12000.0)))

        src_factor = ripe.get("endpoint_factors", {}).get(src, {}) if ripe.get("available") else {}
        dst_factor = ripe.get("endpoint_factors", {}).get(dst, {}) if ripe.get("available") else {}
        has_measurement = bool(src_factor or dst_factor)
        measurement_factor = math.sqrt(
            safe_float(src_factor.get("latency_factor"), 1.0) * safe_float(dst_factor.get("latency_factor"), 1.0)
        )

        src_measured = safe_float(src_factor.get("throughput_mbps"), 0.0)
        dst_measured = safe_float(dst_factor.get("throughput_mbps"), 0.0)
        measured_rates = [value for value in (src_measured, dst_measured) if value > 0]

        if measured_rates:
            baseline = statistics.median(measured_rates)
            source = "ripe_measurement_results_throughput"
        elif ookla.get("available"):
            src_baseline = ookla_endpoint_baseline(ookla, endpoint_by_id[src], args.base_mbps, args.ookla_radius_km)
            dst_baseline = ookla_endpoint_baseline(ookla, endpoint_by_id[dst], args.base_mbps, args.ookla_radius_km)
            baseline = math.sqrt(max(src_baseline, 0.1) * max(dst_baseline, 0.1))
            source = "ookla_tile_throughput"
        else:
            # RIPE gives node/measurement geography and reliability, not throughput.
            # Use reliability to scale a conservative broadband baseline.
            baseline = args.base_mbps
            source = "ripe_satnogs_reliability_proxy"

        if has_measurement and not measured_rates:
            source = source + "_ripe_measurement_results_latency"

        gravity_scale = source_rate / max(p95_source, 1.0)
        calibrated_rate = baseline * (0.55 + 0.45 * gravity_scale) * (0.35 + 0.65 * rel) * distance_factor * measurement_factor
        calibrated_rate = max(args.min_mbps, min(args.max_mbps, calibrated_rate))

        out = dict(row)
        out["source_rate_mbps"] = row["rate_mbps"]
        out["rate_mbps"] = round(calibrated_rate, 3)
        out["calibration_source"] = source
        out["calibration_reliability"] = round(rel, 4)
        out["calibration_distance_factor"] = round(distance_factor, 4)
        out["calibration_measurement_factor"] = round(measurement_factor, 4)
        out["calibration_baseline_mbps"] = round(baseline, 3)
        calibrated.append(out)

    out_csv = DERIVED / f"{args.out_stem}.csv"
    out_json = DERIVED / f"{args.out_stem}.json"
    columns = [
        "id",
        "source_ground_id",
        "destination_ground_id",
        "start_elapsed_s",
        "end_elapsed_s",
        "rate_mbps",
        "source_rate_mbps",
        "source_label",
        "destination_label",
        "distance_km",
        "derivation",
        "calibration_source",
        "calibration_reliability",
        "calibration_distance_factor",
        "calibration_measurement_factor",
        "calibration_baseline_mbps",
    ]
    write_csv(out_csv, calibrated, columns)
    out_json.write_text(json.dumps(calibrated, indent=2, ensure_ascii=False) + "\n")

    rates = [safe_float(row["rate_mbps"]) for row in calibrated]
    manifest = {
        "traffic_demands_calibrated": str(out_csv.relative_to(ROOT)),
        "traffic_demands_calibrated_json": str(out_json.relative_to(ROOT)),
        "demand_count": len(calibrated),
        "rate_mbps_min": min(rates) if rates else 0.0,
        "rate_mbps_median": statistics.median(rates) if rates else 0.0,
        "rate_mbps_max": max(rates) if rates else 0.0,
        "base_mbps": args.base_mbps,
        "min_mbps": args.min_mbps,
        "max_mbps": args.max_mbps,
        "ookla": ookla,
        "ripe_measurements": ripe,
        "limitations": [
            "Default calibration uses reliability/geography metadata, not measured throughput.",
            "Provide --ookla-sample with avg_d_kbps/avg_u_kbps/tests and optional lat/lon fields to calibrate against Ookla throughput tiles.",
            "Provide --ripe-results-sample with RIPE Atlas prb_id plus RTT or throughput fields to calibrate against measurement results.",
            "Still not an official Starlink customer OD traffic matrix.",
        ],
    }
    manifest_name = "traffic_calibration_manifest.json"
    if args.out_stem != "traffic_demands_calibrated":
        manifest_name = f"{args.out_stem}_manifest.json"
    (DERIVED / manifest_name).write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    return manifest


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-mbps", type=float, default=35.0)
    parser.add_argument("--min-mbps", type=float, default=2.0)
    parser.add_argument("--max-mbps", type=float, default=80.0)
    parser.add_argument("--ookla-sample", default="")
    parser.add_argument("--ookla-radius-km", type=float, default=250.0)
    parser.add_argument("--ripe-results-sample", default="")
    parser.add_argument("--ripe-target-rtt-ms", type=float, default=80.0)
    parser.add_argument("--out-stem", default="traffic_demands_calibrated")
    args = parser.parse_args(argv)
    manifest = calibrate(args)
    print(json.dumps(manifest, indent=2, ensure_ascii=False))
    return 0 if manifest["demand_count"] > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
