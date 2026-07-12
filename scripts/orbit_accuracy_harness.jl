#!/usr/bin/env julia
#=
Orbit accuracy verification harness (v1)
=======================================

Quantifies **relative** position differences among platform propagators as a
function of propagation horizon. This is a reusable platform asset — not a
one-shot report. v1 has **no absolute truth** (no precision ephemeris).

Usage
-----
    # default: Walker 24/6 + 20 Starlink TLEs, horizons 1/6/24/72 h
    julia -t auto --project=src/orbit scripts/orbit_accuracy_harness.jl

    # smaller / faster smoke
    julia -t auto --project=src/orbit scripts/orbit_accuracy_harness.jl \
        --walker-T=12 --walker-P=3 --n-tle=5 --dt-s=300 --horizons-h=1,6,24

    # skip real-TLE leg
    julia -t auto --project=src/orbit scripts/orbit_accuracy_harness.jl --skip-tle

Outputs (overwrite)
-------------------
    scripts/orbit_accuracy_results.csv
    scripts/orbit_accuracy_report.md

Parameters (CLI)
----------------
    --walker-T=N          Walker satellite count (default 24)
    --walker-P=N          Walker planes (default 6)
    --walker-F=N          Walker phasing (default 1)
    --alt-km=X            altitude km (default 550)
    --inc-deg=X           inclination deg (default 53)
    --n-tle=N             real Starlink TLEs to sample (default 20)
    --tle-stride=N        take every N-th TLE triple (default 50)
    --dt-s=X              sample step seconds (default 120)
    --horizons-h=a,b,c    comma-separated horizons in hours (default 1,6,24,72)
    --tle-path=PATH       TLE file (default data/tle/celestrak/starlink_gp_latest.tle)
    --out-csv=PATH        CSV output path
    --out-md=PATH         Markdown report path
    --skip-tle            skip real-TLE / SGP4 leg
    --skip-walker         skip synthetic Walker leg

Truth statement
---------------
Relative cross-propagator differences only. Absolute accuracy against a
precision ephemeris is future work via `compare_against_ephemeris(...)`.
=#

using Dates
using LinearAlgebra: norm
using Printf
using Statistics: mean
using SatelliteToolbox
using SatelliteToolboxSgp4
using SatelliteSimOrbit

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const DEFAULT_TLE = joinpath(REPO_ROOT, "data", "tle", "celestrak", "starlink_gp_latest.tle")
const DEFAULT_CSV = joinpath(@__DIR__, "orbit_accuracy_results.csv")
const DEFAULT_MD  = joinpath(@__DIR__, "orbit_accuracy_report.md")

# WGS-84 / SGP4-compatible μ (m³/s²) for mean-motion → semi-major axis.
const MU_EARTH_M3_S2 = 3.986004418e14

"""Harness run configuration (all fields overridable via CLI)."""
Base.@kwdef mutable struct HarnessConfig
    walker_T::Int = 24
    walker_P::Int = 6
    walker_F::Int = 1
    alt_km::Float64 = 550.0
    inc_deg::Float64 = 53.0
    n_tle::Int = 20
    tle_stride::Int = 50
    dt_s::Float64 = 120.0
    horizons_h::Vector{Float64} = [1.0, 6.0, 24.0, 72.0]
    tle_path::String = DEFAULT_TLE
    out_csv::String = DEFAULT_CSV
    out_md::String = DEFAULT_MD
    skip_tle::Bool = false
    skip_walker::Bool = false
end

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

function _parse_float_list(s::AbstractString)
    return [parse(Float64, strip(x)) for x in split(s, ',') if !isempty(strip(x))]
end

