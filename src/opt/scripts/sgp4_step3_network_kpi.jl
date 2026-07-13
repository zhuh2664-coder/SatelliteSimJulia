#!/usr/bin/env julia
# =============================================================================
# Step 3 real-scale experiment: real Starlink TLE → SGP4 ECEF series →
# network KPI end-to-end gradient (θ = 7N orbital elements → network KPI).
#
#   • Connectivity  (soft algebraic connectivity λ₂) at large N via the
#     tape-free eigenvalue-perturbation VJP (scales to the full constellation).
#   • Latency       (soft expected end-to-end latency, ms) via Enzyme dL/dP.
#
# Reports for each: loss, ‖grad‖, timing, per-parameter-class scaled sensitivity
# ‖xⱼ ⊙ ∂L/∂xⱼ‖₂, and a hard reference (exact λ₂ via eigvals / Dijkstra latency).
#
# Config via env: SATSIM_CONN_N (default 1584), SATSIM_CONN_NT (4),
#   SATSIM_LAT_N (200), SATSIM_LAT_NT (6), SATSIM_TLE_PATH.
# Standalone (does not include test/). Run with `--threads=auto`.
# =============================================================================
using LinearAlgebra
using Printf
using SatelliteToolbox
using SatelliteToolboxSgp4
using SatelliteSimOpt: sgp4_series_ecef, sgp4_network_kpi_gradient,
                       network_kpi_config, network_kpi_loss, default_od_pairs,
                       soft_connectivity_loss_vjp, network_kpi_loss_grad_positions,
                       soft_algebraic_connectivity, soft_expected_latency_ms,
                       soft_isl_adjacency, hard_isl_adjacency, dijkstra_latency

const D2R = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)
const TLE_PATH = get(ENV, "SATSIM_TLE_PATH",
    joinpath(@__DIR__, "..", "..", "..", "data", "tle", "celestrak", "starlink_gp_latest.tle"))
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
    return params, epochs, n
end

# Scaled sensitivity per orbital-element class: ‖xⱼ ⊙ ∂L/∂xⱼ‖₂ (dimensionless).
function class_sensitivity(params, grad, N)
    out = Dict{String,Float64}()
    for c in 1:7
        idxs = c:7:(7N)
        out[CLASSES[c]] = norm(params[idxs] .* grad[idxs])
    end
    return out
end

function median_pairwise(pos)
    N = size(pos, 1)
    ds = Float64[]
    for i in 1:N, j in (i+1):N
        push!(ds, sqrt((pos[i,1,1]-pos[j,1,1])^2 + (pos[i,1,2]-pos[j,1,2])^2 + (pos[i,1,3]-pos[j,1,3])^2))
    end
    return sort(ds)[max(1, length(ds) ÷ 2)]
end

function print_sensitivity(sens)
    ks = sort(collect(keys(sens)); by = k -> -sens[k])
    println("  scaled sensitivity ‖xⱼ·∂L/∂xⱼ‖₂ (desc):")
    for k in ks
        @printf("    %-3s = %.4e\n", k, sens[k])
    end
end

# ── Connectivity λ₂ at large N (perturbation VJP) ─────────────────────────────
function run_connectivity()
    N = parse(Int, get(ENV, "SATSIM_CONN_N", "1584"))
    NT = parse(Int, get(ENV, "SATSIM_CONN_NT", "4"))
    params, epochs, N = read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 90.0; length=NT))
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]

    pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    dmed = median_pairwise(pos)
    d_thresh = 5500.0
    τ = 200.0; fiedler_K = parse(Int, get(ENV, "SATSIM_CONN_K", "1500"))
    println("="^78)
    @printf("CONNECTIVITY λ₂  N=%d NT=%d  d_thresh=%.0f km (median pair %.0f km) τ=%.0f K=%d\n",
            N, NT, d_thresh, dmed, τ, fiedler_K)

    # warm + timed forward series
    sgp4_series_ecef(params[1:7], epochs[1:1], ts_min, gmsts; jd_ref=jd_ref)
    t_series = @elapsed pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)

    cfg = network_kpi_config(N, NT; kind=:connectivity, d_thresh=d_thresh, τ=τ, fiedler_K=fiedler_K)
    # warm dL/dP
    soft_connectivity_loss_vjp(pos, network_kpi_config(min(N,8), NT; kind=:connectivity,
        d_thresh=d_thresh, τ=τ, fiedler_K=10))
    t_vjp = @elapsed (lossP, dP) = soft_connectivity_loss_vjp(pos, cfg)

    t_total = @elapsed (loss, grad) = sgp4_network_kpi_gradient(params, epochs, ts_min;
        jd_ref=jd_ref, gmsts=gmsts, engine=:blockdiag, kind=:connectivity,
        d_thresh=d_thresh, τ=τ, fiedler_K=fiedler_K)

    @printf("  loss (−mean λ₂) = %.9f   mean λ₂ = %.6f   ‖grad‖ = %.6e\n",
            loss, -loss, norm(grad))
    @printf("  finite grad = %s  (n=%d)\n", string(all(isfinite, grad)), length(grad))
    @printf("  timing: series=%.3fs  dL/dP(perturb)=%.3fs  total grad=%.3fs\n",
            t_series, t_vjp, t_total)
    print_sensitivity(class_sensitivity(params, grad, N))

    # hard reference: exact λ₂ (eigvals) at the first time slice
    try
        A = soft_isl_adjacency(pos[:, 1, :]; d_thresh=d_thresh, τ=τ)
        d = vec(sum(A; dims=2))
        L = Diagonal(d) - A
        t_eig = @elapsed ev = sort(eigvals(Symmetric(Matrix(L))))
        λ2_exact = ev[2]
        λ2_soft = soft_algebraic_connectivity(pos[:, 1:1, :]; d_thresh=d_thresh, τ=τ, fiedler_K=fiedler_K)
        @printf("  hard ref (t=1): exact λ₂=%.6f  power-iter λ₂=%.6f  relerr=%.2e  gap(λ₃−λ₂)=%.3e  (eig %.1fs)\n",
                λ2_exact, λ2_soft, abs(λ2_soft - λ2_exact)/abs(λ2_exact), ev[3]-ev[2], t_eig)
    catch e
        println("  hard ref (eigvals) skipped: ", sprint(showerror, e))
    end
    return nothing
