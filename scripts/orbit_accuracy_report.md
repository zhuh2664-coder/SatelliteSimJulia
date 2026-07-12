# Orbit Accuracy Harness Report (v1)

Generated: 2026-07-12 18:03:25
Host threads: 8  |  Wall time: 0.5 s

## 1. Configuration

| Parameter | Value |
|---|---|
| Walker | T=24, P=6, F=1, alt=550.0 km, inc=53.0° |
| Real TLE | n=20, stride=50, path=`/Users/zhuhai/Research/SatelliteSimJulia/data/tle/celestrak/starlink_gp_latest.tle` |
| Horizons (h) | 1.0, 6.0, 24.0, 72.0 |
| Sample dt (s) | 120.0 |
| Kepler pairs | two_body ↔ j2 ↔ j4 (inertial) |
| TLE pairs | sgp4 (TEME) ↔ j2_approx (TEME) |
| Julia project | `--project=src/orbit` |

## 2. Method & frame convention

- **Walker / Keplerian**: `propagate_positions` with `TwoBodyPropagator` / `J2Propagator` / `J4Propagator`. Same `KeplerianElements` init for all three; positions are inertial (SatelliteToolbox TEME-compatible).
- **Real TLE**: `SatelliteToolboxSgp4.sgp4!` → TEME km. Approximate J2 counterpart: convert TLE mean elements → `KeplerianElements` via Kepler's law (μ = 3.986004418e14), treat mean anomaly as true anomaly (near-circular), then `J2Propagator`.
- **Metrics**: over all sats × times — RMSE and max of Euclidean position difference (km). Drift ≈ end-of-horizon RMSE (or max) divided by horizon in days (km/day).
- **`sgp4_arc_from_epoch`**: chord length of SGP4 position from epoch to horizon — **orbital motion scale, not an error**.

## 3. Truth statement (honest)

> **v1 has no absolute truth.** There is no precision ephemeris (SP3/OEM/HPOP reference) in this run. All numbers are **relative cross-propagator differences**. Absolute accuracy validation is deferred to `compare_against_ephemeris(...)` (stub in the harness; precision-ephemeris ingest is future work).

Additional TLE caveats:
- TLE mean elements ≠ osculating Keplerian; epoch SGP4↔J2 offset of O(10 km) is expected and is **not** pure propagation error.
- SGP4 includes drag (B*) and higher-order effects absent from analytical J2.

## 4. Results

### 4.1 Walker synthetic — Keplerian pairs (inertial)

| Pair | Horizon (h) | RMSE (km) | Max (km) | End RMSE (km) | Drift RMSE (km/day) | Drift Max (km/day) |
|---|---:|---:|---:|---:|---:|---:|
| two_body_vs_j2 | 1.0 | 7.6733 | 18.3702 | 13.1812 | 316.3487 | 440.8849 |
| two_body_vs_j4 | 1.0 | 7.6690 | 18.3658 | 13.1737 | 316.1692 | 440.7804 |
| j2_vs_j4 | 1.0 | 0.0211 | 0.0363 | 0.0363 | 0.8703 | 0.8721 |
| two_body_vs_j2 | 6.0 | 45.7237 | 109.7489 | 79.0853 | 316.3412 | 438.9957 |
| two_body_vs_j4 | 6.0 | 45.6978 | 109.7227 | 79.0404 | 316.1616 | 438.8909 |
| j2_vs_j4 | 6.0 | 0.1258 | 0.2180 | 0.2176 | 0.8703 | 0.8720 |
| two_body_vs_j2 | 24.0 | 182.6684 | 440.1188 | 316.2360 | 316.2360 | 438.1487 |
| two_body_vs_j4 | 24.0 | 182.5649 | 440.0142 | 316.0569 | 316.0569 | 438.0460 |
| j2_vs_j4 | 24.0 | 0.5027 | 0.8720 | 0.8703 | 0.8703 | 0.8720 |
| two_body_vs_j2 | 72.0 | 546.9507 | 1.316e+03 | 946.0334 | 315.3445 | 438.5777 |
| two_body_vs_j4 | 72.0 | 546.6434 | 1.316e+03 | 945.5054 | 315.1685 | 438.4807 |
| j2_vs_j4 | 72.0 | 1.5077 | 2.6161 | 2.6110 | 0.8703 | 0.8720 |

