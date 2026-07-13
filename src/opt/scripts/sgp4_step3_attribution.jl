#!/usr/bin/env julia
# =============================================================================
# Minimal "gradient-as-attribution" demo for Step3 differentiable network KPIs.
#
# Uses a small number of real Starlink TLEs to show how a scalar network KPI
# attributes its sensitivity back to the seven orbital-element classes of the
# TLE parameter vector. Scaled sensitivity is ‖xⱼ ⊙ ∂L/∂xⱼ‖₂ (dimensionless),
# which reflects both the magnitude of the parameter and the gradient.
#
# Standalone: run with `--project=src/opt` (no heavy env required).
# =============================================================================
using LinearAlgebra
using Printf
using SatelliteToolbox
using SatelliteToolboxSgp4
using SatelliteSimOpt: sgp4_series_ecef, sgp4_network_kpi_gradient,
                       network_kpi_config, default_od_pairs

const D2R = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)
const TLE_PATH = joinpath(@__DIR__, "..", "..", "..",
                          "data", "tle", "celestrak", "starlink_gp_latest.tle")
const CLASSES = ("n₀", "e", "i", "Ω", "ω", "M", "B*")

function read_params_epochs(n::Int)
    lines = readlines(TLE_PATH)
    avail = length(lines) ÷ 3
    n = min(n, avail)
    tles = SatelliteToolboxSgp4.TLE[]
    for i in 1:n
        push!(tles, SatelliteToolboxSgp4.read_tle(strip(lines[3i-1]), strip(lines[3i]);
                                                  verify_checksum=false))
    end
    epochs = Float64[SatelliteToolboxSgp4.tle_epoch(t) for t in tles]
    params = Float64[]
    for t in tles
        append!(params, (t.mean_motion * REV_DAY_TO_RAD_MIN, t.eccentricity,
                         t.inclination * D2R, t.raan * D2R,
                         t.argument_of_perigee * D2R, t.mean_anomaly * D2R, t.bstar))
    end
    return params, epochs
end

function class_sensitivities(params, grad, N)
    sens = Dict{String,Float64}()
    total = 0.0
    for c in 1:7
        idxs = c:7:(7N)
        val = norm(params[idxs] .* grad[idxs])
        sens[CLASSES[c]] = val
        total += val
    end
    rel = total > 0 ? Dict(k => v / total for (k, v) in sens) :
                      Dict(k => 0.0 for k in keys(sens))
    return sens, rel
end

function print_sensitivities(params, grad, N, title)
    sens, rel = class_sensitivities(params, grad, N)
    println("  $title scaled sensitivity (‖xⱼ·∂L/∂xⱼ‖₂):")
    for k in sort(collect(keys(sens)); by = k -> -sens[k])
        @printf("    %-3s  %.4e  (%.2f%%)\n", k, sens[k], 100 * rel[k])
    end
    return sens
end

function main()
    N, NT = 8, 3
    params, epochs = read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 60.0; length = NT))
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    od = default_od_pairs(N; count = 4)

    println("SGP4 Step3 minimal attribution demo | N=$N NT=$NT | TLE=$TLE_PATH")
    println("=" ^ 78)

    # Connectivity: −mean algebraic connectivity λ₂
    loss_conn, grad_conn = sgp4_network_kpi_gradient(
        params, epochs, ts_min; jd_ref = jd_ref, gmsts = gmsts,
        engine = :blockdiag, kind = :connectivity,
        d_thresh = 9000.0, τ = 300.0, fiedler_K = 400,
    )
    @printf("CONNECTIVITY  loss(−mean λ₂) = %.6f   ‖grad‖ = %.6e\n",
            loss_conn, norm(grad_conn))
    print_sensitivities(params, grad_conn, N, "connectivity")

    # Latency: soft expected end-to-end latency (ms)
    kw = (d_thresh = 9000.0, τ = 300.0, τsp = 60.0, bellman_K = N, penalty_km = 5.0e5)
    loss_lat, grad_lat = sgp4_network_kpi_gradient(
        params, epochs, ts_min; jd_ref = jd_ref, gmsts = gmsts,
        engine = :blockdiag, kind = :latency, od_pairs = od, kw...
    )
    @printf("\nLATENCY       loss(ms) = %.6f   ‖grad‖ = %.6e\n",
            loss_lat, norm(grad_lat))
    print_sensitivities(params, grad_lat, N, "latency")

    println("=" ^ 78)
    println("STEP3_ATTRIBUTION_DONE")
end

main()
