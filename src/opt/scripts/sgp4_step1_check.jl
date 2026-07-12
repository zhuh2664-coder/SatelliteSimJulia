#!/usr/bin/env julia
# Step 1 smoke check: real Starlink TLE → SGP4 ECEF series → coverage loss gradient.
# Standalone script for Modal mirror; must not include test/ files.

using LinearAlgebra: norm
using SatelliteToolbox
using SatelliteToolboxSgp4
using SatelliteSimOpt: sgp4_series_ecef, sgp4_e2e_gradient, coverage_loss, ground_grid

const D2R = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)
const TLE_PATH = get(ENV, "SATSIM_TLE_PATH",
    joinpath(@__DIR__, "..", "..", "..", "data", "tle", "celestrak", "starlink_gp_latest.tle"))

function read_starlink_params_epochs(n::Int)
    lines = readlines(TLE_PATH)
    tles = SatelliteToolboxSgp4.TLE[]
    for i in 1:n
        l1 = strip(lines[3i - 1])
        l2 = strip(lines[3i])
        push!(tles, SatelliteToolboxSgp4.read_tle(l1, l2; verify_checksum=false))
    end
    epochs = [SatelliteToolboxSgp4.tle_epoch(t) for t in tles]
    params = Float64[]
    for t in tles
        append!(params, [
            t.mean_motion * REV_DAY_TO_RAD_MIN,
            t.eccentricity,
            t.inclination * D2R,
            t.raan * D2R,
            t.argument_of_perigee * D2R,
            t.mean_anomaly * D2R,
            t.bstar,
        ])
    end
    return params, epochs
end

function main()
    N = 10
    NT = 10
    params0, epochs = read_starlink_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 95.0; length=NT))
    gmsts = [SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    gp, w = ground_grid(5, 10)
    loss, grad = sgp4_e2e_gradient(params0, epochs, ts_min, gp, w;
                                   gmsts=gmsts, jd_ref=jd_ref,
                                   min_el=10.0, τ_cov=5.0, dt=1.0,
                                   τ_revisit=1.0, λ=0.1)

    finite = isfinite(loss) && all(isfinite, grad)
    if !finite
        println("STEP1 fail: loss or grad not finite")
        exit(1)
    end
    println("STEP1 loss=$(loss) grad_norm=$(norm(grad)) finite=true")

    function loss_from_params(p)
        T = eltype(p)
        pos = sgp4_series_ecef(p, epochs, ts_min, T.(gmsts); jd_ref=jd_ref)
        return coverage_loss(pos, T.(gp), T.(w);
                             min_el=T(10.0), τ_cov=T(5.0), dt=T(1.0),
                             τ_revisit=T(1.0), λ=T(0.1))
    end

    n_check = min(20, length(grad))
    idxs = partialsortperm(abs.(grad), 1:n_check; rev=true)
    relerrs = Float64[]
    for idx in idxs
        h = 1e-6 * max(abs(params0[idx]), 1e-2)
        xp = copy(params0); xm = copy(params0)
        xp[idx] += h; xm[idx] -= h
        g_fd = (loss_from_params(xp) - loss_from_params(xm)) / (2h)
        g_ad = grad[idx]
        push!(relerrs, abs(g_ad - g_fd) / (abs(g_fd) + 1e-12))
    end
    fd_max = maximum(relerrs)
    println("STEP1 fd_max_relerr=$(fd_max) n_checked=$(n_check)")

    if fd_max >= 1e-3
        println("STEP1 fail: fd_max_relerr $(fd_max) >= 1e-3")
        exit(1)
    end
    println("STEP1_OK")
end

main()