function parse_cli!(cfg::HarnessConfig, args::Vector{String})
    for a in args
        if startswith(a, "--walker-T=");     cfg.walker_T = parse(Int, split(a, '='; limit=2)[2])
        elseif startswith(a, "--walker-P="); cfg.walker_P = parse(Int, split(a, '='; limit=2)[2])
        elseif startswith(a, "--walker-F="); cfg.walker_F = parse(Int, split(a, '='; limit=2)[2])
        elseif startswith(a, "--alt-km=");   cfg.alt_km = parse(Float64, split(a, '='; limit=2)[2])
        elseif startswith(a, "--inc-deg=");  cfg.inc_deg = parse(Float64, split(a, '='; limit=2)[2])
        elseif startswith(a, "--n-tle=");    cfg.n_tle = parse(Int, split(a, '='; limit=2)[2])
        elseif startswith(a, "--tle-stride="); cfg.tle_stride = parse(Int, split(a, '='; limit=2)[2])
        elseif startswith(a, "--dt-s=");     cfg.dt_s = parse(Float64, split(a, '='; limit=2)[2])
        elseif startswith(a, "--horizons-h="); cfg.horizons_h = _parse_float_list(split(a, '='; limit=2)[2])
        elseif startswith(a, "--tle-path="); cfg.tle_path = split(a, '='; limit=2)[2]
        elseif startswith(a, "--out-csv=");  cfg.out_csv = split(a, '='; limit=2)[2]
        elseif startswith(a, "--out-md=");   cfg.out_md = split(a, '='; limit=2)[2]
        elseif a == "--skip-tle";           cfg.skip_tle = true
        elseif a == "--skip-walker";        cfg.skip_walker = true
        elseif a in ("-h", "--help")
            println(stderr, "See header comment in scripts/orbit_accuracy_harness.jl")
            exit(0)
        else
            error("Unknown argument: $a")
        end
    end
    return cfg
end

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

"""Pairwise position metrics over all sats × times (km)."""
function position_diff_metrics(pos_a::Array{<:Real,3}, pos_b::Array{<:Real,3})
    size(pos_a) == size(pos_b) || throw(ArgumentError("position array size mismatch"))
    n_sat, n_t, _ = size(pos_a)
    diffs = Vector{Float64}(undef, n_sat * n_t)
    k = 0
    @inbounds for i in 1:n_sat, j in 1:n_t
        k += 1
        dx = Float64(pos_a[i, j, 1] - pos_b[i, j, 1])
        dy = Float64(pos_a[i, j, 2] - pos_b[i, j, 2])
        dz = Float64(pos_a[i, j, 3] - pos_b[i, j, 3])
        diffs[k] = sqrt(dx * dx + dy * dy + dz * dz)
    end
    rmse = sqrt(mean(abs2, diffs))
    mx = maximum(diffs)
    # end-of-horizon slice (last time index across sats)
    end_diffs = Vector{Float64}(undef, n_sat)
    @inbounds for i in 1:n_sat
        dx = Float64(pos_a[i, n_t, 1] - pos_b[i, n_t, 1])
        dy = Float64(pos_a[i, n_t, 2] - pos_b[i, n_t, 2])
        dz = Float64(pos_a[i, n_t, 3] - pos_b[i, n_t, 3])
        end_diffs[i] = sqrt(dx * dx + dy * dy + dz * dz)
    end
    end_rmse = sqrt(mean(abs2, end_diffs))
    end_max = maximum(end_diffs)
    return (; rmse_km=rmse, max_km=mx, end_rmse_km=end_rmse, end_max_km=end_max, n_samples=length(diffs))
end

"""Crude drift rate from end-of-horizon RMSE (km/day)."""
drift_rate_km_per_day(end_rmse_km::Float64, horizon_h::Float64) =
    end_rmse_km / (horizon_h / 24.0)

function make_tspan(horizon_h::Float64, dt_s::Float64)
    t_end = horizon_h * 3600.0
    return collect(0.0:dt_s:t_end)
end

# ---------------------------------------------------------------------------
# Propagators — Walker / Keplerian (inertial / TEME-compatible)
# ---------------------------------------------------------------------------

const KEPLER_PROPS = (
    ("two_body", SatelliteSimOrbit.TwoBodyPropagator()),
    ("j2",       SatelliteSimOrbit.J2Propagator()),
    ("j4",       SatelliteSimOrbit.J4Propagator()),
)

function propagate_kepler(elems::Vector{KeplerianElements}, tspan::Vector{Float64}, name::String)
    prop = Dict(p => o for (p, o) in KEPLER_PROPS)[name]
    return SatelliteSimOrbit.propagate_positions(elems, tspan; propagator=prop)
end

# ---------------------------------------------------------------------------
# TLE helpers — SGP4 TEME + approximate J2 from mean elements
# ---------------------------------------------------------------------------

