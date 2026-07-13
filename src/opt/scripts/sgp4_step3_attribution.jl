#!/usr/bin/env julia
# =============================================================================
# Step 3 minimal "gradient-as-attribution" demo:
#
#   real Starlink TLE → SGP4 ECEF series →
#   L = coverage_loss + weighted soft-network KPI → ∂L/∂(7N TLE parameters)
#
# The seven reported scores are local scaled sensitivities
# ‖x_class ⊙ ∂L/∂x_class‖₂. They are useful attribution diagnostics, not causal
# effects. The script checks one central-FD component per class plus a random
# directional derivative before printing STEP3_ATTRIBUTION_OK.
# =============================================================================
using LinearAlgebra: dot, norm
using Printf
using Random
using SatelliteToolbox
using SatelliteToolboxSgp4
using SatelliteSimOpt: coverage_loss, default_od_pairs, ground_grid,
                       network_kpi_loss, sgp4_e2e_gradient,
                       sgp4_network_kpi_gradient, sgp4_series_ecef

const D2R = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)
const TLE_PATH = get(ENV, "SATSIM_TLE_PATH",
    joinpath(@__DIR__, "..", "..", "..", "data", "tle", "celestrak", "starlink_gp_latest.tle"))
const CLASSES = ("n₀", "e", "i", "Ω", "ω", "M", "B*")
const W_LAT = 1.0e-3
const W_REACH = 0.25
const W_CONN = 1.0

function read_params_epochs(n::Int)
    isfile(TLE_PATH) || error("TLE file not found: $TLE_PATH")
    lines = readlines(TLE_PATH)
    n = min(n, length(lines) ÷ 3)
    n >= 2 || error("the attribution demo needs at least two TLE records")
    tles = SatelliteToolboxSgp4.TLE[]
    for i in 1:n
        push!(tles, SatelliteToolboxSgp4.read_tle(
            strip(lines[3i - 1]), strip(lines[3i]); verify_checksum=false,
        ))
    end
    epochs = Float64[SatelliteToolboxSgp4.tle_epoch(t) for t in tles]
    params = Float64[]
    for t in tles
        append!(params, (
            t.mean_motion * REV_DAY_TO_RAD_MIN, t.eccentricity,
            t.inclination * D2R, t.raan * D2R,
            t.argument_of_perigee * D2R, t.mean_anomaly * D2R, t.bstar,
        ))
    end
    return params, epochs, n
end

function median_pairwise_distance(P)
    ds = Float64[
        norm(P[i, 1, :] .- P[j, 1, :])
        for i in 1:size(P, 1) for j in (i + 1):size(P, 1)
    ]
    return sort!(ds)[max(1, length(ds) ÷ 2)]
end

function class_sensitivities(params, grad, N)
    return [norm(params[c:7:(7N)] .* grad[c:7:(7N)]) for c in 1:7]
end

function composite_loss(p, epochs, ts_min, gmsts, jd_ref, gp, weights, od, dt, net_kw)
    T = eltype(p)
    P = sgp4_series_ecef(p, epochs, ts_min, T.(gmsts); jd_ref=jd_ref)
    loss_cov = coverage_loss(
        P, T.(gp), T.(weights);
        min_el=T(10.0), τ_cov=T(5.0), dt=T(dt), τ_revisit=T(1.0), λ=T(0.1),
    )
    loss_net = network_kpi_loss(
        P; kind=:combined, od_pairs=od,
        w_lat=W_LAT, w_reach=W_REACH, w_conn=W_CONN, net_kw...,
    )
    return loss_cov + loss_net
end