end

# ── Latency at moderate N (Enzyme dL/dP) ──────────────────────────────────────
function run_latency()
    N = parse(Int, get(ENV, "SATSIM_LAT_N", "200"))
    NT = parse(Int, get(ENV, "SATSIM_LAT_NT", "6"))
    params, epochs, N = read_params_epochs(N)
    jd_ref = maximum(epochs)
    ts_min = collect(range(0.0, 90.0; length=NT))
    gmsts = Float64[SatelliteToolbox.jd_to_gmst(jd_ref + t / 1440.0) for t in ts_min]

    pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    dmed = median_pairwise(pos)
    d_thresh = 1.15 * dmed
    τ = 400.0; τsp = 80.0; bellman_K = 24
    od = default_od_pairs(N; count=16)
    println("="^78)
    @printf("LATENCY (soft ms)  N=%d NT=%d  d_thresh=%.0f km (median pair %.0f km) τ=%.0f τsp=%.0f K=%d  |od|=%d\n",
            N, NT, d_thresh, dmed, τ, τsp, bellman_K, length(od))

    kw = (d_thresh=d_thresh, τ=τ, τsp=τsp, bellman_K=bellman_K, penalty_km=5.0e5)
    cfg = network_kpi_config(N, NT; kind=:latency, od_pairs=od, kw...)

    t_series = @elapsed pos = sgp4_series_ecef(params, epochs, ts_min, gmsts; jd_ref=jd_ref)
    # warm
    network_kpi_loss_grad_positions(pos, cfg)
    t_dP = @elapsed (lossP, dP) = network_kpi_loss_grad_positions(pos, cfg)
    t_total = @elapsed (loss, grad) = sgp4_network_kpi_gradient(params, epochs, ts_min;
        jd_ref=jd_ref, gmsts=gmsts, engine=:blockdiag, kind=:latency, od_pairs=od, kw...)

    @printf("  loss (mean soft latency) = %.6f ms   ‖grad‖ = %.6e\n", loss, norm(grad))
    @printf("  finite grad = %s  (n=%d)\n", string(all(isfinite, grad)), length(grad))
    @printf("  timing: series=%.3fs  dL/dP(Enzyme)=%.3fs  total grad=%.3fs\n",
            t_series, t_dP, t_total)
    print_sensitivity(class_sensitivity(params, grad, N))

    # hard reference: Dijkstra mean latency on the hard adjacency (t=1), same OD
    try
        Ah = hard_isl_adjacency(pos[:, 1, :]; d_thresh=d_thresh)
        lat_hard, n_unreach = dijkstra_latency(Ah; od_pairs=[(s, d) for (s, d) in od])
        soft_ms_t1 = soft_expected_latency_ms(pos[:, 1:1, :]; od_pairs=od, kw...)
        mean_hard = isempty(lat_hard) ? NaN : sum(lat_hard) / length(lat_hard)
        @printf("  hard ref (t=1): Dijkstra mean latency=%.4f ms over %d/%d reachable OD;  soft=%.4f ms\n",
                mean_hard, length(lat_hard), length(od), soft_ms_t1)
    catch e
        println("  hard ref (Dijkstra) skipped: ", sprint(showerror, e))
    end
    return nothing
end

function main()
    @printf("Step 3 network-KPI experiment | threads=%d | TLE=%s\n", Threads.nthreads(), TLE_PATH)
    run_connectivity()
    run_latency()
    println("="^78)
    println("STEP3_DONE")
end

main()