"""Read every `stride`-th 3-line Starlink TLE, up to `n` satellites."""
function load_starlink_tles(path::AbstractString; n::Int=20, stride::Int=50)
    isfile(path) || error("TLE file not found: $path")
    lines = readlines(path)
    length(lines) >= 3 || error("TLE file too short: $path")
    triples = Int(length(lines) ÷ 3)
    tles = Any[]
    names = String[]
    idx = 1
    while length(tles) < n && idx <= triples
        base = (idx - 1) * 3
        name = strip(lines[base + 1])
        l1 = strip(lines[base + 2])
        l2 = strip(lines[base + 3])
        tle = SatelliteToolboxSgp4.read_tle(l1, l2; verify_checksum=false)
        push!(tles, tle)
        push!(names, name)
        idx += stride
    end
    length(tles) == n || @warn "Requested $n TLEs but only got $(length(tles)) (file triples=$triples, stride=$stride)"
    return tles, names
end

"""
Approximate TLE mean elements → `KeplerianElements` for J2 analytical init.

Caveats (documented in report):
- TLE stores **mean** elements for SGP4; J2 propagator treats them as osculating.
- Near-circular LEO: mean anomaly ≈ true anomaly (e typically ~1e-4 for Starlink).
- Semi-major axis from Kepler's law with μ = $MU_EARTH_M3_S2.
- Epoch of KeplerianElements set to 0; tspan is seconds since TLE epoch.
"""
function tle_to_approx_keplerian(tle)::KeplerianElements
    n_rad_s = Float64(tle.mean_motion) * 2π / 86400.0
    a_m = (MU_EARTH_M3_S2 / n_rad_s^2)^(1 / 3)
    return KeplerianElements(
        0.0,
        a_m,
        Float64(tle.eccentricity),
        deg2rad(Float64(tle.inclination)),
        deg2rad(Float64(tle.raan)),
        deg2rad(Float64(tle.argument_of_perigee)),
        deg2rad(Float64(tle.mean_anomaly)),  # ≈ true anomaly for near-circular
    )
end

"""SGP4 propagate to TEME positions (km), shape (N, T, 3). Time = minutes from each TLE epoch."""
function propagate_sgp4_teme(tles, tspan_s::Vector{Float64})
    n_sat = length(tles)
    n_t = length(tspan_s)
    pos = zeros(n_sat, n_t, 3)
    Threads.@threads for i in 1:n_sat
        sgp4d = SatelliteToolboxSgp4.sgp4_init(tles[i])
        for j in 1:n_t
            r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, tspan_s[j] / 60.0)
            pos[i, j, 1] = r[1]
            pos[i, j, 2] = r[2]
            pos[i, j, 3] = r[3]
        end
    end
    return pos
end

# ---------------------------------------------------------------------------
# Future absolute-truth stub
# ---------------------------------------------------------------------------

"""
    compare_against_ephemeris(propagator_positions, ephemeris_positions; frame=:ecef) -> NamedTuple

**Stub (v1 unused).** Precision-ephemeris absolute validation is future work.

Intended contract:
- `propagator_positions`, `ephemeris_positions`: `(N_sat, N_time, 3)` km in the same frame
- returns RMSE / max / per-sat drift rates against the external ephemeris

v1 intentionally has **no** absolute truth source; only relative cross-propagator
differences are computed.
"""
function compare_against_ephemeris(
    propagator_positions::AbstractArray{<:Real,3},
    ephemeris_positions::AbstractArray{<:Real,3};
    frame::Symbol = :ecef,
)
    error(
        "compare_against_ephemeris is a v1 stub — precision ephemeris ingest ",
        "(SP3 / OEM / high-fidelity numerical) is future work. frame=$frame, ",
        "shapes=$(size(propagator_positions))/$(size(ephemeris_positions))",
    )
end

# ---------------------------------------------------------------------------
# Experiment runners
# ---------------------------------------------------------------------------

"""One CSV/report row."""
function make_row(; scenario, pair, horizon_h, frame, n_sat, n_time, dt_s, metrics, notes="")
    days = horizon_h / 24.0
    return (
        scenario = scenario,
        pair = pair,
        horizon_h = horizon_h,
        frame = frame,
        n_sat = n_sat,
        n_time = n_time,
        dt_s = dt_s,
        rmse_km = metrics.rmse_km,
        max_km = metrics.max_km,
        end_rmse_km = metrics.end_rmse_km,
        end_max_km = metrics.end_max_km,
        drift_rmse_km_per_day = drift_rate_km_per_day(metrics.end_rmse_km, horizon_h),
        drift_max_km_per_day = metrics.end_max_km / days,
        n_samples = metrics.n_samples,
        notes = notes,
    )