function main()
    N_req = parse(Int, get(ENV, "SATSIM_ATTR_N", "8"))
    NT = parse(Int, get(ENV, "SATSIM_ATTR_NT", "4"))
    NT >= 1 || error("SATSIM_ATTR_NT must be positive")
    params, epochs, N = read_params_epochs(N_req)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 60.0; length=NT))
    dt = NT > 1 ? ts_min[2] - ts_min[1] : 1.0
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]
    gp, weights = ground_grid(4, 8)
    od = default_od_pairs(N; count=min(N, 4))

    P0 = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    dmed = median_pairwise_distance(P0)
    net_kw = (
        d_thresh=1.15 * dmed, τ=400.0, τsp=60.0, bellman_K=N,
        fiedler_K=400, penalty_km=5.0e5,
    )

    println("="^78)
    @printf("Step 3 attribution | N=%d NT=%d dt=%.1f min threads=%d\n",
            N, NT, dt, Threads.nthreads())
    println("  TLE: ", TLE_PATH)
    @printf("  L = L_cov + L_net; L_net = %.0e·latency − %.2f·reachability − %.1f·λ₂\n",
            W_LAT, W_REACH, W_CONN)

    elapsed = @elapsed begin
        loss_cov, grad_cov = sgp4_e2e_gradient(
            params, epochs, ts_min, gp, weights;
            jd_ref=jd_ref, gmsts=gmsts, engine=:blockdiag, dt=dt,
        )
        loss_net, grad_net = sgp4_network_kpi_gradient(
            params, epochs, ts_min;
            jd_ref=jd_ref, gmsts=gmsts, engine=:blockdiag, kind=:combined,
            od_pairs=od, w_lat=W_LAT, w_reach=W_REACH, w_conn=W_CONN, net_kw...,
        )
        loss = loss_cov + loss_net
        grad = grad_cov + grad_net
    end

    finite = isfinite(loss) && all(isfinite, grad) && norm(grad) > 0
    @printf("  L_cov=%.6f L_net=%.6f L=%.6f ‖grad‖=%.6e finite=%s time=%.3fs\n",
            loss_cov, loss_net, loss, norm(grad), string(finite), elapsed)
    finite || error("loss/gradient must be finite and nonzero")

    scores = class_sensitivities(params, grad, N)
    ranking = sortperm(scores; rev=true)
    println("  scaled local sensitivity (non-causal), descending:")
    for c in ranking
        @printf("    %-3s = %.4e\n", CLASSES[c], scores[c])
    end
    println("  most sensitive class: ", CLASSES[first(ranking)])

    loss_fn(p) = composite_loss(
        p, epochs, ts_min, gmsts, jd_ref, gp, weights, od, dt, net_kw,
    )
    gscale = maximum(abs, grad)
    bstar_scale = maximum(abs, params[7:7:end])
    fd_max = 0.0
    for c in 1:7
        idxs = collect(c:7:length(params))
        idx = idxs[argmax(abs.(grad[idxs]))]
        h0 = c == 7 ?
            1e-4 * max(abs(params[idx]), max(bstar_scale, 1e-5)) :
            1e-6 * max(abs(params[idx]), 1e-2)
        floor = c == 7 ? 1e-8 * gscale + 1e-12 : 1e-10 * gscale + 1e-12
        best = Inf
        for scale in (0.1, 1.0, 10.0)
            h = scale * h0
            xp = copy(params); xm = copy(params)
            xp[idx] += h; xm[idx] -= h
            gfd = (loss_fn(xp) - loss_fn(xm)) / (2h)
            best = min(best, abs(grad[idx] - gfd) / (abs(gfd) + floor))
        end
        fd_max = max(fd_max, best)
        @printf("  FD %-3s best_relerr=%.3e\n", CLASSES[c], best)
        best < (c == 7 ? 5e-3 : 1e-3) ||
            error("FD mismatch for $(CLASSES[c]): best_relerr=$best")
    end

    Random.seed!(42)
    direction = randn(length(params))
    direction ./= norm(direction)
    direction .*= max.(abs.(params), 1e-2)
    hdir = 1e-6
    dd_ad = dot(grad, direction)
    dd_fd = (
        loss_fn(params .+ hdir .* direction) -
        loss_fn(params .- hdir .* direction)
    ) / (2hdir)
    dd_rel = abs(dd_ad - dd_fd) / (abs(dd_fd) + 1e-12)
    @printf("  FD summary max_class_relerr=%.3e directional_relerr=%.3e\n",
            fd_max, dd_rel)
    dd_rel < 1e-3 || error("directional derivative mismatch: relerr=$dd_rel")

    println("="^78)
    println("STEP3_ATTRIBUTION_OK")
end

main()