### 4.2 Real Starlink TLE — SGP4 vs approximate J2 (TEME)

| Pair | Horizon (h) | RMSE (km) | Max (km) | End RMSE (km) | Drift RMSE (km/day) | Drift Max (km/day) |
|---|---:|---:|---:|---:|---:|---:|
| sgp4_vs_j2_approx | 1.0 | 10.2105 | 28.5600 | 9.3826 | 225.1822 | 654.0128 |
| sgp4_vs_j2_approx | 6.0 | 15.2837 | 86.4029 | 24.1257 | 96.5026 | 308.5679 |
| sgp4_vs_j2_approx | 24.0 | 46.1179 | 299.3302 | 78.3528 | 78.3528 | 279.7828 |
| sgp4_vs_j2_approx | 72.0 | 212.3348 | 1.739e+03 | 449.4790 | 149.8263 | 579.6438 |

### 4.3 SGP4 orbital arc scale (not error)

| Horizon (h) | Mean chord (km) | Max chord (km) |
|---:|---:|---:|
| 1.0 | 1.239e+04 | 1.286e+04 |
| 6.0 | 6.989e+03 | 1.001e+04 |
| 24.0 | 1.035e+04 | 1.359e+04 |
| 72.0 | 7.512e+03 | 1.349e+04 |

## 5. Conclusions vs literature expectations

Literature / domain priors used for sanity check (not absolute truth):
- SGP4 vs precision ephemeris often cited ~**1–3 km/day** growth for LEO.
- Two-body (no J2) diverges quickly from J2/SGP4 due to missing nodal/apsidal precession.
- J2 vs J4 differences are much smaller than two-body vs J2 for LEO over days.

Observed in this run:
- **two_body vs j2**: 1 h RMSE ≈ 7.6733 km, 24 h RMSE ≈ 182.6684 km, 72 h RMSE ≈ 546.9507 km. Drift (end RMSE) ≈ 316.2360 km/day at 24 h / 315.3445 km/day at 72 h. **Consistent with rapid two-body divergence.**
- **j2 vs j4**: 24 h RMSE ≈ 0.5027 km, 72 h RMSE ≈ 1.5077 km — much smaller than two_body↔j2, as expected.
- **sgp4 vs j2_approx**: 1 h RMSE ≈ 10.2105 km, 24 h RMSE ≈ 46.1179 km, 72 h RMSE ≈ 212.3348 km; end drift ≈ 78.3528 km/day (24 h). This is **larger** than the oft-cited SGP4 ~1–3 km/day *vs precision ephemeris* prior — expected, because the J2 leg is initialized from **TLE mean elements** (epoch bias + missing drag/higher-order terms), not a fitted osculating state or precision truth. Treat as an analytic-vs-SGP4 **order-of-magnitude** gap, not absolute SGP4 accuracy.

Net: the harness reproduces the expected qualitative hierarchy (two_body ≫ sgp4↔j2_approx ≫ j2↔j4) without claiming absolute accuracy. Closing the gap to the 1–3 km/day literature prior requires `compare_against_ephemeris` against a precision product.

## 6. Limitations

1. **No absolute truth** — relative diffs only; see §3 and `compare_against_ephemeris` stub.
2. **TLE→J2 mean-element approximation** injects epoch bias; interpret SGP4↔J2 growth carefully.
3. Frame is inertial/TEME for all pairs; ECEF/GMST not mixed into pair diffs.
4. Sample cadence `dt=120.0 s` undersamples sub-minute structure (acceptable for km-scale secular growth).
5. Small constellation (Walker 24, TLE n=20) — enough for order-of-magnitude platform checks, not constellation-wide statistics.

## 7. Reproduce

```bash
julia -t auto --project=src/orbit scripts/orbit_accuracy_harness.jl \
  --walker-T=24 --walker-P=6 --n-tle=20 \
  --dt-s=120.0 --horizons-h=1.0,6.0,24.0,72.0
```

Artifacts: `/Users/zhuhai/Research/SatelliteSimJulia/scripts/orbit_accuracy_results.csv`, `/Users/zhuhai/Research/SatelliteSimJulia/scripts/orbit_accuracy_report.md`.