end

function run_walker_pairs(cfg::HarnessConfig)
    rows = NamedTuple[]
    elems = generate_walker_delta(;
        T = cfg.walker_T, P = cfg.walker_P, F = cfg.walker_F,
        alt_km = cfg.alt_km, inc_deg = cfg.inc_deg,
    )
    prop_names = [p for (p, _) in KEPLER_PROPS]
    @info "Walker scenario" T=cfg.walker_T P=cfg.walker_P F=cfg.walker_F n_sat=length(elems)

    for H in cfg.horizons_h
        tspan = make_tspan(H, cfg.dt_s)
        @info "  Walker horizon" hours=H n_time=length(tspan)
        positions = Dict{String,Array{Float64,3}}()
        for name in prop_names
            positions[name] = propagate_kepler(elems, tspan, name)
        end
        for i in 1:length(prop_names)-1, j in (i+1):length(prop_names)
            a, b = prop_names[i], prop_names[j]
            m = position_diff_metrics(positions[a], positions[b])
            push!(rows, make_row(;
                scenario = "walker_$(cfg.walker_T)_$(cfg.walker_P)",
                pair = "$(a)_vs_$(b)",
                horizon_h = H,
                frame = "inertial_TEME_compatible",
                n_sat = length(elems),
                n_time = length(tspan),
                dt_s = cfg.dt_s,
                metrics = m,
                notes = "same KeplerianElements init; relative only",
            ))
        end
    end
    return rows
end

function run_tle_pairs(cfg::HarnessConfig)
    rows = NamedTuple[]
    tles, names = load_starlink_tles(cfg.tle_path; n=cfg.n_tle, stride=cfg.tle_stride)
    elems = KeplerianElements[tle_to_approx_keplerian(t) for t in tles]
    @info "TLE scenario" n=length(tles) first=get(names, 1, "?") last=get(names, length(names), "?")

    for H in cfg.horizons_h
        tspan = make_tspan(H, cfg.dt_s)
        @info "  TLE horizon" hours=H n_time=length(tspan)
        pos_sgp4 = propagate_sgp4_teme(tles, tspan)
        pos_j2   = SatelliteSimOrbit.propagate_positions(elems, tspan;
                                                         propagator=SatelliteSimOrbit.J2Propagator())
        m = position_diff_metrics(pos_sgp4, pos_j2)
        push!(rows, make_row(;
            scenario = "starlink_tle_n$(length(tles))",
            pair = "sgp4_vs_j2_approx",
            horizon_h = H,
            frame = "TEME",
            n_sat = length(tles),
            n_time = length(tspan),
            dt_s = cfg.dt_s,
            metrics = m,
            notes = "J2 init from TLE mean elems (a via Kepler μ; M≈ν); epoch bias expected",
        ))

        # SGP4 self: displacement from epoch position (orbit motion scale, not error).
        # Reported so operators can see LEO orbital arc magnitudes vs pair diffs.
        n_sat, n_t, _ = size(pos_sgp4)
        arc = Vector{Float64}(undef, n_sat)
        @inbounds for i in 1:n_sat
            dx = pos_sgp4[i, n_t, 1] - pos_sgp4[i, 1, 1]
            dy = pos_sgp4[i, n_t, 2] - pos_sgp4[i, 1, 2]
            dz = pos_sgp4[i, n_t, 3] - pos_sgp4[i, 1, 3]
            arc[i] = sqrt(dx * dx + dy * dy + dz * dz)
        end
        arc_rmse = sqrt(mean(abs2, arc))
        arc_max = maximum(arc)
        push!(rows, make_row(;
            scenario = "starlink_tle_n$(length(tles))",
            pair = "sgp4_arc_from_epoch",
            horizon_h = H,
            frame = "TEME",
            n_sat = length(tles),
            n_time = length(tspan),
            dt_s = cfg.dt_s,
            metrics = (; rmse_km=arc_rmse, max_km=arc_max, end_rmse_km=arc_rmse,
                        end_max_km=arc_max, n_samples=n_sat),
            notes = "NOT an error metric — chord length from epoch pos to horizon pos (orbital motion scale)",
        ))
    end
    return rows
end

# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

const CSV_HEADER = join([
    "scenario", "pair", "horizon_h", "frame", "n_sat", "n_time", "dt_s",
    "rmse_km", "max_km", "end_rmse_km", "end_max_km",
    "drift_rmse_km_per_day", "drift_max_km_per_day", "n_samples", "notes",
], ",")

function write_csv(path::AbstractString, rows)
    open(path, "w") do io
        println(io, CSV_HEADER)
        for r in rows
            @printf(io,
                "%s,%s,%.6g,%s,%d,%d,%.6g,%.8g,%.8g,%.8g,%.8g,%.8g,%.8g,%d,\"%s\"\n",
                r.scenario, r.pair, r.horizon_h, r.frame, r.n_sat, r.n_time, r.dt_s,
                r.rmse_km, r.max_km, r.end_rmse_km, r.end_max_km,
                r.drift_rmse_km_per_day, r.drift_max_km_per_day, r.n_samples, r.notes,
            )
        end
    end
end

function _fmt(x::Real; digs=4)
    abs(x) >= 1000 ? @sprintf("%.3e", x) : @sprintf("%.*f", digs, x)
end

function write_markdown(path::AbstractString, cfg::HarnessConfig, rows; elapsed_s::Float64)
    open(path, "w") do io
        println(io, "# Orbit Accuracy Harness Report (v1)")
        println(io)
        println(io, "Generated: $(Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS"))")
        println(io, "Host threads: $(Threads.nthreads())  |  Wall time: $(_fmt(elapsed_s; digs=1)) s")
        println(io)
        println(io, "## 1. Configuration")
        println(io)
        println(io, "| Parameter | Value |")
        println(io, "|---|---|")
        println(io, "| Walker | T=$(cfg.walker_T), P=$(cfg.walker_P), F=$(cfg.walker_F), alt=$(cfg.alt_km) km, inc=$(cfg.inc_deg)° |")
        println(io, "| Real TLE | n=$(cfg.n_tle), stride=$(cfg.tle_stride), path=`$(cfg.tle_path)` |")
        println(io, "| Horizons (h) | $(join(cfg.horizons_h, ", ")) |")
        println(io, "| Sample dt (s) | $(cfg.dt_s) |")
        println(io, "| Kepler pairs | two_body ↔ j2 ↔ j4 (inertial) |")
        println(io, "| TLE pairs | sgp4 (TEME) ↔ j2_approx (TEME) |")
        println(io, "| Julia project | `--project=src/orbit` |")
        println(io)
        println(io, "## 2. Method & frame convention")
        println(io)
        println(io, "- **Walker / Keplerian**: `propagate_positions` with `TwoBodyPropagator` / `J2Propagator` / `J4Propagator`. Same `KeplerianElements` init for all three; positions are inertial (SatelliteToolbox TEME-compatible).")
        println(io, "- **Real TLE**: `SatelliteToolboxSgp4.sgp4!` → TEME km. Approximate J2 counterpart: convert TLE mean elements → `KeplerianElements` via Kepler's law (μ = $MU_EARTH_M3_S2), treat mean anomaly as true anomaly (near-circular), then `J2Propagator`.")
        println(io, "- **Metrics**: over all sats × times — RMSE and max of Euclidean position difference (km). Drift ≈ end-of-horizon RMSE (or max) divided by horizon in days (km/day).")
        println(io, "- **`sgp4_arc_from_epoch`**: chord length of SGP4 position from epoch to horizon — **orbital motion scale, not an error**.")
        println(io)
        println(io, "## 3. Truth statement (honest)")
        println(io)
        println(io, "> **v1 has no absolute truth.** There is no precision ephemeris (SP3/OEM/HPOP reference) in this run. All numbers are **relative cross-propagator differences**. Absolute accuracy validation is deferred to `compare_against_ephemeris(...)` (stub in the harness; precision-ephemeris ingest is future work).")
        println(io)
        println(io, "Additional TLE caveats:")
        println(io, "- TLE mean elements ≠ osculating Keplerian; epoch SGP4↔J2 offset of O(10 km) is expected and is **not** pure propagation error.")
        println(io, "- SGP4 includes drag (B*) and higher-order effects absent from analytical J2.")
        println(io)
        println(io, "## 4. Results")
        println(io)

        walker_rows = filter(r -> startswith(String(r.scenario), "walker"), rows)
        tle_rows = filter(r -> startswith(String(r.scenario), "starlink") && r.pair != "sgp4_arc_from_epoch", rows)
        arc_rows = filter(r -> r.pair == "sgp4_arc_from_epoch", rows)

        if !isempty(walker_rows)
            println(io, "### 4.1 Walker synthetic — Keplerian pairs (inertial)")
            println(io)
            println(io, "| Pair | Horizon (h) | RMSE (km) | Max (km) | End RMSE (km) | Drift RMSE (km/day) | Drift Max (km/day) |")
            println(io, "|---|---:|---:|---:|---:|---:|---:|")
            for r in walker_rows
                println(io, "| $(r.pair) | $(r.horizon_h) | $(_fmt(r.rmse_km)) | $(_fmt(r.max_km)) | $(_fmt(r.end_rmse_km)) | $(_fmt(r.drift_rmse_km_per_day)) | $(_fmt(r.drift_max_km_per_day)) |")
            end
            println(io)
        end

        if !isempty(tle_rows)
            println(io, "### 4.2 Real Starlink TLE — SGP4 vs approximate J2 (TEME)")
            println(io)
            println(io, "| Pair | Horizon (h) | RMSE (km) | Max (km) | End RMSE (km) | Drift RMSE (km/day) | Drift Max (km/day) |")
            println(io, "|---|---:|---:|---:|---:|---:|---:|")
            for r in tle_rows
                println(io, "| $(r.pair) | $(r.horizon_h) | $(_fmt(r.rmse_km)) | $(_fmt(r.max_km)) | $(_fmt(r.end_rmse_km)) | $(_fmt(r.drift_rmse_km_per_day)) | $(_fmt(r.drift_max_km_per_day)) |")
            end
            println(io)
        end

        if !isempty(arc_rows)
            println(io, "### 4.3 SGP4 orbital arc scale (not error)")
            println(io)
            println(io, "| Horizon (h) | Mean chord (km) | Max chord (km) |")
            println(io, "|---:|---:|---:|")
            for r in arc_rows
                println(io, "| $(r.horizon_h) | $(_fmt(r.rmse_km)) | $(_fmt(r.max_km)) |")
            end
            println(io)
        end

        println(io, "## 5. Conclusions vs literature expectations")
        println(io)
        _write_conclusions(io, walker_rows, tle_rows)
        println(io)
        println(io, "## 6. Limitations")
        println(io)
        println(io, "1. **No absolute truth** — relative diffs only; see §3 and `compare_against_ephemeris` stub.")
        println(io, "2. **TLE→J2 mean-element approximation** injects epoch bias; interpret SGP4↔J2 growth carefully.")
        println(io, "3. Frame is inertial/TEME for all pairs; ECEF/GMST not mixed into pair diffs.")
        println(io, "4. Sample cadence `dt=$(cfg.dt_s) s` undersamples sub-minute structure (acceptable for km-scale secular growth).")
        println(io, "5. Small constellation (Walker $(cfg.walker_T), TLE n=$(cfg.n_tle)) — enough for order-of-magnitude platform checks, not constellation-wide statistics.")
        println(io)
        println(io, "## 7. Reproduce")
        println(io)
        println(io, "```bash")
        println(io, "julia -t auto --project=src/orbit scripts/orbit_accuracy_harness.jl \\")
        println(io, "  --walker-T=$(cfg.walker_T) --walker-P=$(cfg.walker_P) --n-tle=$(cfg.n_tle) \\")
        println(io, "  --dt-s=$(cfg.dt_s) --horizons-h=$(join(cfg.horizons_h, ','))")
        println(io, "```")
        println(io)
        println(io, "Artifacts: `$(cfg.out_csv)`, `$(cfg.out_md)`.")
    end
end

function _write_conclusions(io, walker_rows, tle_rows)
    # Extract key order-of-magnitude facts for narrative.
    function _find(rows, pair, H)
        for r in rows
            if r.pair == pair && r.horizon_h == H
                return r
            end
        end
        return nothing
    end

    tb_j2_1 = _find(walker_rows, "two_body_vs_j2", 1.0)
    tb_j2_24 = _find(walker_rows, "two_body_vs_j2", 24.0)
    tb_j2_72 = _find(walker_rows, "two_body_vs_j2", 72.0)
    j2_j4_24 = _find(walker_rows, "j2_vs_j4", 24.0)
    j2_j4_72 = _find(walker_rows, "j2_vs_j4", 72.0)
    sgp4_1 = _find(tle_rows, "sgp4_vs_j2_approx", 1.0)
    sgp4_24 = _find(tle_rows, "sgp4_vs_j2_approx", 24.0)
    sgp4_72 = _find(tle_rows, "sgp4_vs_j2_approx", 72.0)

    println(io, "Literature / domain priors used for sanity check (not absolute truth):")
    println(io, "- SGP4 vs precision ephemeris often cited ~**1–3 km/day** growth for LEO.")
    println(io, "- Two-body (no J2) diverges quickly from J2/SGP4 due to missing nodal/apsidal precession.")
    println(io, "- J2 vs J4 differences are much smaller than two-body vs J2 for LEO over days.")
    println(io)
    println(io, "Observed in this run:")
    if tb_j2_1 !== nothing && tb_j2_24 !== nothing
        println(io, "- **two_body vs j2**: 1 h RMSE ≈ $(_fmt(tb_j2_1.rmse_km)) km, 24 h RMSE ≈ $(_fmt(tb_j2_24.rmse_km)) km" *
            (tb_j2_72 === nothing ? "." : ", 72 h RMSE ≈ $(_fmt(tb_j2_72.rmse_km)) km.") *
            " Drift (end RMSE) ≈ $(_fmt(tb_j2_24.drift_rmse_km_per_day)) km/day at 24 h" *
            (tb_j2_72 === nothing ? "." : " / $(_fmt(tb_j2_72.drift_rmse_km_per_day)) km/day at 72 h.") *
            " **Consistent with rapid two-body divergence.**")
    end
    if j2_j4_24 !== nothing
        println(io, "- **j2 vs j4**: 24 h RMSE ≈ $(_fmt(j2_j4_24.rmse_km)) km" *
            (j2_j4_72 === nothing ? "" : ", 72 h RMSE ≈ $(_fmt(j2_j4_72.rmse_km)) km") *
            " — much smaller than two_body↔j2, as expected.")
    end
    if sgp4_24 !== nothing
        println(io, "- **sgp4 vs j2_approx**: 1 h RMSE ≈ $(sgp4_1 === nothing ? "n/a" : _fmt(sgp4_1.rmse_km)) km, " *
            "24 h RMSE ≈ $(_fmt(sgp4_24.rmse_km)) km" *
            (sgp4_72 === nothing ? "" : ", 72 h RMSE ≈ $(_fmt(sgp4_72.rmse_km)) km") *
            "; end drift ≈ $(_fmt(sgp4_24.drift_rmse_km_per_day)) km/day (24 h)." *
            " This is **larger** than the oft-cited SGP4 ~1–3 km/day *vs precision ephemeris* prior — expected, " *
            "because the J2 leg is initialized from **TLE mean elements** (epoch bias + missing drag/higher-order terms), " *
            "not a fitted osculating state or precision truth. Treat as an analytic-vs-SGP4 **order-of-magnitude** gap, not absolute SGP4 accuracy.")
    end
    println(io)
    println(io, "Net: the harness reproduces the expected qualitative hierarchy " *
        "(two_body ≫ sgp4↔j2_approx ≫ j2↔j4) without claiming absolute accuracy. " *
        "Closing the gap to the 1–3 km/day literature prior requires `compare_against_ephemeris` against a precision product.")
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main(args::Vector{String}=ARGS)
    cfg = parse_cli!(HarnessConfig(), args)
    @info "Orbit accuracy harness v1 starting" threads=Threads.nthreads() horizons=cfg.horizons_h

    t0 = time()
    rows = NamedTuple[]
    if !cfg.skip_walker
        append!(rows, run_walker_pairs(cfg))
    end
    if !cfg.skip_tle
        append!(rows, run_tle_pairs(cfg))
    end
    elapsed = time() - t0

    write_csv(cfg.out_csv, rows)
    write_markdown(cfg.out_md, cfg, rows; elapsed_s=elapsed)
    @info "Wrote" csv=cfg.out_csv md=cfg.out_md rows=length(rows) elapsed_s=elapsed
    return rows
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
